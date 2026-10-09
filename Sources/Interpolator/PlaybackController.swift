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
        /// Scale the picture down before interpolating.
        ///
        /// The downscale toggle the 4K decision was recorded with, and the only thing that
        /// makes 4K material play in real time on a machine that cannot interpolate it:
        /// interpolation is per-pixel, so 1080p is a quarter of the work. The measured 4K
        /// result is half the intervals skipped and a constant ~150 ms lag; this is how a
        /// user buys that back, at the cost of the resolution.
        ///
        /// Ignored when the source is already at or below 1080p — upscaling would be work
        /// spent to lose information.
        public var downscaleTo1080p: Bool

        public init(outputRate: FrameRate,
                    depth: Int = 2,
                    sceneDetection: Bool = true,
                    leadSeconds: Double = 1.0,
                    startSeconds: Double = 0,
                    downscaleTo1080p: Bool = false) {
            self.outputRate = outputRate
            self.depth = depth
            self.sceneDetection = sceneDetection
            self.leadSeconds = leadSeconds
            self.startSeconds = startSeconds
            self.downscaleTo1080p = downscaleTo1080p
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
    /// Kept after a session is torn down, so `status` still answers once the film has ended.
    private var lastSkipped = 0
    private var problemList: [String] = []
    /// A play request that is waiting for the first frame to exist.
    private var playRequested = false
    private var firstFrameReady = false

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
        lock.unlock()
        if let current { tearDown(current, wait: false) }
        audio?.pause()
    }

    // MARK: - Transport

    /// Build the session and start producing. The film does not play until ``play()``.
    public func start() throws {
        lock.lock()
        guard session == nil else {
            lock.unlock()
            throw Failure.alreadyStarted
        }
        lock.unlock()
        try beginSession(at: configuration.startSeconds, resetClock: true)
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
    }

    /// Jump to a position. Rebuilds the session, which takes about a second.
    public func seek(to seconds: Double) throws {
        lock.lock()
        let wasPlaying = clock.isPlaying
        lock.unlock()
        let target = max(0, min(seconds, info.duration))
        if info.duration > 0, target >= info.duration {
            throw Failure.pastEnd(seconds)
        }
        try beginSession(at: target, resetClock: false)
        lock.lock()
        // A seek to a new position has to decode and re-prepare too, so resuming goes
        // through the same gate as a first play rather than starting the clock into a gap.
        // `beginSession` has already moved the sound and the clock to `target`.
        playRequested = wasPlaying
        lock.unlock()
        if !wasPlaying { clock.pause() }
    }

    /// Stop and release everything.
    public func stop() {
        lock.lock()
        let current = session
        session = nil
        playRequested = false
        firstFrameReady = false
        lock.unlock()
        guard let current else { return }
        tearDown(current, wait: true)
        audio?.pause()
        clock.stop()
    }

    public var status: Status {
        lock.lock()
        let report = lastReport
        let skipped = session?.skipped.count ?? lastSkipped
        lock.unlock()
        return Status(state: clock.state,
                      position: clock.mediaTime,
                      duration: info.duration,
                      shown: report?.shown ?? 0,
                      dropped: report?.dropped ?? 0,
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
        lock.lock()
        let previous = session
        session = nil
        lock.unlock()
        if let previous { tearDown(previous, wait: true) }

        let outputRate = configuration.outputRate
        let sourceRate = info.frameRate
        // What the pipeline will actually be handed. The downscale is decided here, once,
        // and everything downstream — the buffers, the sink, the presentation size — is
        // built from this rather than from the file's own dimensions.
        let presentation = Self.presentationSize(for: info,
                                                 downscale: configuration.downscaleTo1080p)
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
    }

    /// Start the film again from the beginning, after it has ended.
    ///
    /// A new session, because the old one's threads are gone and a pipeline is single-use.
    /// The play request is re-armed rather than honoured immediately: the first frame of the
    /// new session does not exist yet, and starting the clock now is invariant 36 all over
    /// again — with sound, a picture that starts a second and a third behind the soundtrack
    /// and never catches up.
    private func restart() {
        try? beginSession(at: 0, resetClock: false)
        lock.lock()
        playRequested = true
        lock.unlock()
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

    // MARK: - Arithmetic

    /// Intervals of lead-in a run reads before its first rendered interval.
    ///
    /// `SceneChangeDetector.Config.historyLength` is 30, and the tracker needs the history
    /// before it can judge an interval the way the whole-film render would.
    static let leadInIntervals = 31

    /// The size the pipeline will be handed, after any downscale.
    ///
    /// Height is forced **even**. 4:2:0 chroma is subsampled by two in both directions, so an
    /// odd height is not a slightly wrong picture — it is a frame the pixel format cannot
    /// describe, and the failure arrives far from here as a buffer that will not allocate.
    /// 3840×1632 halves to 1920×816, which happens to be even; a 2160-high source would not.
    static func presentationSize(for info: MediaInfo, downscale: Bool) -> MediaInfo {
        guard downscale, info.width > 1920 else { return info }
        let factor = 1920.0 / Double(info.width)
        let height = max(2, Int((Double(info.height) * factor).rounded()) & ~1)
        return info.scaled(toWidth: 1920, height: height)
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
