import AVFoundation
import AppKit
import Interpolator
import SwiftUI
import UniformTypeIdentifiers

/// The layer the presenter draws into, and the view that shows it.
///
/// ## Why this is created once and held by the model
///
/// SwiftUI rebuilds view bodies freely, and a `NSViewRepresentable` that made its layer in
/// `makeNSView` would be fine — SwiftUI calls that once per view identity. But the **renderer**
/// is handed to `PlaybackController`, which hands it to `DisplayPresenter`, which writes to it
/// from its own thread for the length of a film. If a rebuild produced a second layer, the
/// presenter would go on drawing into the one nobody can see, and the window would show a
/// frozen frame with no error anywhere.
///
/// So the model owns one `DisplayHost`, the layer inside it never changes identity, and the
/// representable does nothing but hand the same view back.
///
/// ## Why the host is on the main actor and the presenter is not
///
/// `AVSampleBufferDisplayLayer` is main-actor isolated — the SDK marks it `NS_SWIFT_UI_ACTOR` —
/// so everything that *configures* it (gravity, opacity, extended range) happens here, on the
/// main actor, once per film. Everything that *feeds* it happens on the presenter's thread, and
/// goes to the **renderer** rather than the layer: `AVSampleBufferVideoRenderer` carries no
/// actor annotation, and the layer's own `enqueue`/`flush`/`isReadyForMoreMediaData` are
/// deprecated in macOS 15 in favour of it. See `DisplayPresenter` for the crash that settled it.
@MainActor
final class DisplayHost {
    let view = VideoLayerView(frame: .zero)

    /// The half of the layer the presenter talks to. Taken once, on the main actor, and then
    /// owned by the presenter for the life of the film.
    var renderer: AVSampleBufferVideoRenderer { view.displayLayer.sampleBufferRenderer }

    /// Tell the layer whether the frames it will receive are extended-range.
    ///
    /// §20's HDR decision: 10-bit passthrough, and let macOS tone-map for an SDR display.
    /// There is no tone-mapping code in this app for the system compositor to disagree with —
    /// which was the point, because this machine's ffmpeg has no `zscale` and `scale_vt`
    /// returns `ENOSYS`, so a tone-mapping curve in the real-time path would have been
    /// hand-rolled with its own colour-correctness questions.
    func prepare(for info: MediaInfo) {
        view.displayLayer.wantsExtendedDynamicRangeContent = info.isHDR
        view.displayLayer.isOpaque = true
        view.displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// How the picture is fitted to the window — `fit` letterboxes, `fill` crops.
    ///
    /// A plain property write on the layer, with **no session rebuild**. `videoGravity` is read
    /// by the layer as it composites each frame, so the next frame is already fitted the new
    /// way. That is the difference between this and the resolution policy beside it in the
    /// readout: changing the interpolation size changes every buffer and the size the encoder
    /// writes, so it has to tear the session down, while this one costs nothing. It is also why
    /// this can be a control a viewer works while watching.
    var fitMode: FitMode {
        get { view.fitMode }
        set { view.fitMode = newValue }
    }

    /// Drop everything queued, for a seek.
    func discardQueuedFrames() {
        view.displayLayer.sampleBufferRenderer.flush()
    }
}

/// An `NSView` whose backing layer **is** the display layer.
///
/// `makeBackingLayer` rather than assigning `layer` after `wantsLayer`: assigning it works
/// until AppKit decides to replace the backing layer, and then the picture disappears for
/// reasons that are nowhere near this file.
///
/// ## Why the double click is handled *here*
///
/// The picture is an `NSView` sitting on top of everything SwiftUI would otherwise attach a
/// gesture to, so a `.onTapGesture` in the view body never fires: the event arrives at this view
/// first and, with nothing to do with it, is passed up the responder chain rather than into the
/// SwiftUI gesture layer. A `mouseDown` override is the one thing that is certain to work.
///
/// The pointer *is* tracked — but at the window, not here. See `AppModel.installEventMonitors()`:
/// revealing the chrome has to work while the pointer is over the transport as well as over the
/// picture, and a tracking area on this view would cover only the picture.
@MainActor
final class VideoLayerView: NSView {

    let displayLayer = AVSampleBufferDisplayLayer()

    /// The picture was double-clicked. Full screen in, full screen out.
    var onDoubleClick: (() -> Void)?

    /// How the picture fills the view. See ``DisplayHost/fitMode``.
    ///
    /// **`videoGravity` and not a manual transform.** `resizeAspect` preserves the aspect ratio
    /// and leaves the remainder black — letterbox or pillarbox, whichever the shapes call for —
    /// and `resizeAspectFill` preserves it and crops the overflow. Both are the layer's own
    /// documented behaviour, the same choice `VTPixelTransferSession` makes for the file on disk
    /// (`kVTScalingMode_Letterbox` / `kVTScalingMode_Trim`), so what a viewer sees in the window
    /// and what a conversion writes are the same two modes and not two approximations of them.
    var fitMode: FitMode = .fit {
        didSet { applyGravity() }
    }

    private func applyGravity() {
        displayLayer.videoGravity = fitMode == .fit ? .resizeAspect : .resizeAspectFill
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyGravity()
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the display layer is created in code, not from a nib")
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    override var isOpaque: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

/// Hosts the model's display view. It hosts it and nothing else.
struct VideoSurface: NSViewRepresentable {
    let host: DisplayHost
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> VideoLayerView {
        host.view.onDoubleClick = onDoubleClick
        return host.view
    }

    /// Re-assign rather than ignore: the closure captures the model, and the model is a
    /// reference type, so this is the same closure every time — but a representable that
    /// silently drops its inputs is how a gesture stops working after some unrelated change.
    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

/// Hands the model the `NSWindow` SwiftUI made for it.
///
/// Full screen is an `NSWindow` property — `toggleFullScreen(_:)`,
/// `styleMask.contains(.fullScreen)`, the two notifications — and a SwiftUI `Window` scene does
/// not expose the window. A zero-sized representable is the supported way to reach it:
/// `viewDidMoveToWindow` is the one callback certain to run once the window exists, and it runs
/// again if SwiftUI ever re-parents the view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReader {
        let reader = WindowReader()
        reader.onWindow = onWindow
        return reader
    }

    func updateNSView(_ reader: WindowReader, context: Context) {
        reader.onWindow = onWindow
    }

    @MainActor
    final class WindowReader: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// The system file chooser, which is AppKit's and not SwiftUI's on macOS.
enum FileChooser {

    static let filmExtensions = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm"]

    /// The content types the panel may filter by, or `[]` for no filter at all.
    ///
    /// **Whether macOS can name these is not something to assume in either direction**, and the
    /// filter is therefore built at run time.
    ///
    /// Measured on this machine — `UTType(filenameExtension:)`, all eight extensions:
    ///
    /// ```
    /// mkv   public.matroska                        conforms to public.movie
    /// mp4   public.mpeg-4                          conforms to public.movie
    /// m4v   com.apple.m4v-video                    conforms to public.movie
    /// mov   com.apple.quicktime-movie              conforms to public.movie
    /// avi   public.avi                             conforms to public.movie
    /// ts    public.mpeg-2-transport-stream         conforms to public.movie
    /// m2ts  public.avchd-mpeg-2-transport-stream   conforms to public.movie
    /// webm  org.webmproject.webm                   conforms to public.movie
    /// ```
    ///
    /// All eight are declared here, so the panel filters by them. But `isDeclared` means
    /// *declared by the system or by some installed app*, and `public.matroska` is exactly the
    /// kind of UTI a media player brings with it — on a Mac with nothing installed that reads
    /// `.mkv`, the same call returns a **dynamic** type, `dyn.…`, which matches nothing on disk.
    /// Handing the panel a list containing one of those would grey out every Matroska file in
    /// the folder, and Matroska is the format the disc in the drive actually is.
    ///
    /// So: if every extension resolves to a declared type, filter by them. If even one does not,
    /// pass the empty array — an unfiltered panel — and check the extension after the choice,
    /// where a wrong pick can be answered with a sentence instead of a grey row.
    static var filterTypes: [UTType] {
        let declared = filmExtensions.compactMap { UTType(filenameExtension: $0) }
            .filter { $0.isDeclared }
        return declared.count == filmExtensions.count ? declared : []
    }

    /// Whether the app can make sense of this file, by extension.
    static func looksLikeFilm(_ url: URL) -> Bool {
        filmExtensions.contains(url.pathExtension.lowercased())
    }

    @MainActor
    static func chooseFilm() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a film to play or convert"
        panel.prompt = "Open"
        panel.allowedContentTypes = filterTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFilms() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose films to convert to 60 fps"
        panel.prompt = "Add"
        panel.allowedContentTypes = filterTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
