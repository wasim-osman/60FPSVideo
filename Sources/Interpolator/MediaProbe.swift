import Foundation

/// What a file actually is, read from the file rather than assumed from its name.
///
/// ## Why this goes through ffprobe rather than AVFoundation
///
/// This was measured, not preferred. AVFoundation is the obvious choice on macOS
/// and it is genuinely better at some things, but for *opening the user's file* it
/// fails in three ways that all matter here:
///
/// 1. **It cannot open Matroska at all.** `loadTracks` throws `Cannot Open`. Every
///    BluRay rip in circulation is either MKV or MP4, so that is half the library.
/// 2. **It reports the frame rate as a Float.** `nominalFrameRate` gave 23.975872
///    for a 24000/1001 film. Invariant 14 says a decimal rate drifts the
///    interpolation phase and destroys 20% of the passthrough frames, so the exact
///    rational is not a nicety. ffprobe reports `r_frame_rate=24000/1001` directly.
/// 3. **A lossless remux is not a safe workaround.** Remuxing the MKV to MOV to get
///    it past (1) produced a file with a mangled frame duration (656/16000, i.e.
///    24.39 fps) and with the HDR10 metadata stripped, because AVFoundation reads
///    the container's `mdcv`/`clli` boxes and a stream copy does not write them.
///    Both are silent — the file opens and plays, just wrongly.
///
/// ffprobe answers all three, for every container, and the decode side is not a
/// bottleneck: measured at **37 source frames per second** for 4K HEVC to raw P010
/// through a pipe, while the interpolator only consumes about 14.6.
///
/// So the split is: **ffmpeg decodes and describes, AVFoundation encodes.** The
/// encode side stays on VideoToolbox because that is what the app must ship, and
/// because it is proven to carry HDR10 metadata byte-exact (invariant 21).
public struct MediaInfo: Sendable {

    public let url: URL
    public let width: Int
    public let height: Int

    /// The exact rational rate. Never a decimal — see invariant 14.
    public let frameRate: FrameRate
    /// `nil` when the container does not state it. Streams frequently do not;
    /// counting frames means decoding them, which is the caller's business.
    public let frameCount: Int?
    public let duration: Double

    /// ffmpeg's own name for the pixel format, kept verbatim for diagnostics.
    public let pixelFormat: String
    /// The pipeline format negotiated from it.
    public let format: FrameFormat

    public let colorPrimaries: String?
    public let transferFunction: String?
    public let colorSpace: String?
    public let colorRange: String?

    public let masteringDisplay: MasteringDisplay?
    public let contentLightLevel: ContentLightLevel?

    /// First audio stream's codec, for deciding whether it can be passed through.
    public let audioCodec: String?
    public let audioChannels: Int?

    /// True when the transfer function is a high-dynamic-range one. This is the
    /// switch that decides whether the pipeline runs 8-bit or 10-bit.
    public var isHDR: Bool {
        guard let transferFunction else { return false }
        return ["smpte2084", "smpte428", "arib-std-b67", "bt2020-10", "bt2020-12"]
            .contains(transferFunction)
    }

    /// A copy with the audio stream's details filled in.
    public func withAudio(codec: String?, channels: Int?) -> MediaInfo {
        MediaInfo(url: url, width: width, height: height, frameRate: frameRate,
                  frameCount: frameCount, duration: duration,
                  pixelFormat: pixelFormat, format: format,
                  colorPrimaries: colorPrimaries, transferFunction: transferFunction,
                  colorSpace: colorSpace, colorRange: colorRange,
                  masteringDisplay: masteringDisplay,
                  contentLightLevel: contentLightLevel,
                  audioCodec: codec, audioChannels: channels)
    }

    /// Audio codecs that can be copied into an MP4/MOV container unchanged.
    ///
    /// The reference disc carries DTS-X 7.1, which is exactly the case this exists
    /// for: it cannot go into MP4, and silently dropping it would be worse than
    /// saying so.
    public static let audioPassThroughCodecs: Set<String> =
        ["aac", "ac3", "eac3", "alac", "mp3"]

    /// Whether the audio can be copied into an MP4/MOV container unchanged.
    public var audioCanPassThroughToMP4: Bool {
        guard let audioCodec else { return true }
        return MediaInfo.audioPassThroughCodecs.contains(audioCodec)
    }
}

/// HDR10 mastering display metadata, as the disc states it.
///
/// The values are held in the units the SEI uses, *not* in nits or in floats,
/// because that is the form the encoder needs and the conversion is where this is
/// easy to get wrong: luminances are in 0.0001 cd/m², so 1000 nits is 10,000,000.
public struct MasteringDisplay: Sendable, Equatable {
    public let redX: Int, redY: Int
    public let greenX: Int, greenY: Int
    public let blueX: Int, blueY: Int
    public let whiteX: Int, whiteY: Int
    /// In 0.0001 cd/m².
    public let minLuminance: Int, maxLuminance: Int

    public init(redX: Int, redY: Int, greenX: Int, greenY: Int,
                blueX: Int, blueY: Int, whiteX: Int, whiteY: Int,
                minLuminance: Int, maxLuminance: Int) {
        self.redX = redX; self.redY = redY
        self.greenX = greenX; self.greenY = greenY
        self.blueX = blueX; self.blueY = blueY
        self.whiteX = whiteX; self.whiteY = whiteY
        self.minLuminance = minLuminance; self.maxLuminance = maxLuminance
    }

    public var maxNits: Double { Double(maxLuminance) * 0.0001 }
    public var minNits: Double { Double(minLuminance) * 0.0001 }

    /// The 24-byte SEI payload, big-endian.
    ///
    /// Order is **green, blue, red** — the HEVC spec's `display_primaries` order,
    /// not RGB. Getting that wrong produces a picture with the primaries rotated,
    /// which looks plausible and is wrong.
    public var seiPayload: Data {
        var bytes: [UInt8] = []
        func u16(_ v: Int) {
            bytes += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        func u32(_ v: Int) {
            bytes += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                      UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        u16(greenX); u16(greenY)
        u16(blueX); u16(blueY)
        u16(redX); u16(redY)
        u16(whiteX); u16(whiteY)
        u32(maxLuminance)
        u32(minLuminance)
        return Data(bytes)
    }
}

/// Content light level metadata — the two numbers that let a display decide how
/// hard to drive its backlight.
public struct ContentLightLevel: Sendable, Equatable {
    /// MaxCLL, in nits.
    public let maxContent: Int
    /// MaxFALL, in nits.
    public let maxAverage: Int

    public init(maxContent: Int, maxAverage: Int) {
        self.maxContent = maxContent
        self.maxAverage = maxAverage
    }

    /// The 4-byte SEI payload, big-endian: MaxCLL then MaxFALL.
    public var seiPayload: Data {
        var bytes: [UInt8] = []
        for v in [maxContent, maxAverage] {
            bytes += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        return Data(bytes)
    }
}

public enum MediaProbeError: Error, CustomStringConvertible {
    case ffprobeMissing
    case failed(status: Int32, message: String)
    case noVideoStream(String)
    case unreadableOutput(String)

    public var description: String {
        switch self {
        case .ffprobeMissing:
            "ffprobe is not on PATH. The pipeline needs ffmpeg to open media files."
        case .failed(let status, let message):
            "ffprobe exited \(status): \(message)"
        case .noVideoStream(let path):
            "no video stream in \(path)"
        case .unreadableOutput(let detail):
            "could not read ffprobe's output: \(detail)"
        }
    }
}

/// Reads what a file is, using ffprobe.
public enum MediaProbe {

    /// Where ffprobe is. Resolved from the usual places, with an environment
    /// variable escape hatch for a bundled or non-standard copy.
    ///
    /// Computed rather than a stored override, so there is no mutable global state
    /// — under Swift 6 strict concurrency a settable static is a data race waiting
    /// to happen, and this does not need one. Not hardcoded to a single path
    /// either: Homebrew is `/opt/homebrew` on Apple Silicon but `/usr/local` on
    /// Intel, and a wrong guess produces a confusing "ffprobe is not on PATH" for a
    /// user who can plainly run ffprobe in a terminal.
    public static var ffprobePath: String {
        if let override = ProcessInfo.processInfo.environment["FFPROBE"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
            "/opt/local/bin/ffprobe",
        ]
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Last resort: ask the shell, so a PATH-only install still works.
        if let found = which("ffprobe") { return found }
        return candidates[0]
    }

    /// Where ffmpeg is, resolved the same way.
    public static var ffmpegPath: String {
        if let override = ProcessInfo.processInfo.environment["FFMPEG"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
        ]
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let found = which("ffmpeg") { return found }
        return candidates[0]
    }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Probe a file. Throws rather than guessing if anything is missing.
    public static func probe(_ url: URL) throws -> MediaInfo {
        // One call, both halves: the stream carries the colour tags and the rate,
        // and the *first frame* carries the HDR10 side data. Reading a frame means
        // decoding one, which is why the interval is limited to a single frame.
        let json = try run([
            "-v", "error",
            "-select_streams", "v:0",
            "-read_intervals", "%+#1",
            "-show_streams", "-show_frames", "-show_format",
            "-of", "json",
            url.path,
        ])
        var info = try parse(json, url: url)

        // Audio needs its own query: ffprobe's stream selector is a filter, and
        // `v:0` excludes the audio stream rather than describing it. The batch
        // converter needs the codec to decide whether the audio can be copied into
        // an MP4, and "cannot" has to be known before the job starts rather than
        // discovered when the mux fails at the end.
        if let audio = try? audioStream(url) {
            info = info.withAudio(codec: audio.codec, channels: audio.channels)
        }
        return info
    }

    static func audioStream(_ url: URL) throws -> (codec: String?, channels: Int?) {
        let json = try run([
            "-v", "error", "-select_streams", "a:0",
            "-show_streams", "-of", "json", url.path,
        ])
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let stream = streams.first else { return (nil, nil) }
        return (stream["codec_name"] as? String, stream["channels"] as? Int)
    }

    /// Probe only the stream, without decoding a frame. Faster, but the HDR10
    /// static metadata is not available this way.
    public static func probeStreamOnly(_ url: URL) throws -> MediaInfo {
        let json = try run([
            "-v", "error", "-select_streams", "v:0",
            "-show_streams", "-of", "json", url.path,
        ])
        return try parse(json, url: url)
    }

    // MARK: - Internals

    static func run(_ arguments: [String]) throws -> Data {
        let executable = ffprobePath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MediaProbeError.ffprobeMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw MediaProbeError.failed(status: -1, message: "\(error)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MediaProbeError.failed(
                status: process.terminationStatus,
                message: String(data: errorData, encoding: .utf8) ?? "no message")
        }
        return data
    }

    static func parse(_ data: Data, url: URL) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaProbeError.unreadableOutput("not a JSON object")
        }
        guard let streams = root["streams"] as? [[String: Any]],
              let stream = streams.first else {
            throw MediaProbeError.noVideoStream(url.lastPathComponent)
        }

        guard let width = stream["width"] as? Int,
              let height = stream["height"] as? Int else {
            throw MediaProbeError.unreadableOutput("stream has no width/height")
        }

        // r_frame_rate is the container's stated rate as a rational string. Prefer
        // it; fall back to avg_frame_rate, then refuse rather than invent one.
        let rateString = (stream["r_frame_rate"] as? String)
            ?? (stream["avg_frame_rate"] as? String)
        guard let rateString, let rate = FrameRate.parse(rateString) else {
            throw MediaProbeError.unreadableOutput(
                "no usable frame rate (r_frame_rate was \(stream["r_frame_rate"] ?? "absent"))")
        }

        let pixelFormat = (stream["pix_fmt"] as? String) ?? ""

        // HDR10 static metadata lives on the *frame*, not the stream.
        var mastering: MasteringDisplay?
        var lightLevel: ContentLightLevel?
        if let frames = root["frames"] as? [[String: Any]] {
            for side in (frames.first?["side_data_list"] as? [[String: Any]]) ?? [] {
                switch side["side_data_type"] as? String {
                case "Mastering display metadata":
                    mastering = parseMastering(side)
                case "Content light level metadata":
                    if let maxContent = side["max_content"] as? Int,
                       let maxAverage = side["max_average"] as? Int {
                        lightLevel = ContentLightLevel(maxContent: maxContent,
                                                       maxAverage: maxAverage)
                    }
                default:
                    break
                }
            }
        }

        // Duration: Matroska and many transport streams do not put it on the
        // stream, only on the container, so both are consulted.
        let streamDuration = Double(stream["duration"] as? String ?? "")
        let formatDuration = Double(
            ((root["format"] as? [String: Any])?["duration"] as? String) ?? "")
        let duration = streamDuration ?? formatDuration ?? 0

        // Frame count: usually absent for MKV. Deriving it from the duration is an
        // estimate, so it is only offered when the container actually said so —
        // callers that need an exact count have to count, and a plausible-looking
        // guess would be worse than nil.
        let frameCount = stream["nb_frames"] as? Int

        return MediaInfo(
            url: url,
            width: width,
            height: height,
            frameRate: rate,
            frameCount: frameCount,
            duration: duration,
            pixelFormat: pixelFormat,
            format: negotiateFormat(pixelFormat),
            colorPrimaries: stream["color_primaries"] as? String,
            transferFunction: stream["color_transfer"] as? String,
            colorSpace: stream["color_space"] as? String,
            colorRange: stream["color_range"] as? String,
            masteringDisplay: mastering,
            contentLightLevel: lightLevel,
            audioCodec: nil,
            audioChannels: nil)
    }

    /// ffprobe reports the mastering display as rationals like `"34000/50000"`.
    ///
    /// Those are **not** the SEI values, and reading the numerator directly only
    /// works by coincidence. ffprobe prints `AVMasteringDisplayMetadata`, whose
    /// primaries are chromaticity coordinates in 0...1 (`34000/50000` = 0.68) and
    /// whose luminances are in cd/m² (`10000000/10000` = 1000 nits). The SEI wants
    /// chromaticity × 50000 and luminance in 0.0001 cd/m². So each value is scaled
    /// back up by its own factor, which is correct whatever denominator ffprobe
    /// happens to choose — and it does choose different ones.
    ///
    /// Getting this wrong is quiet rather than loud: taking the quotient as-is
    /// rounds 0.68 to 1, which is a valid chromaticity and a wrong picture.
    static func parseMastering(_ side: [String: Any]) -> MasteringDisplay? {
        /// Parse `"a/b"` into a Double. Returns nil rather than 0 on anything
        /// unexpected, because a zeroed mastering display is a *valid* payload that
        /// claims the content is black.
        func quotient(_ key: String) -> Double? {
            guard let text = side[key] as? String else { return nil }
            let parts = text.split(separator: "/")
            guard let numerator = Double(parts.first ?? "") else { return nil }
            guard parts.count >= 2 else { return numerator }
            guard let denominator = Double(parts[1]), denominator != 0 else { return nil }
            return numerator / denominator
        }
        /// Chromaticity: fraction of 1, scaled to the SEI's 1/50000 units.
        func chromaticity(_ key: String) -> Int? {
            quotient(key).map { Int(($0 * 50000).rounded()) }
        }
        /// Luminance: cd/m², scaled to the SEI's 0.0001 cd/m² units.
        func luminance(_ key: String) -> Int? {
            quotient(key).map { Int(($0 * 10000).rounded()) }
        }

        guard let redX = chromaticity("red_x"), let redY = chromaticity("red_y"),
              let greenX = chromaticity("green_x"), let greenY = chromaticity("green_y"),
              let blueX = chromaticity("blue_x"), let blueY = chromaticity("blue_y"),
              let whiteX = chromaticity("white_point_x"),
              let whiteY = chromaticity("white_point_y"),
              let minL = luminance("min_luminance"),
              let maxL = luminance("max_luminance")
        else { return nil }
        return MasteringDisplay(redX: redX, redY: redY,
                                greenX: greenX, greenY: greenY,
                                blueX: blueX, blueY: blueY,
                                whiteX: whiteX, whiteY: whiteY,
                                minLuminance: minL, maxLuminance: maxL)
    }

    /// Choose the pipeline format from ffmpeg's pixel format name.
    ///
    /// Anything 10-bit or deeper goes to P010; everything else to NV12. Matching on
    /// the name is less tidy than matching on a code, but ffprobe's names are stable
    /// and this is the only place the decision is made.
    public static func negotiateFormat(_ pixelFormat: String) -> FrameFormat {
        let tenBit = ["10le", "10be", "p010", "p016", "y210", "y212", "y216"]
        return tenBit.contains(where: pixelFormat.contains) ? .p010 : .nv12
    }
}
