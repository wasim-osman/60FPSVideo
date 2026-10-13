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
        ///
        /// Past 2 this does nothing at all, which is measured rather than assumed: 2, 4 and
        /// 8 all give 13.4–13.5 source frames/s at 4K. It is not a knob for speed. Use
        /// ``engines`` for that.
        public var depth: Int

        /// Interpolating sessions to run at once. **This is the knob for speed.**
        ///
        /// One session cannot be hurried, however many requests are queued at it, because
        /// it runs them one at a time. Several sessions do overlap. Measured at 4K on the
        /// real HDR film, one whole conversion per session:
        ///
        ///     sessions   aggregate   speed-up
        ///        1        13.4/s      1.00x
        ///        2        21.5/s      1.60x
        ///        4        23.8/s      1.78x
        ///        6        17.0/s      1.27x
        ///
        /// So the answer is four and not "as many as there are cores": at six the sessions
        /// fight and the run is *slower* than it was with four. `RenderWorkers.suggested()`
        /// picks a count for the machine; 1 leaves this exactly as it was before.
        public var engines: Int

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

        /// Called once per interval this run reads in its render range, on the driving
        /// thread, in order, with the **film's own** interval number.
        ///
        /// ## Why an interval and not a frame
        ///
        /// An interval is the unit of work — it is what costs 104.7 ms at 4K — so it is the
        /// unit that a progress bar has to move in. A per-frame callback would fire two and a
        /// half times per interval on 23.976 → 59.94 and tell the caller nothing the interval
        /// number does not.
        ///
        /// ## Why the film's number and not the run's
        ///
        /// A windowed run reads a lead-in before the interval it renders, so a run-local
        /// number would start negative and a resumed job would start its percentage over.
        /// The film's number is the one the output frames were numbered against (invariant 33),
        /// so a caller can divide it by the film's length and get something that means the same
        /// thing on a first run and on a resumed one.
        ///
        /// The batch converter turns this into a percentage; playback leaves it `nil`, because
        /// a player's progress is the clock and it already has one.
        public var progress: (@Sendable (Int) -> Void)?

        public init(depth: Int = 2,
                    engines: Int = 1,
                    sceneDetection: Bool = true,
                    maximumSourceFrames: Int? = nil,
                    expectedOutputFrameCount: Int? = nil,
                    window: Window? = nil,
                    rendersInterval: (@Sendable (Int) -> Bool)? = nil,
                    progress: (@Sendable (Int) -> Void)? = nil) {
            self.depth = depth
            self.engines = max(1, engines)
            self.sceneDetection = sceneDetection
            self.maximumSourceFrames = maximumSourceFrames
            self.expectedOutputFrameCount = expectedOutputFrameCount
            self.window = window
            self.rendersInterval = rendersInterval
            self.progress = progress
        }
    }

    /// Where the driving thread's time went, in seconds.
    ///
    /// ## Why this exists
    ///
    /// A conversion that uses a fifth of the CPU and two thirds of the GPU is not short of
    /// compute — it is *waiting* for something, and which something cannot be read off the
    /// activity monitors. `top` shows four cores busy and a GPU that is not saturated whether
    /// the pipeline is blocked on the decoder, on the engine pool, or on its own single-threaded
    /// bookkeeping; the three look identical from outside and have opposite fixes.
    ///
    /// The discriminator is ``slotWait``. The driver holds a slot from before it loads a frame
    /// until the engine's completion releases it, so time spent waiting for a free slot is time
    /// the *pool* was the constraint. If that number is near zero and the others sum to the wall
    /// time, the pool was never the limit and the driver's own serial work is the ceiling — which
    /// means adding sessions cannot help and only removing work from the driver can.
    ///
    /// Measured on the real 4K HDR film at four sessions, this is what settled it: the driver's
    /// own load-and-sign work was **40.8 ms of every 42 ms**, and the pool wait was **0.0 s over
    /// the whole run**. See BUILD-DECISIONS §28.
    public struct StageCosts: Sendable, Equatable {
        /// Blocked in `source.read` — the decoder, or the pipe.
        public var read = 0.0
        /// Computing frame signatures for scene detection.
        public var signature = 0.0
        /// Copying packed frames into the engine's `CVPixelBuffer`s.
        public var load = 0.0
        /// Waiting for a free slot: the engine pool, or whatever the completions are waiting on.
        public var slotWait = 0.0
        /// Inside `engine.submit`.
        public var submit = 0.0
        /// Handing passthrough frames to the sink.
        public var passthrough = 0.0

        public init() {}

        /// A segmented job renders one segment at a time, so its report is the sum of its
        /// pieces. Without this the aggregate would have to be assembled field by field at the
        /// call site, which is how a field gets left out.
        public static func + (lhs: StageCosts, rhs: StageCosts) -> StageCosts {
            var total = StageCosts()
            total.read = lhs.read + rhs.read
            total.signature = lhs.signature + rhs.signature
            total.load = lhs.load + rhs.load
            total.slotWait = lhs.slotWait + rhs.slotWait
            total.submit = lhs.submit + rhs.submit
            total.passthrough = lhs.passthrough + rhs.passthrough
            return total
        }

        /// Everything the driver did that was not waiting for the pool. When this is the wall
        /// time, the driver is the ceiling.
        public var driverBusy: Double { read + signature + load + submit + passthrough }

        public var summary: String {
            String(format: "read %.1f  sign %.1f  load %.1f  submit %.1f  pass %.1f  slotWait %.1f",
                   read, signature, load, submit, passthrough, slotWait)
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
        /// Where the driving thread spent `wallSeconds`. See ``StageCosts``.
        public let stages: StageCosts
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
    /// The interpolating sessions this run drives, in parallel.
    ///
    /// A pool rather than one engine because one engine cannot be made to go faster.
    /// `VTFrameProcessor` serialises its own work: measured at 4K on real HDR film, asking
    /// one session for 2, 4 or 8 requests in flight gave 13.4, 13.5 and 13.5 source
    /// frames/s — identical. Separate sessions do run at the same time, because the unit
    /// they queue behind is VideoToolbox's and not their own. See ``RenderWorkers`` for
    /// the scaling curve and where it stops.
    private let engines: [InterpolationEngine]
    private let configuration: Configuration
    private var hasRun = false

    /// The shipping configuration: real `VTFrameProcessor` sessions, `configuration.engines`
    /// of them.
    public init(source: FrameSource,
                sourceRate: FrameRate,
                outputRate: FrameRate,
                configuration: Configuration = Configuration()) {
        self.source = source
        self.sourceRate = sourceRate
        self.outputRate = outputRate
        self.configuration = configuration
        self.engines = (0..<max(1, configuration.engines)).map { _ in
            VTFrameProcessorEngine(source: sourceRate, output: outputRate,
                                   depth: configuration.depth)
        }
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
        self.engines = [engine]
    }

    /// Take a pool of engines from the caller.
    ///
    /// The same seam as the single-engine initialiser, for the same reason: a recording
    /// engine can say which session each interval was given to, and how many were in
    /// flight at once. Parallelism that is not observed is parallelism that is not there —
    /// the failure mode is not a crash but a run that quietly uses one session and takes
    /// exactly as long as it did before.
    ///
    /// The engines must all be built for the same rate pair and the same depth; the
    /// pipeline sizes its slot ring from the largest of each.
    public init(source: FrameSource,
                sourceRate: FrameRate,
                outputRate: FrameRate,
                engines: [InterpolationEngine],
                configuration: Configuration = Configuration()) {
        precondition(!engines.isEmpty, "a pipeline needs at least one engine")
        self.source = source
        self.sourceRate = sourceRate
        self.outputRate = outputRate
        self.configuration = configuration
        self.engines = engines
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

        let engines = self.engines

        // What each session may assume about the order it is about to be fed.
        //
        // **`.random`, always — and this is not a conservative default, it is the true one.**
        // The SDK defines `.sequential` as "the current submission follows presentation time
        // order *without jump or skip*". This pipeline breaks that claim in two places, and the
        // second one is unavoidable:
        //
        // - A pool is fed a **stride**. With four sessions, one of them receives intervals
        //   0, 4, 8, … so every submission it gets is a jump from the one before.
        // - **An interval whose frames are all passthrough is never submitted at all** (the
        //   `resolved.isEmpty` branch below). A scene cut forces exactly that: both frames
        //   either side of the cut become passthroughs, so the interval is skipped and the
        //   sequence has a gap. Measured on the real film, that gap is not free: with the
        //   session told `.sequential` the two output frames *after* every cut come back as a
        //   plain cross-fade — a visible double exposure — because the optical flow it carries
        //   forward describes an interval it was never given. Told `.random` instead, the same
        //   session produces the correct motion-compensated frames, and its output matches a
        //   four-session pool to **57.93 dB mean, 3 frames of 3068 below 40 dB**, against a
        //   four-versus-four control of 58.42 dB and none. The `.sequential` run differs from
        //   both at *every* cut: 17 frames below 40 dB.
        //
        // So the sequence is never one unbroken pass, and saying otherwise buys 11% of a single
        // session's throughput with wrong pixels on the two frames after every cut. That is not
        // a trade this project makes. At the shipping default of four sessions it costs nothing
        // at all — measured 21.2 against 21.2 source frames/s, and 55.7 s wall in both of two
        // runs.
        //
        // A caller that genuinely drives one contiguous run can still ask for `.sequential` at
        // the engine. Nothing in this package does, because nothing in it can promise that.
        let order: SubmissionOrder = .random
        for engine in engines { engine.setSubmissionOrder(order) }

        for engine in engines { try engine.prepare(width: width, height: height) }
        defer { for engine in engines { engine.shutdown() } }

        // Sized from the largest engine in the pool, so a caller that hands over engines
        // built with different depths still gets a ring that is big enough for all of them
        // rather than one that quietly reuses a slot a request is still holding.
        let maximumInterpolations = engines.map(\.maximumInterpolationsPerInterval).max() ?? 3
        let slotsPerEngine = engines.map(\.depth).max() ?? 2
        // One ring of slots for the whole pool. A slot is handed to whichever session the
        // round robin lands on, and the slot's own semaphore is what keeps a buffer from
        // being reused while a request still holds it (invariant 17) — so the two do not
        // have to be paired, only counted together.
        let slotCount = engines.count * slotsPerEngine

        let pool = try PixelBufferPool(
            width: width, height: height, format: format,
            capacity: slotCount * (2 + maximumInterpolations))
        let slots: [Slot] = try (0..<slotCount).map { _ in
            Slot(a: try pool.makeBuffer(),
                 b: try pool.makeBuffer(),
                 destinations: try (0..<maximumInterpolations)
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

        // Where the driving thread's time goes. See ``StageCosts``.
        let clock = StageClock()

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
                var ok = false
                try clock.measuring(.read) { ok = try source.read(into: pointer) }
                guard ok else {
                    eof = true
                    break
                }
                held += 1
                if configuration.sceneDetection {
                    // Signatures are computed on the way past, not in a second
                    // pass. A pipe cannot be rewound, and a second pass over a real
                    // file would mean decoding the whole film twice.
                    clock.measuring(.signature) {
                        let signature = FrameSignature.compute(
                            luma: UnsafeRawPointer(pointer), format: format,
                            width: width, height: height, bytesPerRow: packedLumaStride)
                        decisions.append(contentsOf: tracker.push(signature))
                    }
                }
            }
            return absolute < base + held
        }

        let problems = ProblemLog()
        let slotFree = (0..<slotCount).map { _ in DispatchSemaphore(value: 1) }

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
                // Announced **before** the work, not after. A callback fired on completion
                // would never see the film's last interval — the run ends by the source
                // running out, so there is nothing after the last interval to fire from — and a
                // percentage that stops at 99.4% for the length of the final segment reads as a
                // job that hung. `isCut` for this interval has already been decided, three
                // lines above, so nothing downstream is being guessed at.
                configuration.progress?(globalInterval)
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
                    let slotIndex = submitted % slotCount
                    // Which session takes this interval. Slots are handed out in the same
                    // rotation, so consecutive intervals land on consecutive sessions and a
                    // pool of four gets four requests in flight before any session is asked
                    // for its second.
                    let engine = engines[slotIndex % engines.count]
                    // Invariant 17: acquired before the load, released in the completion.
                    clock.measuring(.slotWait) { slotFree[slotIndex].wait() }
                    let slot = slots[slotIndex]

                    clock.measuring(.load) {
                        format.load(packed: UnsafeRawPointer(ring.pointers[interval % ring.count]),
                                    into: slot.a, width: width, height: height)
                        format.load(packed: UnsafeRawPointer(ring.pointers[(interval + 1) % ring.count]),
                                    into: slot.b, width: width, height: height)
                    }

                    // Passthrough frames cost nothing and need no engine call. On
                    // 23.976 -> 59.94 that is one output frame in five, free.
                    clock.measuring(.passthrough) {
                        for frame in resolved {
                            guard case .passthrough(let sourceIndex) = frame.kind else { continue }
                            // `frame.index` is the film's output frame; the sink is writing this
                            // run's file, which begins at zero.
                            sink.write(sourceIndex == globalInterval ? slot.a : slot.b,
                                       at: frame.index - outputBase)
                            passthroughFrames += 1
                        }
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
                        clock.measuring(.submit) { engine.submit(request) }
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

        // Every session, not just one: a run that drained the first and returned would
        // truncate the output while the other three were still writing into it.
        for (index, engine) in engines.enumerated() {
            do {
                try engine.drain()
            } catch {
                problems.record("engine \(index) drain: \(error)")
            }
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
                      stages: clock.costs,
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

/// Where the driving thread's time went, accumulated as the run proceeds.
///
/// A class rather than a struct so the nested `hold` function and the loop can both add to
/// it without either owning it. Deliberately unlocked: only the thread running `run` ever
/// touches it, which is the same claim ``InterpolationPipeline`` already makes about itself.
private final class StageClock {
    /// The stages a driver iteration is divided into. An enum rather than a key path because
    /// `self[keyPath:]` is not an assignable lvalue through a class reference — the compiler
    /// rejects it as "left side of mutating operator isn't mutable".
    enum Stage {
        case read, signature, load, slotWait, submit, passthrough
    }

    var read = 0.0
    var signature = 0.0
    var load = 0.0
    var slotWait = 0.0
    var submit = 0.0
    var passthrough = 0.0

    /// Run `body`, adding its wall time to `stage`.
    ///
    /// `DispatchTime.now()` costs about 25 ns against the ~42 ms an interval costs at 4K, so
    /// the instrument sits four orders of magnitude below the thing it measures — which is the
    /// only condition under which a timer inside a hot loop is allowed to stay in the build.
    ///
    /// `rethrows`, so the one call site that reads from the decoder keeps its `try` and the
    /// five that cannot fail do not have to carry one.
    @inline(__always)
    func measuring(_ stage: Stage, _ body: () throws -> Void) rethrows {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(stage, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
        try body()
    }

    @inline(__always)
    private func add(_ stage: Stage, _ seconds: Double) {
        switch stage {
        case .read: read += seconds
        case .signature: signature += seconds
        case .load: load += seconds
        case .slotWait: slotWait += seconds
        case .submit: submit += seconds
        case .passthrough: passthrough += seconds
        }
    }

    var costs: InterpolationPipeline.StageCosts {
        var costs = InterpolationPipeline.StageCosts()
        costs.read = read
        costs.signature = signature
        costs.load = load
        costs.slotWait = slotWait
        costs.submit = submit
        costs.passthrough = passthrough
        return costs
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
