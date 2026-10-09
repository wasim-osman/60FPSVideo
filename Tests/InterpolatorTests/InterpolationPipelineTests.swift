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
    private var framesRead = 0
    private var closed = false

    init(width: Int, height: Int, format: FrameFormat, frameRate: FrameRate,
         totalFrames: Int, firstFrame: Int = 0) {
        self.width = width
        self.height = height
        self.format = format
        self.totalFrames = totalFrames
        self.firstFrame = firstFrame
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
