import AVFoundation
import CoreMedia
import Foundation

/// Playback, assembled: a source, an engine, a clock, a queue and a display.
///
/// ## The shape
///
/// Two threads and a bounded queue between them:
///
/// - the **producer** decodes and interpolates, and runs as fast as the engine allows —
///   which at 1080p is faster than real time and at 4K is not;
/// - the **presenter** takes finished frames and enqueues them at their own moment.
///
/// Neither paces the other directly. The queue's bound is what stops the producer running
/// away, and the clock is what the presenter paces against. Everything else follows from
/// those two.
///
/// ## What a seek costs, and why
///
/// A seek tears the session down and builds a new one: a new decoder seeked to the new
/// position, a new pipeline (the pipeline is single-use, deliberately — a run has exactly
/// one beginning and one end), a new queue and a new pair of threads. It is a second of
/// work, and it is the honest design rather than a compromise: the alternative is a pipeline
/// that can be interrupted, which means a slot/semaphore loop with a fourth way to leave it,
/// and invariant 17's bug lived in exactly that loop.
///
/// ## What it deliberately does not do
///
/// The clock is the film's own time and the picture is paced to it. When there is **sound**,
/// the sound *is* the clock — see ``PlaybackAudio`` — because a compressed audio stream
/// cannot be retimed, so the picture follows the sound rather than the other way round. That
/// is a change to where ``PlaybackClock`` gets its time from and to three lines of ordering
/// in this file, and to nothing else.
public final class PlaybackController: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// The rate the film is presented at. 59.94 unless something says otherwise.
        public var outputRate: FrameRate
        /// Requests kept in flight. 2 is the minimum that works (invariant 3).
        public var depth: Int
        public var sceneDetection: Bool
        /// How far ahead of the clock the producer may run, in seconds of output.
        public var leadSeconds: Double
        /// Where to begin, in seconds.
        public var startSeconds: Double
        /// What size to interpolate at.
        ///
        /// The lever that decides whether a 4K film plays in real time here. Interpolation is
        /// per-pixel, and — measured — a **step function of frame width** rather than of pixel
        /// count, so the only way to hold the rate on this machine is to interpolate at fewer
        /// columns and let the display scale the result up.
        ///
        /// That is precisely the resize SVP performs before it interpolates, and it is the one of
        /// SVP's two levers `VTFrameProcessor` leaves us: the other is its block-matching motion
        /// model, which the framework does not expose at all. Measured at 4K on the real film,
        /// `.source` gives half the intervals skipped and a constant ~150 ms of lag; `.automatic`
        /// gives real time.
        public var resolutionPolicy: PlaybackResolutionPolicy

        public init(outputRate: FrameRate,
                    depth: Int = 2,
                    sceneDetection: Bool = true,
                    leadSeconds: Double = 1.0,
                    startSeconds: Double = 0,
                    resolutionPolicy: PlaybackResolutionPolicy = .automatic) {
            self.outputRate = outputRate
            self.depth = depth
            self.sceneDetection = sceneDetection
            self.leadSeconds = leadSeconds
            self.startSeconds = startSeconds
            self.resolutionPolicy = resolutionPolicy
        }
    }

    public struct Status: Sendable {
        public let state: PlaybackClock.State
        /// Where the playhead is, in seconds.
        public let position: Double
        /// The film's length, as the probe reported it.
        public let duration: Double
        public let shown: Int
        public let dropped: Int
        /// Output frames the renderer refused to compute because the clock had passed them.
        public let skippedIntervals: Int

        public var droppedFraction: Double {
            let total = shown + dropped
            return total == 0 ? 0 : Double(dropped) / Double(total)
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case alreadyStarted
        case notStarted
        case pastEnd(Double)
        case source(String)

        public var description: String {
            switch self {
            case .alreadyStarted: "playback is already running"
            case .notStarted: "playback has not been started"
            case .pastEnd(let t): "there is nothing at \(t) s"
            case .source(let detail): "could not open the film: \(detail)"
            }
        }
    }

    public let clock: PlaybackClock
    public let configuration: Configuration
    private let url: URL
    private let info: MediaInfo
    private let display: VideoDisplay
    /// The sound, when the film has any.
    ///
    /// `any AudioTransport` rather than `PlaybackAudio`, so this file needs no audio hardware
    /// to be tested and so the ordering rules below — which are the part that is silently
    /// wrong when it is wrong — can be checked against a fake that moves by hand.
    private let audio: (any AudioTransport)?

    private let lock = NSLock()
    private var session: Session?
    private var lastReport: DisplayPresenter.Report?
    /// The size the pipeline will be handed, decided once per film by ``resolveInterpolation()``.
    ///
    /// Cached because a seek rebuilds the session, and a calibration is a measured run of the
    /// pipeline — paying for it on every seek would make scrubbing a two-second-per-click
    /// operation. It is a property of the film and the machine, and neither changes mid-playback.
    private var resolved: MediaInfo?
    /// What the calibration found, when the policy asked for one.
    private var calibration: PlaybackCalibrator.Choice?
    /// Kept after a session is torn down, so `status` still answers once the film has ended.
    private var lastSkipped = 0
    private var problemList: [String] = []
    /// A play request that is waiting for the first frame to exist.
    private var playRequested = false
    private var firstFrameReady = false

    // MARK: - Where a session is built

    /// The one thread a session is ever built on.
    ///
    /// A seek is not a move of the playhead: it tears the session down — both threads joined, the
    /// decoder closed — and builds a new one, which means spawning ffmpeg and asking it to seek
    /// into the file. Measured on the real 4K film that is **120 ms of blocking work, worst 162**,
    /// and it used to happen **on the calling thread**, which in the app is the main thread. The
    /// main thread is where the window is drawn, so the block *is* the freeze a viewer sees when
    /// they grab the playhead — and the bad ones are intermittent because the cost depends on
    /// where in the film the target lands: `-ss` seeks to the preceding keyframe and then decodes
    /// forward to the requested instant, so how far back that keyframe sits is the whole variance.
    ///
    /// Every build goes through here instead, and the callers return immediately.
    ///
    /// **One serial queue, not one per caller.** Two builds at once would each tear down the
    /// other's session — which is exactly why the rate watchdog's rebuild was already being
    /// marshalled onto the main thread before this existed. Serialising them is the property that
    /// mattered; the main thread was only ever how it was achieved.
    private let sessionQueue = DispatchQueue(label: "interp.playback.session",
                                             qos: .userInitiated)

    /// Which build the caller last asked for.
    ///
    /// A rebuild takes long enough that another request can arrive while the first is still
    /// running, and a user who clicks the playhead twice has asked for the second position, not
    /// for both. A queued build whose token is stale is dropped rather than run: running it would
    /// tear down the session the newer request is about to build, and the film would settle at
    /// where the *older* click said.
    private var requestToken: UInt64 = 0

    /// Is this request still the one being waited on?
    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requestToken == token
    }

    /// Take the next token, invalidating everything already queued.
    private func nextToken() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        requestToken &+= 1
        return requestToken
    }

    // MARK: - Holding the rate

    /// The rate watchdog: the player's own answer to "is this actually real time".
    ///
    /// ## Why a prediction is not enough
    ///
    /// `.automatic` picks a width by running the *pipeline* for a measured number of intervals
    /// and comparing that against one interval of film time. That probe is honest about what it
    /// measures and silent about what it does not: it writes into a sink that discards frames, so
    /// it never runs the queue, never runs the presenter, and never presents. **Everything the
    /// player does that is not interpolation is absent from the number that decides how much
    /// interpolation the player may do.**
    ///
    /// Measured on the real film at 1920 wide, the engine alone costs **31.74 ms per interval**
    /// against a **41.71 ms** budget — 24% spare. Measured on the same film through the whole
    /// player, the picture came out at **59.4 fps of 59.94** — 0.6% *over*. So the non-engine
    /// half of the player consumes very nearly the whole of the spare, and a prediction with 24%
    /// of headroom is really a prediction with none. Nothing in the probe can see this, and no
    /// margin constant fixes it, because the cost that eats the spare depends on the window the
    /// film is playing in, the display it is on, and what else the machine is doing.
    ///
    /// So the player watches itself. Every ``watchdogInterval`` it takes the picture's own
    /// counter and asks a simpler question than the calibration asked: *did the last second and a
    /// half present at the rate we need?* If it did not, twice running, the picture is narrowed
    /// one rung of the ladder and the session rebuilt at the same instant of film.
    ///
    /// This is SVP's `fi_auto`, which also lowers quality to hold the rate — and it is the honest
    /// version of it, because the thing being lowered is chosen from what the machine actually
    /// did rather than from what it was expected to do.
    private var watchdog: DispatchSourceTimer?
    /// The last sample: frames shown, and when. `nil` until two samples exist.
    private var watchdogSample: (shown: Int, at: TimeInterval)?
    /// Consecutive samples below the target. One short sample is a seek or a stall, not a verdict.
    private var shortSamples = 0
    /// How many times this film's picture has been narrowed. Bounded, because a player that keeps
    /// halving its own resolution is a player that has not understood the problem.
    private var narrowings = 0
    private let watchdogQueue = DispatchQueue(label: "interp.playback.watchdog")

    /// How often the player checks its own rate.
    private static let watchdogInterval: TimeInterval = 1.5
    /// How far below the target counts as short. Not 1.0: a rate that oscillates around the
    /// target by a fraction of a frame is a player working at its limit and holding.
    private static let watchdogTolerance = 0.97
    /// Short samples in a row before the picture is narrowed.
    private static let watchdogPatience = 2
    /// The most rungs the player may descend for one film.
    private static let maximumNarrowings = 2

    /// One run of the film, from one position.
    ///
    /// `@unchecked Sendable`: every field is a reference to something that manages its own
    /// synchronisation, and `producerFailure` is written once by the producer and read only
    /// after `producerDone` has been waited on — which is a happens-before edge rather than
    /// a hope.
    private final class Session: @unchecked Sendable {
        let queue: PlaybackBuffer
        let source: FFmpegFrameSource
        let sink: DisplayFrameSink
        let presenter: DisplayPresenter
        /// Intervals the clock had already passed. Read at the end, because it is the one
        /// number that says whether the machine kept up — a run that skipped a fifth of its
        /// intervals is a run that played, and one that skipped four fifths is a run that
        /// stuttered, and the two look identical from the picture alone.
        let skipped: Counter
        let producerDone = DispatchSemaphore(value: 0)
        let presenterDone = DispatchSemaphore(value: 0)
        var producerFailure: Error?
        /// Set before the source is closed. A read that fails *because* we closed the
        /// decoder is not a problem with the film, and reporting it as one would put a
        /// spurious error on every stop and every seek — which is how a real one gets
        /// ignored.
        var tearingDown = false

        init(queue: PlaybackBuffer, source: FFmpegFrameSource, sink: DisplayFrameSink,
             presenter: DisplayPresenter, skipped: Counter) {
            self.queue = queue
            self.source = source
            self.sink = sink
            self.presenter = presenter
            self.skipped = skipped
        }
    }

    /// - Parameters:
    ///   - url: the film.
    ///   - display: where frames go. `AVSampleBufferDisplayLayer` in the app.
    ///   - configuration: the run's shape.
    ///   - info: the probe. Its `duration` is the clock's end and its frame rate is the
    ///     source rate; nothing here re-reads the file.
    ///   - audio: the sound, if any. When one is given **and** no clock is, the clock is
    ///     built over it — the sound becomes the definition of where the film is. Passing
    ///     both is allowed and is what the tests do, where the clock is driven by hand.
    ///   - clock: injected so a test can drive the playhead by hand. The default builds one
    ///     over the sound, or over the process uptime when there is no sound.
    public init(url: URL,
                display: VideoDisplay,
                configuration: Configuration,
                info: MediaInfo,
                audio: (any AudioTransport)? = nil,
                clock: PlaybackClock? = nil) {
        self.url = url
        self.display = display
        self.configuration = configuration
        self.info = info
        self.audio = audio
        if let clock {
            self.clock = clock
        } else if let audio {
            // The sound is the clock. The closure captures the transport rather than the
            // controller, so there is no cycle to break — the controller holds the sound, the
            // sound holds nothing.
            self.clock = PlaybackClock(timeSource: { audio.mediaTime })
        } else {
            self.clock = PlaybackClock()
        }
    }

    deinit {
        lock.lock()
        let current = session
        let timer = watchdog
        watchdog = nil
        lock.unlock()
        // Cancelled outside the lock, and only here once — a `DispatchSourceTimer` that is
        // cancelled while still suspended traps, so `watchdog` is only ever set after `resume()`
        // and this is the only place it is taken without being stopped first.
        timer?.cancel()
        if let current { tearDown(current, wait: false) }
        audio?.pause()
    }

    // MARK: - Transport

    /// Build the session and start producing. The film does not play until ``play()``.
    ///
    /// Synchronous, and deliberately: this is the film *opening*, where the app is already showing
    /// "Preparing…" and there is nothing to keep responsive, and its callers need the session to
    /// exist by the time it returns. It runs on ``sessionQueue`` rather than on the caller so that
    /// an opening and a seek can never overlap.
    public func start() throws {
        lock.lock()
        guard session == nil else {
            lock.unlock()
            throw Failure.alreadyStarted
        }
        lock.unlock()
        try sessionQueue.sync {
            try beginSession(at: configuration.startSeconds, resetClock: true)
        }
    }

    /// Start playing, or arm playback to start as soon as the first frame is ready.
    ///
    /// **The clock does not start until there is something to show.** Pressing play starts
    /// the film's clock, and the decoder, the engine session and the buffer pool take about
    /// **1.3 s** to produce the first frame on the real 4K film — so starting the clock on
    /// the press throws away a second and a third of the film before anything appears, and
    /// the picture then plays that far behind the sound for the rest of the run. It is not a
    /// gap that closes.
    ///
    /// So a play request is a *request*: it is honoured by the presenter, which knows when
    /// the first frame exists. If one already does, this starts immediately.
    ///
    /// **With sound this matters twice over**, because the sound *is* the clock: starting the
    /// soundtrack on the press would put the picture a second and a third behind it with no
    /// mechanism to ever catch up.
    ///
    /// Pressing play after the film has ended **restarts it**, and that is a seek rather than
    /// a resume: the session's threads have finished and a pipeline is single-use, so there is
    /// nothing left to resume from. It used to just start the clock, which left the playhead
    /// running against no producer at all — a film that played and showed nothing.
    public func play() {
        lock.lock()
        let ended = clock.state == .ended
        let ready = firstFrameReady
        lock.unlock()
        if ended {
            restart()
            return
        }
        lock.lock()
        playRequested = true
        lock.unlock()
        if ready { startPlaying() }
    }

    public func pause() {
        lock.lock()
        playRequested = false
        lock.unlock()
        // The sound stops first. `clock.pause()` re-anchors against the sound's position, so
        // pausing the clock while the sound was still moving would fold a few milliseconds of
        // sound into the playhead — small, but in the direction that grows.
        audio?.pause()
        clock.pause()
        // A paused player has no rate to judge, and leaving the watchdog running would let it
        // count a pause as a shortfall and narrow the picture for a film nobody is watching.
        stopWatchdog()
    }

    /// Jump to a position.
    ///
    /// **Asynchronous, and that is the fix rather than an inconvenience.** The rebuild is ~120 ms
    /// of blocking work (worst measured 162 ms on the real 4K film) and it used to run on the
    /// caller's thread — which in the app is the main thread, where the window is drawn. So the
    /// click *was* a freeze, and an intermittent one, because ffmpeg's `-ss` lands on the
    /// preceding keyframe and decodes forward to the requested instant: how far back that keyframe
    /// sits is the variance.
    ///
    /// This now returns immediately and the work happens on ``sessionQueue``. `completion` is
    /// called on that queue when the session exists, when the request failed, or when a newer
    /// request superseded it. The error travels through the completion rather than `throws`
    /// because there is no longer a caller sitting on the result.
    ///
    /// - Parameter resume: whether to play after the jump. `nil` means "as the player was", which
    ///   is the intent rather than the clock's state — during startup the clock is deliberately
    ///   held until the first frame exists, and a seek in that window must not turn a film that is
    ///   starting into a film that is paused.
    public func seek(to seconds: Double,
                     resume: Bool? = nil,
                     completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        let target = max(0, min(seconds, info.duration))
        lock.lock()
        // Read *now*, not when the build runs: whether the film was playing is a fact about the
        // moment of the click, and by the time the queue reaches it the old session is gone.
        let wasPlaying = resume ?? (playRequested || clock.isPlaying)
        lock.unlock()

        if info.duration > 0, target >= info.duration {
            completion?(.failure(Failure.pastEnd(seconds)))
            return
        }

        let token = nextToken()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // `completion?(…)` returns `Void?`, so it cannot be the operand of `return` in a
            // `Void` closure — the call and the return have to be separate statements.
            guard self.isCurrent(token) else {
                completion?(.success(()))
                return
            }
            do {
                try self.beginSession(at: target, resetClock: false)
            } catch {
                completion?(.failure(error))
                return
            }
            self.lock.lock()
            // A seek to a new position has to decode and re-prepare too, so resuming goes
            // through the same gate as a first play rather than starting the clock into a gap.
            // `beginSession` has already moved the sound and the clock to `target`.
            self.playRequested = wasPlaying
            self.lock.unlock()
            if !wasPlaying { self.clock.pause() }
            completion?(.success(()))
        }
    }

    /// Stop and release everything.
    ///
    /// The session is **detached** here, on the caller's thread, because that is what makes the
    /// picture stop and it is a single pointer write. The join and the decoder close — the parts
    /// that block — go to ``sessionQueue``, where they cannot hold up the caller. Anything already
    /// queued is invalidated first: a build that is about to run belongs to a film that is no
    /// longer open.
    public func stop() {
        lock.lock()
        let current = session
        session = nil
        playRequested = false
        firstFrameReady = false
        lock.unlock()
        _ = nextToken()
        stopWatchdog()
        guard let current else { return }
        sessionQueue.async { [self] in
            tearDown(current, wait: true)
            audio?.pause()
            clock.stop()
        }
    }

    /// Which frame counters a status should carry.
    ///
    /// Extracted and tested on its own because the bug it fixes was a **choice between two
    /// sources**, and a choice is testable without a decoder while neither source is.
    static func counters(live: DisplayPresenter?,
                         report: DisplayPresenter.Report?) -> (shown: Int, dropped: Int) {
        guard let live else {
            return (report?.shown ?? 0, report?.dropped ?? 0)
        }
        return (live.shown, live.dropped)
    }

    /// Where the film is, and what the picture has done so far.
    ///
    /// ## Why the counters come from the presenter and not from the report
    ///
    /// `lastReport` is assigned in `finish(_:session:)` — the handler for a run that has
    /// **ended**. Reading `shown` from it means reading `nil` for the whole of a film, and `0`
    /// is what `nil` becomes. So `status.shown` was structurally zero during playback: a caller
    /// polling it to find out whether playback was keeping up was told, every time, that
    /// nothing had been shown.
    ///
    /// Measured: the app played the real 4K film correctly — picture advancing, skip counter
    /// climbing, sound in sync — while its rate readout said **"0.0 fps of 59.94 presented"**
    /// from the first frame to the last. `DisplayPresenter.shown` exists precisely for this and
    /// says so in its own documentation ("readable *during* a run, which is the only way a
    /// player can show a live drop rate"); the controller was simply not asking it.
    ///
    /// The report stays as the fallback, for the state after a run has ended and its session
    /// released — where the live counters are gone and the report is the only record left.
    public var status: Status {
        lock.lock()
        let report = lastReport
        let presenter = session?.presenter
        let skipped = session?.skipped.count ?? lastSkipped
        lock.unlock()

        // Read outside the controller's lock, because `DisplayPresenter.shown` takes the
        // presenter's own. Taking one lock while holding the other is how two correct pieces of
        // code deadlock when they are put together, and it would be a deadlock that only shows
        // up under a poll from another thread — which is exactly how this is used.
        let counters = Self.counters(live: presenter, report: report)

        return Status(state: clock.state,
                      position: clock.mediaTime,
                      duration: info.duration,
                      shown: counters.shown,
                      dropped: counters.dropped,
                      skippedIntervals: skipped)
    }

    /// Anything that went wrong: engine failures, sink failures, a decoder that died.
    public var problems: [String] {
        lock.lock(); defer { lock.unlock() }
        return problemList
    }

    /// Wait for the current session to finish — the film reaching its end, or a failure.
    /// Returns when both threads have stopped.
    public func waitUntilFinished() {
        lock.lock()
        let current = session
        lock.unlock()
        guard let current else { return }
        current.producerDone.wait()
        current.presenterDone.wait()
    }

    // MARK: - Sessions

    private func beginSession(at seconds: Double, resetClock: Bool) throws {
        // The invariant this whole file depends on, stated where it can be enforced: exactly one
        // build at a time, on one queue. Every caller above goes through `sessionQueue` — `start`
        // with `sync`, everything else with `async` — so a seek, a watchdog narrowing and an
        // end-of-film restart cannot interleave and tear down each other's sessions.
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        lock.lock()
        let previous = session
        session = nil
        lock.unlock()
        if let previous { tearDown(previous, wait: true) }

        let outputRate = configuration.outputRate
        let sourceRate = info.frameRate
        // What the pipeline will actually be handed. The resolution is decided here, once,
        // and everything downstream — the buffers, the sink, the presentation size — is
        // built from this rather than from the file's own dimensions.
        let presentation = resolveInterpolation()
        let planner = IntervalPlanner(source: sourceRate, output: outputRate)

        // Which source frame to start from, and therefore which output frame the run's
        // first rendered frame is. The clock is in film time and the timestamps are in
        // output frames, so the two have to be made to agree here — and the numbering has
        // to be the *film's*, not the run's, or a seek would put the picture back at zero
        // while the sound kept going.
        let startInterval = max(0, Int((seconds * sourceRate.doubleValue).rounded(.down)))
        let outputStart = planner.output(forInterval: startInterval).first?.index ?? 0

        // The tracker's history, exactly as a segment needs it: without it the first
        // interval of the run is judged with no backward evidence and a cut at the seek
        // point is decided differently from the same cut mid-film.
        let leadIn = min(startInterval, Self.leadInIntervals)

        let source: FFmpegFrameSource
        do {
            source = try FFmpegFrameSource(
                url: url, info: presentation,
                startSeconds: Self.seekSeconds(forFrame: startInterval - leadIn,
                                               rate: sourceRate),
                frameLimit: nil,
                scale: presentation.width != info.width)
        } catch {
            throw Failure.source("\(error)")
        }

        let queue = PlaybackBuffer(
            capacity: PlaybackPacer(outputRate: outputRate,
                                    leadSeconds: configuration.leadSeconds).leadFrames)
        let sink = DisplayFrameSink(queue: queue, width: presentation.width,
                                    height: presentation.height,
                                    format: presentation.format,
                                    outputOffset: outputStart)
        let pacer = PlaybackPacer(outputRate: outputRate,
                                  leadSeconds: configuration.leadSeconds)

        // The skip policy, and the only place the clock is consulted during a run. An
        // interval is worth rendering while the film has not finished playing it.
        let clock = self.clock
        let skipped = Counter()
        let renders: @Sendable (Int) -> Bool = { interval in
            let wanted = pacer.rendersInterval(interval, source: sourceRate,
                                               at: clock.mediaTime)
            if !wanted { skipped.increment() }
            return wanted
        }

        let pipeline = InterpolationPipeline(
            source: source, sourceRate: sourceRate, outputRate: outputRate,
            configuration: .init(depth: configuration.depth,
                                 sceneDetection: configuration.sceneDetection,
                                 window: .init(readFromInterval: startInterval - leadIn,
                                               renderFromInterval: startInterval,
                                               renderToInterval: Int.max,
                                               outputStart: outputStart),
                                 rendersInterval: renders))

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: outputRate)
        let newSession = Session(queue: queue, source: source, sink: sink,
                                 presenter: presenter, skipped: skipped)
        presenter.onReady = { [weak self] in self?.firstFrameArrived() }

        // **The sound moves first, and it is waited on.** The clock's anchor records the
        // sound's position, so an unarrived seek would leave the anchor pointing at the old
        // position — and the playhead would then gain the whole distance seeked the moment the
        // sound arrived, which reads as a stutter and is really arithmetic. This is why
        // `AudioTransport.seek` is required to be synchronous.
        audio?.seek(to: seconds)
        if resetClock { clock.stop() }
        // Where this run begins. `stop()` puts the playhead at zero, so a run that starts
        // anywhere else has to say so — otherwise the frames would be numbered from
        // `startSeconds` while the clock sat at zero, and the presenter would consider every
        // one of them superseded until the clock caught up: a film that begins with minutes
        // of black.
        clock.seek(to: seconds)

        let producer = Thread { [weak self, newSession, pipeline, sink] in
            defer { newSession.producerDone.signal() }
            do {
                _ = try pipeline.run(into: sink)
            } catch {
                newSession.producerFailure = error
                // A read that fails because the decoder was closed on purpose is how a stop
                // and a seek are *supposed* to end a run, not a fault in the film.
                if !newSession.tearingDown {
                    self?.record("the film stopped early: \(error)")
                }
            }
        }
        producer.name = "interp.playback.producer"

        let consumer = Thread { [weak self, newSession, presenter] in
            defer { newSession.presenterDone.signal() }
            let report = presenter.run()
            self?.finish(report, session: newSession)
        }
        consumer.name = "interp.playback.presenter"

        lock.lock()
        session = newSession
        firstFrameReady = false
        lock.unlock()

        producer.start()
        consumer.start()
    }

    /// The first frame of the session exists. Honour a play request that was made before it
    /// did — which is the normal case, because pressing play is what starts the work.
    private func firstFrameArrived() {
        lock.lock()
        firstFrameReady = true
        let wanted = playRequested
        lock.unlock()
        if wanted { startPlaying() }
    }

    /// Begin the run for real: the sound and the clock, in that order.
    ///
    /// The sound first for the same reason a seek moves it first — `clock.play()` anchors
    /// media time against the sound's position, and anchoring a moment before the sound starts
    /// is right; anchoring and then *moving* the sound would not be.
    private func startPlaying() {
        audio?.play()
        clock.play()
        startWatchdog()
    }

    /// Start the film again from the beginning, after it has ended.
    ///
    /// A new session, because the old one's threads are gone and a pipeline is single-use.
    /// The play request is re-armed rather than honoured immediately: the first frame of the
    /// new session does not exist yet, and starting the clock now is invariant 36 all over
    /// again — with sound, a picture that starts a second and a third behind the soundtrack
    /// and never catches up.
    private func restart() {
        // The play request is armed *before* the build is queued, so that the first frame of the
        // new session finds it already waiting — `firstFrameArrived` is what honours it, and it
        // can arrive on the presenter's thread the moment the session starts producing.
        let token = nextToken()
        lock.lock()
        playRequested = true
        lock.unlock()
        sessionQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            try? self.beginSession(at: 0, resetClock: false)
        }
    }

    private func finish(_ report: DisplayPresenter.Report, session: Session) {
        lock.lock()
        let isCurrent = self.session === session
        if isCurrent { lastReport = report }
        lock.unlock()
        guard isCurrent else { return }

        // The film ended rather than being abandoned. Pin the clock so the playhead stops
        // at the end instead of running past it, and so pressing play restarts rather than
        // resuming from nowhere.
        if !report.endedByAbandon, info.duration > 0 {
            clock.end(at: info.duration)
        }
        for problem in report.problems { record(problem) }
    }

    private func tearDown(_ session: Session, wait: Bool) {
        // Order matters. Abandoning wakes both ends, and closing the source makes the
        // decoder stop, which is what ends the producer's loop — a pipeline cannot be
        // interrupted from outside, deliberately, so the way to stop one is to take away
        // what it is reading.
        session.tearingDown = true
        session.queue.abandon()
        session.source.close()
        if wait {
            session.producerDone.wait()
            session.presenterDone.wait()
            lastSkipped = session.skipped.count
        }
    }

    private func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }

    // MARK: - The rate watchdog

    /// Begin watching the presented rate. Idempotent, and a no-op unless the policy asked to be
    /// measured: `.source` and `.p1080` are *instructions*, and a player that quietly narrows a
    /// size the user chose is a player that lied about a setting.
    private func startWatchdog() {
        guard configuration.resolutionPolicy == .automatic else { return }
        lock.lock()
        guard watchdog == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + Self.watchdogInterval,
                       repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkRate() }
        // Resumed before it is stored, so nothing can ever cancel a suspended source — which
        // traps rather than failing.
        timer.resume()
        watchdog = timer
        lock.unlock()
    }

    private func stopWatchdog() {
        lock.lock()
        let timer = watchdog
        watchdog = nil
        watchdogSample = nil
        shortSamples = 0
        lock.unlock()
        timer?.cancel()
    }

    /// One sample: what has the picture actually done since the last one?
    private func checkRate() {
        let state = status
        lock.lock()
        let ready = firstFrameReady
        lock.unlock()

        // Nothing to judge while the film is paused, and nothing to judge while a session is
        // being rebuilt: a rebuild is a second with no frames in it *by construction*, and
        // counting that as a shortfall would narrow the picture because the player rebuilt.
        guard state.state == .playing, ready else {
            lock.lock()
            watchdogSample = nil
            shortSamples = 0
            lock.unlock()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let previous = watchdogSample
        watchdogSample = (shown: state.shown, at: now)
        lock.unlock()

        guard let previous, now > previous.at else { return }
        let achieved = Double(state.shown - previous.shown) / (now - previous.at)
        let target = configuration.outputRate.doubleValue
        guard target > 0 else { return }

        guard achieved < target * Self.watchdogTolerance else {
            lock.lock(); shortSamples = 0; lock.unlock()
            return
        }

        lock.lock()
        shortSamples += 1
        let patience = shortSamples
        let taken = narrowings
        lock.unlock()
        guard patience >= Self.watchdogPatience, taken < Self.maximumNarrowings else { return }
        narrow()
    }

    /// Give up one rung of the ladder and rebuild the session at the same instant of film.
    private func narrow() {
        lock.lock()
        let current = (resolved ?? info).width
        lock.unlock()

        guard let next = InterpolationWidth.narrower(than: current, sourceWidth: info.width) else {
            // Already on the narrowest rung. Stop asking: there is nothing left to give, and a
            // check every second and a half that can only rebuild forever is worse than a
            // picture that is honestly short of the rate.
            lock.lock(); narrowings = Self.maximumNarrowings; lock.unlock()
            return
        }

        let narrowed = InterpolationWidth.scaled(info, toWidth: next)
        let at = clock.mediaTime
        lock.lock()
        resolved = narrowed
        narrowings += 1
        shortSamples = 0
        watchdogSample = nil
        lock.unlock()

        record("the picture did not hold \(configuration.outputRate) at \(current) wide, so it was "
               + "lowered to \(narrowed.width)x\(narrowed.height); the film keeps playing from the "
               + "same instant")

        // The sound keeps playing. `beginSession` moves it to `at`, which is where it already is,
        // so what the viewer sees is a hitch in the picture rather than a jump in the film.
        //
        // Queued on the session queue, where a rebuild and a user's seek cannot overlap. It takes
        // a token like every other request, so a seek issued while this is queued wins — which is
        // the right answer, because the seek is the more recent statement of where the film should
        // be, and `resolved` has already been narrowed for whichever session builds next.
        let token = nextToken()
        sessionQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            try? self.beginSession(at: at, resetClock: false)
        }
    }

    // MARK: - Arithmetic

    /// Intervals of lead-in a run reads before its first rendered interval.
    ///
    /// `SceneChangeDetector.Config.historyLength` is 30, and the tracker needs the history
    /// before it can judge an interval the way the whole-film render would.
    static let leadInIntervals = 31

    /// The size the pipeline will be handed, decided once per film.
    ///
    /// `.automatic` runs a **real calibration** here: a short measured probe of the actual
    /// pipeline, on the actual film, at each rung of the width ladder, widest first, stopping at
    /// the first that fits the film's budget. It is the same question SVP answers with
    /// `fi_auto: true`, answered once at load rather than continuously.
    ///
    /// It runs *before the clock starts*, and that placement is load-bearing. Invariant 36 says a
    /// player must not start its clock before the first frame exists; a calibration run during
    /// playback would be a hitch in the film rather than a delay before it. It also has to happen
    /// before the source is built, because the width is what the decoder is told to scale to.
    ///
    /// The answer is cached, so a seek does not pay for it again.
    private func resolveInterpolation() -> MediaInfo {
        lock.lock()
        let cached = resolved
        lock.unlock()
        if let cached { return cached }

        let chosen: MediaInfo
        switch configuration.resolutionPolicy {
        case .source, .p1080:
            chosen = Self.presentationSize(for: info, policy: configuration.resolutionPolicy)

        case .automatic:
            // Probe a little way in rather than at frame zero. An opening logo is static, and
            // while the engine's cost is close to content-independent — measured at 106.8 against
            // 104.7 ms/interval between a bright desert scene and a dark one — there is no reason
            // to measure the one part of a film that is not representative.
            let probeStart = min(30, max(0, info.duration * 0.1))
            let (choice, scaled) = PlaybackCalibrator.calibrate(
                url: url, info: info,
                sourceRate: info.frameRate,
                outputRate: configuration.outputRate,
                depth: configuration.depth,
                startSeconds: probeStart)
            chosen = scaled
            lock.lock()
            calibration = choice
            lock.unlock()
            if choice.fellBack {
                record("no interpolation size held the film's rate on this machine; "
                       + "using \(choice.width) wide, which will drop frames")
            }
        }

        lock.lock()
        resolved = chosen
        lock.unlock()
        return chosen
    }

    /// What the rate watchdog has seen, and what it has done about it.
    ///
    /// Exposed for the same reason the display layer's state is (see ``DisplayDiagnostics``): a
    /// policy that is supposed to *give ground* when its prediction was wrong has to be
    /// observable while it is deciding. From outside, "it decided not to narrow", "it is not
    /// running at all" and "it is narrowing but the width is not sticking" are the same silence,
    /// and they have three different fixes.
    public var resolutionReport: (width: Int, calibrated: Bool, watching: Bool,
                                  narrowings: Int, shortSamples: Int) {
        lock.lock(); defer { lock.unlock() }
        return ((resolved ?? info).width, calibration != nil, watchdog != nil,
                narrowings, shortSamples)
    }

    /// The size the picture is interpolated at, and what decided it.
    ///
    /// Kept out of ``Status`` on purpose: it is a property of the *film and the machine* rather
    /// than of the moment. It does not change while the film plays, so it does not belong in the
    /// thing a UI polls ten times a second.
    public var interpolationSize: (width: Int, height: Int,
                                   policy: PlaybackResolutionPolicy, calibrated: Bool) {
        lock.lock(); defer { lock.unlock() }
        let size = resolved ?? info
        return (size.width, size.height, configuration.resolutionPolicy, calibration != nil)
    }

    /// The size the pipeline will be handed, after any downscale.
    ///
    /// Height is forced **even**. 4:2:0 chroma is subsampled by two in both directions, so an
    /// odd height is not a slightly wrong picture — it is a frame the pixel format cannot
    /// describe, and the failure arrives far from here as a buffer that will not allocate.
    /// 3840×1632 halves to 1920×816, which happens to be even; a 2160-high source would not.
    ///
    /// `.automatic` is **not** answered here. Its width comes from a measurement rather than
    /// from the policy, and a pure function cannot measure anything — see
    /// ``resolveInterpolation()``.
    static func presentationSize(for info: MediaInfo,
                                 policy: PlaybackResolutionPolicy) -> MediaInfo {
        guard let width = policy.fixedWidth else { return info }
        return InterpolationWidth.scaled(info, toWidth: width)
    }

    /// The seek instant that lands on a given frame.
    ///
    /// `-ss` returns the first frame at or **after** the instant, so frame `n` — which
    /// presents at `n / rate` — needs an instant in `(PTS(n-1), PTS(n)]`, whose midpoint is
    /// `(n - 0.5) / rate`. Aiming at `(n + 0.5) / rate` returns `n + 1`; that cost this
    /// project a whole round of "why does the segmented render drift" (invariant 32).
    ///
    /// Frame 0 is the exception: there is nothing before it to land in, so the seek is zero
    /// rather than a negative time, which ffmpeg would reject.
    static func seekSeconds(forFrame frame: Int, rate: FrameRate) -> Double? {
        guard frame > 0 else { return nil }
        return (Double(frame) - 0.5) / rate.doubleValue
    }

    /// Counts calls, for the skip policy's report.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
