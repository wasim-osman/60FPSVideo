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

        /// How to bring the audio across.
        ///
        /// `nil` derives one from the output's extension — `.mkv` gets a bit-perfect
        /// copy of the disc's own track, anything else gets the MP4 policy. Naming one
        /// explicitly is how you ask for the other, or for the audio to be dropped.
        public var audio: AudioMuxPolicy?

        /// Render the film in pieces of about this many seconds. `nil` renders it in
        /// one go.
        ///
        /// This is not for speed — segments cost a little, in the frame decoded twice
        /// at every boundary and in the join at the end. It is so that a crash, a power
        /// cut or a quit costs one piece rather than three hours, and so the job can be
        /// stopped and picked up again.
        ///
        /// The pieces are recorded in a manifest beside the output, so a second run
        /// skips what is already finished. See ``JobManifest``.
        public var segmentSeconds: Double?

        /// Throw away the record of a previous run and render everything again.
        ///
        /// The normal answer to a manifest that disagrees with this request is to
        /// refuse — see ``Failure/manifestMismatch(_:)`` — because joining half of one
        /// job to half of another produces a file that plays and is wrong.
        public var restart: Bool

        /// Keep the finished segments and the manifest after a successful join.
        ///
        /// Off by default: the segments are a second copy of the whole film, and once
        /// it has been delivered there is nothing left to resume.
        public var keepSegments: Bool

        public init(input: URL,
                    output: URL,
                    policy: OutputRatePolicy = .default,
                    bitRate: Int? = nil,
                    depth: Int = 2,
                    sceneDetection: Bool = true,
                    maximumSourceFrames: Int? = nil,
                    startSeconds: Double? = nil,
                    overwrite: Bool = false,
                    convertWhenAlreadyAtTarget: Bool = false,
                    audio: AudioMuxPolicy? = nil,
                    segmentSeconds: Double? = nil,
                    restart: Bool = false,
                    keepSegments: Bool = false) {
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
            self.audio = audio
            self.segmentSeconds = segmentSeconds
            self.restart = restart
            self.keepSegments = keepSegments
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
        /// What happened to the audio. `nil` when there was nothing to mux.
        public let audio: AudioMuxer.Outcome?
        /// The audio policy that was actually applied — the request's, or the one the
        /// output's extension implied.
        public let audioPolicy: AudioMuxPolicy
        /// What the segments did. `nil` when the film was rendered in one go.
        public let segments: SegmentOutcome?

        public var isClean: Bool { problems.isEmpty && (segments?.problems.isEmpty ?? true) }
        public var cutCount: Int { report.cutCount }
        public var outputFrames: Int { report.outputFrames }

        /// The container the file ended up in.
        public var container: AudioMuxPolicy.Container { audioPolicy.container }

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
        /// There is a manifest beside the output, but it describes a different job.
        case manifestMismatch(String)

        public var description: String {
            switch self {
            case .outputExists(let path):
                return "\(path) already exists; pass overwrite to replace it"
            case .alreadyAtTarget(let detail):
                return detail
            case .shortOutput(let expected, let written):
                return "the pipeline produced \(expected) frames but the sink placed "
                    + "\(written); the output would be silently short"
            case .manifestMismatch(let detail):
                return "the finished segments beside the output are from a different job — "
                    + "\(detail); pass restart to discard them and render everything again"
            }
        }
    }

    // MARK: - Segments

    /// What a segmented job did.
    public struct SegmentOutcome: Sendable {
        public let plan: SegmentPlan
        public let entries: [JobManifest.Entry]
        /// Segments that were already finished and were skipped.
        public let resumed: Set<Int>
        public let joined: SegmentJoiner.Outcome?
        public let problems: [String]

        /// Output frames the finished segments actually hold.
        public var outputFrames: Int { entries.reduce(0) { $0 + $1.frames } }
        /// Whether every segment the plan calls for was rendered.
        public var isComplete: Bool { entries.count == plan.segments.count }

        public var summary: String {
            let rendered = entries.count - resumed.count
            return "\(entries.count)/\(plan.segments.count) segments "
                + "(\(rendered) rendered, \(resumed.count) resumed), "
                + "\(outputFrames) output frames"
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

    /// The audio stage. Injectable so a test can drive the whole converter — ordering,
    /// count check, cleanup, and the decision to mux or not — without ffmpeg.
    ///
    /// A closure rather than an `AudioMuxer` value, so a test can read the *request* the
    /// converter built. Asserting on the plan the converter decided is the point; going
    /// through ffmpeg's argument list to infer it back is not.
    public var mux: @Sendable (MuxRequest) throws -> AudioMuxer.Outcome

    /// The join, for a segmented job.
    ///
    /// A factory rather than a value, because `SegmentJoiner` carries its own seams and a
    /// test wants to replace them — the joiner's checks are `SegmentJoinerTests`' subject,
    /// and this file is about whether the converter renders the right pieces in the right
    /// order and writes down what it did.
    public var makeJoiner: @Sendable () -> SegmentJoiner

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
        self.mux = { try AudioMuxer().mux($0) }
        self.makeJoiner = { SegmentJoiner() }
    }

    public init(probe: @escaping @Sendable (URL) throws -> MediaInfo,
                makeSource: @escaping @Sendable (URL, MediaInfo, Double?, Int?) throws -> FrameSource,
                makeSink: @escaping @Sendable (URL, VideoEncodeSettings) throws -> FrameCountingSink,
                makeEngine: @escaping @Sendable (FrameRate, FrameRate, Int) throws -> InterpolationEngine,
                mux: @escaping @Sendable (MuxRequest) throws -> AudioMuxer.Outcome = {
                    try AudioMuxer().mux($0)
                },
                makeJoiner: @escaping @Sendable () -> SegmentJoiner = { SegmentJoiner() }) {
        self.probe = probe
        self.makeSource = makeSource
        self.makeSink = makeSink
        self.makeEngine = makeEngine
        self.mux = mux
        self.makeJoiner = makeJoiner
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

        // The audio decision is made *before* any work happens, so a request that
        // cannot be honoured — "copy the DTS into MP4" — fails in a second rather than
        // after a two-hour render.
        let audioPolicy = request.audio ?? AudioMuxPolicy.forOutput(request.output)
        // Whether this render cuts the audio at a point that is not the start of the
        // stream. It changes what is possible: a compressed stream can only be cut at a
        // packet boundary, so a cut means a re-encode.
        let cutting = (request.startSeconds ?? 0) > 0 || request.maximumSourceFrames != nil
        let audioPlan = try audioPolicy.plan(for: info, cutting: cutting)

        // Both paths converge on the mux, so the decision of which one to take is the
        // first thing here and the last thing either of them knows about.
        if let seconds = request.segmentSeconds, seconds > 0,
           let plan = Self.segmentPlan(request: request, info: info,
                                       resolution: resolution, segmentSeconds: seconds) {
            return try runSegmented(request, info: info, resolution: resolution,
                                    audioPolicy: audioPolicy, audioPlan: audioPlan,
                                    plan: plan)
        }
        return try runWhole(request, info: info, resolution: resolution,
                            audioPolicy: audioPolicy, audioPlan: audioPlan)
    }

    /// One film, one render.
    private func runWhole(_ request: Request,
                          info: MediaInfo,
                          resolution: OutputRatePolicy.Resolution,
                          audioPolicy: AudioMuxPolicy,
                          audioPlan: AudioMuxPolicy.Plan) throws -> Result {
        let manager = FileManager.default

        // Beside the destination, so the final move is a rename inside one volume — and
        // so that a crashed job leaves something obviously unfinished. It also keeps
        // `AssetWriterSink.begin`, which deletes its own output path, away from the
        // user's file.
        //
        // Two intermediates now, because the audio stage sits between them: the video
        // is written to `staging`, muxed into `temporary`, and only `temporary` is ever
        // renamed into place. `staging` is always `.mp4` — that is what `AVAssetWriter`
        // writes, and ffmpeg's demuxer picks its reader from the extension.
        let staging = Self.stagingURL(beside: request.output)
        let temporary = Self.temporaryURL(beside: request.output)
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: temporary)

        var placed = false
        defer {
            // The staging file is an intermediate and never a deliverable, so it goes
            // whatever happened.
            try? manager.removeItem(at: staging)
            if !placed { try? manager.removeItem(at: temporary) }
        }

        let settings = VideoEncodeSettings.forSource(info, bitRate: request.bitRate)
        let sink = try makeSink(staging, settings)
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

        // How long the picture is, derived from the rate rather than read back from a
        // container that has not been finalised. This is the number the audio has to
        // agree with, and it is exact: `written` frames at a rational rate.
        let videoSeconds = resolution.output.doubleValue > 0
            ? Double(written) / resolution.output.doubleValue : 0

        var problems: [String] = []

        // `moveItem` refuses an existing destination, so a replacement has to be
        // explicit — without this, `overwrite` would run the whole film and then throw
        // at the last step, which is the most expensive possible way to fail. Removing
        // first leaves a window where neither file exists; that is the safe direction,
        // because a crash there loses the old output and leaves an obvious `.partial-`
        // file rather than producing something half of each.
        func place(_ url: URL) throws {
            if request.overwrite, manager.fileExists(atPath: request.output.path) {
                try manager.removeItem(at: request.output)
            }
            try manager.moveItem(at: url, to: request.output)
            placed = true
        }

        var audio: AudioMuxer.Outcome?
        if audioPlan.isSilent {
            // Nothing to mux, so the staged video *is* the answer.
            try place(staging)
        } else {
            let outcome = try mux(MuxRequest(
                video: staging,
                source: request.input,
                output: temporary,
                plan: audioPlan,
                // Snapped to the frame grid, because that is where the picture starts:
                // `-ss` discards frames until the requested instant, so the first frame
                // out is the first one at or *after* the seek. Seeking the audio to the
                // raw request would put it up to a frame early on every conversion.
                audioStart: request.startSeconds.map {
                    AudioMuxer.alignedStart($0, rate: info.frameRate)
                },
                videoSeconds: videoSeconds,
                // A partial render must not produce a file whose audio outlives its
                // picture. A full one keeps the audio's own length, because a score
                // legitimately runs past the last frame.
                boundAudio: request.maximumSourceFrames != nil,
                frameTolerance: 1.0 / info.frameRate.doubleValue,
                sourceChapters: info.chapterCount))
            audio = outcome
            problems += outcome.problems
            try place(temporary)
        }

        let size = (try? manager.attributesOfItem(atPath: request.output.path))?[.size]
        let bytes = (size as? NSNumber)?.int64Value ?? 0

        problems += report.problems
        problems += sink.problems

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
                      problems: problems,
                      audio: audio,
                      audioPolicy: audioPolicy,
                      segments: nil)
    }

    // MARK: - The segmented path

    /// How many source frames the plan should cover.
    ///
    /// Matroska reports `nb_frames=N/A`, so the count is not there to be read. It is
    /// derived from the duration instead, and rounded **up**: a plan that covers more
    /// frames than the film has ends with a segment that comes up short and stops, which
    /// is handled; a plan that covers *fewer* would truncate the film, which is not.
    static func estimatedSourceFrames(request: Request,
                                      info: MediaInfo) -> Int? {
        if let limit = request.maximumSourceFrames { return limit }
        if let stated = info.frameCount { return stated }
        guard info.duration > 0, info.frameRate.doubleValue > 0 else { return nil }
        return Int((info.duration * info.frameRate.doubleValue).rounded(.up)) + 1
    }

    static func segmentPlan(request: Request,
                            info: MediaInfo,
                            resolution: OutputRatePolicy.Resolution,
                            segmentSeconds: Double) -> SegmentPlan? {
        guard let frames = estimatedSourceFrames(request: request, info: info),
              frames >= 2 else { return nil }
        return SegmentPlan(sourceFrameCount: frames,
                           source: info.frameRate,
                           output: resolution.output,
                           segmentSeconds: segmentSeconds)
    }

    /// A film in pieces, each rendered to its own file and recorded before the next one
    /// starts.
    private func runSegmented(_ request: Request,
                              info: MediaInfo,
                              resolution: OutputRatePolicy.Resolution,
                              audioPolicy: AudioMuxPolicy,
                              audioPlan: AudioMuxPolicy.Plan,
                              plan: SegmentPlan) throws -> Result {
        let manager = FileManager.default
        let directory = JobManifest.directory(beside: request.output)
        let staging = Self.stagingURL(beside: request.output)
        let temporary = Self.temporaryURL(beside: request.output)
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: temporary)
        // Before the first segment is rendered, not by the first manifest write: the
        // segment's own file lives here, and an `open` into a directory that does not
        // exist fails silently enough to look like a sink that wrote nothing.
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var placed = false
        defer {
            try? manager.removeItem(at: staging)
            if !placed { try? manager.removeItem(at: temporary) }
            if placed, !request.keepSegments { try? manager.removeItem(at: directory) }
        }

        // What this job is. Recorded so a second run can tell whether what is on disk is
        // the same job, rather than assuming it is because the file names match.
        let fingerprint = JobManifest.Fingerprint.of(
            source: request.input, info: info,
            outputRate: resolution.output, bitRate: request.bitRate,
            depth: request.depth, sceneDetection: request.sceneDetection,
            intervalsPerSegment: plan.intervalsPerSegment)

        var manifest = request.restart ? nil : try JobManifest.load(from: directory)
        if let found = manifest, let difference = found.fingerprint.difference(from: fingerprint) {
            // Half of one job joined to half of another plays perfectly and is wrong —
            // two different films, or one film at two different bit rates. Refusing is
            // the only safe answer; `restart` is the way to say "I know, throw it away".
            guard request.restart else { throw Failure.manifestMismatch(difference) }
            manifest = nil
        }
        var working = manifest ?? JobManifest(fingerprint: fingerprint)
        let finished = working.completed(in: directory, plan: plan)

        var problems: [String] = []
        var sourceFrames = 0
        var interpolatedFrames = 0
        var passthroughFrames = 0
        var cutCount = 0
        var wallSeconds = 0.0

        for segment in plan.segments where !finished.contains(segment.index) {
            let file = directory.appendingPathComponent(
                JobManifest.segmentFileName(index: segment.index,
                                            of: plan.segments.count))
            // Discard, not trust. A segment file that exists may be complete or may be
            // half of one; those two are indistinguishable from the outside, and the
            // manifest is the only thing that says which.
            try? manager.removeItem(at: file)

            let report = try render(segment: segment, of: plan, request: request,
                                    info: info, resolution: resolution, to: file)

            // Zero frames means the source ran out before this segment began, which is
            // how a plan built on an estimated length finds the end of the film.
            guard report.outputFrames > 0 else { break }

            sourceFrames += report.sourceFrames
            interpolatedFrames += report.interpolatedFrames
            passthroughFrames += report.passthroughFrames
            cutCount += report.cutCount
            wallSeconds += report.wallSeconds

            let size = (try? manager.attributesOfItem(atPath: file.path))?[.size]
            working.record(JobManifest.Entry(
                index: segment.index,
                file: file.lastPathComponent,
                bytes: (size as? NSNumber)?.int64Value ?? 0,
                // What landed, not what was planned: the last segment can end short.
                frames: report.outputFrames,
                sourceStart: segment.sourceStart,
                sourceCount: segment.sourceCount,
                outputStart: segment.outputStart,
                outputCount: segment.outputCount,
                wallSeconds: report.wallSeconds))
            // Written *after* the segment is finished and checked, and atomically, so a
            // crash leaves the previous record intact rather than a half-written one.
            try working.write(to: directory)
            problems += report.problems
        }

        // Everything that is finished, in the film's order. The plan's own order, so the
        // concat list is the film even if the manifest was written out of order.
        let files = plan.segments.compactMap { segment -> URL? in
            guard working.entry(for: segment.index) != nil else { return nil }
            return directory.appendingPathComponent(
                JobManifest.segmentFileName(index: segment.index, of: plan.segments.count))
        }
        guard !files.isEmpty else {
            throw Failure.shortOutput(expected: plan.outputFrameCount, written: 0)
        }

        // The join is a container operation over bitstreams that are already correct —
        // no second generation of loss — and it is checked against what the plan says
        // the film has, because a lost boundary is not an error to ffmpeg.
        let joiner = makeJoiner()
        let joined = try joiner.join(files: files, output: staging,
                                     expectedFrames: working.segments.reduce(0) { $0 + $1.frames },
                                     expectedRate: resolution.output)

        let written = joined.frames ?? working.segments.reduce(0) { $0 + $1.frames }
        let videoSeconds = resolution.output.doubleValue > 0
            ? Double(written) / resolution.output.doubleValue : 0

        func place(_ url: URL) throws {
            if request.overwrite, manager.fileExists(atPath: request.output.path) {
                try manager.removeItem(at: request.output)
            }
            try manager.moveItem(at: url, to: request.output)
            placed = true
        }

        var audio: AudioMuxer.Outcome?
        if audioPlan.isSilent {
            try place(staging)
        } else {
            // The audio is muxed once, over the joined picture, and never segmented. A
            // compressed stream can only be cut at a packet boundary, so cutting it per
            // segment would mean re-encoding the DTS-HD MA master that the whole point
            // of the MKV path is to keep bit for bit.
            let outcome = try mux(MuxRequest(
                video: staging,
                source: request.input,
                output: temporary,
                plan: audioPlan,
                audioStart: request.startSeconds.map {
                    AudioMuxer.alignedStart($0, rate: info.frameRate)
                },
                videoSeconds: videoSeconds,
                boundAudio: request.maximumSourceFrames != nil,
                frameTolerance: 1.0 / info.frameRate.doubleValue,
                sourceChapters: info.chapterCount))
            audio = outcome
            problems += outcome.problems
            try place(temporary)
        }

        let size = (try? manager.attributesOfItem(atPath: request.output.path))?[.size]
        let bytes = (size as? NSNumber)?.int64Value ?? 0

        let outcome = SegmentOutcome(plan: plan, entries: working.segments,
                                     resumed: finished, joined: joined,
                                     problems: joined.problems)
        problems += joined.problems
        if !outcome.isComplete {
            problems.append("only \(outcome.entries.count) of \(plan.segments.count) "
                            + "segments were rendered; the film ends early")
        }

        return Result(output: request.output,
                      source: info,
                      resolution: resolution,
                      report: InterpolationPipeline.Report(
                        sourceFrames: sourceFrames,
                        outputFrames: written,
                        interpolatedFrames: interpolatedFrames,
                        passthroughFrames: passthroughFrames,
                        engineCalls: 0,
                        decisions: [],
                        wallSeconds: wallSeconds,
                        problems: []),
                      written: written,
                      bytes: bytes,
                      wallSeconds: wallSeconds,
                      problems: problems,
                      audio: audio,
                      audioPolicy: audioPolicy,
                      segments: outcome)
    }

    /// Render one segment into its own file.
    private func render(segment: SegmentPlan.Segment,
                        of plan: SegmentPlan,
                        request: Request,
                        info: MediaInfo,
                        resolution: OutputRatePolicy.Resolution,
                        to file: URL) throws -> InterpolationPipeline.Report {
        let settings = VideoEncodeSettings.forSource(info, bitRate: request.bitRate)
        let sink = try makeSink(file, settings)

        // Half a frame into the frame's own presentation, so a seek that lands a hair
        // early still lands on this frame rather than the one before it.
        let base = request.startSeconds ?? 0
        let seek = base + (Double(segment.readStart) + 0.5) / info.frameRate.doubleValue
        let source = try makeSource(request.input, info, seek, segment.readCount)
        let engine = try makeEngine(info.frameRate, resolution.output, request.depth)

        let pipeline = InterpolationPipeline(
            source: source,
            sourceRate: info.frameRate,
            outputRate: resolution.output,
            engine: engine,
            configuration: .init(depth: request.depth,
                                 sceneDetection: request.sceneDetection,
                                 maximumSourceFrames: segment.readCount,
                                 expectedOutputFrameCount: segment.outputCount,
                                 window: .init(segment: segment)))

        let report = try pipeline.run(into: sink)
        guard sink.written == report.outputFrames else {
            throw Failure.shortOutput(expected: report.outputFrames, written: sink.written)
        }
        return report
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

    /// The video-only intermediate, between the encoder and the mux.
    ///
    /// Always `.mp4`: that is what `AVAssetWriter` writes, and ffmpeg's demuxer picks
    /// its reader from the extension, so naming it `.mkv` would hand it a Matroska
    /// reader for an MP4 file. The `video-` marker keeps it distinct from the
    /// `partial-` file, which is the one that is nearly a deliverable.
    static func stagingURL(beside output: URL) -> URL {
        let stem = output.deletingPathExtension().lastPathComponent
        let unique = String(UUID().uuidString.prefix(8)).lowercased()
        return output.deletingLastPathComponent()
            .appendingPathComponent("\(stem).video-\(unique).mp4")
    }
}
