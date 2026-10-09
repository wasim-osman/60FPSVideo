import Foundation

/// An output stage that can say how many frames it actually placed.
///
/// ``FrameSink`` deliberately does not require this: a playback sink has no count to
/// report, and inventing one would be a lie. The batch converter does need it, because
/// the one thing it must never do is hand back a file that is quietly short — and a
/// short file is a *valid* file, so nothing downstream would ever complain.
public protocol FrameCountingSink: FrameSink {
    var written: Int { get }
}

/// One film, start to finish: probe it, interpolate it, encode it.
///
/// This is assembly rather than mechanism. All three stages already exist and are
/// tested — `FFmpegFrameSource` reads, `InterpolationPipeline` interpolates,
/// `AssetWriterSink` writes — and what is left is the part that is easy to get wrong
/// precisely *because* it looks trivial: deciding the output rate, naming the file,
/// and refusing to hand back a result that is not what it claims to be.
///
/// ## The two things it exists to prevent
///
/// **A plausible file that is wrong.** `AVAssetWriter` finalises a short file happily.
/// If the sink drops a frame — and it has a deadline that can expire — the result is a
/// valid MP4 that is simply missing pictures, and every check that only asks "did it
/// succeed?" answers yes. This is invariant 18 one layer up, and the answer is the same
/// one: count what landed and compare it against what was supposed to.
///
/// **A failed job that leaves something behind.** The write goes to a sibling
/// temporary path and is renamed into place only after the count agrees. A job that
/// throws leaves no output at all, rather than a truncated file the user might keep.
///
/// ## Testability
///
/// The three stages are injected. The defaults are the real ones — ffprobe, ffmpeg, an
/// `AVAssetWriter` — but a test can drive the whole converter with a synthetic source
/// and a packed-file sink, which is how the ordering, the count check and the cleanup
/// are covered without a display, a GPU or a real film.
public struct BatchConverter: Sendable {

    // MARK: - Request

    /// What to convert, and how.
    public struct Request: Sendable {
        public var input: URL
        public var output: URL

        /// The rate policy. A value rather than a rate, so the batch converter and the
        /// player cannot pick different cadences for the same film.
        public var policy: OutputRatePolicy

        /// `nil` asks `VideoEncodeSettings` for its measured default.
        public var bitRate: Int?

        /// Requests kept in flight. 2 is the minimum that works (invariant 3).
        public var depth: Int
        public var sceneDetection: Bool

        /// Stop after this many source frames. `nil` for the whole film.
        public var maximumSourceFrames: Int?
        /// Seek here first. Input seeking, so it lands on a keyframe.
        public var startSeconds: Double?

        /// Replace an existing output. Off by default: silently overwriting a film is
        /// not something a converter should do on its own initiative.
        public var overwrite: Bool

        /// Convert even when the source is already at the target rate.
        ///
        /// The normal answer is to refuse — see ``Failure/alreadyAtTarget(_:)``. Set
        /// this when the *container* is the point (normalising metadata, say) and the
        /// extra generation of quality loss is accepted.
        public var convertWhenAlreadyAtTarget: Bool

        public init(input: URL,
                    output: URL,
                    policy: OutputRatePolicy = .default,
                    bitRate: Int? = nil,
                    depth: Int = 2,
                    sceneDetection: Bool = true,
                    maximumSourceFrames: Int? = nil,
                    startSeconds: Double? = nil,
                    overwrite: Bool = false,
                    convertWhenAlreadyAtTarget: Bool = false) {
            self.input = input
            self.output = output
            self.policy = policy
            self.bitRate = bitRate
            self.depth = depth
            self.sceneDetection = sceneDetection
            self.maximumSourceFrames = maximumSourceFrames
            self.startSeconds = startSeconds
            self.overwrite = overwrite
            self.convertWhenAlreadyAtTarget = convertWhenAlreadyAtTarget
        }
    }

    // MARK: - Result

    /// What the job did — including what it got wrong.
    public struct Result: Sendable {
        public let output: URL
        /// What the input turned out to be. The mux step needs this: the audio codec
        /// decides whether the copy is bit-perfect or a transcode.
        public let source: MediaInfo
        /// The rate decision, including the note when the policy could not act.
        public let resolution: OutputRatePolicy.Resolution
        public let report: InterpolationPipeline.Report
        /// Frames the sink actually placed. Equals `report.outputFrames` or the run
        /// would have thrown.
        public let written: Int
        public let bytes: Int64
        public let wallSeconds: Double
        /// Pipeline failures and sink failures together, plus anything the read-back
        /// check found. An empty list is the only definition of a clean run.
        public let problems: [String]

        public var isClean: Bool { problems.isEmpty }
        public var cutCount: Int { report.cutCount }
        public var outputFrames: Int { report.outputFrames }

        /// The duration the written frames represent, derived from the rate rather
        /// than read back from a container that may not have been finalised.
        public var outputSeconds: Double {
            resolution.output.doubleValue > 0
                ? Double(written) / resolution.output.doubleValue : 0
        }

        /// Delivered bit rate. The target is not the delivered rate — the encoder
        /// undershoots on dark content by nearly a third — so this is the number
        /// worth reporting.
        public var megabitsPerSecond: Double {
            outputSeconds > 0 ? Double(bytes) * 8 / outputSeconds / 1e6 : 0
        }

        /// Delivered bits per pixel per frame, the form that compares across
        /// resolutions and rates.
        public var bitsPerPixelPerFrame: Double {
            let pixels = Double(source.width * source.height)
            guard pixels > 0, written > 0 else { return 0 }
            return Double(bytes) * 8 / (pixels * Double(written))
        }

        /// The fraction of output frames that cost no inference at all.
        public var passthroughFraction: Double {
            outputFrames > 0 ? Double(report.passthroughFrames) / Double(outputFrames) : 0
        }
    }

    // MARK: - Failure

    public enum Failure: Error, CustomStringConvertible {
        /// The destination exists and `overwrite` was not set.
        case outputExists(String)
        /// The source is already at the target rate, so there is nothing to convert.
        case alreadyAtTarget(String)
        /// The sink placed fewer frames than the pipeline produced.
        case shortOutput(expected: Int, written: Int)

        public var description: String {
            switch self {
            case .outputExists(let path):
                return "\(path) already exists; pass overwrite to replace it"
            case .alreadyAtTarget(let detail):
                return detail
            case .shortOutput(let expected, let written):
                return "the pipeline produced \(expected) frames but the sink placed "
                    + "\(written); the output would be silently short"
            }
        }
    }

    // MARK: - Seams

    public var probe: @Sendable (URL) throws -> MediaInfo
    public var makeSource: @Sendable (URL, MediaInfo, Double?, Int?) throws -> FrameSource
    public var makeSink: @Sendable (URL, VideoEncodeSettings) throws -> FrameCountingSink

    /// The interpolation engine, from the rates and the depth.
    ///
    /// The shipping answer is `VTFrameProcessor` and nothing else — the RIFE tier was
    /// measured and dropped. This is a seam for the *test*, not a quality tier: it lets
    /// a test drive the converter's ordering, its count check and its cleanup without
    /// a GPU, which is where the bugs that matter here actually live.
    public var makeEngine: @Sendable (FrameRate, FrameRate, Int) throws -> InterpolationEngine

    /// The shipping configuration: ffprobe, ffmpeg, `VTFrameProcessor`, and an
    /// `AVAssetWriter`.
    public init() {
        self.probe = { try MediaProbe.probe($0) }
        self.makeSource = { url, info, start, limit in
            try FFmpegFrameSource(url: url, info: info,
                                  startSeconds: start, frameLimit: limit)
        }
        self.makeSink = { url, settings in
            AssetWriterSink(url: url, settings: settings)
        }
        self.makeEngine = { source, output, depth in
            VTFrameProcessorEngine(source: source, output: output, depth: depth)
        }
    }

    public init(probe: @escaping @Sendable (URL) throws -> MediaInfo,
                makeSource: @escaping @Sendable (URL, MediaInfo, Double?, Int?) throws -> FrameSource,
                makeSink: @escaping @Sendable (URL, VideoEncodeSettings) throws -> FrameCountingSink,
                makeEngine: @escaping @Sendable (FrameRate, FrameRate, Int) throws -> InterpolationEngine) {
        self.probe = probe
        self.makeSource = makeSource
        self.makeSink = makeSink
        self.makeEngine = makeEngine
    }

    // MARK: - Run

    public func run(_ request: Request) throws -> Result {
        let info = try probe(request.input)
        let resolution = request.policy.resolve(source: info.frameRate)

        // A source already at the target rate is not a conversion. Re-encoding it would
        // spend a generation of quality and change nothing about the cadence.
        if resolution.isPassthrough && !request.convertWhenAlreadyAtTarget {
            throw Failure.alreadyAtTarget(
                "\(request.input.lastPathComponent) is already \(resolution.output)"
                    + (resolution.note.map { " — \($0)" } ?? "")
                    + "; set convertWhenAlreadyAtTarget to re-encode it anyway")
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: request.output.path), !request.overwrite {
            throw Failure.outputExists(request.output.path)
        }

        // Beside the destination, so the final move is a rename inside one volume — and
        // so that a crashed job leaves something obviously unfinished. It also keeps
        // `AssetWriterSink.begin`, which deletes its own output path, away from the
        // user's file.
        let temporary = Self.temporaryURL(beside: request.output)
        try? manager.removeItem(at: temporary)

        var placed = false
        defer { if !placed { try? manager.removeItem(at: temporary) } }

        let settings = VideoEncodeSettings.forSource(info, bitRate: request.bitRate)
        let sink = try makeSink(temporary, settings)
        let source = try makeSource(request.input, info,
                                    request.startSeconds, request.maximumSourceFrames)
        let engine = try makeEngine(info.frameRate, resolution.output, request.depth)

        let pipeline = InterpolationPipeline(
            source: source,
            sourceRate: info.frameRate,
            outputRate: resolution.output,
            engine: engine,
            configuration: .init(depth: request.depth,
                                 sceneDetection: request.sceneDetection,
                                 maximumSourceFrames: request.maximumSourceFrames,
                                 expectedOutputFrameCount: Self.expectedOutputFrames(
                                    request: request, info: info, resolution: resolution)))

        // The pipeline calls `sink.finish()` itself, at the end of `run`.
        let report = try pipeline.run(into: sink)
        let written = sink.written

        guard written == report.outputFrames else {
            throw Failure.shortOutput(expected: report.outputFrames, written: written)
        }

        // `moveItem` refuses an existing destination, so a replacement has to be
        // explicit — without this, `overwrite` would run the whole film and then throw
        // at the last step, which is the most expensive possible way to fail. Removing
        // first leaves a window where neither file exists; that is the safe direction,
        // because a crash there loses the old output and leaves an obvious `.partial-`
        // file rather than producing something half of each.
        if request.overwrite, manager.fileExists(atPath: request.output.path) {
            try manager.removeItem(at: request.output)
        }
        try manager.moveItem(at: temporary, to: request.output)
        placed = true

        let size = (try? manager.attributesOfItem(atPath: request.output.path))?[.size]
        let bytes = (size as? NSNumber)?.int64Value ?? 0

        var problems = report.problems + sink.problems

        // Read the finished file back, rather than trusting the objects that wrote it.
        // The in-process count proves frames were *placed*; only the container proves
        // they were indexed and finalised, which is a different failure.
        do {
            let check = try probe(request.output)
            if let frames = check.frameCount, frames != written {
                problems.append("the container reports \(frames) frames, "
                                + "\(written) were written")
            }
        } catch {
            problems.append("could not re-probe the output: \(error)")
        }

        return Result(output: request.output,
                      source: info,
                      resolution: resolution,
                      report: report,
                      written: written,
                      bytes: bytes,
                      wallSeconds: report.wallSeconds,
                      problems: problems)
    }

    // MARK: - Helpers

    /// The exact output length, when the source states its own.
    ///
    /// Only when it does: Matroska reports `nb_frames=N/A`, and this value is a hint a
    /// sink may size a file from, so it has to be either right or absent. A guessed
    /// count is worse than no count.
    static func expectedOutputFrames(request: Request,
                                     info: MediaInfo,
                                     resolution: OutputRatePolicy.Resolution) -> Int? {
        guard let total = info.frameCount else { return nil }
        let usable = min(total, request.maximumSourceFrames ?? total)
        // One source frame makes no interval, so there is nothing to state.
        guard usable >= 2 else { return nil }
        return PhasePlan(sourceFrameCount: usable,
                         source: info.frameRate,
                         output: resolution.output)?.outputFrameCount
    }

    /// A sibling of the destination that cannot be mistaken for a finished file.
    ///
    /// The extension is kept because it is what the container is; the `partial` marker
    /// is what says the job did not get there.
    static func temporaryURL(beside output: URL) -> URL {
        let stem = output.deletingPathExtension().lastPathComponent
        let ext = output.pathExtension.isEmpty ? "mp4" : output.pathExtension
        let unique = String(UUID().uuidString.prefix(8)).lowercased()
        return output.deletingLastPathComponent()
            .appendingPathComponent("\(stem).partial-\(unique).\(ext)")
    }
}
