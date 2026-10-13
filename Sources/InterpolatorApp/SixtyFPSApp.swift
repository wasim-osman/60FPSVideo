import SwiftUI

/// 60FPS — a frame-interpolation player and batch converter for macOS.
///
/// The whole app is a thin shell over `Interpolator`: the pipeline, the player, the batch
/// converter, the audio and the arithmetic are all in the library and all tested without a
/// window. What lives here is the part that needs one — a layer to draw into, a way to choose
/// a file, and somewhere to put a progress bar that runs for four hours.
@main
struct SixtyFPSApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @State private var model = AppModel()

    var body: some Scene {
        // `Window` and not `WindowGroup`.
        //
        // Measured: `WindowGroup` plus `CFBundleDocumentTypes` in the Info.plist gives **two**
        // windows when a film is opened from the Finder — one from the launch and one from the
        // document-open event, both named "60FPS", one of them empty. That is SwiftUI's
        // document behaviour and it is right for an editor with a document per window; this app
        // has one player, one queue and one set of settings, so a second window is a second
        // empty shell over the same model.
        //
        // `Window` is a single unique scene, and it closes the gap the other way too: with
        // `applicationShouldTerminateAfterLastWindowClosed` returning true, an app that cannot
        // make a second window also cannot end up running with none — which is the state two of
        // the first launches of a freshly built bundle came up in, with an idle run loop and no
        // window at all. Whatever that was, this removes the way to get there.
        Window("60FPS", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // `AnyLayout`, not `if isFullScreen { … } else { … }`. The branch is the natural way to
        // write this and it **destroys the picture**: both sides contain the player, both sides
        // therefore contain a `VideoSurface`, and a `VideoSurface` hands SwiftUI the one `NSView`
        // the presenter is drawing into. SwiftUI builds the incoming branch (adopting that view)
        // and then dismantles the outgoing one, whose teardown removes it again — leaving the
        // layer fed and off screen. `AnyLayout` keeps one child list and changes only the
        // arrangement, so nothing is torn down. See `PlayerView`, where the same trap was found
        // and measured.
        let layout = model.isFullScreen
            ? AnyLayout(ZStackLayout(alignment: .top))
            : AnyLayout(VStackLayout(spacing: 0))

        layout {
            // `zIndex`, because the two layouts disagree about what "first" means. A `VStack`
            // draws its children top to bottom, so the picker being first puts it above the
            // content; a `ZStack` draws them in order, so being first puts it *behind* the
            // player — and the picker disappeared in full screen entirely, which is how this was
            // found. In the window they never overlap and the value is inert.
            chrome
                .zIndex(model.isFullScreen ? 1 : 0)
            content
        }
        .frame(minWidth: 900, minHeight: 620)
        // Where the model gets the window it is playing in — the one thing a SwiftUI `Window`
        // scene does not hand over, and the thing full screen is a property of.
        .background(WindowAccessor { model.adopt(window: $0) })
        .task {
            model.refreshCacheSize()
            // Two ways in, one destination. The Finder route is parked in `OpenRequest`
            // because it can arrive before this view exists; the command line is read here
            // because it cannot arrive at any other time.
            //
            // Both routes *show* what they opened. The app opens on Convert — the queue is the
            // reason it exists — but "open this film" means "play this film", whether it came
            // from the Finder, from `open -a`, or from a path on the command line. Leaving the
            // tab on Convert would load a film the user then has to go and find.
            OpenRequest.shared.take { urls in
                model.tab = .player
                model.accept(urls: urls)
            }
            if let named = AppModel.filmFromCommandLine() {
                model.tab = .player
                model.accept(urls: [named])
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .batch: BatchView()
        case .player: PlayerView()
        }
    }

    /// The tab picker: a full-width strip in the window, a floating capsule in full screen.
    ///
    /// Faded rather than removed for the same reason the transport is — it is one child of the
    /// layout above, and changing the child list would re-identify the picture.
    @ViewBuilder
    private var chrome: some View {
        if model.isFullScreen {
            picker
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 10)
                .opacity(model.chromeHidden ? 0 : 1)
                .allowsHitTesting(!model.chromeHidden)
                .animation(.easeInOut(duration: 0.18), value: model.chromeHidden)
        } else {
            VStack(spacing: 0) {
                picker
                Divider()
            }
        }
    }

    private var picker: some View {
        @Bindable var model = model
        return Picker("", selection: $model.tab) {
            ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320)
    }
}

/// The menu bar.
///
/// The keyboard shortcuts are the ones a player is expected to have, and they are here rather
/// than in the window so they work whatever has focus — which matters because the video
/// surface is an `NSView` that will happily eat a space bar otherwise.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Film…") { model.chooseAndOpen() }
                .keyboardShortcut("o")
            Button("Add Films to Convert…") { model.addFilms() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Playback") {
            Button(model.status?.state == .playing ? "Pause" : "Play") {
                model.togglePlay()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.film == nil)

            Button("Stop") { model.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.film == nil)

            Divider()

            // The bare arrow keys are handled by the model's key monitor rather than as key
            // equivalents here — see `AppModel.handleTransportKey`. They carry these same amounts,
            // so what the menu says is what the keys do.
            Button("Back \(Int(AppModel.backSeconds)) Seconds") {
                model.nudge(by: -AppModel.backSeconds)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(model.film == nil)
            Button("Forward \(Int(AppModel.forwardSeconds)) Seconds") {
                model.nudge(by: AppModel.forwardSeconds)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(model.film == nil)

            Divider()

            Picker("Speed", selection: Binding(
                get: { model.settings.playbackSpeed },
                set: { model.setSpeed($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : String(format: "%gx", speed)).tag(speed)
                }
            }
            .disabled(model.film == nil)

            Divider()

            // The stock `View ▸ Enter Full Screen` is *not* this item's equivalent, and the
            // difference was measured rather than assumed: that item's key equivalent carries
            // `NSEvent.ModifierFlags.function` — Fn+F — so **⌃⌘F did nothing at all** in the
            // shipping build, which is the shortcut every other viewer on the system answers to.
            // This is that shortcut, wired to the app's own viewer rather than to a bare window.
            Button(model.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
                model.toggleFullScreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }

        CommandGroup(replacing: .appInfo) {
            Button("About 60FPS") { AboutWindow.show() }
        }
    }
}
