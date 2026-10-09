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
    @State private var tab = Tab.player

    enum Tab: String, CaseIterable, Identifiable {
        case player = "Player"
        case batch = "Convert"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 320)

            Divider()

            switch tab {
            case .player: PlayerView()
            case .batch: BatchView()
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task {
            model.refreshCacheSize()
            // Two ways in, one destination. The Finder route is parked in `OpenRequest`
            // because it can arrive before this view exists; the command line is read here
            // because it cannot arrive at any other time.
            OpenRequest.shared.take { model.accept(urls: $0) }
            if let named = AppModel.filmFromCommandLine() {
                model.accept(urls: [named])
            }
        }
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

            Button("Back 10 Seconds") { model.seek(to: (model.status?.position ?? 0) - 10) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model.film == nil)
            Button("Forward 10 Seconds") { model.seek(to: (model.status?.position ?? 0) + 10) }
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
        }

        CommandGroup(replacing: .appInfo) {
            Button("About 60FPS") { AboutWindow.show() }
        }
    }
}
