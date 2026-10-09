import Foundation

/// Joins the rendered segments into one picture, without re-encoding it.
///
/// ## Why this is ffmpeg's job and not ours
///
/// The segments are complete, independently encoded MP4s. Concatenating them means
/// rewriting a container — index, timestamps, track headers — around bitstreams that are
/// already correct. That is exactly what ffmpeg's concat demuxer does with `-c copy`, and it
/// is what every other tool in this space does too. Writing it here would mean owning a
/// second MP4 muxer, and the first one (`AVAssetWriter`) already earns its keep.
///
/// ## The one thing that had to be measured rather than assumed
///
/// Whether a join reproduces the film. It is not obvious: each segment was encoded on its
/// own, each has its own edit list and its own timestamps, and the concat demuxer offsets
/// each by the previous one's duration. A frame lost or duplicated at every boundary would
/// be a stutter on a schedule, and it would survive every check that only counted frames.
///
/// Measured on the reference film: two segments of four intervals each, joined, against one
/// render of the same eight intervals. **All twenty decoded frames hash identically.** Not
/// "the same count" — the same pictures. That is what makes the whole segmented design
/// safe, and it is why the check below is a frame count *and* a rate rather than a size.
public struct SegmentJoiner: Sendable {

    /// What the join produced, and what was wrong with it.
    public struct Outcome: Sendable {
        public let bytes: Int64
        /// Frames the finished file states, when it states one.
        public let frames: Int?
        public let rate: String?
        public let problems: [String]

        public var isClean: Bool { problems.isEmpty }

        public var summary: String {
            let count = frames.map { "\($0) frames" } ?? "an unstated frame count"
            return "joined \(count)\(rate.map { " at \($0)" } ?? "")"
        }
    }

    // MARK: - Seams

    public var runFFmpeg: @Sendable ([String]) throws -> String
    /// Frame count and rate from the finished file, read from its index rather than by
    /// decoding it.
    public var probeVideo: @Sendable (URL) throws -> (frames: Int?, rate: String?)
    public var ffmpegPath: @Sendable () -> String

    public init() {
        self.runFFmpeg = { try AudioMuxer.runProcess($0) }
        self.probeVideo = { try SegmentJoiner.probeVideo(at: $0) }
        self.ffmpegPath = { MediaProbe.ffmpegPath }
    }

    public init(runFFmpeg: @escaping @Sendable ([String]) throws -> String,
                probeVideo: @escaping @Sendable (URL) throws -> (frames: Int?, rate: String?),
                ffmpegPath: @escaping @Sendable () -> String = { MediaProbe.ffmpegPath }) {
        self.runFFmpeg = runFFmpeg
        self.probeVideo = probeVideo
        self.ffmpegPath = ffmpegPath
    }

    // MARK: - The list

    /// The concat list ffmpeg reads.
    ///
    /// File names rather than paths, because ffmpeg resolves them against the list's own
    /// directory — so the list lives in the job directory beside the segments and the whole
    /// job stays movable.
    ///
    /// The single quote is the only character the format gives meaning to, and it is
    /// escaped by closing the quote, emitting an escaped one, and reopening: `'\''`. Our own
    /// names are `%04d.mp4` and never contain one, but the escape is here because the day
    /// someone changes the naming is not the day to discover this.
    public func listContents(files: [String]) -> String {
        files.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'\n" }
            .joined()
    }

    public func arguments(listPath: URL, output: URL) -> [String] {
        ["-hide_banner", "-v", "error", "-nostdin",
         "-f", "concat", "-safe", "0", "-i", listPath.path,
         // The picture is already encoded. Joining it is a container operation and nothing
         // else — a second generation of loss here would undo the whole point.
         "-c", "copy",
         // So the joined file can be read while it is being written, the same reason the
         // muxer asks for it.
         "-movflags", "+faststart",
         "-y", output.path]
    }

    // MARK: - Join

    /// Concatenate `files` into `output`, and check what came out.
    ///
    /// `expectedFrames` is the plan's own count. The join is only allowed to agree with it:
    /// a join that produces fewer frames has lost a boundary, and one that produces more has
    /// duplicated one, and neither would show up as an error from ffmpeg.
    @discardableResult
    public func join(files: [URL], output: URL,
                     expectedFrames: Int?, expectedRate: FrameRate?) throws -> Outcome {
        guard !files.isEmpty else {
            throw SegmentJoinError.nothingToJoin
        }
        let executable = ffmpegPath()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SegmentJoinError.ffmpegMissing
        }

        // The list lives beside the segments so ffmpeg's relative resolution finds them.
        let list = output.deletingLastPathComponent().appendingPathComponent("concat.txt")
        try listContents(files: files.map(\.lastPathComponent))
            .write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }

        try? FileManager.default.removeItem(at: output)
        _ = try runFFmpeg([executable] + arguments(listPath: list, output: output))

        let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size]
        let bytes = (size as? NSNumber)?.int64Value ?? 0

        var problems: [String] = []
        var frames: Int?
        var rate: String?
        do {
            let read = try probeVideo(output)
            frames = read.frames
            rate = read.rate
            if let expected = expectedFrames, let got = read.frames, got != expected {
                problems.append("the join produced \(got) frames where the plan says "
                                + "\(expected); a boundary was lost or duplicated")
            }
            if let expected = expectedRate, let got = read.rate, got != "\(expected)" {
                problems.append("the join produced \(got) where the plan says \(expected)")
            }
        } catch {
            problems.append("could not read the joined file back: \(error)")
        }

        return Outcome(bytes: bytes, frames: frames, rate: rate, problems: problems)
    }

    // MARK: - Reading the result

    /// Frame count and rate, from the container's index.
    ///
    /// `nb_frames` and not `nb_read_frames`: the latter counts by decoding, which on a
    /// two-hour 4K film is a second pass over the whole picture to answer a question the
    /// index already knows. Both are strings when they come from the container, so both are
    /// parsed as strings — invariant 29, which has now cost this project three separate
    /// afternoons.
    public static func probeVideo(at url: URL) throws
        -> (frames: Int?, rate: String?) {
        let json = try MediaProbe.run([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=nb_frames,avg_frame_rate",
            "-of", "json", url.path,
        ])
        return try parseVideo(json)
    }

    /// The parse, split out so it can be tested against what ffprobe really emits rather
    /// than against a process that has to exist.
    static func parseVideo(_ data: Data) throws -> (frames: Int?, rate: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (root["streams"] as? [[String: Any]])?.first else {
            throw MediaProbeError.unreadableOutput("no video stream")
        }
        func text(_ key: String) -> String? {
            guard let value = stream[key] as? String, value != "N/A" else { return nil }
            return value
        }
        return (frames: text("nb_frames").flatMap(Int.init), rate: text("avg_frame_rate"))
    }
}

public enum SegmentJoinError: Error, CustomStringConvertible {
    case nothingToJoin
    case ffmpegMissing

    public var description: String {
        switch self {
        case .nothingToJoin:
            return "there are no segments to join"
        case .ffmpegMissing:
            return "ffmpeg is not on PATH, so the segments cannot be joined"
        }
    }
}
