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
/// | interpolation resolution | **Full** | §13 — true 4K, accept the drops, with a one-click way out |
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

    /// Interpolate at the source's own size, or scale to 1080p first.
    ///
    /// `true` is §13's recorded choice — true 4K, accept the drops — and it is the default so
    /// the behaviour matches the decision. The toggle is what makes it reversible in one click
    /// when a 4K title judders, which §13 required. Playback only: the batch converter writes
    /// at the source's resolution, because a delivered file is not a preview.
    var interpolateAtFullResolution = true

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
    var playbackDownscales: Bool { !interpolateAtFullResolution }

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
    func outputURL(for input: URL) -> URL {
        let directory = outputDirectory.map { URL(fileURLWithPath: $0) }
            ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(stem)-60fps")
            .appendingPathExtension(audioPolicy.container.fileExtension)
    }
}
