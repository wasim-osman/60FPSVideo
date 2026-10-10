import AVFoundation
import AppKit
import Foundation
import Interpolator
import Observation

/// One film, as the player sees it.
struct Film: Sendable, Identifiable {
    var id: URL { url }
    let url: URL
    let info: MediaInfo

    var name: String { url.lastPathComponent }
    var is4K: Bool { info.width > 1920 }
}

/// The whole app's state, and the only thing that talks to the library.
///
/// ## Why one model and not a model per screen
///
/// The player and the batch converter share one GPU, one ffmpeg, and — the part that makes a
/// split awkward — one set of recorded decisions. A player that downscales to 1080p while the
/// converter writes 4K is the *same setting* read by two paths, and two models would be two
/// places for them to disagree. So the settings live here once and both screens read them.
@MainActor
@Observable
final class AppModel {

    // MARK: - Settings

    var settings: AppSettings {
        didSet { settings.save() }
    }

    // MARK: - The film

    private(set) var film: Film?
    private(set) var loading = false
    var loadError: String?

    // MARK: - Playback

    let displayHost = DisplayHost()
    private(set) var status: PlaybackController.Status?
    private(set) var problems: [String] = []
    /// What the sound turned out to be: which track, by which route, and how long it took.
    private(set) var soundLine: String?
    /// A line for work that has to happen before a frame can be shown.
    private(set) var preparing: String?
    /// Measured frames per second of wall time, from the player's own count.
    private(set) var presentedRate: Double = 0
    /// Where the scrubber is. Separate from `status.position` so dragging does not fight the
    /// clock — a scrubber bound straight to the playhead moves under the user's finger.
    var scrubPosition: Double = 0
    var isScrubbing = false

    private var controller: PlaybackController?
    private var sound: PlaybackAudio?
    private var ticker: Task<Void, Never>?
    private var playBegan: Date?
    private var playBeganShown = 0
    /// Whether the last tick saw the picture running. The rate is measured across the
    /// **transition into** playing, which is the only instant at which both counts are zero.
    private var wasPlaying = false

    // MARK: - The batch queue

    private(set) var jobs: [BatchJob] = []
    private(set) var queueRunning = false
    private var queueTask: Task<Void, Never>?

    // MARK: - The soundtrack cache

    private(set) var cacheBytes: Int64 = 0
    private(set) var cacheEntries = 0

    // MARK: - Folder access

    /// What macOS last said about the folders films live in.
    ///
    /// Filled in from work the user actually asked for, never from a probe on a screen that
    /// merely opened. A check *is* the question — there is no way to read the answer without
    /// attempting the access, and attempting it on a folder macOS has never been asked about
    /// raises a prompt. Probing three folders to populate a status line therefore raises three
    /// dialogs, measured one at a time; a settings screen that greets you with a queue of
    /// system alerts is worse than a status line that says "not asked yet".
    private(set) var folderAccess: FolderAccess.Report = FolderAccess.report()
    private(set) var checkingFolderAccess = false

    /// What real operations have proved, keyed by folder path.
    ///
    /// Evidence rather than a question: the app has just read a file here, or just been
    /// refused one. Neither raises a prompt, which is the point.
    private var knownFolderAccess: [String: FolderAccess.State] = [:]

    init(settings: AppSettings = .load()) {
        self.settings = settings
    }

    // MARK: - Opening a film

    func chooseAndOpen() {
        guard let url = FileChooser.chooseFilm() else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        await closeFilm()
        loading = true
        loadError = nil
        do {
            // Probing runs ffprobe, so it goes off the main actor. `MediaInfo` is `Sendable`,
            // which is what makes that a one-line `await` rather than a reason to keep a
            // subprocess on the thread that draws the window.
            let info = try await Task.detached(priority: .userInitiated) {
                try MediaProbe.probe(url)
            }.value
            let opened = Film(url: url, info: info)
            film = opened
            // The film read. That is an answer macOS has already given about this folder, and
            // recording it here is what lets the settings row say something true without ever
            // asking a question of its own.
            noteFolderAccess(for: url, succeeded: true)
            try await startSession(for: opened)
        } catch {
            // A film that will not open is the failure this app was worst at explaining: macOS
            // refuses the read, the probe fails, and what the user sees is a message about the
            // probe. If the folder is one macOS gates, say so and say where the switch is.
            //
            // Classifying the failure is safe here — the read has just been refused, so this
            // returns immediately and cannot raise a prompt the user did not ask for.
            var message = "\(error)"
            let verdict = FolderAccess.classify(afterFailureIn: url)
            knownFolderAccess[verdict.path] = verdict.state
            refreshFolderAccess()
            if verdict.state == .refused {
                message += "\n\nmacOS is refusing this app access to "
                    + "\(url.deletingLastPathComponent().lastPathComponent). "
                    + "Open Settings ▸ Folder access to put that right."
            }
            loadError = message
        }
        loading = false
    }

    func closeFilm() async {
        ticker?.cancel()
        ticker = nil
        controller?.stop()
        controller = nil
        sound?.shutdown()
        sound = nil
        displayHost.discardQueuedFrames()
        endRealTimeActivity()
        film = nil
        status = nil
        problems = []
        soundLine = nil
        preparing = nil
        presentedRate = 0
        playBegan = nil
        wasPlaying = false
        scrubPosition = 0
    }

    /// Tell macOS this process is doing real-time work, for as long as a film is open.
    ///
    /// Measured, and the reason this exists: with the window in the background the film
    /// **stalled** — the picture froze, the transport went back to "play" and the position
    /// stopped at 0:01:10.3 and stayed there across three samples twelve seconds apart — while
    /// the same build playing in the foreground advanced normally, 798 → 799 → 800 → 801
    /// intervals. A player that only plays when you are looking at it is not a player.
    ///
    /// `.userInitiated` says the work is for the user and should not be deferred;
    /// `.latencyCritical` says it has a deadline, which a frame that must be on screen in
    /// 16.7 ms certainly has. Together they are what stops App Nap from coalescing the
    /// presenter's timers and the decoder's wakeups into a schedule of its own choosing.
    ///
    /// Held from the moment a session is built to the moment it is torn down, including while
    /// paused. A pause is a moment in a film, not the end of the app's real-time obligation —
    /// and releasing the assertion on pause is how you get a player that stutters for the first
    /// second after every resume while the scheduler works out that it means it again.
    private var activity: NSObjectProtocol?

    private func beginRealTimeActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "playing a film at 59.94 fps")
    }

    private func endRealTimeActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    /// Build the session: the sound first, because the clock is built over it.
    private func startSession(for film: Film) async throws {
        var prepared: PlaybackAudio?
        var line: String?

        if settings.useSound, !film.info.audioTracks.isEmpty {
            let plan = AudioPlaybackPlan.choose(
                for: film.info,
                containerIsPlayable: AudioPlaybackPlan.containerIsPlayable(film.url))

            switch plan {
            case .none:
                line = "no audio"
            case .direct:
                // Nothing to prepare, so there is nothing to wait for and nothing to say.
                prepared = try await PlaybackAudio(url: film.url, plan: plan,
                                                   track: film.info.audioTracks.first)
                line = "\(plan)"
            case .remux, .transcode:
                // The one case a user has to wait for, and it is worth saying why: a DTS-only
                // disc takes minutes and a copy of the disc's own compatibility track takes
                // seconds, and the difference is invisible unless it is stated.
                preparing = plan.isLossless
                    ? "Copying the disc's \(plan.codec ?? "") track…"
                    : "Re-encoding \(plan.codec ?? "") to AAC — this disc has nothing macOS can play…"
                let extractor = AudioExtractor()
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try extractor.prepare(from: film.url, info: film.info)
                }.value
                preparing = nil
                prepared = try await PlaybackAudio(url: outcome.url, plan: outcome.plan,
                                                   track: track(of: outcome.plan,
                                                                in: film.info))
                line = "\(outcome.plan)"
                    + (outcome.fromCache ? "  (cached)" : "")
                    + String(format: "  ·  %.1f MB", Double(outcome.bytes) / 1e6)
                if !outcome.fromCache {
                    line? += String(format: "  ·  prepared in %.1f s", outcome.wallSeconds)
                }
            }
        } else if !film.info.audioTracks.isEmpty {
            line = "sound is off"
        }

        displayHost.prepare(for: film.info)
        sound = prepared
        soundLine = line

        let controller = PlaybackController(
            url: film.url,
            display: displayHost.renderer,
            configuration: .init(outputRate: settings.policy.resolve(
                                    source: film.info.frameRate).output,
                                 depth: settings.depth,
                                 sceneDetection: settings.sceneDetection,
                                 downscaleTo1080p: settings.playbackDownscales),
            info: film.info,
            audio: prepared)
        self.controller = controller
        // A fresh controller is a fresh measurement. `wasPlaying` is reset rather than carried
        // over, because the ticker's whole job is to notice the *transition* into playing and a
        // new session that starts already "playing" has no transition to notice.
        playBegan = nil
        wasPlaying = false
        beginRealTimeActivity()
        controller.play()
        try controller.start()
        sound?.setSpeed(settings.playbackSpeed)
        sound?.volume = settings.volume
        startTicking()
        refreshCacheSize()
    }

    private func track(of plan: AudioPlaybackPlan, in info: MediaInfo) -> AudioTrack? {
        info.audioTracks.first { $0.index == plan.track }
    }

    // MARK: - Transport

    func play() {
        controller?.play()
    }

    func pause() {
        controller?.pause()
        // Disarm here as well as in the ticker. The two can disagree for up to one tick, and a
        // pause-and-resume inside that window would otherwise go unnoticed and leave the paused
        // seconds in the average — a rate that is wrong in the direction that flatters the app.
        playBegan = nil
        wasPlaying = false
    }

    func togglePlay() {
        (status?.state == .playing) ? pause() : play()
    }

    func stop() {
        controller?.stop()
        playBegan = nil
        wasPlaying = false
    }

    /// Jump. The session is rebuilt, which is about a second of work on the main thread.
    ///
    /// Yielded first so the "seeking" state is actually drawn: a `seek` that begins inside the
    /// same run-loop turn as the click leaves the user looking at the old frame with no
    /// indication that anything is happening.
    func seek(to seconds: Double) {
        guard let controller else { return }
        let target = max(0, min(seconds, film?.info.duration ?? seconds))
        preparing = "Seeking…"
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            try? controller.seek(to: target)
            preparing = nil
            // A seek is a discontinuity, so the measurement starts again after it — a second of
            // rebuilding with no frames in it is not evidence about the rate the picture runs at.
            playBegan = nil
            wasPlaying = false
            refresh()
        }
    }

    func setSpeed(_ speed: Double) {
        settings.playbackSpeed = speed
        // The sound carries the speed, not the clock: the clock's host time is already media
        // time, so a speed in both would multiply.
        sound?.setSpeed(speed)
    }

    func setVolume(_ volume: Double) {
        settings.volume = volume
        sound?.volume = volume
    }

    func setSoundEnabled(_ enabled: Bool) {
        settings.useSound = enabled
        if !enabled { sound?.pause() }
    }

    /// Rebuild the session with the current settings. How a resolution change takes effect.
    func reloadForSettingsChange() {
        guard let film else { return }
        let position = status?.position ?? 0
        let wasPlaying = status?.state == .playing
        Task { @MainActor in
            preparing = "Applying settings…"
            ticker?.cancel()
            ticker = nil
            controller?.stop()
            controller = nil
            sound?.shutdown()
            sound = nil
            do {
                try await startSession(for: film)
                if position > 0 { try? controller?.seek(to: position) }
                if wasPlaying { play() }
            } catch {
                loadError = "\(error)"
            }
            preparing = nil
        }
    }

    // MARK: - The ticker

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func refresh() {
        guard let controller else { return }
        let latest = controller.status
        status = latest
        problems = controller.problems
        if !isScrubbing { scrubPosition = latest.position }

        // The measurement is armed on the **transition into** playing, not on the play request.
        //
        // A play request is not a play. `PlaybackController` holds the clock until the first
        // frame exists — starting it earlier would put the picture permanently behind the sound,
        // with no mechanism to catch up — so at the instant a user presses play, nothing has been
        // shown and nothing is running. Arming there and then disarming on the first "not playing
        // yet" tick is what the first version did, and it left the readout saying
        // **"0.0 fps of 59.94 presented"** for the whole of a film that was playing perfectly:
        // the picture advanced, the skip counter climbed, and the one number that exists to say
        // whether playback is keeping up said zero.
        //
        // Arming on the transition is also the only version that survives a buffering gap, a
        // seek, or a settings reload — each of which stops and restarts the picture without any
        // of them being a play request this model ever sees.
        let playing = latest.state == .playing
        if playing, !wasPlaying {
            playBegan = Date()
            playBeganShown = latest.shown
            presentedRate = 0
        } else if !playing {
            playBegan = nil
        }
        wasPlaying = playing

        if let began = playBegan {
            let wall = Date().timeIntervalSince(began)
            // Measured, not assumed: this is the number §13 requires the app to show rather
            // than pretending, because a 4K source playing at half the target rate is a real
            // and acceptable state that must not look like a working one.
            if wall > 0.5 {
                presentedRate = Double(latest.shown - playBeganShown) / wall
            }
        }
    }

    // MARK: - The queue

    func addFilms() {
        add(urls: FileChooser.chooseFilms())
    }

    /// Queue these files for conversion, skipping any already queued.
    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            guard !jobs.contains(where: { $0.input == url }) else { continue }
            let job = BatchJob(input: url, output: settings.outputURL(for: url))
            jobs.append(job)
            // Probed at add time, so the row can state the resolution, rate and HDR before
            // anything runs — and so a file that cannot be read fails now rather than four
            // hours into a queue.
            Task { await probe(job) }
        }
    }

    /// Take films the system handed us — the command line, or "Open With → 60FPS".
    ///
    /// The first one goes to the player and the rest go to the queue. Opening six files at once
    /// and showing one of them while five silently vanish is worse than either extreme, and
    /// this is what the gesture means: *play this, and get on with the others.*
    func accept(urls: [URL]) {
        let films = urls.filter(FileChooser.looksLikeFilm)
        guard let first = films.first else { return }
        Task { await open(first) }
        add(urls: Array(films.dropFirst()))
    }

    /// A film named on the command line: `swift run 60FPS -- some.mkv`.
    ///
    /// The packaging script's `open -a 60FPS some.mkv` route arrives through the app delegate
    /// instead, but this one is what makes the app testable without a window manager driving
    /// the open panel.
    static func filmFromCommandLine(_ arguments: [String] = CommandLine.arguments) -> URL? {
        arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func probe(_ job: BatchJob) async {
        do {
            let info = try await Task.detached(priority: .utility) {
                try MediaProbe.probe(job.input)
            }.value
            job.info = info
            job.output = settings.outputURL(for: job.input)
            noteFolderAccess(for: job.input, succeeded: true)
        } catch {
            // A film added to the queue is read straight away — that is the point of probing at
            // add time — so a refusal surfaces here, minutes before the job would have run, and
            // is recorded rather than left to be discovered as a queue full of failures.
            let verdict = FolderAccess.classify(afterFailureIn: job.input)
            knownFolderAccess[verdict.path] = verdict.state
            refreshFolderAccess()
            job.state = .failed
            job.failure = verdict.state == .refused
                ? "\(error)\n\nmacOS is refusing this app access to "
                    + "\(job.input.deletingLastPathComponent().lastPathComponent). "
                    + "See Settings ▸ Folder access."
                : "\(error)"
        }
    }

    func remove(_ job: BatchJob) {
        jobs.removeAll { $0 === job }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .finished || $0.state == .failed }
    }

    func startQueue() {
        guard queueTask == nil else { return }
        queueRunning = true
        queueTask = Task { @MainActor [weak self] in
            while let self, let next = self.jobs.first(where: { $0.state == .waiting }) {
                await self.run(next)
            }
            self?.queueRunning = false
            self?.queueTask = nil
        }
    }

    func stopQueue() {
        queueTask?.cancel()
        queueTask = nil
        queueRunning = false
        for job in jobs where job.state == .running {
            job.state = .stopped
        }
    }

    /// One job, on a thread of its own.
    ///
    /// **One at a time, deliberately.** The interpolation is per-pixel and saturates the GPU;
    /// the measurement behind `depth` is that requests in flight stop helping at 2, and four
    /// concurrent 4K jobs would be four jobs each running at a quarter speed with four times
    /// the memory. The queue exists to make a night's work unattended, not to make it faster.
    private func run(_ job: BatchJob) async {
        job.state = .running
        job.started = Date()
        job.failure = nil

        let converter = makeConverter(for: job)
        let request = makeRequest(for: job)
        job.output = request.output

        do {
            let result = try await Task.detached(priority: .utility) {
                try converter.run(request)
            }.value
            job.result = result
            job.state = .finished
            job.progress = nil
            noteFolderAccess(for: job.input, succeeded: true)
        } catch {
            // A conversion that cannot even read its input is the other half of the silent
            // refusal: the batch queue shows a failure, and the reason is a folder macOS has
            // stopped answering about. Classifying it here records the answer without asking.
            let verdict = FolderAccess.classify(afterFailureIn: job.input)
            knownFolderAccess[verdict.path] = verdict.state
            refreshFolderAccess()
            job.failure = verdict.state == .refused
                ? "\(error)\n\nmacOS is refusing this app access to "
                    + "\(job.input.deletingLastPathComponent().lastPathComponent). "
                    + "See Settings ▸ Folder access."
                : "\(error)"
            job.state = .failed
        }
        job.finished = Date()
    }

    private func makeConverter(for job: BatchJob) -> BatchConverter {
        var converter = BatchConverter()
        let throttle = Throttle(interval: 0.1)
        converter.progress = { progress in
            // Called once per interval — 172 627 times for a two-hour film. Hopping to the
            // main actor on every one would spend more time scheduling than the interpolation
            // does, so the throttle is here rather than in the view.
            guard throttle.allow() else { return }
            Task { @MainActor in job.progress = progress }
        }
        return converter
    }

    private func makeRequest(for job: BatchJob) -> BatchConverter.Request {
        let sourceRate = job.info?.frameRate.doubleValue ?? 24
        return BatchConverter.Request(
            input: job.input,
            output: job.output,
            policy: settings.policy,
            bitRate: nil,
            depth: settings.depth,
            workers: settings.workers,
            sceneDetection: settings.sceneDetection,
            maximumSourceFrames: settings.previewSeconds.map {
                Int(($0 * sourceRate).rounded())
            },
            startSeconds: nil,
            overwrite: settings.overwrite,
            convertWhenAlreadyAtTarget: false,
            audio: settings.audioPolicy,
            segmentSeconds: settings.segmentSeconds,
            restart: job.restart,
            keepSegments: settings.keepSegments)
    }

    func reveal(_ job: BatchJob) {
        NSWorkspace.shared.activateFileViewerSelecting([job.output])
    }

    // MARK: - The soundtrack cache

    func refreshCacheSize() {
        let entries = AudioCache.default.contents()
        cacheBytes = entries.reduce(0) { $0 + $1.bytes }
        cacheEntries = entries.count
    }

    func clearCache() {
        AudioCache.default.clear()
        refreshCacheSize()
    }

    // MARK: - Folder access

    /// Refresh the status line from what is already known. **Asks nothing.**
    ///
    /// This is what the settings screen does when it opens. A probe here would raise a system
    /// prompt for every folder macOS has never been asked about — three of them, one dialog at
    /// a time — so the screen reports what the app has already proved and offers to ask.
    func refreshFolderAccess() {
        folderAccess = FolderAccess.report(known: knownFolderAccess, including: activeFolders)
    }

    /// Record what a real file operation just proved about the folder it touched.
    ///
    /// Called when a film opens and when one fails. A success is an answer macOS has already
    /// given; a failure is classified by asking again, which is safe because the read has just
    /// been refused and cannot raise a prompt the second time.
    func noteFolderAccess(for url: URL, succeeded: Bool) {
        let folder = url.deletingLastPathComponent()
        knownFolderAccess[folder.path] = succeeded
            ? .allowed
            : FolderAccess.classify(afterFailureIn: url).state
        refreshFolderAccess()
    }

    /// Every folder the app is currently working with.
    private var activeFolders: [URL] {
        var urls: [URL] = []
        if let film { urls.append(film.url) }
        urls.append(contentsOf: jobs.map(\.input))
        if let directory = settings.outputDirectory { urls.append(URL(fileURLWithPath: directory)) }
        return urls
    }

    /// Ask macOS — the row's action, and the only thing that can be done about a refusal.
    ///
    /// Two outcomes, in this order, because macOS has one answer per app:
    ///
    /// 1. **Ask.** For a folder it has never been answered about, this is the call that raises
    ///    the system prompt, which is what "clickable so the prompt can be re-triggered" asks
    ///    for.
    /// 2. **If the answer is already no**, macOS does not ask again: a second attempt fails
    ///    immediately and silently. The switch has to be moved by hand, so this opens the pane
    ///    it lives in rather than leaving a button that appears to do nothing.
    ///
    /// Off the main thread, because step 1 blocks for as long as a system prompt is on screen
    /// — blocking the main thread there would freeze the window the user is being asked about.
    func fixFolderAccess() {
        guard !checkingFolderAccess else { return }
        checkingFolderAccess = true
        let extra = activeFolders

        Task.detached(priority: .userInitiated) {
            let (report, known) = FolderAccess.probe(including: extra)
            await MainActor.run {
                self.knownFolderAccess.merge(known) { _, new in new }
                self.folderAccess = report
                self.checkingFolderAccess = false
                // Only when it is still refusing. A granted check means the prompt was answered
                // this time, and opening System Settings over a working app would be a
                // confusing thing to do to someone who just clicked "Allow".
                if !report.isClear {
                    FolderAccess.openPrivacySettings()
                }
            }
        }
    }
}

/// A rate limit, for a callback that fires 172 627 times.
///
/// A lock-protected `Date` rather than an actor, because the caller is on the job's thread and
/// an `await` there would suspend the pipeline's driving loop once per interval — turning a
/// cheap check into a scheduling round trip.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(interval: TimeInterval) { self.interval = interval }

    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

// MARK: - A job in the queue

@MainActor
@Observable
final class BatchJob: Identifiable {
    enum State: Equatable {
        case waiting, running, finished, failed, stopped

        var label: String {
            switch self {
            case .waiting: "Waiting"
            case .running: "Running"
            case .finished: "Done"
            case .failed: "Failed"
            case .stopped: "Stopped"
            }
        }
    }

    let id = UUID()
    let input: URL
    var output: URL
    var info: MediaInfo?
    var state: State = .waiting
    var progress: BatchConverter.Progress?
    var result: BatchConverter.Result?
    var failure: String?
    var started: Date?
    var finished: Date?
    /// Throw away a previous run's pieces and render everything again.
    var restart = false

    init(input: URL, output: URL) {
        self.input = input
        self.output = output
    }

    var name: String { input.lastPathComponent }

    var elapsed: TimeInterval? {
        guard let started else { return nil }
        return (finished ?? Date()).timeIntervalSince(started)
    }

    /// A projection, from what has actually happened.
    ///
    /// Only stated once there is enough of a run to mean anything, and stated as an estimate
    /// because that is what it is: the interpolation cost varies with how much of the film is
    /// moving, and a projection offered after two seconds is a guess wearing a number.
    var remaining: TimeInterval? {
        guard state == .running, let elapsed, elapsed > 30,
              let fraction = progress?.fraction, fraction > 0.02 else { return nil }
        return elapsed / fraction - elapsed
    }
}
