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

    /// Every audio stream, in the container's order.
    ///
    /// All of them rather than the first, because the *first* is frequently not the
    /// useful one. Measured on the reference disc: stream 1 is DTS-HD MA + DTS:X 7.1
    /// and stream 2 is an AC-3 5.1 compatibility track. The 7.1 is the one worth
    /// keeping and the 5.1 is the only one that can go into an MP4 bit-perfect, so a
    /// decision made from `first` alone gets *both* halves wrong — it would transcode
    /// a track it could have copied, or copy one it should have kept in full.
    public let audioTracks: [AudioTrack]

    /// How many chapter marks the container states.
    ///
    /// Worth carrying because it is a thing that vanishes without a word. ffmpeg's MP4
    /// muxer writes the source's chapters as a QuickTime chapter track — a `text`
    /// track referenced by the video track's `tref`, which `ffprobe` reports as an
    /// extra `bin_data` stream nobody asked for. That is correct and desirable (the
    /// film keeps its chapter marks), but it is also exactly the kind of thing a later
    /// `-map_metadata -1` would silently delete, so the count is read back and
    /// compared rather than assumed.
    public let chapterCount: Int

    /// The first audio stream's codec. Convenience for callers that only need
    /// "is there audio, and roughly what".
    public var audioCodec: String? { audioTracks.first?.codec }
    public var audioChannels: Int? { audioTracks.first?.channels }
    public var hasAudio: Bool { !audioTracks.isEmpty }

    /// True when the transfer function is a high-dynamic-range one. This is the
    /// switch that decides whether the pipeline runs 8-bit or 10-bit.
    public var isHDR: Bool {
        guard let transferFunction else { return false }
        return ["smpte2084", "smpte428", "arib-std-b67", "bt2020-10", "bt2020-12"]
            .contains(transferFunction)
    }

    /// A copy with the audio streams and chapter count filled in.
    public func withAudio(_ tracks: [AudioTrack], chapters: Int) -> MediaInfo {
        MediaInfo(url: url, width: width, height: height, frameRate: frameRate,
                  frameCount: frameCount, duration: duration,
                  pixelFormat: pixelFormat, format: format,
                  colorPrimaries: colorPrimaries, transferFunction: transferFunction,
                  colorSpace: colorSpace, colorRange: colorRange,
                  masteringDisplay: masteringDisplay,
                  contentLightLevel: contentLightLevel,
                  audioTracks: tracks, chapterCount: chapters)
    }

    /// A copy describing the same film at a different size.
    ///
    /// Playback's downscale, and the reason it is a *description* rather than a transform:
    /// the frame geometry is what the pipeline reads to size its buffers and what the sink
    /// reads to build its output, so a source that scales its frames has to say so in the
    /// same place everything else looks. Passing the original `MediaInfo` alongside a
    /// scaling decoder would size every buffer for 4K and then fill it with 1080p rows.
    ///
    /// The colour fields are carried through untouched: scaling does not change primaries,
    /// transfer function or range, and pretending otherwise is how a 10-bit HDR frame
    /// acquires an SDR description.
    public func scaled(toWidth width: Int, height: Int) -> MediaInfo {
        MediaInfo(url: url, width: width, height: height, frameRate: frameRate,
                  frameCount: frameCount, duration: duration,
                  pixelFormat: pixelFormat, format: format,
                  colorPrimaries: colorPrimaries, transferFunction: transferFunction,
                  colorSpace: colorSpace, colorRange: colorRange,
                  masteringDisplay: masteringDisplay,
                  contentLightLevel: contentLightLevel,
                  audioTracks: audioTracks, chapterCount: chapterCount)
    }

    /// Audio codecs an MP4/MOV container can carry.
    ///
    /// ## Why this is a list we keep, and not something ffmpeg decides
    ///
    /// The original justification here was that "DTS cannot be copied into MP4 at
    /// all". **That is false, and it was measured.** `ffmpeg -c:a copy -f mp4` writes a
    /// DTS track without complaint — the only diagnostic is a benign
    /// `codec frame size is not set`, and the file comes out at the full 1.7 MB. What
    /// actually happens is worse than a refusal: **macOS cannot open the result**
    /// (`AudioFileOpenURL failed` on a file that ffmpeg reports as a valid MP4 with a
    /// valid DTS stream). DTS is not in the MP4 registry; ffmpeg will write the
    /// non-standard fourcc anyway and most players will then refuse it.
    ///
    /// So the rule is not "ffmpeg will stop us" — it is that **the container's codec
    /// registry is a policy this app states**, because a file that is technically
    /// writable and practically unplayable is the exact failure mode this project
    /// keeps having to design against. Measured on the same clip: AC-3 5.1 copies into
    /// MP4 and macOS opens it; AAC 7.1 transcodes to a real 8-channel 7.1 track at
    /// ~636 kbps and macOS opens that too.
    public static let audioPassThroughCodecs: Set<String> =
        ["aac", "ac3", "eac3", "alac", "mp3"]

    /// Codecs a Matroska container can carry unchanged. Everything the MP4 set holds,
    /// plus the ones a BluRay actually ships with.
    public static let matroskaAudioCodecs: Set<String> =
        audioPassThroughCodecs.union(["dts", "truehd", "flac", "opus", "vorbis", "pcm_s16le",
                                      "pcm_s24le", "pcm_bluray", "pcm_dvd"])

    /// Whether the audio can be copied into an MP4/MOV container unchanged.
    public var audioCanPassThroughToMP4: Bool {
        guard let audioCodec else { return true }
        return MediaInfo.audioPassThroughCodecs.contains(audioCodec)
    }
}

/// One audio stream, as the container states it.
///
/// The fields are the ones a decision actually needs. `index` is ffmpeg's own stream
/// index in the source, which is what `-map` takes — so a plan can name the track it
/// chose without re-deriving the mapping later and getting it wrong.
public struct AudioTrack: Sendable, Equatable, CustomStringConvertible {

    /// ffmpeg's stream index in the source file. `-map 1:<index>` in the mux.
    public let index: Int
    public let codec: String
    /// e.g. `DTS-HD MA + DTS:X`. Needed to tell lossless DTS from the lossy core,
    /// which the codec name alone cannot express.
    public let profile: String?
    public let channels: Int?
    /// ffmpeg's name for it: `7.1`, `5.1(side)`, `stereo`, …
    public let channelLayout: String?
    public let sampleRate: Int?
    public let bitRate: Int?
    /// The container's own default disposition.
    public let isDefault: Bool

    public init(index: Int, codec: String, profile: String? = nil,
                channels: Int? = nil, channelLayout: String? = nil,
                sampleRate: Int? = nil, bitRate: Int? = nil,
                isDefault: Bool = false) {
        self.index = index
        self.codec = codec
        self.profile = profile
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.isDefault = isDefault
    }

    /// Whether the *stream itself* is lossless.
    ///
    /// DTS is the case that needs the profile: plain DTS core is lossy, and DTS-HD MA
    /// — which is what a BluRay actually carries — is not. Reading the codec name
    /// alone would call a lossless track lossy, which is the difference between
    /// "copy this, it is the master" and "transcode it, it is already degraded".
    public var isLossless: Bool {
        switch codec {
        case "truehd", "mlp", "flac", "alac":
            return true
        case "dts":
            let profile = self.profile ?? ""
            return profile.contains("MA") || profile.contains("X")
        default:
            return codec.hasPrefix("pcm_")
        }
    }

    public var description: String {
        // A profile frequently restates the codec — `dts` with profile
        // `DTS-HD MA + DTS:X` — and printing both gives "DTS DTS-HD MA + DTS:X",
        // which reads like a different track from the one the file has.
        let name = codec.uppercased()
        var parts: [String] = []
        if let profile, !profile.isEmpty {
            parts.append(profile.uppercased().hasPrefix(name) ? profile : "\(name) \(profile)")
        } else {
            parts.append(name)
        }
        if let channelLayout { parts.append(channelLayout) }
        else if let channels { parts.append("\(channels) ch") }
        if let bitRate { parts.append("\(bitRate / 1000) kbps") }
        return parts.joined(separator: " ")
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
        // discovered when the mux fails at the end. *Every* audio stream is read,
        // because on the reference disc the usable one is the second. Chapters ride
        // along on the same call — they are metadata, so it costs nothing to ask.
        if let extra = try? trackInfo(url) {
            info = info.withAudio(extra.tracks, chapters: extra.chapters)
        }
        return info
    }

    /// Every audio stream, and the chapter count, in one ffprobe call.
    ///
    /// No `-select_streams` filter: it filters *out* rather than describing, so the
    /// unfiltered stream list is the only way to see all of them at once. The video
    /// streams are dropped on the `codec_type` field, which is cheap.
    static func trackInfo(_ url: URL) throws -> (tracks: [AudioTrack], chapters: Int) {
        let json = try run([
            "-v", "error",
            "-show_streams", "-show_chapters", "-of", "json", url.path,
        ])
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return ([], 0)
        }
        let streams = root["streams"] as? [[String: Any]] ?? []

        let tracks: [AudioTrack] = streams.compactMap { stream in
            guard stream["codec_type"] as? String == "audio",
                  let index = stream["index"] as? Int,
                  let codec = stream["codec_name"] as? String else { return nil }
            // ffprobe reports numeric stream fields as strings when they come from
            // the container rather than the decoder, so both forms are accepted —
            // invariant 29, learned the expensive way on `nb_frames`.
            let disposition = stream["disposition"] as? [String: Any]
            return AudioTrack(
                index: index,
                codec: codec,
                profile: stream["profile"] as? String,
                channels: intValue(stream["channels"]),
                channelLayout: stream["channel_layout"] as? String,
                sampleRate: intValue(stream["sample_rate"]),
                bitRate: intValue(stream["bit_rate"]),
                isDefault: intValue(disposition?["default"]) == 1)
        }
        let chapters = (root["chapters"] as? [[String: Any]])?.count ?? 0
        return (tracks, chapters)
    }

    /// An ffprobe field that may be a JSON number or a numeric string.
    ///
    /// Both happen, for the same field, depending on whether the value came from the
    /// container or from the decoder — `nb_frames` was silently nil for every file
    /// because only the number form was accepted (invariant 29).
    static func intValue(_ any: Any?) -> Int? {
        (any as? Int) ?? (any as? String).flatMap(Int.init)
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
        //
        // **ffprobe emits this as a string**, not a number: `"nb_frames": "28"`. It is
        // a string because it is also allowed to be `"N/A"`. An `as? Int` cast therefore
        // yields `nil` for every file that *does* state a count — which is worse than
        // useless, because everything downstream that guards on the count then passes
        // vacuously. Measured: the batch converter's read-back check never once compared
        // a container's frame count against what was written. Both forms are accepted.
        let frameCount = (stream["nb_frames"] as? Int)
            ?? (stream["nb_frames"] as? String).flatMap(Int.init)

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
            audioTracks: [], chapterCount: 0)
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
