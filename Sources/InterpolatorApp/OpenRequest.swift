import AppKit
import Foundation

/// Films the system asks the app to open, held until there is a model to give them to.
///
/// AppKit creates the application delegate **before** SwiftUI creates the app's state, so a
/// file that arrives at launch — a double-click, a drag onto the Dock icon, `open -a 60FPS` —
/// has nowhere to go yet. Dropping it on the floor is the default, and it is silent: the app
/// comes up with an empty window and the user concludes it ignored them.
///
/// So it is parked here and drained by the window on its first appearance, which is also when
/// the player is ready to build a session for it.
@MainActor
final class OpenRequest {

    static let shared = OpenRequest()

    private var waiting: [URL] = []
    private var drain: (([URL]) -> Void)?

    private init() {}

    /// Hand over whatever arrived. Before the window exists this accumulates.
    func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let drain {
            drain(urls)
        } else {
            waiting.append(contentsOf: urls)
        }
    }

    /// Take everything waiting, and everything that arrives from here on.
    ///
    /// The pending batch is delivered inside this call rather than queued onto a later turn,
    /// because the caller is about to become the only route in and a gap between the two would
    /// lose a file that landed in it.
    func take(_ handler: @escaping ([URL]) -> Void) {
        let pending = waiting
        waiting = []
        drain = handler
        if !pending.isEmpty { handler(pending) }
    }
}

/// Receives "open this file" from the Finder.
///
/// `application(_:open:)` and not `application(_:openFile:)`: the latter is the pre-10.13
/// entry point and is not called for a multi-file drop. Both routes end at `OpenRequest`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            OpenRequest.shared.deliver(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Required by AppKit in macOS 14 and later, and its absence is not neutral: an app that
    /// does not answer this question is refused secure state restoration and logged as a
    /// defect. Answered honestly rather than copied — this app has no restored state that
    /// could be tampered with to make it do something it would not otherwise do.
    ///
    /// Note what is *not* claimed here: nothing about this app is worth restoring. The film is
    /// reopened by path, the settings live in `UserDefaults`, and the window is one window.
    /// Window restoration is enabled because turning it off is a second, larger claim — that
    /// macOS cannot be trusted to remember a frame rectangle — and it is not one I can support.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
