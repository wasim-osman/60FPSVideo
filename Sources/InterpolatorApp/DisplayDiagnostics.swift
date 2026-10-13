import AVFoundation
import AppKit
import Foundation

/// A once-a-second line describing everything between the pipeline and the glass.
///
/// ## Why this exists
///
/// The failure this was written for has no error path anywhere in the app. The presenter
/// reports frames going out, the clock reports the film advancing, the sound keeps playing —
/// and the picture on screen does not change. Every counter the app already had is on the
/// *producer* side of the display layer, so every counter says the app is fine.
///
/// The two ways that can happen are indistinguishable from the outside and need different
/// fixes:
///
/// 1. **The layer was replaced.** `VideoLayerView` returns its display layer from
///    `makeBackingLayer()`, and `DisplayHost` hands that same object to the presenter once. If
///    AppKit ever builds a *new* backing layer — which it is entitled to do when a view moves
///    between windows or screens, and full screen moves the window to another screen — the view
///    draws a fresh empty layer while the presenter keeps filling the one nobody can see. The
///    picture is then frozen, with no error, forever.
/// 2. **The layer stopped displaying.** Same symptom, opposite fix: the layer has to be flushed
///    and resumed.
///
/// The field that separates them is `layer === view.layer`. The rest of the line exists so that
/// the answer is not "well, it was one of these" — `renderer.status`, `isReadyForMoreMediaData`
/// and `requiresFlushToResumeDecoding` say what the renderer thinks it is doing, the window's
/// occlusion state says whether macOS is even drawing it, and the frame counters say whether the
/// pipeline is still producing.
///
/// ## Using it
///
/// ```
/// SIXTYFPS_DIAG=1 /Applications/60FPS.app/Contents/MacOS/60FPS     # stderr
/// SIXTYFPS_DIAG=/tmp/60fps-diag.log open -a 60FPS                  # a file
/// ```
///
/// `1` means stderr. Any other value is a path, and the lines are appended there **as well as**
/// written to stderr. The file matters because the two ways of launching an app are not equally
/// good at carrying a diagnostic: run from a shell, stderr is the terminal; launched by the
/// Finder or by `open`, stderr is a descriptor nobody is reading, and the log is empty for a
/// reason that looks like the app never ran.
///
/// Lines are one a second, prefixed `[diag]`. Off unless the variable is set, because a player
/// that logs while it plays is a player that costs frames to say so.
@MainActor
final class DisplayDiagnostics {

    private let host: DisplayHost
    /// Whatever the model wants to add — the clock, the counters, the transport state.
    private let extra: () -> String
    private weak var window: NSWindow?
    private var task: Task<Void, Never>?
    private let file: FileHandle?

    init(host: DisplayHost, extra: @escaping () -> String) {
        self.host = host
        self.extra = extra
        self.file = Self.openLogFile()
    }

    /// Where the lines go, or `nil` for stderr only.
    private static func openLogFile() -> FileHandle? {
        guard let value = ProcessInfo.processInfo.environment["SIXTYFPS_DIAG"],
              !value.isEmpty, value != "1" else { return nil }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    static var isEnabled: Bool {
        guard let value = ProcessInfo.processInfo.environment["SIXTYFPS_DIAG"] else { return false }
        return !value.isEmpty
    }

    func start(on window: NSWindow?) {
        guard Self.isEnabled else { return }
        self.window = window
        let layer = host.view.displayLayer
        log("on — layer \(Self.address(layer))")
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - One sample

    private func sample() {
        let view = host.view
        let layer = view.displayLayer
        let renderer = layer.sampleBufferRenderer

        var parts: [String] = []

        // The question. `backing` means the view is drawing the layer the presenter is feeding.
        parts.append(layer === view.layer
                     ? "layer=backing"
                     : "layer=ORPHAN(view.layer is \(Self.address(view.layer)))")
        parts.append("super=\(layer.superlayer == nil ? "nil" : Self.address(layer.superlayer))")
        parts.append("inTree=\(layer.superlayer != nil)")
        parts.append("hidden=\(layer.isHidden)")
        parts.append(String(format: "opacity=%.2f", layer.opacity))
        parts.append("bounds=\(Self.size(layer.bounds.size))")
        parts.append("frame=\(Self.size(layer.frame.size))")

        parts.append("view=\(Self.size(view.frame.size))")
        parts.append("viewWin=\(view.window != nil)")
        parts.append("viewHidden=\(view.isHidden)")
        parts.append(String(format: "alpha=%.2f", view.alphaValue))
        parts.append(String(format: "scale=%.2f", layer.contentsScale))

        parts.append("status=\(Self.name(renderer.status))")
        parts.append("ready=\(renderer.isReadyForMoreMediaData)")
        parts.append("needsFlush=\(renderer.requiresFlushToResumeDecoding)")
        // Only the renderer's error, not the layer's. The layer's is the same object and is
        // deprecated in its favour — and a diagnostic that does not compile clean is a
        // diagnostic nobody leaves in the tree.
        if let error = renderer.error { parts.append("err=\(error)") }

        if let window {
            parts.append("win=\(Self.size(window.frame.size))"
                         + "@\(Int(window.frame.minX)),\(Int(window.frame.minY))")
            parts.append("fs=\(window.styleMask.contains(.fullScreen))")
            parts.append("occluded=\(!window.occlusionState.contains(.visible))")
            parts.append("winScale=\(String(format: "%.2f", window.backingScaleFactor))")
            parts.append("screen=\(window.screen.map { Self.size($0.frame.size) } ?? "nil")")
        } else {
            parts.append("win=nil")
        }

        parts.append(extra())
        log(parts.joined(separator: " "))
    }

    // MARK: - Formatting

    private static func name(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .rendering: return "rendering"
        case .failed: return "FAILED"
        @unknown default: return "status(\(status.rawValue))"
        }
    }

    private static func size(_ size: CGSize) -> String {
        String(format: "%.0fx%.0f", size.width, size.height)
    }

    /// A short identity for an object, so two lines can be compared by eye.
    ///
    /// `ObjectIdentifier` rather than `Unmanaged.passUnretained(...).toOpaque()`, because the
    /// layer may be replaced *and* the old one freed, and a freed pointer's address is a number
    /// that can be handed out again — which is a log line that lies in exactly the case it is
    /// being read for. `ObjectIdentifier` is not reused while any reference lives.
    private static func address(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return "0x" + String(UInt(bitPattern: ObjectIdentifier(object)), radix: 16)
    }

    private func log(_ line: String) {
        let data = Data("[diag] \(line)\n".utf8)
        FileHandle.standardError.write(data)
        if let file {
            // Written and flushed one line at a time. A diagnostic that is still sitting in a
            // buffer when the picture freezes is a diagnostic that is read after the fact and
            // says nothing about the moment.
            try? file.write(contentsOf: data)
        }
    }
}
