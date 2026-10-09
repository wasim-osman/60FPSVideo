import Foundation

/// Everything the mux needs, in one value.
///
/// A value rather than nine parameters, because the seam that lets a test drive the
/// whole converter without ffmpeg has to be a single closure — and a nine-argument
/// closure is somewhere to put two arguments in the wrong order and never find out,
/// since every one of them is a number or a path.
public struct MuxRequest: Sendable {

    /// The finished picture, video only. Written by `AssetWriterSink`.
    public let video: URL
    /// The original film, which still has its audio.
    public let source: URL
    /// Where the muxed file goes. Not the final destination — the converter renames it.
    public let output: URL
    public let plan: AudioMuxPolicy.Plan

    /// Where the audio must begin, **already snapped to the frame grid** by
    /// ``AudioMuxer/alignedStart(_:rate:)``. `nil` starts it at the beginning.
    public let audioStart: Double?
    /// How long the picture is, from the frame count and the rate rather than read back
    /// from a container that has not been finalised.
    public let videoSeconds: Double
    /// Whether to cut the audio to the picture. True for a partial render.
    public let boundAudio: Bool
    /// How far the audio may sit from the picture before it counts as a fault.
    /// One source frame, which is the granularity the alignment works to.
    public let frameTolerance: Double
    /// Chapter marks in the source, so a drop can be noticed.
    public let sourceChapters: Int

    public init(video: URL, source: URL, output: URL,
                plan: AudioMuxPolicy.Plan, audioStart: Double?,
                videoSeconds: Double, boundAudio: Bool,
                frameTolerance: Double, sourceChapters: Int = 0) {
        self.video = video
        self.source = source
        self.output = output
        self.plan = plan
        self.audioStart = audioStart
        self.videoSeconds = videoSeconds
        self.boundAudio = boundAudio
        self.frameTolerance = frameTolerance
        self.sourceChapters = sourceChapters
    }
}

/// Puts the audio back into the video, and checks that it arrived.
///
/// ## Why ffmpeg muxes rather than AVFoundation
///
/// The same split the rest of the project uses: **ffmpeg owns containers, VideoToolbox
/// owns the encode.** `AVAssetWriter` writes a video-only file — it can hold audio, but
/// getting a DTS-HD MA track through it means decoding to PCM and re-encoding, which is
/// the one thing this app must not do to a soundtrack. ffmpeg takes the finished video,
/// takes the original file's audio stream, and either copies it byte for byte or
/// transcodes it, with no re-encode of the picture at all (`-c:v copy`).
///
/// ## The three things a mux silently gets wrong
///
/// 1. **The audio does not arrive.** `-map` is a filter, not a default: get the stream
///    index wrong and ffmpeg writes a file with picture and no sound, exits 0, and
///    nothing downstream notices. The output is re-probed and a missing audio stream is
///    an error rather than a note.
/// 2. **The audio is offset from the picture.** The video was rendered from a `-ss`
///    seek, and the audio has to be seeked to the *same content time* — but not to the
///    same *number*. `-ss` discards decoded frames until the requested instant, so the
///    picture begins at the first source frame at or after the request, up to a whole
///    frame later. Seeking the audio to the raw request puts it early by that much on
///    every converted film. ``alignedStart(_:rate:)`` snaps it to the frame grid, and
///    the two streams' start times in the finished file are compared to prove it.
/// 3. **The audio is the wrong length.** A partial render — a segment, or a test run —
///    must not produce a file whose audio runs on for two hours past the last picture.
public struct AudioMuxer: Sendable {

    // MARK: - What the output turned out to be

    /// Stream timings, read back from the finished container.
    ///
    /// Seconds and `nil`-able, because ffprobe omits `duration` on some containers and
    /// a zero would read as a real, catastrophic value.
    public struct Streams: Sendable, Equatable {
        /// Whether the container has an audio stream *at all*. Deliberately separate
        /// from ``audioSeconds``: Matroska does not state a per-stream duration, so
        /// treating an absent duration as an absent stream reports "the audio was lost"
        /// about a file that has the audio right there. That is invariant 29's mistake
        /// — an absent value read as a real one — and it is what this cost to learn.
        public let hasAudio: Bool
        public let videoSeconds: Double?
        public let audioSeconds: Double?
        public let videoStart: Double?
        public let audioStart: Double?
        /// Chapter marks the container states. Zero is a legitimate answer; a *drop*
        /// against the source is not.
        public let chapters: Int

        public init(hasAudio: Bool,
                    videoSeconds: Double?, audioSeconds: Double?,
                    videoStart: Double?, audioStart: Double?,
                    chapters: Int = 0) {
            self.hasAudio = hasAudio
            self.videoSeconds = videoSeconds
            self.audioSeconds = audioSeconds
            self.videoStart = videoStart
            self.audioStart = audioStart
            self.chapters = chapters
        }

        /// How far the audio sits from the picture, in seconds. `nil` when either
        /// start time is absent — which is not the same as zero.
        public var offset: Double? {
            guard let videoStart, let audioStart else { return nil }
            return audioStart - videoStart
        }

        public var description: String {
            func show(_ value: Double?) -> String {
                value.map { String(format: "%.4f", $0) } ?? "-"
            }
            // `not stated` rather than `-`: Matroska omits the per-stream duration
            // entirely, and a dash reads like a zero.
            let audio = audioSeconds.map { String(format: "%.4f s", $0) } ?? "not stated"
            return "video \(show(videoSeconds)) s from \(show(videoStart)), "
                + "audio \(audio) from \(show(audioStart))"
        }
    }

    // MARK: - Result

    public struct Outcome: Sendable {
        public let plan: AudioMuxPolicy.Plan
        public let bytes: Int64
        public let streams: Streams?
        /// Everything that was wrong. An empty list is the only clean run.
        public let problems: [String]
        /// How much the audio input was actually offset, to cancel the picture's rebase.
        /// Zero is the ordinary case: the app's own picture starts at zero, and MP4 never
        /// needs the correction because it carries the edit list itself. Kept rather than
        /// discarded so a conversion that needed it can say so, and one that did not
        /// cannot claim it did. See ``arguments(for:videoStartOffset:)``.
        public let audioOffset: Double

        public init(plan: AudioMuxPolicy.Plan, bytes: Int64, streams: Streams?,
                    problems: [String], audioOffset: Double = 0) {
            self.plan = plan
            self.bytes = bytes
            self.streams = streams
            self.problems = problems
            self.audioOffset = audioOffset
        }

        public var isClean: Bool { problems.isEmpty }

        /// What actually happened, in the terms the user cares about.
        public var summary: String {
            switch plan.action {
            case .none:
                return "none (\(plan.reason))"
            case .copy(_, let codec, let channels):
                return "copied bit-perfect — \(codec.uppercased()) \(channels ?? 0) ch"
            case .transcode(_, let from, let to, let channels, let bitRate):
                return "transcoded \(from.uppercased()) -> \(to.uppercased()) "
                    + "\(channels) ch @ \(bitRate / 1000) kbps"
            }
        }

        /// The offset the read-back found, for the report.
        public var offset: Double? { streams?.offset }
    }

    // MARK: - Seams

    /// Runs ffmpeg and returns its combined diagnostics. Throws on a non-zero exit.
    public var runFFmpeg: @Sendable ([String]) throws -> String
    /// Reads the finished container's stream timings.
    public var probeStreams: @Sendable (URL) throws -> Streams
    /// The video input's earliest raw timestamp. Below zero when the encoder reordered
    /// its frames and the source container cancelled the delay with an edit list —
    /// which is exactly the case that has to be compensated for. See
    /// ``arguments(for:videoStartOffset:)``.
    public var videoMinPTS: @Sendable (URL) throws -> Double
    /// Where ffmpeg is. Resolved the same way the decoder resolves it.
    public var ffmpegPath: @Sendable () -> String

    public init() {
        self.runFFmpeg = { arguments in try AudioMuxer.runProcess(arguments) }
        self.probeStreams = { try AudioMuxer.probeStreams(at: $0) }
        self.videoMinPTS = { try AudioMuxer.probeMinPTS(at: $0) }
        self.ffmpegPath = { MediaProbe.ffmpegPath }
    }

    public init(runFFmpeg: @escaping @Sendable ([String]) throws -> String,
                probeStreams: @escaping @Sendable (URL) throws -> Streams,
                videoMinPTS: @escaping @Sendable (URL) throws -> Double
                    = { try AudioMuxer.probeMinPTS(at: $0) },
                ffmpegPath: @escaping @Sendable () -> String = { MediaProbe.ffmpegPath }) {
        self.runFFmpeg = runFFmpeg
        self.probeStreams = probeStreams
        self.videoMinPTS = videoMinPTS
        self.ffmpegPath = ffmpegPath
    }

    // MARK: - The frame grid

    /// How much to offset the audio input, given the picture's earliest raw timestamp.
    ///
    /// The single home of the rule, because two places deciding it is how a report comes
    /// to disagree with the command it describes: the harness once announced a correction
    /// on an MP4 mux that the argument list had deliberately skipped.
    ///
    /// Zero when there is nothing to cancel, and zero for MP4 — which carries the edit
    /// list through, so nothing is rebased and the same offset would push the audio *early*
    /// by exactly that much. Measured: the audio went to 0.000 where it should have stayed
    /// at 0.003.
    public static func audioOffset(for container: AudioMuxPolicy.Container,
                                   videoStartOffset: Double) -> Double {
        guard container == .mkv, videoStartOffset < 0 else { return 0 }
        return videoStartOffset
    }

    /// The first source frame at or after `seconds`.
    ///
    /// This is where the *picture* starts, not where the request was. `-ss` before an
    /// input decodes from the preceding keyframe and discards frames until the target
    /// time, so the first frame emitted is the first whose timestamp is **at or after**
    /// the request. At 23.976 the gap is up to 41.7 ms, which is small enough to look
    /// like nothing and is present on every converted film.
    public static func alignedStart(_ seconds: Double, rate: FrameRate) -> Double {
        guard seconds > 0 else { return 0 }
        let frames = (seconds * Double(rate.numerator) / Double(rate.denominator))
            .rounded(.up)
        return frames * Double(rate.denominator) / Double(rate.numerator)
    }

    // MARK: - The command

    /// The ffmpeg arguments, built where they can be read and tested.
    ///
    /// `-c:v copy` is not negotiable: the picture was just encoded once and re-encoding
    /// it here would be a second generation of loss for no reason.
    ///
    /// `videoStartOffset` is the video input's earliest raw timestamp, and it is the one
    /// number that has to be known before the command can be written. See the comment
    /// inside for why it is passed rather than probed here.
    public func arguments(for request: MuxRequest,
                          videoStartOffset: Double = 0) -> [String] {
        var arguments = ["-hide_banner", "-v", "error", "-nostdin",
                         "-i", request.video.path]

        // When the picture's earliest *raw* timestamp is below zero, the encoder reordered
        // its frames and the source container cancelled the delay with an edit list — the
        // picture presents from zero while its packets start earlier. Matroska cannot
        // carry an edit list, so ffmpeg rebases **every** stream by `-min(raw PTS)` to
        // lift the picture to zero, and takes the audio with it: the sound ends up a whole
        // reorder delay late, which on a 6-frame HEVC encode is 250 ms. Measured on the
        // reference film, the audio landed at 0.253 s against a picture at 0.000.
        //
        // Offsetting the audio input by the same amount makes ffmpeg's rebase land it back
        // where it belongs: the audio's raw start drops to `0.003 - 0.250`, the picture's
        // `-0.250` is still the minimum, the rebase is still `+0.250`, and the audio comes
        // out at 0.003 — where the edit list said it was.
        let offset = AudioMuxer.audioOffset(for: request.plan.container,
                                            videoStartOffset: videoStartOffset)
        if offset < 0 {
            arguments += ["-itsoffset", String(format: "%.6f", offset)]
        }

        // `-ss` is an input option: it applies to the input that follows it, so the
        // video — which is already the right piece of the film — is not seeked and the
        // audio is.
        if let audioStart = request.audioStart, audioStart > 0 {
            arguments += ["-ss", String(format: "%.6f", audioStart)]
        }
        arguments += ["-i", request.source.path]

        arguments += ["-map", "0:v:0"]
        if let track = request.plan.action.trackIndex {
            arguments += ["-map", "1:\(track)"]
        }
        arguments += ["-c:v", "copy"]

        switch request.plan.action {
        case .none:
            break
        case .copy:
            arguments += ["-c:a", "copy"]
        case .transcode(_, _, let to, let channels, let bitRate):
            arguments += ["-c:a", to, "-ac", "\(channels)", "-b:a", "\(bitRate)"]
        }

        // An output option, so it caps the file rather than the input. Only applied
        // when the render is deliberately partial: a full conversion's audio may
        // legitimately outlast the last frame of picture, and cutting it would be
        // wrong.
        if request.boundAudio {
            arguments += ["-t", String(format: "%.6f", request.videoSeconds)]
        }
        if request.plan.container == .mp4 {
            // The moov atom at the front, so the file can be played while it is still
            // being copied rather than only after it has been read to the end.
            arguments += ["-movflags", "+faststart"]
        }
        arguments += ["-y", request.output.path]
        return arguments
    }

    // MARK: - Run

    /// Mux the chosen audio stream into the video.
    public func mux(_ request: MuxRequest) throws -> Outcome {
        guard request.plan.action != .none else {
            // The caller is expected to skip the mux entirely in this case; reaching
            // here means it forgot, and a silent no-op would hide that.
            throw AudioMuxError.ffmpegFailed(
                status: -1, message: "nothing to mux: the plan has no audio action")
        }

        let executable = ffmpegPath()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AudioMuxError.ffmpegMissing
        }

        // Probed before the command is written, because it changes the command. It costs a
        // header read and a few packets, not a pass over the film. A probe that fails is
        // not a reason to refuse the mux: the offset check below still guards the result,
        // and a missing correction is reported rather than hidden.
        let videoStartOffset = (try? videoMinPTS(request.video)) ?? 0
        // What was actually applied, which is not the same as what was probed — the
        // container decides. Kept separate so the report cannot overstate the work.
        let audioOffset = AudioMuxer.audioOffset(for: request.plan.container,
                                                 videoStartOffset: videoStartOffset)
        let arguments = [executable] + arguments(for: request,
                                                 videoStartOffset: videoStartOffset)
        try? FileManager.default.removeItem(at: request.output)
        _ = try runFFmpeg(arguments)

        let size = (try? FileManager.default
            .attributesOfItem(atPath: request.output.path))?[.size]
        let bytes = (size as? NSNumber)?.int64Value ?? 0

        // Read the finished file back. `ffmpeg` exiting 0 says the *command* worked;
        // it does not say the audio is in there, that it starts where the picture
        // does, or that it runs the right length.
        var streams: Streams?
        var problems: [String] = []
        do {
            let read = try probeStreams(request.output)
            streams = read

            if !read.hasAudio {
                throw AudioMuxError.audioMissingFromOutput(request.output.lastPathComponent)
            }
            if let offset = read.offset, abs(offset) > request.frameTolerance {
                var message = String(format:
                    "the audio starts %.1f ms away from the picture, "
                    + "which is more than one frame (%.1f ms)",
                    offset * 1000, request.frameTolerance * 1000)
                if audioOffset < 0 {
                    // Say the correction was attempted, so the number is not mistaken for
                    // the uncorrected one.
                    message += String(format:
                        " — and that is after offsetting the audio by %.1f ms to cancel "
                        + "the picture's rebase", -audioOffset * 1000)
                }
                problems.append(message)
            }
            // A duration the container did not state is a check that could not be made.
            // Matroska never states a per-stream duration, so treating that as a defect
            // would put a "problem" on every MKV conversion and train the reader to
            // ignore the list — which is worse than the gap. It is shown in the stream
            // line instead, where it is information rather than an accusation.
            if let audio = read.audioSeconds, audio + 0.5 < request.videoSeconds {
                problems.append(String(format:
                    "the audio runs %.2f s short of the picture (%.2f s against %.2f s)",
                    request.videoSeconds - audio, audio, request.videoSeconds))
            }
            if request.boundAudio, let audio = read.audioSeconds,
               audio > request.videoSeconds + 1.0 {
                problems.append(String(format:
                    "the audio was to stop at %.2f s but runs to %.2f s",
                    request.videoSeconds, audio))
            }
            // Chapters ride along on ffmpeg's own initiative — they are not mapped, so
            // nothing asks for them and nothing would notice them going. A partial
            // render legitimately keeps only the marks inside its window, so the check
            // is only meaningful when the whole film was rendered.
            if !request.boundAudio, request.sourceChapters > 0,
               read.chapters < request.sourceChapters {
                problems.append("the source has \(request.sourceChapters) chapter marks "
                                + "but the output has \(read.chapters); chapters were dropped")
            }
        } catch let error as AudioMuxError {
            throw error
        } catch {
            problems.append("could not read the muxed file back: \(error)")
        }

        return Outcome(plan: request.plan, bytes: bytes, streams: streams,
                       problems: problems, audioOffset: audioOffset)
    }

    // MARK: - Defaults

    /// A string one thread writes and another reads, with the lock that makes it legal.
    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func store(_ value: String) {
            lock.lock(); text = value; lock.unlock()
        }

        var value: String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
    }

    /// Runs a process to completion and returns its stderr.
    static func runProcess(_ arguments: [String]) throws -> String {
        guard let executable = arguments.first else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AudioMuxError.ffmpegFailed(status: -1, message: "\(error)")
        }
        // Both pipes are drained concurrently: an undrained 64 KB pipe blocks the
        // writer, which deadlocks ffmpeg and, through it, the job.
        //
        // The text lives in a lock-protected box rather than a captured `var`, because
        // a `var` captured by a concurrently-executing closure is a data race the
        // compiler can see — and in a build that is otherwise warning-free, a warning
        // here is the one signal that something is genuinely wrong.
        let box = TextBox()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            _ = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            box.store(String(data: data, encoding: .utf8) ?? "")
        }
        group.wait()
        process.waitUntilExit()
        let errorText = box.value
        guard process.terminationStatus == 0 else {
            throw AudioMuxError.ffmpegFailed(status: process.terminationStatus,
                                            message: errorText.isEmpty
                                                ? "no message" : errorText)
        }
        return errorText
    }

    /// Stream timings from ffprobe.
    ///
    /// `-show_entries` is given once with both sections; passing it twice makes the
    /// second call override the first and silently drops half the answer.
    public static func probeStreams(at url: URL) throws -> Streams {
        let json = try MediaProbe.run([
            "-v", "error",
            "-show_entries", "stream=codec_type,start_time,duration:format=duration",
            "-show_chapters",
            "-of", "json", url.path,
        ])
        return try parseStreams(json)
    }

    /// The parse, split out so it can be tested against the shapes ffprobe really
    /// emits rather than against a process that has to exist.
    static func parseStreams(_ data: Data) throws -> Streams {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw MediaProbeError.unreadableOutput("no streams")
        }

        func number(_ any: Any?) -> Double? {
            // ffprobe emits these as strings when they come from the container, and
            // `"N/A"` when it does not know. Both are handled rather than assumed —
            // invariant 29 is exactly this mistake.
            if let value = any as? Double { return value }
            if let text = any as? String { return Double(text) }
            return nil
        }

        let formatDuration = number(
            (root["format"] as? [String: Any])?["duration"])

        func first(_ type: String) -> [String: Any]? {
            streams.first { $0["codec_type"] as? String == type }
        }
        let video = first("video")
        let audio = first("audio")

        return Streams(
            hasAudio: audio != nil,
            videoSeconds: number(video?["duration"]) ?? formatDuration,
            audioSeconds: number(audio?["duration"]),
            videoStart: number(video?["start_time"]),
            audioStart: number(audio?["start_time"]),
            chapters: (root["chapters"] as? [[String: Any]])?.count ?? 0)
    }

    // MARK: - The picture's earliest raw timestamp

    /// How many packets to scan for the video's earliest timestamp.
    ///
    /// A reordered encoder emits its frames out of presentation order, so the earliest
    /// timestamp is *not* in the first packet — it is somewhere inside the reorder window.
    /// HEVC's decoded-picture buffer holds at most 16 frames, so 32 packets cover any real
    /// encoder with room to spare, and reading 32 packets of a two-hour film costs one
    /// seek rather than a pass.
    static let reorderWindow = 32

    /// The video input's earliest raw timestamp, over the reorder window.
    ///
    /// Only the *raw* packet times matter here, not the presentation times. An MP4 whose
    /// picture presents from zero may still have packets starting at `-0.250`, because the
    /// container carried the difference as an edit list — and the edit list is precisely
    /// what Matroska cannot express, and precisely what ffmpeg rebases away. Reading
    /// `start_time` instead would report the presentation start, which is zero in exactly
    /// the case that needs the correction.
    public static func probeMinPTS(at url: URL) throws -> Double {
        let text = try MediaProbe.run([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "packet=pts_time",
            "-read_intervals", "%+#\(reorderWindow)",
            "-of", "csv=p=0",
            url.path,
        ])
        return parseMinPTS(text)
    }

    /// The lowest timestamp in a list of packet times, or zero when none is below zero.
    ///
    /// Starting from zero and taking the minimum gives the value its meaning directly: the
    /// amount the picture's packets start *below* zero. A stream that starts at or after
    /// zero returns zero, which is "no correction", and a stream that cannot be read at all
    /// also returns zero — the same answer, because there is nothing to correct for.
    ///
    /// `N/A` is what ffprobe writes when it cannot place a packet, and it must not be read
    /// as a zero: a zero is a real, aligned value, and inventing one would silently disable
    /// the correction. `Double("N/A")` is nil, so the line is skipped.
    static func parseMinPTS(_ data: Data) -> Double {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        var lowest = 0.0
        for line in text.split(separator: "\n") {
            guard let value = Double(line.trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            lowest = min(lowest, value)
        }
        return lowest
    }
}
