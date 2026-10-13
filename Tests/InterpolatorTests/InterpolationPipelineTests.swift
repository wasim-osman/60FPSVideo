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
    /// The film-wide number of the first frame this source yields.
    ///
    /// Zero for a whole-film run. A segmented run seeks its source to the segment's
    /// read start, so its "first frame" is not the film's — which is exactly the
    /// distinction ``InterpolationPipeline/Window`` exists to carry.
    private let firstFrame: Int
    /// The film-wide number after which the picture changes completely.
    ///
    /// The default pattern is a diagonal ramp that shifts seven code values per frame — a
    /// smooth pan, which is exactly what the scene detector should *not* call a cut. Setting
    /// this inverts the ramp from that frame on, which is a hard discontinuity in both the
    /// histogram and the grid, so the detector calls it. Tests need that because a cut is
    /// the one thing that makes the pipeline skip an interval outright, and the submission
    /// order depends on it.
    private let cutAfter: Int?
    private var framesRead = 0
    private var closed = false

    init(width: Int, height: Int, format: FrameFormat, frameRate: FrameRate,
         totalFrames: Int, firstFrame: Int = 0, cutAfter: Int? = nil) {
        self.width = width
        self.height = height
        self.format = format
        self.totalFrames = totalFrames
        self.firstFrame = firstFrame
        self.cutAfter = cutAfter
        self.frameByteSize = format.packedByteSize(width: width, height: height)
        self.info = MediaInfo(
            url: URL(fileURLWithPath: "/dev/null"),
            width: width, height: height, frameRate: frameRate,
            frameCount: totalFrames,
            duration: Double(totalFrames) / frameRate.doubleValue,
            pixelFormat: format == .p010 ? "p010le" : "nv12", format: format,
            colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
            colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
            audioTracks: [], chapterCount: 0)
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
                    // A diagonal ramp that shifts by one pixel per frame, wrapped. Past
                    // `cutAfter` the ramp is inverted, which is a discontinuity the scene
                    // detector reads as a cut.
                    let ramp = (x + y + index * 7) % range
                    let value = (cutAfter.map { index > $0 } ?? false) ? range - 1 - ramp : ramp
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
        let frame = packedFrame(firstFrame + framesRead)
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
    private var recordedOrder: SubmissionOrder?

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

    /// Recorded rather than ignored, because getting this wrong is silent: the run
    /// completes, the frame count is right, and the picture is wrong. A double that
    /// swallows it cannot fail the test that catches that.
    func setSubmissionOrder(_ order: SubmissionOrder) {
        lock.lock(); recordedOrder = order; lock.unlock()
    }

    var submissionOrder: SubmissionOrder? {
        lock.lock(); defer { lock.unlock() }
        return recordedOrder
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

            // **Invariant 23, in the double as well as in the engine.** The caller's
            // completion runs *before* this request is retired from the depth
            // accounting. `drain()` returns as soon as `inFlight` reaches zero, so a
            // double that retired first would let the pipeline finalise its output
            // while a completion — the one that writes the last frames — was still
            // running. The real engine gets this right (`VTFrameProcessorEngine` runs
            // the completion at line 159 and retires afterwards); this double used to
            // signal first, which is the same bug wearing a test's clothes.
            //
            // It hid for a long time because the gap between the two statements is
            // normally microseconds. Under a full parallel suite the thread gets
            // descheduled in that gap, the pipeline returns early, and a handful of
            // frames never reach the sink — which is exactly the flake it produced.
            request.completion(.success(()))

            self.lock.lock()
            self.observations.append((interval, aBytes, bBytes))
            self.inFlight -= 1
            self.lock.unlock()
            self.semaphore.signal()
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

    private func makeSource(frames: Int, format: FrameFormat = .nv12,
                            firstFrame: Int = 0) -> SyntheticFrameSource {
        SyntheticFrameSource(width: Self.width, height: Self.height, format: format,
                             frameRate: Self.sourceRate, totalFrames: frames,
                             firstFrame: firstFrame)
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

    // MARK: - A run that renders a piece of the film rather than all of it

    /// Renders one segment of a plan, the way a segmented job does: a source seeked to the
    /// segment's read start, `maximumSourceFrames` set to what it reads, and a window naming
    /// which of the frames it reads are its own to render.
    private func runSegment(_ segment: SegmentPlan.Segment,
                            makeSource: (Int, Int) -> SyntheticFrameSource)
        throws -> (report: InterpolationPipeline.Report,
                   sink: MemoryFrameSink,
                   source: SyntheticFrameSource) {
        let frameSource = makeSource(segment.readStart, segment.readCount)
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(
            source: frameSource,
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: engine,
            configuration: .init(
                sceneDetection: false,
                maximumSourceFrames: segment.readCount,
                expectedOutputFrameCount: segment.outputCount,
                window: .init(segment: segment)))
        let report = try pipeline.run(into: sink)
        return (report, sink, frameSource)
    }

    @Test("a windowed run produces its segment's frames, numbered from zero")
    func windowedRunProducesItsSegment() throws {
        let frames = 200
        let plan = try #require(SegmentPlan(sourceFrameCount: frames,
                                            source: Self.sourceRate,
                                            output: Self.outputRate,
                                            targetSourceFrames: 30))
        for segment in plan.segments {
            let (report, sink, _) = try runSegment(segment) { start, count in
                makeSource(frames: count, firstFrame: start)
            }
            let detail = "\(segment.description)"
            #expect(report.outputFrames == segment.outputCount, "\(detail)")
            // Its file starts at zero, whatever the segment's place in the film is.
            #expect(sink.count == segment.outputCount, "\(detail)")
            #expect(sink.ordered.map(\.index) == Array(0..<segment.outputCount), "\(detail)")
            #expect(sink.problems.isEmpty, "\(detail)")
            #expect(report.problems.isEmpty, "\(detail)")
        }
    }

    @Test("a windowed run renders only its own intervals, not all the frames it reads")
    func windowedRunRendersOnlyItsOwn() throws {
        // The whole point of the lead-in and lead-out: a segment reads 33 more frames than
        // it renders intervals for, and must not emit a single output frame for them.
        let frames = 200
        let plan = try #require(SegmentPlan(sourceFrameCount: frames,
                                            source: Self.sourceRate,
                                            output: Self.outputRate,
                                            targetSourceFrames: 30))
        let interior = try #require(plan.segments.dropLast().dropFirst().first)
        #expect(interior.leadIn > 0, "this segment needs a real lead-in to be a test")

        let (report, sink, _) = try runSegment(interior) { start, count in
            makeSource(frames: count, firstFrame: start)
        }
        // If the context were rendered, the count would be the read count's worth of
        // intervals rather than the segment's own.
        #expect(report.outputFrames == interior.outputCount)
        #expect(sink.count == interior.outputCount)
        // And the whole plan's segments still add up to the film.
        #expect(plan.outputFrameCount == PhasePlan(sourceFrameCount: frames,
                                                   source: Self.sourceRate,
                                                   output: Self.outputRate)!.outputFrameCount)
    }

    /// Ground truth, not a comparison against a second implementation. A frame the global
    /// plan calls a passthrough has to come out of a segment's own file as the source frame
    /// the plan names — and the plan name comes from the film-wide output index, which is
    /// exactly what a run without a window would get wrong.
    @Test("a windowed run's passthrough frames are the source frames the film names")
    func windowedPassthroughsAreExact() throws {
        let frames = 200
        let planner = IntervalPlanner(source: Self.sourceRate, output: Self.outputRate)
        let plan = try #require(SegmentPlan(sourceFrameCount: frames,
                                            source: Self.sourceRate,
                                            output: Self.outputRate,
                                            targetSourceFrames: 30))
        let reference = SyntheticFrameSource(width: Self.width, height: Self.height,
                                             format: .nv12, frameRate: Self.sourceRate,
                                             totalFrames: frames)

        var checked = 0
        for segment in plan.segments {
            let (_, sink, _) = try runSegment(segment) { start, count in
                makeSource(frames: count, firstFrame: start)
            }
            for local in 0..<segment.outputCount {
                let global = segment.outputStart + local
                guard planner.isPassthrough(outputIndex: global) else { continue }
                let expected = reference.packedFrame(planner.interval(forOutputIndex: global))
                let got = sink.frame(at: local)
                #expect(got == expected,
                        "segment \(segment.index) local frame \(local) is film frame \(global), which the plan makes a passthrough")
                checked += 1
            }
        }
        // Every passthrough the film has was checked, not merely some of them. A magic
        // threshold would pass while the loop silently skipped most of its work.
        let expected = try #require(PhasePlan(sourceFrameCount: frames,
                                              source: Self.sourceRate,
                                              output: Self.outputRate))
        #expect(checked == expected.passthroughCount,
                "\(checked) passthroughs checked against the film's \(expected.passthroughCount)")
    }

    /// The reason the margins exist, as a test.
    ///
    /// The cut is placed on the last interval of a segment, which is the one the lead-out
    /// protects: without it the tracker would hit the end of its source and call
    /// `finish()`, and the final interval would be judged with the forward half of the
    /// flash guard unavailable — a different verdict from the one the same interval gets
    /// mid-film.
    @Test("a cut on a segment's last interval is judged as it is mid-film")
    func cutOnASegmentBoundaryIsJudgedTheSame() throws {
        let frames = 63
        // Target 20 puts a boundary at interval 20, so interval 19 — the cut — is the last
        // interval of segment 0. (20 is already a multiple of the phase period, so it is
        // not rounded up; 21 would become 22 and land the boundary one interval late.)
        let cutAt = 19
        let plan = try #require(SegmentPlan(sourceFrameCount: frames,
                                            source: Self.sourceRate,
                                            output: Self.outputRate,
                                            targetSourceFrames: 20))
        let first = try #require(plan.segments.first)
        #expect(first.intervalEnd == cutAt + 1,
                "the cut must land on the segment's last interval for this to test anything, but the segment ends at \(first.intervalEnd)")

        // What the whole film decides.
        let wholeSource = CutFrameSource(width: Self.width, height: Self.height,
                                         format: .nv12, frameRate: Self.sourceRate,
                                         totalFrames: frames, cutAfter: cutAt)
        let wholeSink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let whole = try InterpolationPipeline(
            source: wholeSource,
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: true)).run(into: wholeSink)
        #expect(whole.cutIntervals == [cutAt], "the film should find the cut: \(whole.cutIntervals)")

        // What that segment decides on its own.
        let segmentSource = CutFrameSource(width: Self.width, height: Self.height,
                                           format: .nv12, frameRate: Self.sourceRate,
                                           totalFrames: first.readCount,
                                           cutAfter: cutAt,
                                           firstFrame: first.readStart)
        let segmentSink = MemoryFrameSink(width: Self.width, height: Self.height,
                                          format: .nv12)
        let part = try InterpolationPipeline(
            source: segmentSource,
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: true,
                                 maximumSourceFrames: first.readCount,
                                 expectedOutputFrameCount: first.outputCount,
                                 window: .init(segment: first))).run(into: segmentSink)

        // The segment's decisions are numbered from its read start, so they are shifted back
        // to the film's numbering before being compared.
        let shifted = part.cutIntervals.map { $0 + first.readStart }
        #expect(shifted == whole.cutIntervals,
                "the segment found \(shifted); the film found \(whole.cutIntervals)")
    }

    // MARK: - Skipping, which is what playback is

    /// Playback cannot render every interval and stay with its clock. At 4K an interval costs
    /// 104.7 ms against the 41.7 ms the film spends on one, so a player that rendered them all
    /// would cover 0.4 s of film per second while the sound covered 1.0. `rendersInterval` is
    /// how the player renders a subset instead — and this is the property that makes it usable:
    /// **the output contains exactly the frames of the intervals that were rendered**, not a
    /// contiguous run of them.
    @Test("a render filter decides which intervals are computed, and only those frames appear")
    func renderFilterSelectsIntervals() throws {
        let frames = 47
        let source = makeSource(frames: frames)
        let planner = IntervalPlanner(source: Self.sourceRate, output: Self.outputRate)

        // Every third interval, which is the shape a 4K player needs and not a stride a
        // count could express: the *choice* depends on the clock, and only the arithmetic
        // of which frames that implies is fixed.
        let keep: @Sendable (Int) -> Bool = { $0 % 3 == 0 }

        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let report = try InterpolationPipeline(
            source: source,
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: false, rendersInterval: keep))
            .run(into: sink)

        let expected = Set((0..<(frames - 1)).filter(keep)
            .flatMap { planner.output(forInterval: $0).map(\.index) })
        let got = Set(sink.ordered.map(\.index))
        let missing = expected.subtracting(got).sorted()
        let unexpected = got.subtracting(expected).sorted()
        #expect(got == expected,
                "missing \(missing), unexpected \(unexpected)")
        #expect(report.outputFrames == expected.count)
        #expect(report.problems.isEmpty, "\(report.problems)")

        // And the frames that *are* there are the right ones, not merely the right count —
        // every passthrough must still be the source frame the film names for it.
        var kinds: [Int: OutputFrame.Kind] = [:]
        for interval in (0..<(frames - 1)).filter(keep) {
            for frame in planner.output(forInterval: interval) { kinds[frame.index] = frame.kind }
        }
        for (index, bytes) in sink.ordered {
            guard case .passthrough(let sourceIndex) = kinds[index] else { continue }
            #expect(bytes == source.packedFrame(sourceIndex),
                    "output frame \(index) is not source frame \(sourceIndex)")
        }
    }

    @Test("with no filter, every interval is rendered — which is what batch conversion needs")
    func noFilterRendersEverything() throws {
        let frames = 47
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let report = try InterpolationPipeline(
            source: makeSource(frames: frames),
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: false)).run(into: sink)

        let plan = try #require(PhasePlan(sourceFrameCount: frames, source: Self.sourceRate,
                                          output: Self.outputRate))
        #expect(report.outputFrames == plan.outputFrameCount)
        #expect(sink.ordered.map(\.index) == Array(0..<plan.outputFrameCount),
                "a batch run must produce a contiguous output")
    }

    // MARK: - Progress

    /// Collects the interval numbers the pipeline announces.
    ///
    /// A class with a lock rather than an array captured by a closure, because the callback is
    /// `@Sendable` and arrives on the driving thread — which in these tests is the test's own
    /// thread, but the compiler is right not to take that on trust.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var numbers: [Int] = []
        func note(_ interval: Int) { lock.lock(); numbers.append(interval); lock.unlock() }
        var seen: [Int] { lock.lock(); defer { lock.unlock() }; return numbers }
    }

    @Test("progress names every interval the run reads, in order, and none twice")
    func progressCoversEveryInterval() throws {
        let frames = 47
        let log = ProgressLog()
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let report = try InterpolationPipeline(
            source: makeSource(frames: frames),
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: false,
                                 progress: { log.note($0) }))
            .run(into: sink)

        // Every interval of the film, once each, ascending. Not "one per output frame" — a
        // progress bar that counted output frames would run at 2.5× the speed of the work.
        #expect(log.seen == Array(0..<(frames - 1)),
                "got \(log.seen.count) callbacks: \(log.seen.prefix(8))…")
        #expect(report.outputFrames > log.seen.count,
                "output frames outnumber intervals on 23.976 -> 59.94")
    }

    /// The property that makes the callback usable on a resumed job: the numbers are the
    /// **film's**, so dividing by the film's length gives the same answer whether the run
    /// starts at the beginning or at piece 37. A run-local number would start at zero every
    /// time and a resumed job's bar would restart.
    @Test("a windowed run announces the film's interval numbers, not its own")
    func progressUsesTheFilmsNumbering() throws {
        let frames = 200
        let plan = try #require(SegmentPlan(sourceFrameCount: frames,
                                            source: Self.sourceRate,
                                            output: Self.outputRate,
                                            targetSourceFrames: 30))
        // A middle segment, so both a lead-in and a non-zero start are exercised.
        let segment = plan.segments[2]
        let log = ProgressLog()
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        _ = try InterpolationPipeline(
            source: makeSource(frames: segment.readCount, firstFrame: segment.readStart),
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: engine,
            configuration: .init(sceneDetection: false,
                                 maximumSourceFrames: segment.readCount,
                                 expectedOutputFrameCount: segment.outputCount,
                                 window: .init(segment: segment),
                                 progress: { log.note($0) }))
            .run(into: sink)

        let seen = log.seen
        #expect(seen.first == segment.sourceStart,
                "the first announced interval is the segment's own, not its lead-in")
        #expect(seen.last == segment.intervalEnd - 1)
        #expect(seen == Array(segment.sourceStart..<segment.intervalEnd),
                "ascending and contiguous")
        // The lead-in is read but is not the segment's to render, so it must not be announced:
        // a bar that counted it would show work the job never does.
        #expect(segment.leadIn > 0,
                "this segment must have a lead-in for the test to mean anything")
    }

    /// Progress is announced **before** the interval's work, and the reason is the last
    /// interval of the film: a run ends because the source ran out, so a callback fired on
    /// completion has nothing to fire from after the final interval, and a bar that stops at
    /// 99.4% for the length of the final segment reads as a job that hung.
    @Test("progress reaches the film's last interval, which a completion callback could not")
    func progressReachesTheLastInterval() throws {
        let frames = 12
        let log = ProgressLog()
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        _ = try InterpolationPipeline(
            source: makeSource(frames: frames),
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: false, progress: { log.note($0) }))
            .run(into: sink)

        #expect(log.seen.last == frames - 2,
                "the last interval of a \(frames)-frame source is \(frames - 2)")
        #expect(log.seen.count == frames - 1)
    }

    /// A player has no progress bar — its progress is the clock, and it already has one — so
    /// the default must cost nothing and change nothing.
    @Test("with no progress callback the run is unchanged")
    func noProgressCallbackIsFine() throws {
        let frames = 20
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let report = try InterpolationPipeline(
            source: makeSource(frames: frames),
            sourceRate: Self.sourceRate,
            outputRate: Self.outputRate,
            engine: RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                    maximumInterpolationsPerInterval: 5, depth: 2,
                                    readDelayMicroseconds: 0),
            configuration: .init(sceneDetection: false)).run(into: sink)
        #expect(report.outputFrames == sink.count)
        #expect(report.problems.isEmpty)
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
    /// The film-wide number of the first frame this source yields, so a source can stand
    /// in for one seeked to a segment's read start.
    private let firstFrame: Int
    private var framesRead = 0
    private var closed = false

    init(width: Int, height: Int, format: FrameFormat, frameRate: FrameRate,
         totalFrames: Int, cutAfter: Int, firstFrame: Int = 0) {
        self.width = width
        self.height = height
        self.format = format
        self.totalFrames = totalFrames
        self.cutAfter = cutAfter
        self.firstFrame = firstFrame
        self.frameByteSize = format.packedByteSize(width: width, height: height)
        self.info = MediaInfo(
            url: URL(fileURLWithPath: "/dev/null"),
            width: width, height: height, frameRate: frameRate,
            frameCount: totalFrames,
            duration: Double(totalFrames) / frameRate.doubleValue,
            pixelFormat: "nv12", format: format,
            colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
            colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
            audioTracks: [], chapterCount: 0)
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
        let frame = packedFrame(firstFrame + framesRead)
        _ = frame.withUnsafeBytes { memcpy(destination, $0.baseAddress!, frameByteSize) }
        framesRead += 1
        return true
    }

    func close() { closed = true }
}

// MARK: - The pool

/// A pool of sessions, and the one statement that has to be true about it.
///
/// This suite exists because the first version of the pool was **wrong in a way nothing
/// reported**. Four sessions were given a stride — 0, 4, 8, … — while each was told its
/// submissions followed one another "without jump or skip". The SDK's `SubmissionMode` is a
/// statement of fact that the processor acts on by keeping internal caches, so a false one
/// produces wrong pixels rather than slow ones. Measured on the real 4K HDR film, the run
/// completed cleanly, wrote the right number of frames, and differed from a sequential run
/// by a mean of **36 dB** (min 17 dB, 894 of 1198 frames below 40 dB) against a **58 dB**
/// control for two runs of the identical configuration.
///
/// So the order is asserted here rather than left to the call site to remember, and the
/// distribution is asserted so that "the pool is used" is a fact about the run and not a
/// hope about the code.
///
/// **The same mistake was in the single-session path, and had been since before the pool
/// existed.** The first version of this suite asserted that one session driving a whole film
/// *is* sequential, on the grounds that it is fed the intervals in order and the faster mode
/// is worth 11%. The reasoning was wrong: the pipeline never submits an interval whose frames
/// are all passthrough, and a scene cut forces exactly that, so the session's submissions have
/// a gap in them however many sessions there are. Comparing the app's own output at one
/// session against four is what made it visible — the two frames after every cut came back as
/// a plain cross-fade. That is now invariant 44.
@Suite("InterpolationPipeline — a pool of sessions")
struct InterpolationPipelinePoolTests {

    private static let width = 128
    private static let height = 96
    private static let sourceRate = FrameRate.parse("23.976")!
    private static let outputRate = FrameRate.parse("59.94")!

    private func makeSource(frames: Int) -> SyntheticFrameSource {
        SyntheticFrameSource(width: Self.width, height: Self.height, format: .nv12,
                             frameRate: Self.sourceRate, totalFrames: frames)
    }

    private func makeEngines(_ count: Int, depth: Int = 2) -> [RecordingEngine] {
        (0..<count).map { _ in
            RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                            maximumInterpolationsPerInterval: 5, depth: depth,
                            readDelayMicroseconds: 0)
        }
    }

    @Test("the work is spread across every session in the pool")
    func workIsSpreadAcrossThePool() throws {
        let frames = 40
        let engines = makeEngines(4)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: makeSource(frames: frames),
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engines: engines,
                                             configuration: .init(engines: 4,
                                                                  sceneDetection: false))
        let report = try pipeline.run(into: sink)
        #expect(report.problems.isEmpty)

        // Every interval is accounted for, exactly once, across the whole pool — which is
        // also the assertion that every session was drained. A pipeline that drained the
        // first session and returned would leave holes here.
        let counts = engines.map(\.submittedCount)
        let total = counts.reduce(0, +)
        #expect(total == report.engineCalls,
                "the pool saw \(total) intervals, the run reported \(report.engineCalls)")
        #expect(!counts.contains(0), "a session was never used: \(counts)")

        // Round robin, so the shares differ by at most one.
        #expect(counts.max()! - counts.min()! <= 1,
                "the work is not spread evenly: \(counts)")

        // And no interval was given to two sessions at once.
        let all = engines.flatMap { $0.observed.map(\.interval) }.sorted()
        #expect(all == Array(Set(all)).sorted(), "an interval was submitted twice")
    }

    @Test("a session that is one of a pool is told its submissions are not sequential")
    func aPoolIsNotSequential() throws {
        let engines = makeEngines(3)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: makeSource(frames: 24),
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engines: engines,
                                             configuration: .init(engines: 3,
                                                                  sceneDetection: false))
        _ = try pipeline.run(into: sink)
        for (index, engine) in engines.enumerated() {
            #expect(engine.submissionOrder == .random,
                    "session \(index) was told \(String(describing: engine.submissionOrder)) while being fed every third interval")
        }
    }

    @Test("one session driving a whole film is still not sequential — a cut skips an interval")
    func aSingleSessionIsStillNotSequential() throws {
        // This test used to assert the opposite, and it was wrong.
        //
        // The reasoning was: one session, no `rendersInterval` filter, so the intervals
        // arrive in presentation order and `.sequential` is true — and it is worth 13.4
        // against 12.0 source frames/s, so keep it. What that missed is the *second* way the
        // sequence breaks, and it is the one that needs no pool and no filter: **an interval
        // whose frames are all passthrough is never submitted**, and a scene cut forces
        // exactly that. Both frames either side of a cut become passthroughs, the interval is
        // skipped, and the session's next submission is a jump.
        //
        // Measured on the real 4K HDR film, the cost of that lie is visible: the two output
        // frames after every cut came back as a plain cross-fade — a double exposure — while
        // the same session told `.random` produced correct motion-compensated frames.
        let frames = 40
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let source = SyntheticFrameSource(width: Self.width, height: Self.height, format: .nv12,
                                          frameRate: Self.sourceRate, totalFrames: frames,
                                          cutAfter: frames / 2)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(sceneDetection: true))
        let report = try pipeline.run(into: sink)

        // The mechanism first, so this is not a test of a constant. A cut was found…
        #expect(report.cutCount >= 1, "the synthetic cut was not detected: \(report.decisions)")
        // …and the interval it landed in was skipped rather than submitted, which is what
        // makes the stream non-contiguous. `frames - 1` intervals exist; a run that
        // submitted every one of them would be genuinely sequential.
        #expect(report.engineCalls < frames - 1,
                "no interval was skipped (\(report.engineCalls) calls for \(frames - 1) intervals), so this test is no longer exercising the case it was written for")

        // And so the order is stated honestly.
        #expect(engine.submissionOrder == .random,
                "a single session over a film with a cut was told \(String(describing: engine.submissionOrder))")
    }

    @Test("a run that skips intervals is not sequential either")
    func aSkippingRunIsNotSequential() throws {
        // Playback's case. The pacer hands the pipeline a filter, the filter skips the
        // intervals the clock has already passed, and the submissions that reach the
        // session have gaps — so "without jump or skip" is not true of them.
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: makeSource(frames: 24),
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(
                                                sceneDetection: false,
                                                rendersInterval: { $0 % 2 == 0 }))
        _ = try pipeline.run(into: sink)
        #expect(engine.submissionOrder == .random)
    }

    @Test("the pool never asks a session for more than its depth")
    func eachSessionRespectsItsDepth() throws {
        let engines = makeEngines(3, depth: 2)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: makeSource(frames: 36),
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engines: engines,
                                             configuration: .init(depth: 2, engines: 3,
                                                                  sceneDetection: false))
        _ = try pipeline.run(into: sink)
        for (index, engine) in engines.enumerated() {
            #expect(engine.peakConcurrentRequests <= 2,
                    "session \(index) had \(engine.peakConcurrentRequests) in flight, depth 2")
        }
    }

    @Test("a pool writes exactly the frames the plan calls for")
    func aPoolProducesTheSameOutputAsOneSession() throws {
        // The property the whole change rests on: four sessions are a way of going faster,
        // not a way of producing something different. A single session's output is the
        // reference; the pool has to match it frame for frame.
        let frames = 47
        let single = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 0)
        let singleSink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let singlePipeline = InterpolationPipeline(source: makeSource(frames: frames),
                                                   sourceRate: Self.sourceRate,
                                                   outputRate: Self.outputRate,
                                                   engine: single,
                                                   configuration: .init(sceneDetection: false))
        _ = try singlePipeline.run(into: singleSink)

        let engines = makeEngines(4)
        let poolSink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let poolPipeline = InterpolationPipeline(source: makeSource(frames: frames),
                                                 sourceRate: Self.sourceRate,
                                                 outputRate: Self.outputRate,
                                                 engines: engines,
                                                 configuration: .init(engines: 4,
                                                                      sceneDetection: false))
        _ = try poolPipeline.run(into: poolSink)

        #expect(poolSink.count == singleSink.count)
        #expect(poolSink.ordered.map(\.index) == singleSink.ordered.map(\.index))
        #expect(poolSink.ordered.map(\.bytes) == singleSink.ordered.map(\.bytes))
    }

    // MARK: - The stage instrument

    /// `StageCosts` exists to answer "which stage owns the wall time", and the answer is
    /// worthless unless the numbers add up to the run. `slotWait` is the discriminator: the
    /// driver holds a slot from before it loads a frame until the engine's completion releases
    /// it, so time spent waiting for one is time the *pool* was the constraint — and time spent
    /// in the other five is time the driver was. If the two did not partition the run, a
    /// conclusion drawn from them would be an artefact of the instrument.
    @Test("the stages account for the run, and slotWait is the wait for the pool")
    func stagesAccountForTheRun() throws {
        let source = makeSource(frames: 30)
        // A deliberately slow engine — 20 ms a call against a 128x96 synthetic frame — so the
        // pool is unambiguously the constraint and the driver must spend the run waiting for
        // slots rather than filling them.
        let engine = RecordingEngine(width: Self.width, height: Self.height, format: .nv12,
                                     maximumInterpolationsPerInterval: 5, depth: 2,
                                     readDelayMicroseconds: 20_000)
        let sink = MemoryFrameSink(width: Self.width, height: Self.height, format: .nv12)
        let pipeline = InterpolationPipeline(source: source,
                                             sourceRate: Self.sourceRate,
                                             outputRate: Self.outputRate,
                                             engine: engine,
                                             configuration: .init(depth: 2, sceneDetection: false))
        let report = try pipeline.run(into: sink)
        let stages = report.stages

        // The stages are a partition of the driver's own time, so they cannot exceed the run —
        // which also runs `sink.finish()` and the drains, neither of which is the driver's.
        #expect(stages.driverBusy + stages.slotWait <= report.wallSeconds,
                "stages \(stages.summary) exceed the \(report.wallSeconds)s run")

        // And they have to account for most of it. The only thing deliberately unmeasured is the
        // loop's own bookkeeping, which is arithmetic on two integers.
        #expect(stages.driverBusy + stages.slotWait >= report.wallSeconds * 0.5,
                "stages \(stages.summary) account for too little of the \(report.wallSeconds)s run")

        // ~29 intervals at 20 ms is ~580 ms of pool, so the driver waits rather than works.
        #expect(stages.slotWait > stages.driverBusy,
                "the driver should be waiting for the pool: \(stages.summary)")
    }

    /// The arithmetic a segmented job needs: its report is the sum of its pieces, and a field
    /// left out of the sum is a field that silently reads zero.
    @Test("stage costs add up field by field")
    func stageCostsAdd() {
        var a = InterpolationPipeline.StageCosts()
        a.read = 1; a.signature = 2; a.load = 3
        a.slotWait = 4; a.submit = 5; a.passthrough = 6
        var b = InterpolationPipeline.StageCosts()
        b.read = 10; b.signature = 20; b.load = 30
        b.slotWait = 40; b.submit = 50; b.passthrough = 60

        let total = a + b
        #expect(total.read == 11)
        #expect(total.signature == 22)
        #expect(total.load == 33)
        #expect(total.slotWait == 44)
        #expect(total.submit == 55)
        #expect(total.passthrough == 66)

        // `driverBusy` is everything the driver did that was *not* waiting for the pool, so
        // `slotWait` is deliberately outside it — that exclusion is the whole measurement.
        // 187 of driver work, 44 of waiting for the pool, 231 of the driver's own time.
        #expect(total.driverBusy == 11 + 22 + 33 + 55 + 66)
        #expect(total.driverBusy + total.slotWait == 231)
    }
}
