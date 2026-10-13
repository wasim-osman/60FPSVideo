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

/// Which screen the window is showing.
///
/// Convert first, and open on it. The queue is the reason the app exists — a film is added,
/// converted and left; the player is for checking the result. Declaration order is the picker's
/// order, so this enum's case order *is* the tab order.
///
/// Declared here rather than inside `RootView` because the full-screen chrome rule needs it: the
/// tab picker is chrome on the player and the whole of the navigation on the queue, and only the
/// model can see both that rule and the tab at once.
enum AppTab: String, CaseIterable, Identifiable {
    case batch = "Convert"
    case player = "Player"
    var id: String { rawValue }
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

    /// What size the picture is actually being interpolated at, and what decided it.
    ///
    /// Surfaced because the whole trade this app makes is a resolution one: on a 4K film that
    /// cannot hold its rate, the honest thing is to say *which* resolution it fell to rather than
    /// leave the user comparing a soft picture against nothing. `nil` before a session exists.
    var interpolationSize: (width: Int, height: Int, policy: PlaybackResolutionPolicy,
                            calibrated: Bool)? {
        controller?.interpolationSize
    }
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
    /// Which seek the UI is waiting on.
    ///
    /// The rebuild happens off the main thread now, so a click returns before its jump has
    /// finished — and a second click must mean the *second* position. Bumping this makes the
    /// first click's completion a no-op, so "Seeking…" is cleared by the jump actually in flight
    /// rather than by whichever one happens to finish first.
    private var seekToken = 0

    // MARK: - The window

    /// Which screen the window is showing.
    var tab: AppTab = .batch

    /// Whether the window is in macOS full screen, **as macOS reports it**.
    ///
    /// Read from the window and kept in step by the two full-screen notifications, rather than
    /// tracked here from the calls this model makes. That is the only version that stays true when
    /// full screen is entered or left by something this model did not do — the green button, a
    /// double click on the title bar, the stock `View ▸ Enter Full Screen`, or the state macOS
    /// restores for the window at launch, which it does.
    private(set) var isFullScreen = false

    /// Whether the tab picker and the transport are on screen.
    ///
    /// In full screen the chrome takes itself away after a few still seconds and comes back the
    /// instant the pointer moves — the difference between a video window and a video *viewer*. It
    /// stays up while the film is paused, because a paused viewer is reaching for the transport,
    /// not looking at the picture.
    private(set) var chromeVisible = true

    /// Whether the chrome should be **off** screen right now.
    ///
    /// One predicate, read by both the window shell and the player, so the two can never disagree
    /// about whether the picture owns the screen.
    var chromeHidden: Bool { isFullScreen && !chromeVisible && tab == .player }

    /// How long the chrome stays up after the pointer stops moving.
    private static let chromeIdleSeconds: Double = 2.5

    private weak var window: NSWindow?
    private var chromeTask: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var lastPointerMove = Date.distantPast

    /// Take the window SwiftUI made for this scene.
    ///
    /// Full screen is an `NSWindow` property and SwiftUI's `Window` scene does not hand the window
    /// over, so ``WindowAccessor`` reports it as soon as it exists. Everything here is idempotent:
    /// the accessor can report the same window more than once.
    func adopt(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // `.mouseMoved` is not delivered at all unless the window asks for it, and the reveal
        // gesture is the whole mechanism — so this line is the feature, not a detail.
        window.acceptsMouseMovedEvents = true
        isFullScreen = window.styleMask.contains(.fullScreen)
        observe(window)
        installEventMonitors()
        if isFullScreen { startChromeTimer() }
        // Off unless `SIXTYFPS_DIAG=1`. Started here because this is the one callback that is
        // certain to run once the window exists, which is the first moment there is anything
        // between the presenter and the glass worth describing.
        startDiagnostics(on: window)
    }

    /// The once-a-second account of the display layer. See ``DisplayDiagnostics``.
    ///
    /// Built here rather than as a `lazy var`, because the `@Observable` macro rewrites stored
    /// properties and a lazy one is not a shape it keeps.
    private var diagnostics: DisplayDiagnostics?

    private func startDiagnostics(on window: NSWindow) {
        guard diagnostics == nil else { return }
        let reader = DisplayDiagnostics(host: displayHost) { [weak self] in
            guard let self, let status = self.status else { return "no session" }
            // The watchdog's own account of the resolution decision. Without it a picture that
            // is short of the rate and a watchdog that has given up look exactly alike.
            let resolution = self.controller?.resolutionReport
            let watch = resolution.map {
                "res=\($0.width) calibrated=\($0.calibrated) watching=\($0.watching) "
                + "narrowings=\($0.narrowings) short=\($0.shortSamples)"
            } ?? "res=n/a"
            return String(format: "state=%@ pos=%.2f shown=%d dropped=%d rate=%.1f prep=%@ %@",
                          "\(status.state)", status.position, status.shown, status.dropped,
                          self.presentedRate, self.preparing ?? "-", watch)
        }
        diagnostics = reader
        reader.start(on: window)
    }

    /// Watch the window's own account of being full screen.
    ///
    /// Notifications rather than an `NSWindowDelegate`: SwiftUI installs a delegate of its own on
    /// the window it made, and taking that slot would replace SwiftUI's window behaviour with
    /// this app's, which is a much larger change than the one being made here.
    private func observe(_ window: NSWindow) {
        let centre = NotificationCenter.default
        for token in windowObservers { centre.removeObserver(token) }
        windowObservers = []
        let transitions: [(Notification.Name, Bool)] = [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false),
        ]
        for (name, entering) in transitions {
            // `queue: .main` plus `assumeIsolated`, not a `Task`: the notification is already
            // arriving on the main thread, and hopping would put the chrome one runloop turn
            // behind the transition it is there to accompany.
            let token = centre.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenChanged(entering) }
            }
            windowObservers.append(token)
        }
    }

    private func fullScreenChanged(_ entering: Bool) {
        isFullScreen = entering
        if entering {
            // The chrome is **up** when full screen is entered: the user has just asked for
            // something and needs to see that it happened. It takes itself away from there.
            chromeVisible = true
            lastPointerMove = Date()
            startChromeTimer()
        } else {
            stopChromeTimer()
            chromeVisible = true
        }
    }

    /// Enter full screen, or leave it. The window reports back through the notifications above,
    /// so nothing is set here — the state follows macOS rather than predicting it.
    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Local monitors, so the pointer and Escape are seen wherever they land.
    ///
    /// A **local** monitor sees this app's events before they are dispatched, which is what makes
    /// the reveal work over the picture, over the transport, and over the SwiftUI views that sit
    /// above both. A tracking area on the video view would cover only the picture — and the
    /// picture is exactly where the pointer is *not* when the user is reaching for the scrubber,
    /// which is the one moment the chrome must not be about to vanish.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        let moves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(event) }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var swallowed = false
            MainActor.assumeIsolated { swallowed = self?.handleKey(event) ?? false }
            return swallowed ? nil : event
        }
        eventMonitors = [moves, keys].compactMap { $0 }
    }

    private func pointerMoved(_ event: NSEvent) {
        guard isFullScreen, event.window === window else { return }
        lastPointerMove = Date()
        if !chromeVisible { chromeVisible = true }
    }

    /// Escape leaves full screen.
    ///
    /// Handled here rather than with a SwiftUI key handler because the video surface is an
    /// `NSView` holding the key window's focus, and the event has to be **swallowed** rather than
    /// merely observed: macOS has its own opinion about Escape in a full-screen window, and two
    /// handlers acting on one press would enter and leave full screen again in the same breath.
    private func handleKey(_ event: NSEvent) -> Bool {
        if isFullScreen, event.keyCode == 53, event.window === window {
            toggleFullScreen()
            return true
        }
        return handleTransportKey(event)
    }

    /// How far the two arrow keys move the playhead.
    ///
    /// **Deliberately different amounts**, which is unusual enough to say out loud: `←` steps back
    /// five seconds and `→` steps forward ten. The two gestures are not mirror images because the
    /// things they are for are not: back is "what did it say", where five seconds is one line of
    /// dialogue, and forward is "get on with it", where ten is a scene beat.
    static let backSeconds: Double = 5
    static let forwardSeconds: Double = 10

    /// Bare arrow keys, and why they are not menu shortcuts.
    ///
    /// **A menu item with a bare arrow key equivalent takes that key away from every focused text
    /// field in the app.** AppKit checks the menu bar's key equivalents *before* the responder
    /// chain sees the key, so `←` in the Settings screen's text field would jump the film instead
    /// of moving the caret. That is the whole reason this is a local monitor rather than two more
    /// `Button`s in the Playback menu: a monitor can be told *where* it is, and this one only
    /// answers while the player is the screen showing and nothing is being typed into.
    ///
    /// The `⌘←` and `⌘→` menu items stay, and they carry the same amounts as these, so the menu
    /// is still a true description of what the keys do.
    private func handleTransportKey(_ event: NSEvent) -> Bool {
        guard tab == .player, film != nil, event.window === window else { return false }
        // A focused field's editor is an `NSTextView`. Nothing on the player screen is one today;
        // this is the guard that keeps that from mattering if something ever is.
        if window?.firstResponder is NSTextView { return false }
        switch event.keyCode {
        case 123:
            nudge(by: -Self.backSeconds)
            return true
        case 124:
            nudge(by: Self.forwardSeconds)
            return true
        default:
            return false
        }
    }

    /// Move the playhead relative to where it is. Clamped by ``seek(to:)``, so the ends are safe.
    func nudge(by seconds: Double) {
        seek(to: (status?.position ?? 0) + seconds)
    }

    /// The one loop that decides whether the chrome is up.
    ///
    /// A loop rather than a timer re-armed on every pointer move. Mouse-moved events arrive
    /// hundreds of times a second, and cancelling and rebuilding a `Task` on each one would cost
    /// more than the thing being scheduled; four times a second is nothing beside a pipeline
    /// interpolating 59.94 frames a second.
    private func startChromeTimer() {
        chromeTask?.cancel()
        chromeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isFullScreen else { return }
                let idle = Date().timeIntervalSince(self.lastPointerMove)
                // Only the player has a picture to watch, and only a running film is one to watch
                // it in. On the queue there is no gesture that would bring the picker back, and a
                // paused viewer is looking for the transport rather than at the picture.
                let wanted = self.tab == .player
                    && self.status?.state == .playing
                    && idle >= Self.chromeIdleSeconds
                guard wanted == self.chromeVisible else { continue }
                self.chromeVisible = !wanted
                if !self.chromeVisible { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    private func stopChromeTimer() {
        chromeTask?.cancel()
        chromeTask = nil
    }

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

    /// Tell macOS a conversion is work the user asked for, for as long as it runs.
    ///
    /// The same class of failure as the player's, one state further out. A conversion is hours
    /// long, it is started deliberately, and it is expected to run **while the window is in the
    /// background** — which is precisely the state App Nap exists for. Without an assertion the
    /// system is entitled to coalesce this process's timers and throttle its I/O, and a job that
    /// takes all night is the worst possible place to discover that.
    ///
    /// What it does **not** take is `.latencyCritical`. That option claims a deadline, and a
    /// batch job has none: there is no frame that must be on screen in 16.7 ms. Claiming one
    /// would be a lie told to the scheduler, and the scheduler acts on it — it would raise this
    /// process's priority above work that really does have a deadline.
    ///
    /// A token of its own rather than the player's, because the two genuinely overlap: a film can
    /// be playing while a job runs in the queue, and ending either one must not end the other.
    private var jobActivity: NSObjectProtocol?

    private func beginJobActivity() {
        guard jobActivity == nil else { return }
        jobActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "converting a film")
    }

    private func endJobActivity() {
        guard let jobActivity else { return }
        ProcessInfo.processInfo.endActivity(jobActivity)
        self.jobActivity = nil
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
        displayHost.fitMode = settings.playbackFitMode
        sound = prepared
        soundLine = line

        let controller = PlaybackController(
            url: film.url,
            display: displayHost.renderer,
            configuration: .init(outputRate: settings.policy.resolve(
                                    source: film.info.frameRate).output,
                                 depth: settings.depth,
                                 sceneDetection: settings.sceneDetection,
                                 resolutionPolicy: settings.playbackResolution),
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

    /// Jump. The session is rebuilt **off the main thread**, so this returns at once and the
    /// window keeps drawing for the whole of the rebuild.
    ///
    /// That is the fix for the freeze, and it was measured rather than assumed. The rebuild is
    /// ~120 ms of blocking work on the real 4K film — joining the old session's threads, spawning
    /// ffmpeg, seeking into a 9.9 GB file — and it used to happen right here, on the main thread,
    /// inside a `Task` that had yielded 16 ms to draw a spinner and then froze the very frame it
    /// was drawn on. The bad ones are worse than the average, because `-ss` seeks to the preceding
    /// keyframe and decodes forward to the target, so how far back that keyframe sits is the
    /// whole of the variance — which is why the freeze was intermittent rather than every time.
    ///
    /// `seekToken` is what makes a second click mean the second position: the first click's
    /// completion becomes a no-op once a newer one exists, so "Seeking…" belongs to the jump
    /// actually in flight instead of being cleared by whichever one finishes first.
    func seek(to seconds: Double) {
        guard let controller else { return }
        let target = max(0, min(seconds, film?.info.duration ?? seconds))
        preparing = "Seeking…"
        // A seek is a discontinuity, so the measurement starts again around it — a second of
        // rebuilding with no frames in it is not evidence about the rate the picture runs at.
        playBegan = nil
        wasPlaying = false
        seekToken += 1
        let token = seekToken
        controller.seek(to: target) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekToken == token else { return }
                self.preparing = nil
                self.refresh()
            }
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

    /// Change how the picture is fitted to the window.
    ///
    /// **No session rebuild, and that is not an optimisation — it is the reason this is a
    /// control in the transport at all.** `videoGravity` is read by the layer as it composites,
    /// so this is a property write and the next frame is already fitted the new way. The
    /// resolution policy next to it in the readout cannot work that way: it changes every buffer
    /// and the size the encoder writes, so it has to tear the session down and rebuild, which
    /// costs a seek's worth of interruption. A viewer comparing "bars" with "cropped" would not
    /// tolerate that per toggle.
    func setPlaybackFitMode(_ mode: FitMode) {
        guard mode != settings.playbackFitMode else { return }
        settings.playbackFitMode = mode
        displayHost.fitMode = mode
    }

    /// The screen the picture is on, for saying what the Fit/Fill choice is relative to.
    ///
    /// Falls back to the main screen when the window is not known yet — a film can be opened
    /// before `adopt(window:)` has run, and a readout that goes blank in that window is worse
    /// than one that names the wrong-but-close screen for a moment.
    var presentationDisplay: DisplayList.Display? {
        DisplayList.display(for: window?.screen ?? NSScreen.main)
    }

    /// The pixel size the picture is being fitted **into** — the layer's own bounds.
    ///
    /// The layer, and not the screen. Windowed, the picture fits the *window*, so a readout
    /// that named the screen's size while the window had been dragged to a third of it would be
    /// describing a different rectangle. In full screen the two coincide, which is what makes
    /// this the number that is correct in both cases rather than one that is only right
    /// sometimes.
    ///
    /// Read on demand rather than observed. It changes when the user resizes a window or moves
    /// to another screen, neither of which is an event this model subscribes to — and a readout
    /// that is one tick stale after a drag is not a readout that is wrong, because the ticker
    /// repaints it within the second.
    var presentedSize: OutputSize? {
        let layer = displayHost.view.displayLayer
        let size = layer.bounds.size
        let scale = layer.contentsScale
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        return OutputSize(width: Int((size.width * scale).rounded()),
                          height: Int((size.height * scale).rounded()))
    }

    /// What the Fit/Fill choice does to the picture that is loaded, right now.
    ///
    /// Described rather than applied — the layer does the fitting, exactly as
    /// `VTPixelTransferSession` does it for a file. This is the same ``OutputGeometry`` the
    /// settings screen uses to describe a conversion, which is the point: the two modes mean
    /// the same thing in the window and in the file, and one type says so in both places.
    var presentationGeometry: OutputGeometry? {
        guard let size = interpolationSize, let presented = presentedSize else { return nil }
        return OutputGeometry.fitting(source: OutputSize(width: size.width, height: size.height),
                                      target: presented,
                                      mode: settings.playbackFitMode)
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
                if position > 0 { controller?.seek(to: position) }
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
    /// **One at a time, deliberately, and now measured properly.** The interpolation is
    /// per-pixel and saturates what the framework will give; four concurrent 4K jobs would be
    /// four jobs each running at a quarter speed with four times the memory. Two whole
    /// conversions run side by side at four sessions each — eight sessions in total, in two
    /// processes — measure **8.0 source frames/s each, 16.0 together**, against **23.3 for one
    /// conversion on its own** (§28). Running two jobs at once is not a wash; it is a third
    /// slower than doing them one after the other. The queue exists to make a night's work
    /// unattended, not to make it faster.
    ///
    /// `.userInitiated`, not `.utility`. The user pressed Start and is waiting for the answer;
    /// utility priority is for maintenance the user did not ask for. The QoS of this task is
    /// inherited by every thread the conversion creates — the driver, the engine completions,
    /// the sink — and on Apple Silicon that is what decides whether they are scheduled on the
    /// performance cores or the efficiency ones.
    private func run(_ job: BatchJob) async {
        job.state = .running
        job.started = Date()
        job.failure = nil
        // Before the converter is built, so the first report it makes is the estimator's first
        // sample rather than a continuation of whatever ran in this slot last.
        job.prepareForRun()

        let converter = makeConverter(for: job)
        let request = makeRequest(for: job)
        job.output = request.output

        // For the whole job, not re-asserted per segment: a conversion is one piece of work the
        // user asked for, and letting go between segments would hand the scheduler exactly the
        // gap it is looking for.
        beginJobActivity()
        defer { endJobActivity() }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
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
            Task { @MainActor in job.record(progress) }
        }
        return converter
    }

    private func makeRequest(for job: BatchJob) -> BatchConverter.Request {
        let sourceRate = job.info?.frameRate.doubleValue ?? 24
        return BatchConverter.Request(
            input: job.input,
            output: job.output,
            policy: settings.policy,
            quality: settings.conversionQuality,
            outputTarget: settings.batchOutputTarget,
            fitMode: settings.batchFitMode,
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

    /// Where the time-remaining projection comes from. See ``ProgressEstimator``.
    private var estimator = ProgressEstimator()

    init(input: URL, output: URL) {
        self.input = input
        self.output = output
    }

    var name: String { input.lastPathComponent }

    var elapsed: TimeInterval? {
        guard let started else { return nil }
        return (finished ?? Date()).timeIntervalSince(started)
    }

    /// Clear what a previous run left behind, so a second run does not project a rate measured
    /// on the first one — or on a different film entirely.
    func prepareForRun() {
        estimator.reset()
        progress = nil
        result = nil
        failure = nil
        finished = nil
    }

    /// Take one report from the converter.
    ///
    /// **Only the rendering stage is fed to the estimator, and that is the whole trick.** Probing
    /// and the audio work come *before* the render and carry no fraction; muxing and joining come
    /// after it. Feeding any of them in would put seconds into the window that produced no
    /// progress, and the projection would read long for the rest of the job — which is exactly
    /// what `elapsed / fraction` did, because it started its clock at the probe.
    func record(_ report: BatchConverter.Progress) {
        progress = report
        guard report.stage == .rendering, let fraction = report.fraction else { return }
        estimator.observe(fraction: fraction,
                          at: ProcessInfo.processInfo.systemUptime)
    }

    /// Seconds left, from the rate the job is actually running at.
    ///
    /// `nil` until the estimator can defend a number — a few seconds in, rather than the thirty
    /// the old formula needed before it was willing to divide by anything.
    var remaining: TimeInterval? {
        guard state == .running else { return nil }
        return estimator.remaining
    }

    /// Whether a projection is being offered yet, so the view can say so instead of showing a
    /// number it does not have.
    var isEstimating: Bool { state == .running && !estimator.hasEstimate }
}
