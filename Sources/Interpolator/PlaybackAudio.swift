import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

// MARK: - What the controller needs from the sound

/// The sound, as far as playback is concerned.
///
/// ## Why the sound is the clock
///
/// A compressed audio stream cannot be retimed. Slowing it down or speeding it up without a
/// re-encode is impossible, and a re-encode is a second of work per second of film — so the
/// sound plays at its own rate and **the picture follows it**, not the other way round. That
/// is what every player does, and it is why `mediaTime` here is not a convenience accessor
/// but the definition of where the film is.
///
/// A protocol rather than `PlaybackAudio` directly, so that the clock arithmetic can be
/// tested against a fake that moves by hand. The arithmetic is the part that is silently
/// wrong when it is wrong: a clock that loses a frame's worth of time per pause is a film
/// that is a second out by the end of the reel, and nothing about it looks broken.
public protocol AudioTransport: AnyObject, Sendable {
    /// Where the sound is, in **film** seconds.
    var mediaTime: Double { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    /// Move the sound. Must be **synchronous**: the caller re-anchors a clock against
    /// `mediaTime` immediately afterwards, and an asynchronous seek would leave that anchor
    /// pointing at the old position — which reads as a playhead that jumps by the distance
    /// seeked, every time.
    func seek(to seconds: Double)
    func setSpeed(_ speed: Double)
}

// MARK: - The plan

/// How a source's audio is made playable, and why.
///
/// ## The problem this exists for
///
/// **AVFoundation cannot open Matroska.** The film is an MKV, so its audio cannot simply be
/// handed to `AVPlayer`. Something has to produce a file AVFoundation *can* open, and there
/// are three ways to do it, with costs that differ by a factor of a thousand:
///
/// | | measured on the real disc | lossless |
/// | --- | --- | --- |
/// | `direct` — open the source where it is | instant | yes |
/// | `remux` — copy the track into MP4 | **1.94 s** for the whole film | yes |
/// | `transcode` — re-encode to AAC | **4.5 s per 120 s** ≈ 3.6 min | no |
///
/// The measurement that makes this worth doing properly is on **the disc's second audio
/// track**. `The Fast and the Furious` (2001) UHD carries DTS-HD MA + DTS:X 7.1 as its
/// default and an **AC-3 5.1 compatibility track** that is not the default. `ac3` is in
/// ``MediaInfo/audioPassThroughCodecs`` — macOS opens AC-3 in MP4, which the batch
/// converter's own policy documents — so the sound is a **bit-for-bit copy of a real track
/// on the disc**, prepared in two seconds, with no re-encode anywhere.
///
/// Choosing the non-default track is not a liberty: the AC-3 is the disc's own compatibility
/// mix of the same master, put there by the studio for exactly this reason. What it is *not*
/// is what the batch converter would keep — that copies the DTS-HD MA bit for bit into MKV —
/// so the player says which track it is using rather than deciding quietly.
public enum AudioPlaybackPlan: Sendable, Equatable, CustomStringConvertible {

    /// The source states no audio at all.
    case none

    /// Open the source itself. Only when the container is one AVFoundation reads.
    case direct(track: Int, codec: String)

    /// Copy the track into MP4. Lossless, and fast enough to do while the user waits.
    case remux(track: Int, codec: String)

    /// Re-encode to AAC. The only route for a codec macOS will not decode — DTS-HD MA,
    /// TrueHD, and the rest of what a BluRay actually ships with.
    case transcode(track: Int, codec: String, bitRate: Int, channels: Int)

    /// The ffmpeg stream index of the track, **global** rather than audio-relative.
    ///
    /// `AudioTrack.index` is the stream's index in the whole file — 1 and 2 on the real disc,
    /// not 0 and 1. Mapping with `0:<index>` is unambiguous; mapping with `0:a:<n>` requires
    /// counting the audio streams and hoping nothing else was miscounted, which is one more
    /// place for an off-by-one to hide.
    public var track: Int? {
        switch self {
        case .none: nil
        case .direct(let track, _), .remux(let track, _): track
        case .transcode(let track, _, _, _): track
        }
    }

    public var codec: String? {
        switch self {
        case .none: nil
        case .direct(_, let codec), .remux(_, let codec): codec
        case .transcode(_, let codec, _, _): codec
        }
    }

    /// Whether the sound the user hears is the sound on the disc.
    public var isLossless: Bool {
        switch self {
        case .direct, .remux: true
        case .none, .transcode: false
        }
    }

    /// Whether anything has to be written to disk before playback can start.
    public var needsPreparation: Bool {
        switch self {
        case .direct, .none: false
        case .remux, .transcode: true
        }
    }

    public var description: String {
        switch self {
        case .none:
            "no audio"
        case .direct(let track, let codec):
            "\(codec) track \(track), played in place"
        case .remux(let track, let codec):
            "\(codec) track \(track), copied without re-encoding"
        case .transcode(let track, let codec, let bitRate, let channels):
            "\(codec) track \(track), re-encoded to AAC \(channels)ch at "
                + "\(bitRate / 1000) kbps"
        }
    }

    /// Containers AVFoundation opens by itself.
    ///
    /// Matroska is the one that matters and is absent on purpose: it is the format every
    /// disc rip arrives in, and `AVURLAsset` refuses it. `flac` is here because AVFoundation
    /// has read FLAC files since Big Sur — but a FLAC track *inside Matroska* still cannot be
    /// opened, which is why this set is consulted together with the container rather than
    /// instead of it.
    public static let playableContainers: Set<String> =
        ["mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "caf", "aif", "aiff", "flac"]

    public static func containerIsPlayable(_ url: URL) -> Bool {
        playableContainers.contains(url.pathExtension.lowercased())
    }

    /// Choose a track and a route.
    ///
    /// The order of preference is the whole decision:
    ///
    /// 1. a track macOS can decode **and** which the disc marks as default;
    /// 2. failing that, any track macOS can decode — a copy of the studio's own compatibility
    ///    mix beats a re-encode of the master;
    /// 3. failing that, the default track, re-encoded;
    /// 4. failing that, the first track, re-encoded.
    ///
    /// Rule 2 is the one that earns its keep on a real disc, and rule 3 is the one that keeps
    /// a DTS-only disc playable instead of silent.
    public static func choose(for info: MediaInfo, containerIsPlayable: Bool) -> AudioPlaybackPlan {
        let tracks = info.audioTracks
        guard !tracks.isEmpty else { return .none }
        let decodable = tracks.filter { MediaInfo.audioPassThroughCodecs.contains($0.codec) }
        let chosen = decodable.first(where: \.isDefault)
            ?? decodable.first
            ?? tracks.first(where: \.isDefault)
            ?? tracks[0]

        guard MediaInfo.audioPassThroughCodecs.contains(chosen.codec) else {
            // Not decodable at all, so the only route is a re-encode. AAC tops out at 7.1, so
            // anything wider — an Atmos bed reported as 12 channels, say — has to be brought
            // down; leaving it alone would hand the encoder a layout it cannot describe and
            // the failure would arrive as a silently truncated track.
            let channels = min(8, max(1, chosen.channels ?? 2))
            return .transcode(track: chosen.index, codec: chosen.codec,
                              bitRate: AudioMuxPolicy.defaultBitRate(channels: channels),
                              channels: channels)
        }
        return containerIsPlayable
            ? .direct(track: chosen.index, codec: chosen.codec)
            : .remux(track: chosen.index, codec: chosen.codec)
    }

    /// The ffmpeg arguments that produce a playable file, given the plan.
    ///
    /// `-map 0:<index>` and not `-map 0:a:<n>`: the index is the global stream number the
    /// probe reported, so there is nothing to count.
    ///
    /// **`-map_chapters -1` is not optional.** ffmpeg carries a Matroska's chapters into MP4
    /// as a `bin_data` track, and that track is as long as the *whole film* — so a file
    /// holding two minutes of sound reports a duration of 5811 seconds, and `AVAsset.duration`
    /// believes it. Measured: without this flag, a 120 s extraction from the real disc opened
    /// as 5811.447 s. Every seek and every end-of-track check would have been computed against
    /// the wrong length.
    public func arguments(input: URL, output: URL) -> [String] {
        guard let track else { return [] }
        var arguments = ["-hide_banner", "-nostdin", "-v", "error", "-y",
                         "-i", input.path,
                         "-map", "0:\(track)",
                         "-vn", "-sn", "-dn",
                         "-map_chapters", "-1"]
        switch self {
        case .none, .direct:
            return []
        case .remux:
            arguments += ["-c:a", "copy"]
        case .transcode(_, _, let bitRate, let channels):
            arguments += ["-c:a", "aac", "-b:a", "\(bitRate)"]
            // Only constrain the layout when the source has more channels than AAC can carry;
            // a 5.1 or 7.1 master is passed through at its own width rather than flattened.
            if channels <= 8 {
                arguments += ["-ac", "\(channels)"]
            }
        }
        arguments += ["-f", "mp4", "-progress", "pipe:1", output.path]
        return arguments
    }
}

// MARK: - The cache

/// Where a prepared soundtrack lives between runs.
///
/// Preparing the real disc costs **1.94 s** and 307 MB, which is cheap once and wasteful
/// every time — a player is opened, closed and reopened constantly, and a two-second stall
/// on every open is the difference between an app and a toy. So the file is kept, keyed by
/// everything that would change it: the source's identity, its size and modification date,
/// and the track and codec that were chosen.
///
/// The key includes the **modification date** deliberately. A file that has been replaced by
/// a different cut of the same name is a different film, and a cache that matched on name
/// alone would play the old one's sound against the new one's picture — in sync for the first
/// reel and drifting after that, which is the worst possible way for it to be wrong.
public struct AudioCache: Sendable {

    public let directory: URL
    /// The most the cache may hold before the least recently used entries are dropped.
    public let limit: Int64

    public static let `default` = AudioCache(
        directory: FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("60FPS/audio"),
        limit: 6 * 1024 * 1024 * 1024)

    public init(directory: URL, limit: Int64) {
        self.directory = directory
        self.limit = limit
    }

    /// Everything about a source that would change the file the cache holds.
    public struct Key: Sendable, Equatable, CustomStringConvertible {
        public let source: String
        public let bytes: Int64
        public let modified: Double
        public let track: Int
        public let codec: String

        public init(source: URL, track: Int, codec: String) {
            self.source = source.standardizedFileURL.path
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: source.path)
            self.bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            self.modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            self.track = track
            self.codec = codec
        }

        public var description: String {
            "\(source) [\(bytes) bytes, \(Int(modified))] track \(track) (\(codec))"
        }

        /// A stable file name.
        ///
        /// A digest rather than `hashValue`, which Swift seeds **randomly per process** — a
        /// per-process hash would give every launch a different file name, so the cache would
        /// never hit while filling the disk with copies of the same soundtrack. That is the
        /// whole reason this is not two lines shorter.
        ///
        /// The human-readable stem is kept in front of the digest because a cache directory
        /// full of 64-character hex names is a directory nobody can debug.
        public var fileName: String {
            let digest = AudioCache.digest(description)
            let stem = URL(fileURLWithPath: source).deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .prefix(48)
            return "\(stem)-t\(track)-\(digest).mp4"
        }
    }

    public func url(for key: Key) -> URL {
        directory.appendingPathComponent(key.fileName)
    }

    /// A cached file that is present and non-empty.
    ///
    /// Emptiness matters: a process killed mid-write leaves a zero-length file, and a cache
    /// that trusted the name would hand `AVPlayer` a file with no sound in it and report the
    /// film as silent.
    public func existing(for key: Key) -> URL? {
        let url = url(for: key)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber, size.int64Value > 0 else { return nil }
        // Touch it, so the eviction order reflects use rather than creation.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    public func store(_ data: Data, for key: Key) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: key), options: .atomic)
    }

    /// What the cache holds, and what it would cost to keep.
    public func contents() -> [(url: URL, bytes: Int64, modified: Date)] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]),
                let size = values.fileSize,
                let modified = values.contentModificationDate else { return nil }
            return (url, Int64(size), modified)
        }
    }

    /// Drop least-recently-used entries until the cache fits.
    ///
    /// Run after a successful preparation rather than before, so the file just written is
    /// never the one evicted — which would be a cache that spent two seconds preparing
    /// something and then immediately deleted it.
    @discardableResult
    public func trim(keeping keep: URL? = nil) -> Int {
        var entries = contents()
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return 0 }
        entries.sort { $0.modified < $1.modified }
        var removed = 0
        for entry in entries {
            guard total > limit else { break }
            if let keep, entry.url == keep { continue }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.bytes
            removed += 1
        }
        return removed
    }

    @discardableResult
    public func clear() -> Int {
        let entries = contents()
        var removed = 0
        for entry in entries where (try? FileManager.default.removeItem(at: entry.url)) != nil {
            removed += 1
        }
        return removed
    }

    /// Sixteen hex characters of SHA-256, for the file name.
    ///
    /// `SHA256` and not `Hasher`: see ``Key/fileName``. Sixteen characters of a cryptographic
    /// digest is 64 bits, which is far more than a cache of a few hundred films needs — and
    /// unlike `Hasher` it is the same in every process, which is the property being bought.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - The extractor

/// One child process to run, and where to send what it says.
///
/// A struct rather than three closure parameters, because a function type nested inside
/// another function type cannot be marked `@escaping` — and the reporter genuinely escapes:
/// it is called from the queue draining the child's output, long after the call that supplied
/// it has returned. A stored property is escaping by definition, so the type system stops
/// arguing about it.
public struct AudioSpawn: Sendable {
    public let arguments: [String]
    /// Each line of the child's **standard output**, as it arrives.
    public let onLine: @Sendable (String) -> Void
    public let isCancelled: @Sendable () -> Bool

    public init(arguments: [String],
                onLine: @escaping @Sendable (String) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) {
        self.arguments = arguments
        self.onLine = onLine
        self.isCancelled = isCancelled
    }
}

/// Produces a file AVFoundation can open, and reports how far along it is.
public struct AudioExtractor: Sendable {

    /// The child process runner.
    ///
    /// `onLine` receives each line of the child's **standard output**, which is where
    /// `-progress pipe:1` puts its key=value report. A seam because the interesting parts of
    /// this type — the cache decision, the progress arithmetic, what happens when the job is
    /// cancelled halfway — are all reachable without ffmpeg, and a test that needed a real
    /// two-minute transcode to check a percentage would not be run.
    public var spawn: @Sendable (AudioSpawn) throws -> String

    public var ffmpegPath: @Sendable () -> String

    public init() {
        self.spawn = { try AudioExtractor.runStreaming($0) }
        self.ffmpegPath = { MediaProbe.ffmpegPath }
    }

    public init(spawn: @escaping @Sendable (AudioSpawn) throws -> String,
                ffmpegPath: @escaping @Sendable () -> String = { MediaProbe.ffmpegPath }) {
        self.spawn = spawn
        self.ffmpegPath = ffmpegPath
    }

    public enum Failure: Error, CustomStringConvertible {
        case cancelled
        case noAudio
        case conversionFailed(String)
        case nothingWritten(String)

        public var description: String {
            switch self {
            case .cancelled: "preparing the audio was cancelled"
            case .noAudio: "the film has no audio track"
            case .conversionFailed(let detail):
                "could not prepare the audio: \(detail)"
            case .nothingWritten(let detail):
                "the audio was prepared but the file is empty: \(detail)"
            }
        }
    }

    /// What was produced.
    public struct Outcome: Sendable {
        public let plan: AudioPlaybackPlan
        /// The file to hand `AVPlayer`.
        public let url: URL
        /// True when it was already there and nothing was run.
        public let fromCache: Bool
        public let bytes: Int64
        public let wallSeconds: Double

        public var isClean: Bool { bytes > 0 }
    }

    /// Prepare a playable soundtrack, using the cache when it can.
    ///
    /// - Parameters:
    ///   - url: the film.
    ///   - info: its probe, for the track list.
    ///   - cache: where prepared soundtracks are kept.
    ///   - force: ignore a cached file and prepare again.
    ///   - progress: 0...1 while the conversion runs. `nil` for the fast paths, which are
    ///     over before a bar could be drawn.
    ///   - isCancelled: polled while the child runs.
    public func prepare(from url: URL,
                        info: MediaInfo,
                        cache: AudioCache = .default,
                        force: Bool = false,
                        progress: (@Sendable (Double) -> Void)? = nil,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Outcome {
        let started = DispatchTime.now().uptimeNanoseconds
        let plan = AudioPlaybackPlan.choose(
            for: info, containerIsPlayable: AudioPlaybackPlan.containerIsPlayable(url))

        switch plan {
        case .none:
            throw Failure.noAudio

        case .direct:
            // Nothing to do. The film itself is playable, so the cache is not involved at all
            // — and creating an empty cache directory for a file nobody needed would be a
            // side effect on the user's disk from merely opening a film.
            return Outcome(plan: plan, url: url, fromCache: true, bytes: 0,
                           wallSeconds: 0)

        case .remux, .transcode:
            break
        }

        let key = AudioCache.Key(source: url, track: plan.track ?? 0,
                                 codec: plan.codec ?? "")
        if !force, let hit = cache.existing(for: key) {
            let size = (try? FileManager.default.attributesOfItem(atPath: hit.path))?[.size]
            return Outcome(plan: plan, url: hit, fromCache: true,
                           bytes: (size as? NSNumber)?.int64Value ?? 0,
                           wallSeconds: Double(DispatchTime.now().uptimeNanoseconds
                                               - started) / 1e9)
        }

        try FileManager.default.createDirectory(at: cache.directory,
                                                withIntermediateDirectories: true)
        let destination = cache.url(for: key)
        // The child writes here directly. A partial file from a cancelled run must not be
        // mistaken for a finished one, so it is written to a sibling and renamed only once
        // ffmpeg has exited cleanly — the same discipline the batch converter's staging file
        // exists for, for the same reason.
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        let arguments = [ffmpegPath()] + plan.arguments(input: url, output: partial)
        // The total is the film's own length, so the bar is a real fraction rather than a
        // guess. `AVAsset.duration` is not consulted: the file being prepared is the source,
        // which AVFoundation cannot open — that is the entire reason this type exists.
        let total = max(0.001, info.duration)
        let report: @Sendable (String) -> Void = { line in
            guard let progress, let seconds = AudioExtractor.progressSeconds(from: line) else {
                return
            }
            progress(min(1, max(0, seconds / total)))
        }

        do {
            _ = try spawn(AudioSpawn(arguments: arguments, onLine: report,
                                     isCancelled: isCancelled))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if isCancelled() {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.cancelled
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size]
        let bytes = (size as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.nothingWritten(partial.lastPathComponent)
        }

        // Invariant: `FileManager.moveItem` refuses an existing destination. Checking here
        // rather than catching the throw keeps the failure specific — "something is already
        // at the destination" and "the move failed" are different problems and only one of
        // them is worth retrying.
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        cache.trim(keeping: destination)

        return Outcome(plan: plan, url: destination, fromCache: false, bytes: bytes,
                       wallSeconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
    }

    /// The seconds ffmpeg says it has written, from one `-progress pipe:1` line.
    ///
    /// `out_time_us` is microseconds since the start of the output. `out_time_ms` also exists
    /// and is **not** milliseconds — it is microseconds too, despite the name, which is the
    /// kind of thing that makes a progress bar finish a thousand times too early. `out_time`
    /// is a `HH:MM:SS.microseconds` string, which is what the fallback parses.
    ///
    /// Lines that are not the time are ignored rather than treated as zero: the report is
    /// interleaved with `frame=`, `bitrate=`, `speed=` and a `progress=continue`/`end`
    /// terminator, and a parser that reset on an unknown key would make the bar flicker back
    /// to the start several times a second.
    public static func progressSeconds(from line: String) -> Double? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch parts[0] {
        case "out_time_us":
            return Double(value).map { $0 / 1_000_000 }
        case "out_time":
            let fields = value.split(separator: ":")
            guard fields.count == 3,
                  let hours = Double(fields[0]),
                  let minutes = Double(fields[1]),
                  let seconds = Double(fields[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
    }

    /// Runs a child, handing each line of its output to `onLine`.
    ///
    /// Both pipes are drained concurrently: an undrained 64 KB pipe blocks the writer, which
    /// stalls ffmpeg and, through it, the wait — the same trap `AudioMuxer.runProcess`
    /// documents, and it is a deadlock rather than a slowdown when it happens.
    static func runStreaming(_ request: AudioSpawn) throws -> String {
        let arguments = request.arguments
        guard let executable = arguments.first else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let errorText = LineBox()
        let onLine = request.onLine
        let isCancelled = request.isCancelled
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errorText.store(text: String(data: data, encoding: .utf8) ?? "")
        }
        DispatchQueue.global().async(group: group) {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                onLine(String(line))
            }
        }

        do {
            try process.run()
        } catch {
            throw Failure.conversionFailed("\(error)")
        }

        // Polled rather than waited on, because there has to be a way out: a transcode of a
        // DTS-only disc takes minutes, and a player whose preparation cannot be cancelled is a
        // player that holds the user hostage to a mistake they made by opening the wrong file.
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        group.wait()

        if isCancelled() {
            throw Failure.cancelled
        }
        guard process.terminationStatus == 0 else {
            let detail = errorText.value.isEmpty
                ? "ffmpeg exited \(process.terminationStatus) with no message"
                : errorText.value.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.conversionFailed(detail)
        }
        return errorText.value
    }
}

/// A lock-protected box for a string, so a concurrently-executing closure is not capturing a
/// `var`.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func store(text value: String) { lock.lock(); text = value; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

// MARK: - The player

/// The sound, played by AVFoundation, as the film's clock.
///
/// Thin on purpose. Everything that decides anything lives in ``AudioPlaybackPlan`` (what to
/// produce) and ``AudioExtractor`` (how), both of which are testable without a sound device;
/// what is left here is an `AVPlayer` and the four operations a transport needs.
///
/// ## Why `AVPlayer` and not `AVAudioPlayer`
///
/// `AVAudioPlayer` is the obvious choice for a file, and it is the wrong one for a film: it
/// decodes ahead into memory and is documented for short sounds, while a feature film's
/// soundtrack is 300 MB of AC-3 and two hours long. `AVPlayer` streams from disk, is what the
/// system itself uses for long media, and — the part that matters here — reports its position
/// on the **audio hardware's** clock rather than on a timer.
///
/// ## The main run loop has to keep turning
///
/// **Invariant 37 — AVFoundation delivers its readiness and playback callbacks to the main
/// queue, so a main thread that blocks starves the very events that make an item ready.**
/// Measured: a poll loop that slept with `usleep` on the main thread left the item at
/// `.unknown` for three seconds with `rate` reading 1.0 and `currentTime` pinned at 0.000 —
/// the sound never started, and as a clock it would have held the picture at its first frame
/// for ever. Turning the main run loop instead gave `.readyToPlay` and a position advancing
/// at **1.002×**.
///
/// A SwiftUI app does this for free. Anything driving this from a command-line tool must use
/// `RunLoop.main.run(until:)` rather than a sleep, which is why `interp-harness --sound`
/// does.
public final class PlaybackAudio: AudioTransport, @unchecked Sendable {

    public let plan: AudioPlaybackPlan
    public let url: URL
    public let track: AudioTrack?

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let lock = NSLock()
    private var speed: Double = 1
    private var muted = false

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case noAudioTrack(String)

        public var description: String {
            switch self {
            case .unreadable(let detail): "could not open the soundtrack: \(detail)"
            case .noAudioTrack(let detail): "the soundtrack holds no audio: \(detail)"
            }
        }
    }

    /// Open a prepared soundtrack.
    ///
    /// Asynchronous, because `AVPlayerItem`'s tracks have to be loaded before the item will
    /// report a duration — and a player whose duration is not known yet reports a current
    /// time of zero, which as a clock means the picture would sit at the first frame while the
    /// sound played. Waiting for the load is what stops that.
    public init(url: URL, plan: AudioPlaybackPlan, track: AudioTrack? = nil) async throws {
        self.url = url
        self.plan = plan
        self.track = track
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw Failure.noAudioTrack(url.lastPathComponent)
        }
        let item = AVPlayerItem(asset: asset)
        // The sound is played at its own rate when the user asks for 1.25x, and pitch
        // correction is the difference between a fast film and a comedy.
        item.audioTimePitchAlgorithm = .spectral
        self.item = item
        self.player = AVPlayer(playerItem: item)
        self.player.actionAtItemEnd = .pause
    }

    // MARK: - AudioTransport

    /// Where the sound is, in film seconds.
    ///
    /// A non-finite value is reported as zero rather than passed on: an item that has not been
    /// given a duration yet returns `kCMTimeIndefinite`, and an indefinite clock would make
    /// the pacer drop every frame it holds — a black screen, produced by a defensive
    /// calculation rather than by anything the film did.
    public var mediaTime: Double {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? max(0, seconds) : 0
    }

    public var isPlaying: Bool {
        player.rate != 0
    }

    public func play() {
        lock.lock()
        let rate = Float(speed)
        lock.unlock()
        player.rate = rate
    }

    public func pause() {
        player.rate = 0
    }

    /// Move the sound, and **do not return until it has arrived**.
    ///
    /// ## Three things measured about `AVPlayer.seek`
    ///
    /// 1. **`currentTime` is stale the instant `seek` returns.** Measured: a seek to 60.0 read
    ///    back `0.807` — the old position — at 0 ms, and `60.000` after one run-loop turn.
    /// 2. **The completion handler is not a way to wait for it.** With the main thread blocked
    ///    on a semaphore, the handler never arrived at all: measured, a 3 s wait timed out while
    ///    `currentTime` had *already* moved to 62.892. AVFoundation delivers that callback to
    ///    the main queue, so blocking the main thread to wait for it is waiting for a thread
    ///    that is the one doing the waiting.
    /// 3. **One turn of the run loop is enough.** Measured over five seeks: 1 spin each,
    ///    2.2–46.8 ms, landing on the target to the millisecond every time.
    ///
    /// So the wait is a bounded spin of the **current** run loop, and it has to be, because
    /// the caller re-anchors a clock against ``mediaTime`` on the very next line. A stale
    /// anchor is not a small error: seeking from 0.8 s to 60 s and anchoring against the old
    /// reading makes the playhead read `60 + (60 − 0.8)` = 119.2 s the moment the seek lands,
    /// and every frame the presenter then holds is superseded — a black screen, produced by
    /// arithmetic.
    ///
    /// - Important: call this from the **main thread**. The run loop being spun has to be the
    ///   one AVFoundation feeds, and that is the main one. From a background thread the spin
    ///   would burn its whole deadline and leave the anchor stale; the deadline exists so that
    ///   costs 500 ms rather than hanging, not so that it is acceptable.
    public func seek(to seconds: Double) {
        let target = max(0, seconds)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        let deadline = Date().addingTimeInterval(0.5)
        // 20 ms is under one frame at 59.94 and well under the presenter's one-second lead,
        // so a landing within it cannot show. 2 ms slices keep the cost of a normal landing
        // — one slice — at 2 ms.
        while abs(mediaTime - target) > 0.02, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
    }

    public func setSpeed(_ newSpeed: Double) {
        lock.lock()
        speed = max(0.25, min(4, newSpeed))
        let rate = Float(speed)
        let playing = player.rate != 0
        lock.unlock()
        if playing { player.rate = rate }
    }

    public var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(max(0, min(1, newValue))) }
    }

    public var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    public var seconds: Double {
        let value = CMTimeGetSeconds(item.duration)
        return value.isFinite ? max(0, value) : 0
    }

    /// The clock this sound should drive.
    ///
    /// The rate is left at 1 and the *sound's* rate carries the playback speed. Putting the
    /// speed in both would double it: the clock multiplies the elapsed host time by its own
    /// rate, and the host time here is already media time — so a 2x sound would advance the
    /// film at 4x.
    public var timeSource: PlaybackClock.TimeSource {
        { [unowned self] in self.mediaTime }
    }

    public func shutdown() {
        player.rate = 0
        player.replaceCurrentItem(with: nil)
    }
}
