import CoreMedia
import Foundation

// MARK: - Fit mode

/// What happens to a picture whose aspect ratio does not match the target's.
///
/// ## Why this is the framework's job and not ours
///
/// VideoToolbox ships both answers. `kVTScalingMode_Letterbox` is documented as "preserve
/// aspect ratio of the source, and fill remaining areas with black in to fit destination
/// dimensions"; `kVTScalingMode_Trim` is "preserve aspect ratio of the source, and crop
/// picture to fit destination dimensions". Measured on this machine — 1920×816 into
/// 3440×1440, reading the luma plane of the result:
///
/// | mode | x = 2 | centre | x = 3437 |
/// | --- | --- | --- | --- |
/// | `Letterbox` | **16** | 235 | **16** |
/// | `Trim` | 235 | 235 | 235 |
///
/// 16 is video-range black in NV12, so the bars are genuinely black and not merely dark, and
/// the picture is untouched: a source of 235 reads back as 235. Nothing here hand-rolls a
/// scale or a composite — the sink sets one property and the framework does the rest. That is
/// why this type is a *value* with a mapping rather than a geometry engine, and why the only
/// geometry this file computes is for saying out loud what will happen.
public enum FitMode: String, Codable, CaseIterable, Identifiable, Sendable {

    /// Letterbox or pillarbox: the whole picture, bars where it does not reach.
    case fit

    /// Crop to the target's shape, edge to edge. Loses the overflow.
    case fill

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        }
    }

    public var detail: String {
        switch self {
        case .fit:
            "The whole picture, with bars where it does not reach. Nothing is lost."
        case .fill:
            "Fills the screen edge to edge. The parts that do not fit are cropped away."
        }
    }
}

// MARK: - Output size

/// A pixel size to deliver.
///
/// ## Why both dimensions are forced even
///
/// Both formats this pipeline carries are 4:2:0, so chroma is subsampled by two in both
/// directions and an odd dimension has no unambiguous chroma plane. An odd size is therefore
/// not a slightly wrong picture — it is a frame the pixel format cannot describe, and the
/// failure surfaces far from here as a buffer that will not allocate. This is the same rule
/// `InterpolationWidth.scaled(_:toWidth:)` applies for the same reason.
///
/// **Measured, and worth knowing because it is *not* symmetric:** `VTPixelTransferSession`
/// itself accepts odd dimensions — 3441×3441 transferred with status 0 — so the transfer is
/// not the thing that objects. The constraint belongs to the encoder, and normalising here
/// means the constraint is met before anything downstream has to think about it. No display
/// on this machine has an odd dimension, so in practice this rounds nothing.
public struct OutputSize: Codable, Hashable, Sendable {

    public let width: Int
    public let height: Int

    /// Rounds each dimension **down** to even.
    ///
    /// Down rather than up, so a target can never come out larger than the screen it was
    /// chosen for. At most one column and one row are given up, which is not a visible
    /// difference at any size a person would choose.
    public init(width: Int, height: Int) {
        self.width = max(2, width & ~1)
        self.height = max(2, height & ~1)
    }

    public var label: String { "\(width) × \(height)" }

    public var pixelCount: Int { width * height }

    public var aspect: Double { Double(width) / Double(height) }
}

// MARK: - Output target

/// The size a conversion should *deliver*, which is a separate question from the size it
/// *interpolates* at.
///
/// ## Why these are two questions
///
/// Interpolation cost is a step function of frame width and it is the whole reason this
/// project has a width ladder at all (`InterpolationWidth`, §29–30). Delivered size is a
/// property of the screen the file is for. Until now they were the same number, because
/// `ConversionQuality` set both — so "fast" necessarily meant "a 1080p file", and there was
/// no way to ask for a screen-sized file without paying for a full-resolution interpolation.
///
/// Splitting them is exactly the arrangement SVP ships. SVP interpolates at 3384×1440 and
/// its manual states the rule outright, under *Resizing an Image*:
///
/// > "Frame scaling is used to reduce the CPU load when the frame rate conversion function is
/// > active. … Preliminary reduction of the frame size made before the calculation of
/// > intermediate frames allows using higher-quality parameters for this calculation."
///
/// So a conversion can interpolate at 1920 wide — 31.87 ms per interval against the 41.71 ms
/// budget, where 4K needs ~105 ms — and still deliver a file at the size of the screen it is
/// going to be watched on. The upscale is `VTPixelTransferSession`'s, measured at **2.71 ms
/// per frame** for 1920×816 → 3440×1440 and **3.48 ms** from 4K, which is 4–5% of the
/// interpolation it sits behind.
///
/// `.source` is the default and reproduces the previous behaviour exactly: no target, no
/// scale pass, no change.
public enum OutputTarget: Codable, Hashable, Sendable {

    /// Deliver the film at the size it was interpolated at.
    case source

    /// Deliver at a fixed pixel size, whatever the interpolation ran at.
    case fixed(OutputSize)

    /// The size to deliver for a film of this size.
    public func size(for info: MediaInfo) -> OutputSize {
        switch self {
        case .source: OutputSize(width: info.width, height: info.height)
        case .fixed(let size): size
        }
    }

    /// Whether delivering at this target needs a scale pass at all.
    ///
    /// A target equal to the interpolation size is the common case for `.source` and is worth
    /// answering explicitly: it means the conversion is byte-for-byte the pipeline it was
    /// before, with no transfer session constructed and no buffer copied.
    public func needsScaling(from info: MediaInfo) -> Bool {
        switch self {
        case .source: false
        case .fixed(let size): size.width != info.width || size.height != info.height
        }
    }

    public var label: String {
        switch self {
        case .source: "The film's own size"
        case .fixed(let size): size.label
        }
    }
}

// MARK: - Geometry

/// What the framework will do with a picture, worked out in advance so the app can say it.
///
/// This is deliberately *descriptive*. The scaling sink does not use it to place anything —
/// `VTPixelTransferSession` places the picture, and it does so correctly, as the table on
/// `FitMode` shows. What this is for is the two things a description is needed for: telling
/// the user what a setting will produce before a four-hour job is started, and giving the
/// tests something exact to assert against rather than a screenshot.
///
/// ## The rounding, and why it differs by mode
///
/// The two modes make opposite promises, so the rounding has to go opposite ways:
///
/// - **fit** promises the picture never *overflows* the target, so the free axis is rounded
///   **down**. Rounding up by a pixel would put a sliver of picture where the bars belong.
/// - **fill** promises the picture never *falls short* of the target, so the free axis is
///   rounded **up**. Rounding down by a pixel would leave an unpainted seam at an edge.
///
/// Each is then forced even, in the same direction — both formats are 4:2:0, so an odd dimension
/// has no unambiguous chroma plane. See ``OutputSize``.
///
/// The axis that *decides* the scale is not rounded at all; it is set to the target's own
/// dimension. That is not tidiness. `source.width * (target.width / source.width)` is not
/// reliably `target.width` in binary floating point, and the difference here is the difference
/// between a readout that says "no bars" and one that says "one pixel of bar each side" about a
/// conversion that in fact has none.
public struct OutputGeometry: Equatable, Sendable {

    /// The size the picture is drawn at, inside the target.
    public let scaledWidth: Int
    public let scaledHeight: Int

    /// The target, restated.
    public let targetWidth: Int
    public let targetHeight: Int

    /// Black columns on the left and right. Non-zero only for `fit` on a target wider than
    /// the picture.
    public let pillarBars: Int

    /// Black rows above and below. Non-zero only for `fit` on a target taller than the
    /// picture.
    public let letterBars: Int

    /// The width removed from each side. Non-zero only for `fill` on a target narrower than
    /// the picture.
    public let croppedColumns: Int

    /// The height removed from the top and bottom. Non-zero only for `fill` on a target
    /// shorter than the picture.
    public let croppedRows: Int

    /// The one-line account of what happens, for a readout.
    public var summary: String {
        if scaledWidth == targetWidth && scaledHeight == targetHeight {
            return "the whole picture, unchanged"
        }
        if pillarBars > 0 {
            return "\(scaledWidth) wide picture, \(pillarBars) px bars each side"
        }
        if letterBars > 0 {
            return "\(scaledHeight) high picture, \(letterBars) px bars top and bottom"
        }
        if croppedColumns > 0 {
            return "\(scaledWidth) wide picture, \(croppedColumns) px cropped each side"
        }
        if croppedRows > 0 {
            return "\(scaledHeight) high picture, \(croppedRows) px cropped top and bottom"
        }
        return "the whole picture, unchanged"
    }

    /// Round a dimension to an even number, in the direction the mode requires.
    ///
    /// ## The float that had to be snapped
    ///
    /// `816 * (3440.0 / 1920)` is **1462.0000000000002**, not 1462. `rounded(.up)` of that is
    /// 1463, which is one pixel of phantom crop reported to the user about a conversion that has
    /// none — and the same noise can push a value just *under* an integer and lose a pixel the
    /// other way. So a value within a hair of an integer is snapped onto it first, and the
    /// rounding then acts on a number that means what it says.
    private static func even(_ value: Double, mode: FitMode) -> Int {
        let exact = abs(value - value.rounded()) < 1e-6 ? value.rounded() : value
        switch mode {
        case .fit:
            return max(2, Int(exact.rounded(.down)) & ~1)
        case .fill:
            let ceiling = Int(exact.rounded(.up))
            return max(2, ceiling % 2 == 0 ? ceiling : ceiling + 1)
        }
    }

    /// Work out what a picture of `source` does inside a `target`.
    public static func fitting(source: OutputSize,
                               target: OutputSize,
                               mode: FitMode) -> OutputGeometry {
        let horizontal = Double(target.width) / Double(source.width)
        let vertical = Double(target.height) / Double(source.height)

        // Fit takes the *smaller* factor so the picture cannot overflow on either axis; fill
        // takes the larger so it cannot fall short on either. This single choice is the whole
        // difference between the modes, and it also names the axis the picture exactly fills:
        // the one whose factor was chosen.
        let horizontalDecides = mode == .fit ? horizontal <= vertical : horizontal >= vertical
        let factor = horizontalDecides ? horizontal : vertical

        let scaledWidth = horizontalDecides
            ? target.width
            : even(Double(source.width) * factor, mode: mode)
        let scaledHeight = horizontalDecides
            ? even(Double(source.height) * factor, mode: mode)
            : target.height

        // Fit and fill measure the gap in *opposite* directions, and using one subtraction for
        // both is a bug that reads as correct: for fit the picture is smaller than the target, so
        // the bars are `target − scaled`; for fill it is larger, so the crop is `scaled − target`.
        // Written as one subtraction, the fill case comes out as a negative number, clamps to
        // zero, and reports "no crop" on a picture that is being cropped — which is exactly what
        // the first version of this did.
        let bars = (columns: max(0, target.width - scaledWidth),
                    rows: max(0, target.height - scaledHeight))
        let crop = (columns: max(0, scaledWidth - target.width),
                    rows: max(0, scaledHeight - target.height))

        return OutputGeometry(
            scaledWidth: scaledWidth,
            scaledHeight: scaledHeight,
            targetWidth: target.width,
            targetHeight: target.height,
            pillarBars: mode == .fit ? bars.columns / 2 : 0,
            letterBars: mode == .fit ? bars.rows / 2 : 0,
            croppedColumns: mode == .fill ? crop.columns / 2 : 0,
            croppedRows: mode == .fill ? crop.rows / 2 : 0)
    }
}
