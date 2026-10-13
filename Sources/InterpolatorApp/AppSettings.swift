import Foundation
import Interpolator

/// The settings the whole app reads, persisted as one value.
///
/// ## Why one value and not a dozen `@AppStorage` keys
///
/// Every one of these is a decision recorded in `reports/BUILD-DECISIONS.md` with a
/// measurement behind it, and the *combination* is what a run is. A dozen scattered
/// `@AppStorage` properties would make "what settings produced this file?" a question nobody
/// can answer, and the batch converter already has a `JobManifest` fingerprint because
/// half of one job joined to half of another plays perfectly and is wrong.
///
/// Defaults are the recorded decisions, not invented ones:
///
/// | Setting | Default | Recorded in |
/// | --- | --- | --- |
/// | output rate | 59.94 (`OutputRatePolicy.standard`) | §20 |
/// | playback resolution | **Automatic** | §30 — measure the film and hold real time; §13's Full is still one click away |
/// | conversion quality | **Quality** | §30 — the source's own resolution; Fast is 3.8× faster end to end |
/// | delivered size | **the film's own** | §34 — the separate question; a screen size is one pick away |
/// | fit / fill | **Fit** | §34 — bars lose nothing; cropping is a deliberate act |
/// | depth | 2 | invariant 3 — 1 fails outright |
/// | sessions in parallel | **automatic** (4 on this machine) | §26 — measured 1.78×, six is worse than four |
/// | scene detection | on | invariant 15 |
/// | container + audio | MP4 + AAC | §20 — "both, as a setting" |
/// | segments | off | §23 — for resuming a long job, not for speed |
struct AppSettings: Codable, Sendable, Equatable {

    // MARK: - Output

    /// `OutputRatePolicy`'s label. A *value* rather than a rate, so the player and the batch
    /// converter cannot pick different cadences for the same film — which is the reason the
    /// policy type exists.
    var policyLabel: String = OutputRatePolicy.standard.label

    /// What size the player interpolates at.
    ///
    /// **This replaced a boolean, and the default was reversed with it.** It used to be
    /// `interpolateAtFullResolution = true` — §13's recorded choice to keep true 4K and accept
    /// the dropped frames, with a one-click way out. That is a fine *option* and a poor
    /// *default*: it made the app's first impression a 4K film that judders at 19 fps on a
    /// machine that can hold 60.
    ///
    /// `.automatic` measures the film and interpolates at the widest size that holds real time.
    /// That is the same behaviour SVP gets from `fi_auto: true`, and it is the one of SVP's two
    /// levers `VTFrameProcessor` leaves us. See §30.
    ///
    /// Playback only: a conversion's size is its own setting, because a delivered file is not a
    /// preview.
    var playbackResolution = PlaybackResolutionPolicy.automatic

    /// How much work a conversion is allowed to spend per frame.
    ///
    /// `.quality` interpolates at the source's own resolution and writes it — every measurement
    /// in `reports/` was taken this way. `.fast` interpolates at 1080p and writes 1080p: the
    /// resize SVP performs before it interpolates, measured at **3.8× faster end to end** on the
    /// real 4K film. See §30.
    var conversionQuality = ConversionQuality.quality

    /// The pixel size a conversion should **deliver**, or `nil` for the size it interpolated at.
    ///
    /// ## Why this is separate from ``conversionQuality``
    ///
    /// They were one setting until this existed, and the coupling was the whole problem: a
    /// screen-sized file necessarily cost a full-resolution interpolation, and a cheap
    /// interpolation necessarily produced a small file. Interpolation cost is a step function of
    /// frame width (§29), while delivered size is a property of the screen the file is for. So
    /// they are two questions, and this is the second one.
    ///
    /// With them apart, a conversion can interpolate at 1920 wide — **31.87 ms** per interval
    /// against the film's 41.71 ms budget — and still deliver 3440×1440. The upscale is
    /// `VTPixelTransferSession`'s, measured at **2.71 ms** per frame, 4–5% of the interpolation
    /// it sits behind. That is the arrangement SVP ships, and its manual states the rule. (§34)
    ///
    /// Stored as a **size**, not as a display: a file for a television is still a file for that
    /// television when the television is unplugged, and a setting that silently reverted because
    /// a monitor went to sleep would be worse than one that remembers. See ``OutputTargetChoice``.
    var batchOutputSize: OutputSize? = nil

    /// What happens to the parts of a picture that do not fit the delivered size.
    ///
    /// `.fit` letterboxes and loses nothing; `.fill` crops and fills the screen edge to edge.
    /// Both are `VTPixelTransferSession` scaling modes — `kVTScalingMode_Letterbox` and
    /// `kVTScalingMode_Trim` — so nothing is composited by hand. Default `.fit`, because
    /// silently cropping a film is a bigger surprise than a pair of black bars.
    var batchFitMode = FitMode.fit

    /// How the player fits the picture to the window.
    ///
    /// This is the *presentation* half of the question, and it is independent of
    /// ``playbackResolution``: that decides how many pixels the engine produces, this decides
    /// what is done with them when the window is a different shape. `.fit` is
    /// `videoGravity = .resizeAspect`, `.fill` is `.resizeAspectFill`.
    ///
    /// `.fit` by default for the same reason as ``batchFitMode``, and one more: a letterboxed
    /// 2.35:1 film on a 16:10 screen is what the film's own aspect ratio asks for, and cropping
    /// it is a deliberate act.
    var playbackFitMode = FitMode.fit

    /// Requests in flight. 2 is the minimum that works (invariant 3), and past it the knob is
    /// inert — measured at 4K, depths 2, 4 and 8 all give 13.4–13.5 source frames/s.
    var depth = 2

    /// Interpolating sessions to run at once for a conversion. `0` asks the machine.
    ///
    /// **This is the setting that decides how long a conversion takes.** One session cannot be
    /// hurried; several overlap each other's idle time. Measured on the real 4K HDR film:
    ///
    ///     sessions   aggregate   speed-up
    ///        1        13.4/s      1.00x
    ///        2        21.5/s      1.60x
    ///        4        23.8/s      1.78x
    ///        6        17.0/s      1.27x
    ///
    /// Six sessions are *slower* than four, which is why the default is not "every core" but
    /// whatever the machine is good for — see `RenderWorkers.suggested()`. Zero means that;
    /// a positive number is honoured exactly.
    var workers = 0

    var sceneDetection = true

    // MARK: - Container and audio

    /// `AudioMuxPolicy.Container`'s raw value.
    var container = AudioMuxPolicy.Container.mp4.rawValue

    // MARK: - Long jobs

    /// Render in pieces of about this many seconds. `nil` renders in one go.
    var segmentSeconds: Double? = nil
    /// Keep the pieces and the manifest after a successful join.
    var keepSegments = false
    /// Replace an existing output. Off, because silently overwriting a film is not something a
    /// converter should do on its own initiative.
    var overwrite = false
    /// Stop after this many seconds. For trying a setting without waiting for a film.
    var previewSeconds: Double? = nil
    /// Where outputs go. `nil` puts each one beside its source.
    var outputDirectory: String? = nil

    // MARK: - Playback

    var useSound = true
    var volume: Double = 1
    var playbackSpeed: Double = 1

    // MARK: - Derived

    var policy: OutputRatePolicy {
        OutputRatePolicy.named(policyLabel) ?? .default
    }

    var audioPolicy: AudioMuxPolicy {
        AudioMuxPolicy(container: AudioMuxPolicy.Container(rawValue: container) ?? .mp4)
    }

    /// The resolution the player will interpolate at.
    var playbackPolicy: PlaybackResolutionPolicy { playbackResolution }

    /// The size a conversion will deliver, as the pipeline's own type.
    ///
    /// The one place the settings blob becomes an ``OutputTarget``, so the two representations
    /// cannot drift: the picker reads the size, the job writes the target, and this is the join.
    var batchOutputTarget: OutputTarget {
        batchOutputSize.map { OutputTarget.fixed($0) } ?? .source
    }

    /// What the batch footer says about the delivered size.
    ///
    /// States the interpolation size as well as the delivered size when they differ, because
    /// that difference is the entire point of the setting — a user who has chosen a 3440-wide
    /// delivery and reads "3440 × 1440" has no way to tell whether they are paying for a 4K
    /// interpolation or getting the 1080p one they wanted.
    var batchOutputLabel: String {
        guard let size = batchOutputSize else {
            return "Delivering the film's own size"
        }
        return "Delivering \(size.label) — \(batchFitMode.label.lowercased())"
    }

    /// How many sessions a conversion will actually use, setting or machine's answer.
    var workerCount: Int { RenderWorkers.resolve(workers) }

    /// What the settings screen shows for it.
    ///
    /// The resolved number and not the raw setting, because "automatic" is only useful if it
    /// says what it resolved to — a user who wants to know why a film is taking four hours
    /// needs the number that is actually being used, not the word "automatic".
    var workerLabel: String {
        workers > 0 ? "\(workers)" : "\(RenderWorkers.suggested()) (automatic)"
    }

    // MARK: - Persistence

    /// The stored keys, written out rather than inferred.
    ///
    /// Explicit because ``init(from:)`` below is hand-written, and because the blob is a
    /// user-visible artefact: it survives upgrades, and its key names are the compatibility
    /// contract between this build and the next one.
    private enum CodingKeys: String, CodingKey {
        case policyLabel, playbackResolution, conversionQuality
        case batchOutputSize, batchFitMode, playbackFitMode
        case depth, workers, sceneDetection, container
        case segmentSeconds, keepSegments, overwrite, previewSeconds, outputDirectory
        case useSound, volume, playbackSpeed
    }

    /// The defaults, as a value.
    ///
    /// Spelled out because declaring ``init(from:)`` below suppresses the implicit memberwise
    /// initialiser — and this is what ``load(from:)`` falls back to when there is nothing stored.
    init() {}

    /// Tolerant decoding, because the stored blob is a *cache of a preference set* rather than a
    /// document — and a required field that a user's stored copy predates must not take the rest
    /// of their settings down with it.
    ///
    /// **The failure this fixes was silent and total.** `playbackResolution` and
    /// `conversionQuality` were added as non-optional properties, the stored JSON predated them,
    /// decoding threw, and ``load(from:)`` returned `AppSettings()` — so upgrading reset the
    /// volume, the playback speed, the output folder, the worker count, the depth and the
    /// container, with no message and no way to tell it had happened. Every field is now optional
    /// at the decoding layer and falls back to its own default. (invariant 55)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        policyLabel = try c.decodeIfPresent(String.self, forKey: .policyLabel)
            ?? fallback.policyLabel
        playbackResolution = try c.decodeIfPresent(PlaybackResolutionPolicy.self,
                                                   forKey: .playbackResolution)
            ?? fallback.playbackResolution
        conversionQuality = try c.decodeIfPresent(ConversionQuality.self,
                                                  forKey: .conversionQuality)
            ?? fallback.conversionQuality
        // `nil` is a *meaningful* value here — "the film's own size" — so it must not be
        // confused with "absent from the blob". `decodeIfPresent` gives `OutputSize??`, and the
        // inner optional is the setting; the outer is whether the key was there at all. Both
        // collapse to the default, which is also `nil`, so the two cases happen to agree.
        batchOutputSize = try c.decodeIfPresent(OutputSize.self, forKey: .batchOutputSize)
        batchFitMode = try c.decodeIfPresent(FitMode.self, forKey: .batchFitMode)
            ?? fallback.batchFitMode
        playbackFitMode = try c.decodeIfPresent(FitMode.self, forKey: .playbackFitMode)
            ?? fallback.playbackFitMode
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? fallback.depth
        workers = try c.decodeIfPresent(Int.self, forKey: .workers) ?? fallback.workers
        sceneDetection = try c.decodeIfPresent(Bool.self, forKey: .sceneDetection)
            ?? fallback.sceneDetection
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? fallback.container
        segmentSeconds = try c.decodeIfPresent(Double.self, forKey: .segmentSeconds)
        keepSegments = try c.decodeIfPresent(Bool.self, forKey: .keepSegments)
            ?? fallback.keepSegments
        overwrite = try c.decodeIfPresent(Bool.self, forKey: .overwrite) ?? fallback.overwrite
        previewSeconds = try c.decodeIfPresent(Double.self, forKey: .previewSeconds)
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory)
        useSound = try c.decodeIfPresent(Bool.self, forKey: .useSound) ?? fallback.useSound
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? fallback.volume
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed)
            ?? fallback.playbackSpeed
    }

    private static let key = "60FPS.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Where a job's output should go for a given input.
    ///
    /// Beside the source by default, with `-60fps` appended, and the extension following the
    /// container — because a `.mp4` holding a bit-perfect DTS copy is the exact failure the
    /// container policy exists to prevent, and ffmpeg would write it without complaint.
    ///
    /// ## Why the delivered size is in the name
    ///
    /// Once the delivered size is a setting, the same film converted twice at two sizes is two
    /// different files — and without this they would be the *same path*. `overwrite` is off, so
    /// the second job would stop with "an output already exists" and the user would have to work
    /// out that the answer is to move a file or turn overwriting on. Naming the size makes the
    /// two files coexist, which is what the feature is for.
    ///
    /// The suffix is omitted for `.source`, so a conversion with no target is byte-for-byte the
    /// file it was before this setting existed — the same promise ``OutputTarget/source`` makes.
    func outputURL(for input: URL) -> URL {
        let directory = outputDirectory.map { URL(fileURLWithPath: $0) }
            ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let size = batchOutputSize.map { "-\($0.width)x\($0.height)" } ?? ""
        return directory
            .appendingPathComponent("\(stem)-60fps\(size)")
            .appendingPathExtension(audioPolicy.container.fileExtension)
    }
}
