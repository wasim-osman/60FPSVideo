import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// A source that makes its own frames, so the pipeline can be tested without a
/// decoder being installed.
///
/// Each frame is a distinct, deterministic pattern: a horizontal ramp whose offset
/// advances with the frame index, over a constant chroma. Two properties matter.
/// Every frame is different, so a frame delivered at the wrong position is visible.
/// And the ramp is smooth, so the engine has something real to interpolate rather
/// than a degenerate constant.
final class SyntheticFrameSource: FrameSource, @unchecked Sendable {

    let info: MediaInfo
    let frameByteSize: Int

    private let width: Int
    private let height: Int
    private let format: FrameFormat
    private let totalFrames: Int
    private var framesRead = 0
    private var closed = false

    init(width: Int, height: Int, format: FrameFormat, frameRate: FrameRate,
         totalFrames: Int) {
        self.width = width
        self.height = height
        self.format = format
        self.totalFrames = totalFrames
        self.frameByteSize = format.packedByteSize(width: width, height: height)
        self.info = MediaInfo(
            url: URL(fileURLWithPath: "/dev/null"),
            width: width, height: height, frameRate: frameRate,
            frameCount: totalFrames,
            duration: Double(totalFrames) / frameRate.doubleValue,
            pixelFormat: format == .p010 ? "p010le" : "nv12", format: format,
            colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
            colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
            audioCodec: nil, audioChannels: nil)
    }

    /// The pattern for one frame, as packed bytes. Deterministic, so a test can
    /// regenerate it and compare.
    func packedFrame(_ index: Int) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: frameByteSize)
        let sampleWidth = format.bytesPerSample
        let lumaCode = format.bitDepth == 10 ? 64 : 16
        let range = format.bitDepth == 10 ? 876 : 219

        frame.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for y in 0..<height {
                for x in 0..<width {
                    // A diagonal ramp that shifts by one pixel per frame, wrapped.
                    let value = (x + y + index * 7) % range
                    let code = lumaCode + value
                    if sampleWidth == 1 {
                        (base + y * width + x).storeBytes(of: UInt8(code), as: UInt8.self)
                    } else {
                        // P010: the 10-bit code lives in the top ten bits of a
                        // 16-bit little-endian word.
                        (base + y * width * 2 + x * 2)
                            .storeBytes(of: UInt16(code << 6).littleEndian, as: UInt16.self)
                    }
                }
            }
            // Neutral chroma everywhere: the luma ramp is what the tests read.
            let chromaCode = format.bitDepth == 10 ? 512 : 128
            let chromaBase = base + width * height * sampleWidth
            let chromaBytes = width * (height / 2) * sampleWidth
            if sampleWidth == 1 {
                memset(chromaBase, Int32(chromaCode), chromaBytes)
            } else {
                for i in 0..<(width * (height / 2)) {
                    (chromaBase + i * 2)
                        .storeBytes(of: UInt16(chromaCode << 6).littleEndian, as: UInt16.self)
                }
            }
        }
        return frame
    }

    func read(into destination: UnsafeMutableRawPointer) throws -> Bool {
        guard !closed, framesRead < totalFrames else { return false }
        let frame = packedFrame(framesRead)
        _ = frame.withUnsafeBytes { memcpy(destination, $0.baseAddress!, frameByteSize) }
        framesRead += 1
        return true
    }

    func close() { closed = true }
}

/// A source frame pair travelling onto another thread.
private struct BorrowedPair: @unchecked Sendable {
    let a: CVPixelBuffer
    let b: CVPixelBuffer
}

/// An engine that reads the buffers it was handed, later, on another thread.
///
/// This is what makes invariant 17 testable. `VTFrameProcessor` reads its source
/// buffers asynchronously, and the bug was that the caller refilled a slot while a
/// request still held it — so the engine interpolated a mix of old and new frame
/// data. The damage is disguised as success, which is why it took a while to find.
///
/// Reading after a delay, on a background thread, reproduces exactly that race. A
/// pipeline that respects the per-slot semaphore produces observations that all
/// match the source; one that does not produces a mix.
final class RecordingEngine: InterpolationEngine, @unchecked Sendable {

    let name = "recording"
    let maximumInterpolationsPerInterval: Int
    let depth: Int

    private let width: Int
    private let height: Int
    private let format: FrameFormat
    private let readDelayMicroseconds: UInt32

    private let lock = NSLock()
    private var observations: [(interval: Int, a: [UInt8], b: [UInt8])] = []
    private var inFlight = 0
    private var peakInFlight = 0
    private let semaphore = DispatchSemaphore(value: 0)
    private var firstError: Error?
    private var prepared = false

    init(width: Int, height: Int, format: FrameFormat,
         maximumInterpolationsPerInterval: Int, depth: Int,
         readDelayMicroseconds: UInt32 = 20_000) {
        self.width = width
        self.height = height
        self.format = format
        self.maximumInterpolationsPerInterval = maximumInterpolationsPerInterval
        self.depth = depth
        self.readDelayMicroseconds = readDelayMicroseconds
    }

    func prepare(width: Int, height: Int) throws {
        prepared = true
    }

    func submit(_ request: InterpolationRequest) {
        lock.lock()
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        lock.unlock()

        let interval = request.interval.sourceIndex
        // `CVPixelBuffer` carries no Sendable conformance; this states the borrow
        // the same way `InterpolationRequest` does, and for the same reason — the
        // whole test is about whether that borrow is respected.
        let borrowed = BorrowedPair(a: request.sourceA, b: request.sourceB)

        // Read later, off this thread: the whole point is to look at the buffers
        // after the caller has had a chance to reuse them.
        let delay = readDelayMicroseconds
        Thread.detachNewThread { [weak self] in
            usleep(delay)
            guard let self else { return }
            let aBytes = self.snapshot(borrowed.a)
            let bBytes = self.snapshot(borrowed.b)

            self.lock.lock()
            self.observations.append((interval, aBytes, bBytes))
            self.inFlight -= 1
            self.lock.unlock()
            self.semaphore.signal()

            request.completion(.success(()))
        }
    }

    private func snapshot(_ buffer: CVPixelBuffer) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: format.packedByteSize(width: width,
                                                                      height: height))
        bytes.withUnsafeMutableBytes { raw in
            format.store(buffer: buffer, into: raw.baseAddress!, width: width, height: height)
        }
        return bytes
    }

    func drain() throws {
        lock.lock()
        while inFlight > 0 {
            lock.unlock()
            semaphore.wait()
            lock.lock()
        }
        let error = firstError
        lock.unlock()
        if let error { throw error }
    }

    func shutdown() {}

    /// Every observation, ordered by the interval that produced it.
    var observed: [(interval: Int, a: [UInt8], b: [UInt8])] {
        lock.lock(); defer { lock.unlock() }
        return observations.sorted { $0.interval < $1.interval }
    }

    var peakConcurrentRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return peakInFlight
    }

    var submittedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observations.count
    }
}

@Suite("InterpolationPipeline")
struct InterpolationPipelineTests {

    private static let width = 128
    private static let height = 96
    private static let sourceRate = FrameRate.parse("23.976")!
    private static let outputRate = FrameRate.parse("59.94")!

    private func makeSource(frames: Int, format: FrameFormat = .nv12) -> SyntheticFrameSource {
        SyntheticFrameSource(width: Self.width, height: Self.height, format: format,
                             frameRate: Self.sourceRate, totalFrames: frames)
    }

    // MARK: - Invariant 17, the reason the loop was extracted

    @Test("a slot is never refilled while a request still holds it")
    func slotsAreNotClobberedWhileBorrowed() throws {
        // This is the regression test for the bug that produced 378 wrong frames out
        // of 475 while reporting success. The engine reads the buffers it was handed
        // 20 ms later on another thread; the pipeline runs straight past it. If a
        // slot were reused before its request completed, the observation would show
        // a later interval's frame.
        let frames = 24
        let source = makeSource(frames: frames)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(depth: 2,
                                                                  sceneDetection: false))
        let report = try pipeline.run(into: sink)
        #expect(report.problems.isEmpty)

        let observed = engine.observed
        #expect(!observed.isEmpty, "the engine should have been called")

        var wrong: [String] = []
        for observation in observed {
            let expectedA = source.packedFrame(observation.interval)
            let expectedB = source.packedFrame(observation.interval + 1)
            if observation.a != expectedA {
                wrong.append("interval \(observation.interval): sourceA is not frame "
                             + "\(observation.interval)")
            }
            if observation.b != expectedB {
                wrong.append("interval \(observation.interval): sourceB is not frame "
                             + "\(observation.interval + 1)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(4).joined(separator: "; "))")
    }

    @Test("the engine is never asked to hold more than its depth")
    func concurrencyIsBounded() throws {
        let source = makeSource(frames: 30)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 3)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(depth: 3,
                                                                  sceneDetection: false))
        _ = try pipeline.run(into: sink)
        #expect(engine.peakConcurrentRequests <= 3,
                "peak in flight was \(engine.peakConcurrentRequests), depth is 3")
    }

    // MARK: - The plan is the plan

    @Test("the output frames are exactly the ones the plan calls for")
    func outputMatchesThePlan() throws {
        let frames = 47
        let source = makeSource(frames: frames)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: false))
        let report = try pipeline.run(into: sink)

        let expected = PhasePlan(sourceFrameCount: frames, source: Self.sourceRate,
                                 output: Self.outputRate)!
        #expect(report.outputFrames == expected.outputFrameCount)
        #expect(report.passthroughFrames == expected.passthroughCount)
        #expect(report.interpolatedFrames == expected.interpolatedCount)
        #expect(sink.count == expected.outputFrameCount)
        #expect(sink.ordered.map(\.index) == Array(0..<expected.outputFrameCount))
    }

    @Test("a passthrough frame is byte-identical to the source frame it names")
    func passthroughsAreExact() throws {
        // The strongest property in the pipeline and the one that needs no engine to
        // be correct: a frame the plan calls a passthrough must come out of the sink
        // as the source frame, bit for bit. Everything else is a comparison against
        // a reference implementation; this is a comparison against ground truth.
        let frames = 47
        let source = makeSource(frames: frames)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: false))
        _ = try pipeline.run(into: sink)

        let plan = PhasePlan(sourceFrameCount: frames, source: Self.sourceRate,
                             output: Self.outputRate)!
        var checked = 0
        var mismatches: [Int] = []
        for frame in plan.frames {
            guard case .passthrough(let sourceIndex) = frame.kind else { continue }
            checked += 1
            guard let got = sink.frame(at: frame.index) else {
                mismatches.append(frame.index); continue
            }
            if got != source.packedFrame(sourceIndex) { mismatches.append(frame.index) }
        }
        #expect(checked > 0)
        #expect(mismatches.isEmpty,
                "passthrough frames \(mismatches.prefix(6)) do not match the source")
    }

    @Test("the sink is told the geometry before the first frame")
    func geometryIsDelivered() throws {
        let source = makeSource(frames: 6)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: false))
        _ = try pipeline.run(into: sink)

        let geometry = try #require(sink.receivedGeometry)
        #expect(geometry.width == Self.width)
        #expect(geometry.height == Self.height)
        #expect(geometry.format == .nv12)
        #expect(geometry.sourceRate == Self.sourceRate)
        #expect(geometry.outputRate == Self.outputRate)
        #expect(geometry.sourceFrameCount == 6)
    }

    // MARK: - Short and degenerate sources

    @Test("a source with fewer than two frames produces nothing and does not hang")
    func tooShortSources() throws {
        // Two frames is the minimum for an interval. One frame, or none, has to end
        // cleanly — and critically it must not deadlock waiting on a slot whose
        // completion will never arrive.
        for frames in [0, 1, 2] {
            let source = makeSource(frames: frames)
            let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                         maximumInterpolationsPerInterval: 5, depth: 2,
                                         readDelayMicroseconds: 0)
            let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
            let pipeline = InterpolationPipeline(source: source,
                                                 sourceRate: Self.sourceRate,
                                                 outputRate: Self.outputRate,
                                                 engine: engine,
                                                 configuration: .init(sceneDetection: false))
            let report = try pipeline.run(into: sink)
            let expected = frames >= 2 ? 3 : 0   // 23.976 -> 59.94 over one interval is 3 frames
            #expect(report.outputFrames == expected,
                    "\(frames) source frames should give \(expected) output frames")
            #expect(report.problems.isEmpty)
        }
    }

    @Test("a maximum frame count stops the run where it is asked to")
    func frameLimitIsHonoured() throws {
        let source = makeSource(frames: 100)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: false,
                                                                  maximumSourceFrames: 11))
        let report = try pipeline.run(into: sink)
        #expect(report.sourceFrames == 11)
        let expected = PhasePlan(sourceFrameCount: 11, source: Self.sourceRate,
                                 output: Self.outputRate)!
        #expect(report.outputFrames == expected.outputFrameCount)
    }

    @Test("the run stops at the source's own end, with no frame count up front")
    func stopsAtEndOfSource() throws {
        // The property that makes this usable for a Matroska file and for playback:
        // nothing is told how long the source is. It stops when the source stops.
        let source = makeSource(frames: 37)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: false))
        let report = try pipeline.run(into: sink)
        #expect(report.sourceFrames == 37)
        #expect(report.outputFrames == 90, "36 intervals at 2.5x")
    }

    // MARK: - Rates and refusals

    @Test("an output rate below the source rate is refused")
    func outputBelowSourceIsRefused() {
        let source = makeSource(frames: 10)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: FrameRate.parse("60")!,
                                             outputRate: FrameRate.parse("24")!)
        #expect(throws: InterpolationPipelineError.self) {
            try pipeline.run(into: MemoryFrameSink(width: Self.width, height: Self.height,
                                                   format: .nv12))
        }
    }

    @Test("a pipeline runs once")
    func singleUse() throws {
        // `run` closes the source and shuts the engine down, so a second call would
        // silently do nothing. The precondition makes that loud instead.
        let source = makeSource(frames: 6)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: false))
        _ = try pipeline.run(into: sink)
        #expect(engine.submittedCount > 0)
    }

    // MARK: - Scene detection, through the pipeline

    @Test("scene detection turns a cut interval's interpolations into passthroughs")
    func sceneDetectionIsApplied() throws {
        // The pipeline is handed a source that is a hard cut halfway through: every
        // frame before the cut is one pattern, every frame after it is a different
        // one. The detector should find it, and the interpolations in that interval
        // should come out as passthroughs.
        let source = CutFrameSource(width: Self.width, height: Self.height, format: .nv12,
                                    frameRate: Self.sourceRate,
                                    totalFrames: 24, cutAfter: 12)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)

        let withDetection = InterpolationPipeline(
            source: source, sourceRate: Self.sourceRate, outputRate: Self.outputRate,
            engine: engine, configuration: .init(sceneDetection: true))
        let detected = try withDetection.run(into: sink)

        #expect(detected.decisions.count == 23, "one verdict per interval")
        let cuts = detected.cutIntervals
        #expect(cuts.contains(12), "the cut is between frames 12 and 13, got \(cuts)")
        #expect(detected.cutCount >= 1)

        // Without detection the same source produces more interpolations, because
        // the cut interval is interpolated across. That difference is the whole
        // reason detection exists.
        let source2 = CutFrameSource(width: Self.width, height: Self.height, format: .nv12,
                                     frameRate: Self.sourceRate,
                                     totalFrames: 24, cutAfter: 12)
        let engine2 = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                      maximumInterpolationsPerInterval: 5, depth: 2,
                                      readDelayMicroseconds: 0)
        let sink2 = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let withoutDetection = InterpolationPipeline(
            source: source2, sourceRate: Self.sourceRate, outputRate: Self.outputRate,
            engine: engine2, configuration: .init(sceneDetection: false))
        let plain = try withoutDetection.run(into: sink2)

        #expect(detected.interpolatedFrames < plain.interpolatedFrames)
        #expect(detected.passthroughFrames > plain.passthroughFrames)
        #expect(detected.outputFrames == plain.outputFrames,
                "detection changes what a frame is, never how many there are")
    }
}

/// A source that changes abruptly at a chosen frame, so there is a real cut to find.
final class CutFrameSource: FrameSource, @unchecked Sendable {

    let info: MediaInfo
    let frameByteSize: Int

    private let width: Int
    private let height: Int
    private let format: FrameFormat
    private let totalFrames: Int
    private let cutAfter: Int
    private var framesRead = 0
    private var closed = false

    init(width: Int, height: Int, format: FrameFormat, frameRate: FrameRate,
         totalFrames: Int, cutAfter: Int) {
        self.width = width
        self.height = height
        self.format = format
        self.totalFrames = totalFrames
        self.cutAfter = cutAfter
        self.frameByteSize = format.packedByteSize(width: width, height: height)
        self.info = MediaInfo(
            url: URL(fileURLWithPath: "/dev/null"),
            width: width, height: height, frameRate: frameRate,
            frameCount: totalFrames,
            duration: Double(totalFrames) / frameRate.doubleValue,
            pixelFormat: "nv12", format: format,
            colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
            colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
            audioCodec: nil, audioChannels: nil)
    }

    func packedFrame(_ index: Int) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: frameByteSize)
        // Two shots with nothing in common: a bright ramp, then a dark inverse ramp
        // with an obvious block structure. A cut between them is about as clear as a
        // cut gets.
        let inFirstShot = index <= cutAfter
        frame.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for y in 0..<height {
                for x in 0..<width {
                    let code: Int
                    if inFirstShot {
                        code = 200 - ((x + y) % 40)
                    } else {
                        let block = ((x / 16) + (y / 16)) % 2
                        code = 20 + block * 30
                    }
                    (base + y * width + x).storeBytes(of: UInt8(code), as: UInt8.self)
                }
            }
            memset(base + width * height, 128, width * (height / 2))
        }
        return frame
    }

    func read(into destination: UnsafeMutableRawPointer) throws -> Bool {
        guard !closed, framesRead < totalFrames else { return false }
        let frame = packedFrame(framesRead)
        _ = frame.withUnsafeBytes { memcpy(destination, $0.baseAddress!, frameByteSize) }
        framesRead += 1
        return true
    }

    func close() { closed = true }
}
