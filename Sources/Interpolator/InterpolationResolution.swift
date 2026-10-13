import Foundation

/// How wide the interpolation runs — the one lever that decides whether this machine keeps up.
///
/// ## The measurement this exists for
///
/// `VTFrameProcessor`'s cost is a **step function of frame width**, not of pixel count. Measured
/// on the release build, 192 frames of the real film, 24000/1001 → 60000/1001, depth 2:
///
/// | resolution | pixels | ms/interval | × the 41.7 ms budget |
/// | --- | --- | --- | --- |
/// | 1920×816 | 1.57 Mpx | **31.87** | **0.76** |
/// | 1920×1088 | 2.09 Mpx | **40.73** | **0.98** |
/// | 1984×844 | 1.67 Mpx | 52.01 | 1.25 |
/// | 2048×870 | 1.78 Mpx | 50.96 | 1.22 |
/// | 2560×816 | 2.09 Mpx | 78.53 | 1.88 |
/// | 3384×1440 | 4.87 Mpx | 81.55 | 1.96 |
/// | 3840×1632 | 6.27 Mpx | ~105 | ~2.5 |
///
/// Two rows are the whole point: **2560×816 and 1920×1088 are both 2,088,960 px and cost 78.53
/// against 40.73 ms — 1.93×.** The table is not even monotonic in pixels: 2048×870 beats
/// 1984×844, and 1920×1088 beats both. So the lever is *width*, the ladder below is built from
/// widths rather than from pixel budgets, and only the 1920-wide rungs meet the budget.
///
/// See `reports/BUILD-DECISIONS.md` §29–30 for the full measurement, including why SVP — which
/// resizes to 3384×1440 before it interpolates — is not helped by its own resize either.
public enum InterpolationWidth {

    /// The width a *conversion* may fall back to when asked to be fast.
    ///
    /// 1920 because it is the widest rung measured to meet this film's budget, and because it is
    /// the same kind of reduction SVP makes before interpolating. It is the one of SVP's two
    /// levers that `VTFrameProcessor` leaves us: the other is its block-matching motion model,
    /// which the framework does not expose at all (invariant 51).
    public static let fastConversionWidth = 1920

    /// Candidate widths below the source's own, widest first.
    ///
    /// Deliberately absolute widths rather than fractions of the source: the cost curve steps at
    /// particular *widths*, so a ladder of ratios would land on a different rung for every
    /// aspect ratio and stop being a ladder.
    ///
    /// **One rung per measured tread, and no more.** Probing the real film at five positions with
    /// 30 intervals each — enough samples that the figures reproduce — gives three treads, not
    /// six: 3840 and 2560 cost ~80–93 ms, 1920, 1600 and 1280 all cost ~33–37 ms, and 960 costs
    /// ~25–27 ms. A ladder carrying 1600 and 1280 therefore spends its probe budget walking rungs
    /// that cost the *same* as the one above them, which is how the 960 fallback came to be chosen
    /// without ever being measured. See invariant 54.
    public static let ladder = [2560, 1920, 960]

    /// Milliseconds one interval of film time is worth: how long a render may take and still
    /// keep up with the film.
    ///
    /// 41.708… ms at 24000/1001. The player must produce one interval's output in the time the
    /// film spends playing that interval, or it is losing ground — and the loss is per-frame, so
    /// no amount of queueing recovers it.
    public static func budget(sourceRate: FrameRate) -> Double {
        1000.0 / sourceRate.doubleValue
    }

    /// Every width worth trying for a source, widest first, **including the source's own**.
    ///
    /// The source's own width comes first so that a film this machine *can* handle is never
    /// downscaled: a 1080p source, or 4K on a machine that can afford it, keeps its resolution
    /// and the policy costs nothing.
    public static func candidates(sourceWidth: Int) -> [Int] {
        var widths = [sourceWidth]
        widths += ladder.filter { $0 < sourceWidth }
        return widths
    }

    /// A `MediaInfo` describing the same film at `width`, aspect preserved and height **even**.
    ///
    /// Height is forced even because 4:2:0 chroma is subsampled by two in both directions: an odd
    /// height is not a slightly wrong picture, it is a frame the pixel format cannot describe,
    /// and the failure arrives far from here as a buffer that will not allocate. 3840×1632
    /// halves to 1920×816, which happens to be even; a 2160-high source does not.
    ///
    /// A width at or above the source's is returned unchanged — upscaling to interpolate would be
    /// work spent to lose information.
    public static func scaled(_ info: MediaInfo, toWidth width: Int) -> MediaInfo {
        let target = min(width, info.width)
        guard target < info.width else { return info }
        let factor = Double(target) / Double(info.width)
        let height = max(2, Int((Double(info.height) * factor).rounded()) & ~1)
        return info.scaled(toWidth: target, height: height)
    }

    /// The width a conversion interpolates at, given its quality setting.
    public static func conversionWidth(_ quality: ConversionQuality, sourceWidth: Int) -> Int {
        switch quality {
        case .quality: sourceWidth
        case .fast: min(fastConversionWidth, sourceWidth)
        }
    }

    /// The next rung **below** `width`, or `nil` when it is already the narrowest.
    ///
    /// This is what lets the player give ground rather than only guess. The calibration's answer
    /// is a *prediction* — a short measured run of the pipeline, before the clock starts — and the
    /// thing it cannot see is the cost of presenting, which is not in the probe at all. When the
    /// prediction is wrong the picture is simply short of the rate, and the only honest response
    /// is to look at what actually happened and move down one rung. See `PlaybackController`'s
    /// rate watchdog and §31.
    ///
    /// A `width` that is not on the ladder returns `nil` rather than guessing at a neighbour: the
    /// rungs are absolute widths on a cost curve that steps, so "80% of the current width" is not
    /// a rung and may well cost the same as the one above it.
    public static func narrower(than width: Int, sourceWidth: Int) -> Int? {
        let ladder = candidates(sourceWidth: sourceWidth)
        guard let index = ladder.firstIndex(of: width), index + 1 < ladder.count else {
            return nil
        }
        return ladder[index + 1]
    }
}

// MARK: - Conversion quality

/// How much work a conversion is allowed to spend on each frame.
///
/// Two settings, because there are exactly two things this machine can do: the engine's own dense
/// optical flow at full size, or the same engine at a reduced size. There is no third option to
/// offer — see `InterpolationWidth` and invariant 51.
public enum ConversionQuality: String, Codable, CaseIterable, Identifiable, Sendable {

    /// Interpolate at the source's own resolution and write that resolution.
    ///
    /// Dense per-pixel optical flow, computed at full size — the best picture this project can
    /// produce, and what every measurement in `reports/` was taken with.
    case quality

    /// Interpolate at 1080p and write 1080p.
    ///
    /// The resize SVP performs before it interpolates, and the only one of its two levers the
    /// framework exposes. Measured on the real 4K HDR film: **105 → 31.87 ms per interval**, and
    /// end to end **12.4 s → 3.2 s for 288 source frames — 3.8×** (23.2 → 88.8 source frames/s),
    /// for a 1080p result instead of 4K. The end-to-end figure beats the interpolation's own 3.3×
    /// because the encode is cheaper too: 10.0 MB against 23.1 MB.
    ///
    /// The output is 1080p, not 4K upscaled, and that is a decision rather than an omission:
    /// there is no scaler in this pipeline (this machine's ffmpeg has no `zscale`, and `scale_vt`
    /// fails `ENOSYS`), so upscaling would mean a second full encode pass, which would cost more
    /// than the interpolation saves.
    case fast

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quality: "Quality"
        case .fast: "Fast"
        }
    }

    /// The one-line explanation the picker shows underneath.
    public var detail: String {
        switch self {
        case .quality:
            "Interpolate at the source's resolution. Best picture, slowest."
        case .fast:
            "Interpolate at 1080p and write 1080p. About 3× faster on 4K sources."
        }
    }
}

// MARK: - Playback resolution

/// The resolution the player interpolates at.
///
/// ## Why this replaced a boolean
///
/// It was `interpolateAtFullResolution: Bool`, defaulting to `true` — the recorded §13 decision
/// to keep true 4K and accept the dropped frames, with a one-click way out. That is a fine
/// *option* and a poor *default*: it makes the app's first impression a film that judders at
/// 19 fps when the machine can hold 60.
///
/// SVP's answer to the same problem is `fi_auto: true` — it decides for itself, and it holds the
/// rate. `.automatic` is that behaviour: measure the film, walk the width ladder, and interpolate
/// at the widest rung this machine can actually afford.
public enum PlaybackResolutionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {

    /// Interpolate at the source's own size. Best picture; drops frames when the machine cannot
    /// keep up. The §13 decision, kept as an explicit choice.
    case source

    /// Measure the film, then interpolate at the widest width that meets its budget.
    ///
    /// The default, and the reason a 4K film plays in real time on this machine.
    case automatic

    /// Force 1920 wide. The one-click escape §13 required, kept as its own setting because a
    /// user who has decided they want 1080p should not have to wait for a calibration to agree.
    case p1080

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .source: "Full"
        case .automatic: "Automatic"
        case .p1080: "1080p"
        }
    }

    public var detail: String {
        switch self {
        case .source:
            "Interpolate at the film's own resolution. Best picture; a 4K film will drop frames."
        case .automatic:
            "Measure this film and interpolate at the widest size that holds real time."
        case .p1080:
            "Interpolate at 1920 wide and scale up to the window."
        }
    }

    /// The width this policy asks for, before any calibration.
    ///
    /// `nil` means "the source's own width". `.automatic` returns `nil` because its answer comes
    /// from a measurement rather than from the policy — see ``PlaybackCalibrator``.
    public var fixedWidth: Int? {
        switch self {
        case .source, .automatic: nil
        case .p1080: 1920
        }
    }
}
