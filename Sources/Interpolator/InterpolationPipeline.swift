import CoreVideo
import Foundation

/// The slot/semaphore driving loop, extracted from the harness.
///
/// ## Why it had to be extracted
///
/// Batch conversion, playback and the measurement harness all do the same thing:
/// pull source frames, group them by interval, hand each interval to the engine,
/// and put the result somewhere. The harness had that logic inline, and the two
/// real consumers were about to grow their own copies of it. Three copies of a loop
/// that is this easy to get subtly wrong is two copies too many — and the loop is
/// *exactly* where invariant 17 lives, which is the bug that produced 378 wrong
/// frames out of 475 while reporting success.
///
/// ## Invariant 17, restated because it is the reason this file exists
///
/// A slot's buffers belong to the request that borrowed them until it completes.
/// The engine's own depth throttle is *not* sufficient protection: it lives inside
/// `submit()`, which runs **after** the source frames have been loaded into the
/// slot. So slot `n % depth` can be refilled while request `n - depth` is still
/// reading it, and `VTFrameProcessor` then interpolates a mix of old and new frame
/// data. The damage is disguised as success — a slow shot comes out barely wrong, a
/// fast one very wrong, and the final interval perfectly correct because nothing
/// follows it to clobber the buffers.
///
/// The fix is one semaphore per slot, acquired **before** the load and released in
/// the completion. That ordering is the whole invariant, and it is preserved here
/// unchanged.
///
/// ## Why the frames are read through a three-slot ring
///
/// The harness could `pread` any frame it liked, any number of times, because a
/// packed file is seekable. A real source is not: ffmpeg writes to a pipe and a
/// pipe cannot be rewound. Three separate needs have to be satisfied from one
/// sequential stream:
///
/// - interval `j` needs frames `j` and `j + 1` — a one-frame lookbehind;
/// - the cut decision for interval `j` needs signature `j + 2` — a two-frame
///   lookahead (see ``SceneChangeTracker``);
/// - the cut decision must be known *before* interval `j` is resolved, because
///   resolving it is what turns its interpolations into passthroughs.
///
/// So a ring of exactly three packed frames covers `[j, j + 2]`, one frame is read
/// per interval, and each source frame is read exactly once. Two frames would work
/// for the pixels and be one short for the decision; four would be a frame of
/// lookahead nobody uses.
///
/// ## What this deliberately does not do
///
/// It does not know how many source frames there are, and it does not need to —
/// see ``IntervalPlanner``. It stops when the source stops. That is what makes the
/// same code correct for a Matroska file whose `nb_frames` is `N/A` and for a live
/// playback stream that has no end at all.
///
/// ## Sendable
///
/// `@unchecked`, and it is a claim with a reason rather than a shrug: a pipeline is
/// **single-use and single-threaded**. It is built on one thread, `run` is called once on
/// another, and `hasRun` exists to make a second call a programming error rather than a
/// silent second render. There is nothing to race with, because there is no second accessor.
public final class InterpolationPipeline: @unchecked Sendable {

    // MARK: - Configuration

    /// Where in the film a run sits, when it is a piece of a segmented job rather than the
    /// whole thing.
    ///
    /// ## Why a run has to be told this
    ///
    /// Two numbers in this pipeline are *global* and are computed from a local index:
    ///
    /// - **the phase.** Which output frames are free passthroughs depends on the output
    ///   frame's number, not on how far into this run it is. A segment that numbered its
    ///   output frames from zero would compute passthroughs for a phase the film does not
    ///   have there, and the join would show a duplicate or a drop at every boundary.
    /// - **the cut decision.** Interval `i`'s verdict needs signatures from `i - historyLength`
    ///   to `i + 2`. A run that began reading at its own first interval would judge it with
    ///   a short history and no backward evidence, and would judge its last interval with no
    ///   forward evidence at all, because the tracker calls `finish()` when its source ends.
    ///
    /// So a window says where to read from, which intervals to render, and what the first
    /// rendered output frame's global number is. Intervals outside the render range are read
    /// and fed to the tracker and produce no output — that is the whole point of the type.
    ///
    /// `nil` means the whole source, from frame zero, numbered from zero.
    public struct Window: Sendable {
        /// The global source interval this run's first frame is read at.
        public let readFromInterval: Int
        /// The global source interval this run begins rendering at.
        public let renderFromInterval: Int
        /// The global source interval this run stops rendering at, exclusive.
        public let renderToInterval: Int
        /// The global output frame this run's first rendered output frame is.
        public let outputStart: Int

        public init(readFromInterval: Int, renderFromInterval: Int,
                    renderToInterval: Int, outputStart: Int) {
            self.readFromInterval = readFromInterval
            self.renderFromInterval = renderFromInterval
            self.renderToInterval = renderToInterval
            self.outputStart = outputStart
        }

        /// The window that renders one segment of a plan.
        public init(segment: SegmentPlan.Segment) {
            self.readFromInterval = segment.readStart
            self.renderFromInterval = segment.sourceStart
            self.renderToInterval = segment.intervalEnd
            self.outputStart = segment.outputStart
        }
    }

    public struct Configuration: Sendable {
        /// Requests kept in flight. **2 is the minimum that works**: depth 1 fails
        /// outright on 23.976 → 60, dropping to 56.7 fps (invariant 3).
        public var depth: Int
        /// Detect scene cuts and turn the interpolations across them into held
        /// frames. Off only for the A/B that demonstrates why it is needed.
        public var sceneDetection: Bool
        /// Stop after this many source frames. `nil` for the whole source.
        public var maximumSourceFrames: Int?
        /// A hint for sinks that have to state an output length before the first
        /// frame. The pipeline never uses it to decide anything — it stops when the
        /// source stops, and the hint being wrong cannot corrupt the output.
        public var expectedOutputFrameCount: Int?
        /// The part of the film this run renders. `nil` for the whole source.
        public var window: Window?
        /// Which intervals this run renders, by the film's own interval number.
        ///
        /// `nil` renders every interval in the window, which is what batch conversion wants
        /// and what every test up to now has assumed.
        ///
        /// ## Why playback needs it
        ///
        /// A player cannot render every interval and stay with its clock. Interpolation at
        /// 4K measures **104.7 ms per interval** against the 41.7 ms the film spends on one
        /// at 23.976 — it runs at about **0.4× real time**. A player that rendered every
        /// interval would advance through the film at 0.4 s per second, and no amount of
        /// queueing fixes a deficit that is per-frame rather than transient: the picture
        /// would fall further behind the sound with every second of film.
        ///
        /// So the player renders a **subset** — the intervals whose output is still ahead of
        /// the clock — and the film advances at its own rate. The motion judders, which is
        /// the recorded trade ("keep true 4K, accept the drops"), and the film stays in sync,
        /// which is the part that matters.
        ///
        /// This is a filter rather than a stride because *which* intervals to keep is not
        /// arithmetic: it depends on where the clock is, which changes as the run proceeds.
        /// The closure is called once per interval, on the driving thread, in order.
        public var rendersInterval: (@Sendable (Int) -> Bool)?

        public init(depth: Int = 2,
                    sceneDetection: Bool = true,
                    maximumSourceFrames: Int? = nil,
                    expectedOutputFrameCount: Int? = nil,
                    window: Window? = nil,
                    rendersInterval: (@Sendable (Int) -> Bool)? = nil) {
            self.depth = depth
            self.sceneDetection = sceneDetection
            self.maximumSourceFrames = maximumSourceFrames
            self.expectedOutputFrameCount = expectedOutputFrameCount
            self.window = window
            self.rendersInterval = rendersInterval
        }
    }

    /// What the run did.
    public struct Report: Sendable {
        public let sourceFrames: Int
        public let outputFrames: Int
        public let interpolatedFrames: Int
        public let passthroughFrames: Int
        /// Engine calls made. One per interval that had any interpolation in it.
        public let engineCalls: Int
        /// Every interval verdict the tracker reached, in order. Exposed so the
        /// harness can compare the online path against the offline detector on real
        /// footage, which is where the disagreements nobody thought of live.
        public let decisions: [SceneChangeTracker.Decision]
        public let wallSeconds: Double
        /// Engine failures, in the order they were seen. The sink's own failures are
        /// the sink's to report.
        public let problems: [String]

        public var cutCount: Int { decisions.filter(\.isCut).count }
        public var cutIntervals: [Int] { decisions.filter(\.isCut).map(\.interval) }
    }

    // MARK: - State

    private let source: FrameSource
    private let sourceRate: FrameRate
    private let outputRate: FrameRate
    private let engine: InterpolationEngine
    private let configuration: Configuration
    private var hasRun = false

    /// The shipping configuration: the real `VTFrameProcessor` engine.
    public init(source: FrameSource,
                sourceRate: FrameRate,
                outputRate: FrameRate,
                configuration: Configuration = Configuration()) {
        self.source = source
        self.sourceRate = sourceRate
        self.outputRate = outputRate
        self.configuration = configuration
        self.engine = VTFrameProcessorEngine(source: sourceRate, output: outputRate,
                                            depth: configuration.depth)
    }

    /// Take the engine from the caller.
    ///
    /// This exists so invariant 17 can be tested. That bug is invisible from the
    /// outside when it is not happening, and when it *is* happening it looks like a
    /// slightly wrong frame on fast motion — which is not something a synthetic test
    /// can spot. A recording engine can watch the borrowed buffers directly and say
    /// whether they were clobbered while a request was still holding them.
    public init(source: FrameSource,
                sourceRate: FrameRate,
                outputRate: FrameRate,
                engine: InterpolationEngine,
                configuration: Configuration = Configuration()) {
        self.source = source
        self.sourceRate = sourceRate
        self.outputRate = outputRate
        self.configuration = configuration
        self.engine = engine
    }

    // MARK: - Run

    /// Drive the whole source through the engine and into `sink`.
    ///
    /// Throws only for a failure that makes the job impossible — a bad rate pair,
    /// an engine that will not start, buffers that cannot be allocated. A frame that
    /// fails to interpolate does not throw: it is recorded, and the run continues,
    /// because a 2-hour conversion should not be abandoned over one interval.
    ///
    /// The source is consumed and closed. The pipeline is single-use.
    @discardableResult
    public func run(into sink: FrameSink) throws -> Report {
        precondition(!hasRun, "an InterpolationPipeline runs once")
        hasRun = true
        defer { source.close() }

        let width = source.info.width
        let height = source.info.height
        let format = source.info.format
        let frameByteSize = source.frameByteSize
        // Packed frames have no padding, so the luma stride is the row length
        // exactly. That is *not* the same as a CVPixelBuffer plane's stride, which
        // the pool pads — the two only coincide for 8-bit input.
        let packedLumaStride = width * format.bytesPerSample

        let planner = IntervalPlanner(source: sourceRate, output: outputRate)
        guard planner.isUsable else {
            throw InterpolationPipelineError.degenerateRates(source: sourceRate,
                                                            output: outputRate)
        }
        guard outputRate.doubleValue >= sourceRate.doubleValue else {
            throw InterpolationPipelineError.outputBelowSource(source: sourceRate,
                                                               output: outputRate)
        }

        let engine = self.engine
        try engine.prepare(width: width, height: height)
        defer { engine.shutdown() }

        let pool = try PixelBufferPool(
            width: width, height: height, format: format,
            capacity: engine.depth * (2 + engine.maximumInterpolationsPerInterval))
        let slots: [Slot] = try (0..<engine.depth).map { _ in
            Slot(a: try pool.makeBuffer(),
                 b: try pool.makeBuffer(),
                 destinations: try (0..<engine.maximumInterpolationsPerInterval)
                     .map { _ in try pool.makeBuffer() })
        }

        try sink.begin(SinkGeometry(width: width, height: height, format: format,
                                    sourceRate: sourceRate, outputRate: outputRate,
                                    // What this run reads, which for a segment is its own
                                    // frames rather than the film's.
                                    sourceFrameCount: configuration.maximumSourceFrames
                                        ?? source.info.frameCount,
                                    outputFrameCount: configuration.expectedOutputFrameCount))

        let ring = FrameRing(count: 3, frameByteSize: frameByteSize)
        let tracker = SceneChangeTracker()
        var decisions: [SceneChangeTracker.Decision] = []
        var trackerFinished = false

        // Ring bookkeeping. `held` frames are in the ring, covering the absolute
        // source indices `[base, base + held)`; slot for absolute index `i` is
        // `i % 3`, so a frame is only ever read into a slot that no longer holds
        // anything needed.
        var base = 0
        var held = 0
        var eof = false

        /// Read until absolute frame `absolute` is held, or the source ends.
        /// Returns whether it is held.
        func hold(_ absolute: Int) throws -> Bool {
            while base + held <= absolute && !eof {
                guard held < ring.count else { return false }
                if let cap = configuration.maximumSourceFrames, base + held >= cap {
                    eof = true
                    break
                }
                let pointer = ring.pointers[(base + held) % ring.count]
                guard try source.read(into: pointer) else {
                    eof = true
                    break
                }
                held += 1
                if configuration.sceneDetection {
                    // Signatures are computed on the way past, not in a second
                    // pass. A pipe cannot be rewound, and a second pass over a real
                    // file would mean decoding the whole film twice.
                    let signature = FrameSignature.compute(
                        luma: UnsafeRawPointer(pointer), format: format,
                        width: width, height: height, bytesPerRow: packedLumaStride)
                    decisions.append(contentsOf: tracker.push(signature))
                }
            }
            return absolute < base + held
        }

        let problems = ProblemLog()
        let slotFree = (0..<engine.depth).map { _ in DispatchSemaphore(value: 1) }

        // Where this run sits in the film. Local interval `j` is the film's interval
        // `readBase + j`; only those in `[localRenderFrom, localRenderTo)` produce output.
        let readBase = configuration.window?.readFromInterval ?? 0
        let outputBase = configuration.window?.outputStart ?? 0
        let localRenderFrom = (configuration.window?.renderFromInterval ?? 0) - readBase
        let localRenderTo = configuration.window.map { $0.renderToInterval - readBase } ?? Int.max
        // Keep reading past the last rendered interval, so the tracker holds the forward
        // evidence the flash guard needs for it. Without this the last interval of every
        // segment is decided by `finish()` — end-of-stream semantics — and a cut landing
        // exactly on a segment boundary would be judged differently from the same cut
        // mid-film. Two intervals is what the guard reaches.
        let lastLocalInterval = localRenderTo == Int.max
            ? Int.max : localRenderTo + (configuration.sceneDetection ? 2 : 0)

        var interval = 0
        var submitted = 0
        var outputFrames = 0
        var interpolatedFrames = 0
        var passthroughFrames = 0
        let started = DispatchTime.now().uptimeNanoseconds

        while interval < lastLocalInterval {
            // Interval `j` exists only if source frame `j + 1` does.
            guard try hold(interval) else { break }
            guard try hold(interval + 1) else { break }

            // Signature `j + 2` is what makes interval `j`'s verdict final. Reading
            // it here is what lets the decision be known before the interval is
            // resolved — and it is the read that hits the end of the stream on the
            // last interval, which is exactly where the tail semantics come from.
            _ = try hold(interval + 2)

            if configuration.sceneDetection, !trackerFinished, eof,
               decisions.count <= interval {
                // End of stream and this interval's verdict is still open: no frame
                // after next exists, so `finish()` reproduces the offline detector's
                // end-of-clip behaviour rather than inventing a different answer.
                decisions.append(contentsOf: tracker.finish())
                trackerFinished = true
            }

            // Outside the render range the interval is read for the tracker's sake and
            // produces nothing. This is the whole reason a window exists: the lead-in gives
            // the first rendered interval the history the whole-film render would have given
            // it, and the lead-out gives the last one its forward guard.
            if interval >= localRenderFrom, interval < localRenderTo {
                let isCut = configuration.sceneDetection
                    && interval < decisions.count
                    && decisions[interval].isCut

                // The film's interval, not this run's. Which output frames are free
                // passthroughs is a property of the output frame's own number, and a
                // passthrough's `sourceIndex` names a frame in the film's numbering — so
                // the choice of `slot.a` or `slot.b` has to be made against this same
                // global index. Comparing it against the local one silently wrote the far
                // frame of every passthrough in every segment but the first.
                let globalInterval = readBase + interval
                let planned = planner.output(forInterval: globalInterval)
                // The cut rule is not restated here — `CutResolution` is the same code
                // `PhasePlan.resolvingCuts` runs. A second copy is how a cut ends up
                // handled one way when converting and another when watching.
                let resolved = configuration.sceneDetection
                    ? CutResolution.resolve(planned, isCut: isCut)
                    : planned

                // Playback's skip. The interval is read and judged either way — only the
                // work is skipped — so the tracker's history is the same whether or not the
                // interval is rendered, and a cut decision does not depend on what the clock
                // happened to be doing when it was made.
                let wanted = configuration.rendersInterval?(globalInterval) ?? true

                if wanted, !resolved.isEmpty {
                    let slotIndex = submitted % engine.depth
                    // Invariant 17: acquired before the load, released in the completion.
                    slotFree[slotIndex].wait()
                    let slot = slots[slotIndex]

                    format.load(packed: UnsafeRawPointer(ring.pointers[interval % ring.count]),
                                into: slot.a, width: width, height: height)
                    format.load(packed: UnsafeRawPointer(ring.pointers[(interval + 1) % ring.count]),
                                into: slot.b, width: width, height: height)

                    // Passthrough frames cost nothing and need no engine call. On
                    // 23.976 -> 59.94 that is one output frame in five, free.
                    for frame in resolved {
                        guard case .passthrough(let sourceIndex) = frame.kind else { continue }
                        // `frame.index` is the film's output frame; the sink is writing this
                        // run's file, which begins at zero.
                        sink.write(sourceIndex == globalInterval ? slot.a : slot.b,
                                   at: frame.index - outputBase)
                        passthroughFrames += 1
                    }

                    let interpolations = resolved.filter { !$0.isPassthrough }
                    if interpolations.isEmpty {
                        // Nothing submitted, so no completion will arrive to release the
                        // slot. Release it here or the pipeline deadlocks after `depth`
                        // intervals.
                        slotFree[slotIndex].signal()
                    } else {
                        submitted += 1
                        let destinations = Array(slot.destinations.prefix(interpolations.count))
                        let destinationSet = DestinationSet(buffers: destinations)
                        let intervalIndex = globalInterval
                        let request = InterpolationRequest(
                            interval: SourceInterval(sourceIndex: globalInterval,
                                                     output: resolved),
                            sourceA: slot.a,
                            sourceB: slot.b,
                            destinations: destinations
                        ) { result in
                            defer { slotFree[slotIndex].signal() }
                            switch result {
                            case .success:
                                for (n, frame) in interpolations.enumerated()
                                where n < destinationSet.buffers.count {
                                    sink.write(destinationSet.buffers[n],
                                               at: frame.index - outputBase)
                                }
                            case .failure(let error):
                                problems.record("interval \(intervalIndex): \(error)")
                            }
                        }
                        engine.submit(request)
                        interpolatedFrames += interpolations.count
                    }
                    outputFrames += resolved.count
                }
            }

            // Frame `interval` is no longer needed by anyone: the next interval
            // starts at `interval + 1`.
            base += 1
            held -= 1
            interval += 1
        }

        // Only when the source really ended. A run that stopped because its window was
        // satisfied has no tail to decide, and deciding one would invent verdicts for
        // intervals the film continues past.
        if configuration.sceneDetection, !trackerFinished, eof {
            decisions.append(contentsOf: tracker.finish())
        }

        do {
            try engine.drain()
        } catch {
            problems.record("engine drain: \(error)")
        }

        try sink.finish()

        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        return Report(sourceFrames: interval + held,
                      outputFrames: outputFrames,
                      interpolatedFrames: interpolatedFrames,
                      passthroughFrames: passthroughFrames,
                      engineCalls: submitted,
                      decisions: decisions,
                      wallSeconds: wall,
                      problems: problems.all)
    }
}

// MARK: - Supporting types

/// One slot's buffers. They belong to the request that borrowed them until it
/// completes (invariant 17), which is why the slot is a thing at all rather than
/// just a set of pooled buffers.
private final class Slot {
    let a: CVPixelBuffer
    let b: CVPixelBuffer
    let destinations: [CVPixelBuffer]

    init(a: CVPixelBuffer, b: CVPixelBuffer, destinations: [CVPixelBuffer]) {
        self.a = a
        self.b = b
        self.destinations = destinations
    }
}

/// Destination buffers travelling into an engine completion.
///
/// `CVPixelBuffer` carries no `Sendable` conformance, but the engine's contract is
/// precisely that a submitted buffer is not touched by anyone else until its
/// completion fires. This states that to the compiler rather than leaving it
/// implicit — the same promise ``InterpolationRequest`` makes.
private struct DestinationSet: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
}

/// The sliding window of packed frames.
///
/// Raw allocations rather than `[[UInt8]]` because an array is a value type: every
/// read out of one would copy the whole frame, which at 4K P010 is 3.5 MB per
/// access and three accesses per interval. The pointers are touched from one thread
/// only — the thread driving `run`.
private final class FrameRing {
    let pointers: [UnsafeMutableRawPointer]
    var count: Int { pointers.count }

    init(count: Int, frameByteSize: Int) {
        pointers = (0..<count).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: frameByteSize, alignment: 64)
        }
    }

    deinit {
        for pointer in pointers { pointer.deallocate() }
    }
}

/// Engine failures, which arrive on the engine's completion threads.
private final class ProblemLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func record(_ problem: String) {
        lock.lock(); list.append(problem); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return list
    }
}

public enum InterpolationPipelineError: Error, CustomStringConvertible {
    case degenerateRates(source: FrameRate, output: FrameRate)
    case outputBelowSource(source: FrameRate, output: FrameRate)

    public var description: String {
        switch self {
        case .degenerateRates(let source, let output):
            "\(source) -> \(output) does not admit a phase plan"
        case .outputBelowSource(let source, let output):
            "output rate \(output) is below source rate \(source)"
        }
    }
}
