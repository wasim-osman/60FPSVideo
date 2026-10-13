import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Interpolator

// A headless end-to-end pipeline: packed frames in, packed frames out.
//
// It exists to make the whole chain testable without a UI, and to keep the
// measurement harnesses honest — the numbers in reports/ came from a script that
// did this inline, and this is that logic made reusable.
//
// usage: interp-harness IN W H SRC_RATE OUT_RATE OUT [options]
//   --format nv12|p010   sample width of the packed input (default nv12)
//   --depth N            requests in flight (default 2, minimum 2)
//   --max-frames N       stop after N source frames
//   --detect-only        report scene cuts and exit, no render
//   --no-scene-detect    interpolate across cuts (the old, wrong behaviour)
//
// usage: interp-harness --play FILE [--seconds N] [--rate R] [--depth N] [--no-scene-detect]
//                        [--sound] [--start S] [--prepare-only]
//   Plays the film for N seconds with a counting display instead of a window, and reports
//   whether the picture kept up with the clock. Headless on purpose: the pacing, the drop
//   policy and the skip policy are all arithmetic, and arithmetic is measurable without a
//   screen — while a screen is not measurable at all from here.
//
//   `--sound` prepares and attaches the soundtrack, which then *is* the clock. `--prepare-only`
//   stops after preparing it, so the cost of a re-encode can be measured without watching a
//   film to find out.

// ---------------------------------------------------------------- output

// The packed-frame writer now lives in the library as `PackedFileSink`, so the
// harness, the batch converter and the tests share one implementation. It was
// `OutputWriter` here; the body is unchanged, including the `pwrite` at an explicit
// offset that lets completions land in any order without corrupting the stream.

/// Destination buffers travelling into an engine completion.
///
/// The same borrow contract `InterpolationRequest` states: these buffers are ours
/// alone until the completion fires, because the engine is holding them.
private struct BufferSet: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
}

// ---------------------------------------------------------------- options

struct Options {
    enum SceneMode: String {
        /// Decide cuts from the whole clip up front. What batch conversion does.
        case offline
        /// Decide cuts as frames arrive, with a two-frame lookahead. What playback
        /// must do. Both are run and compared regardless; this picks which one
        /// drives the render.
        case online
    }

    var input = ""
    var width = 0
    var height = 0
    var sourceRate = ""
    var outputRate = ""
    var output = ""
    /// Set by `--rate-policy`. Used when OUT_RATE is the word `auto`, which is how the
    /// harness exercises the shipping rate decision instead of keeping a second copy of
    /// it. See `OutputRatePolicy`.
    var ratePolicy: OutputRatePolicy? = nil
    var format = FrameFormat.nv12
    var sceneMode = SceneMode.offline
    var depth = 2
    var maxFrames: Int? = nil
    var detectOnly = false
    var sceneDetect = true
    /// Drive the render through the extracted `InterpolationPipeline` instead of the
    /// inline loop. The two must produce the same frames, which is the whole point:
    /// the pipeline is what the app ships, and the inline loop is the reference it
    /// was extracted from.
    var pipeline = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func shortRead(frame: Int, expected: Int, got: Int) -> Never {
    fail("short read at frame \(frame): wanted \(expected) bytes, got \(got)")
}

// ---------------------------------------------------------------- --progress

/// Rate-limits the progress callback.
///
/// The converter calls it once per interval — 172 627 times for a two-hour film — and writing
/// a line per call would cost more than the interpolation does.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last: TimeInterval?

    init(interval: TimeInterval) { self.interval = interval }

    func allow() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard last.map({ now - $0 >= interval }) ?? true else { return false }
        last = now
        return true
    }
}

/// The estimator, behind a lock so the `@Sendable` callback can own it.
final class EstimateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var estimator = ProgressEstimator()

    func record(_ progress: BatchConverter.Progress) {
        // Only the rendering stage. Probing and the audio work come *before* the render and
        // carry no fraction; muxing and joining come after it. Feeding either into the window
        // is exactly what `elapsed / fraction` got wrong.
        guard progress.stage == .rendering, let fraction = progress.fraction else { return }
        lock.lock()
        estimator.observe(fraction: fraction, at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    var remaining: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return estimator.remaining
    }
}

/// A duration as a rough human interval, matching the app's `Fmt.interval`.
func interval(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    if seconds < 60 { return "less than a minute" }
    if seconds < 90 { return "under two minutes" }
    let minutes = seconds / 60
    if minutes < 90 { return String(format: "%.0f minutes", minutes) }
    return String(format: "%.1f hours", minutes / 60)
}

func parseOptions() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 6 else {
        FileHandle.standardError.write("""
        usage: interp-harness IN W H SRC_RATE OUT_RATE OUT [options]

        modes:
          --convert IN OUT [options]
                               the batch converter end to end: probe the file,
                               interpolate it, encode it, mux the audio, report what was
                               delivered. Options: --policy standard|sixty, --bitrate BPS,
                       --max-frames N, --start SECONDS, --overwrite,
                       --force (convert even when already at target),
                       --quality quality|fast (quality = interpolate at the source
                       resolution, fast = interpolate at 1080p),
                       --output-size WxH (deliver at that size, independent of
                       --quality; the interpolation size is unchanged),
                       --fit | --fill (bars, or crop, when the shapes differ),
                       --workers N (0 asks the machine),
                       --no-hwaccel (decode in software — the control arm for what
                       the media engine is worth to a whole conversion; §36),
                       --activity (hold the app's no-throttling assertion),
                       --container mp4|mkv (default: from OUT's extension),
                       --audio automatic|copy|transcode|drop.
          --encode IN.packed OUT.mp4 W H [options]
                               encode a packed stream without interpolating. Options:
                               --format, --rate, --bitrate, --max-frames,
                               --metadata-from FILE (colour tags and HDR10 payloads
                               are taken from that file, through the shipping path).
          --mux VIDEO SOURCE OUT [options]
                               the audio stage on its own: take SOURCE's chosen audio
                               stream and put it into VIDEO without re-encoding the
                               picture. Options: --container mp4|mkv,
                               --audio automatic|copy|transcode|drop,
                               --start SECONDS, --video-seconds D, --bound.
                               This is how the whole-film bit-perfect copy is checked
                               without rendering a whole film first.

        options:
          --format nv12|p010   sample width of the packed input (default nv12)
          --scene-mode MODE    offline (whole clip up front, default) or online
                               (two-frame lookahead, as playback must). Both are
                               always run and compared; this picks the driver.
          --depth N            requests in flight (default 2, minimum 2)
          --max-frames N       stop after N source frames
          --detect-only        report scene cuts and exit, no render
          --no-scene-detect    interpolate across cuts (the old, wrong behaviour)
          --pipeline           drive the render through the extracted
                               InterpolationPipeline instead of the inline loop.
                               The two have to produce the same frames; this is how
                               that is checked on real footage.
          --rate-policy NAME   which policy OUT_RATE=auto resolves through:
                               standard (59.94, the default) or sixty (60.000).

        Rates accept an exact rational ("60000/1001") or the industry shorthand
        ("59.94"). The shorthand is mapped onto the exact NTSC rational, because
        "59.94" is a name for 60000/1001 and not a decimal value.

        OUT_RATE may also be the word "auto", which asks the rate policy instead —
        the same type the batch converter and the player use, so this runs the
        shipping decision rather than a second copy of it. A policy never produces
        a rate below the source, so a 60.000 source under the default is reported
        as already at target instead of being quietly downconverted.

        p010 is packed as 16-bit little-endian words with the 10-bit code in the
        top ten bits — the same layout VideoToolbox and ffmpeg's p010le use, so
        the input needs no repacking.

        """.data(using: .utf8)!)
        exit(2)
    }

    var options = Options()
    options.input = args[0]
    guard let width = Int(args[1]) else { fail("bad width '\(args[1])'") }
    guard let height = Int(args[2]) else { fail("bad height '\(args[2])'") }
    options.width = width
    options.height = height
    options.sourceRate = args[3]
    options.outputRate = args[4]
    options.output = args[5]

    var i = 6
    while i < args.count {
        switch args[i] {
        case "--format":
            i += 1
            guard i < args.count else { fail("--format needs a value") }
            switch args[i] {
            case "nv12": options.format = .nv12
            case "p010": options.format = .p010
            default: fail("unknown format '\(args[i])' — expected nv12 or p010")
            }
        case "--scene-mode":
            i += 1
            guard i < args.count, let mode = Options.SceneMode(rawValue: args[i]) else {
                fail("--scene-mode needs 'offline' or 'online'")
            }
            options.sceneMode = mode
        case "--depth":
            i += 1
            guard i < args.count, let value = Int(args[i]) else { fail("--depth needs a number") }
            options.depth = value
        case "--max-frames":
            i += 1
            guard i < args.count, let value = Int(args[i]) else { fail("--max-frames needs a number") }
            options.maxFrames = value
        case "--detect-only":
            options.detectOnly = true
        case "--no-scene-detect":
            options.sceneDetect = false
        case "--pipeline":
            options.pipeline = true
        case "--rate-policy":
            i += 1
            guard i < args.count else {
                fail("--rate-policy needs 'standard' (59.94) or 'sixty' (60.000)")
            }
            guard let policy = OutputRatePolicy.named(args[i]) else {
                fail("unknown rate policy '\(args[i])' — expected 'standard' (59.94) "
                     + "or 'sixty' (60.000)")
            }
            options.ratePolicy = policy
        default:
            fail("unknown option '\(args[i])'")
        }
        i += 1
    }
    return options
}

// ---------------------------------------------------------------- probe mode
//
// `interp-harness --probe FILE` reports what a media file is, and exits. It exists
// because the answer decides how the file gets processed — the frame rate must be
// the exact rational, the depth picks the pixel format, and the HDR10 metadata has
// to be carried through to the encode — and because it is the quickest way to see
// whether a given container can be opened at all. Notably it answers for Matroska,
// which AVFoundation cannot open and therefore cannot answer for.

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--probe" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    do {
        let info = try MediaProbe.probe(url)
        log("file    : \(url.lastPathComponent)")
        log("size    : \(info.width)x\(info.height)")
        log("rate    : \(info.frameRate)  (\(info.frameRate.doubleValue) fps)")
        log("frames  : \(info.frameCount.map(String.init) ?? "not stated")"
            + "   duration \(String(format: "%.2f", info.duration))s")
        log("pixel   : \(info.pixelFormat)  ->  pipeline \(info.format.bitDepth)-bit "
            + "(\(info.format == .p010 ? "P010" : "NV12"))")
        log("colour  : primaries \(info.colorPrimaries ?? "-")"
            + "  transfer \(info.transferFunction ?? "-")"
            + "  matrix \(info.colorSpace ?? "-")"
            + "  range \(info.colorRange ?? "-")")
        log("HDR     : \(info.isHDR ? "yes" : "no")")
        if let display = info.masteringDisplay {
            log(String(format: "  mastering display: R(%d,%d) G(%d,%d) B(%d,%d) WP(%d,%d)"
                       + "  %.4f..%.1f nits",
                       display.redX, display.redY, display.greenX, display.greenY,
                       display.blueX, display.blueY, display.whiteX, display.whiteY,
                       display.minNits, display.maxNits))
            log("  mastering SEI payload: \(display.seiPayload.count) bytes")
        } else {
            log("  mastering display: absent")
        }
        if let level = info.contentLightLevel {
            log("  content light level: MaxCLL \(level.maxContent), "
                + "MaxFALL \(level.maxAverage) nits")
            log("  content light SEI payload: \(level.seiPayload.count) bytes")
        } else {
            log("  content light level: absent")
        }
        if info.audioTracks.isEmpty {
            log("audio   : none")
        }
        // Every stream, because the usable one is often not the first — on the
        // reference disc the 7.1 master is stream 1 and the copyable compatibility
        // track is stream 2.
        for track in info.audioTracks {
            log("audio   : #\(track.index) \(track)"
                + (track.isLossless ? "  lossless" : "")
                + (track.isDefault ? "  [default]" : "")
                + (MediaInfo.audioPassThroughCodecs.contains(track.codec)
                   ? "  -> MP4 ok" : "  -> MP4 needs a transcode"))
        }
        // What each policy would do, so the decision is visible without running a job.
        // Both halves matter: a whole-film conversion copies, and a partial render
        // cannot, because a compressed stream only cuts at a packet boundary.
        for candidate in AudioMuxPolicy.all {
            do {
                let whole = try candidate.plan(for: info).summary
                log("policy  : \(candidate.label) -> \(whole)")
                let cut = try candidate.plan(for: info, cutting: true).summary
                if cut != whole {
                    log("           when cut -> \(cut)")
                }
            } catch {
                log("policy  : \(candidate.label) -> refuses: \(error)")
            }
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// ---------------------------------------------------------------- decode mode
//
// `interp-harness --decode FILE OUT [--start T] [--max-frames N]` decodes through
// the shipping input path — probe, then ffmpeg on a pipe — and writes the frames
// out packed. It exists so that path can be checked against a known-good
// extraction: if the bytes match what ffmpeg produced directly, the source is
// faithful, and everything downstream is working on the frames it thinks it is.

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--decode" {
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputPath = CommandLine.arguments[3]
    var start: Double? = nil
    var limit: Int? = nil
    let rest = Array(CommandLine.arguments.dropFirst(4))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--start":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else { fail("--start needs a number") }
            start = value
        case "--max-frames":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else { fail("--max-frames needs a number") }
            limit = value
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }

    do {
        let info = try MediaProbe.probe(inputURL)
        log("probe : \(info.width)x\(info.height)  \(info.frameRate)  "
            + "\(info.pixelFormat) -> \(info.format.bitDepth)-bit  "
            + "HDR \(info.isHDR ? "yes" : "no")")
        let source = try FFmpegFrameSource(url: inputURL, info: info,
                                           startSeconds: start, frameLimit: limit)
        let descriptor = open(outputPath, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { fail("cannot create \(outputPath)") }
        var staging = [UInt8](repeating: 0, count: source.frameByteSize)
        var written = 0
        let began = DispatchTime.now().uptimeNanoseconds
        while true {
            let more = try staging.withUnsafeMutableBytes { raw -> Bool in
                try source.read(into: raw.baseAddress!)
            }
            if !more { break }
            let wrote = staging.withUnsafeBytes {
                pwrite(descriptor, $0.baseAddress, source.frameByteSize,
                       off_t(written * source.frameByteSize))
            }
            guard wrote == source.frameByteSize else {
                fail("short write at frame \(written): \(wrote)")
            }
            written += 1
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        source.close()
        ftruncate(descriptor, off_t(written * source.frameByteSize))
        fsync(descriptor)
        close(descriptor)
        log("decoded: \(written) frames  \(source.frameByteSize) B/frame  "
            + String(format: "%.2fs  %.1f frames/s", elapsed, Double(written) / elapsed))
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// ---------------------------------------------------------------- encode mode
//
// `interp-harness --encode IN.packed OUT.mp4 W H [options]` runs packed frames
// through the shipping `AssetWriterSink` — the same sink the batch converter uses —
// so the encode can be measured with no pipeline in the way.
//
// It exists for the bit-rate experiment in BUILD-DECISIONS §20. The question is not
// "how good is the output", it is "at what rate does the encode stop being the thing
// you can see", and that can only be answered by encoding *the same frames* at
// several rates and comparing each against the uncompressed originals. Comparing
// against the original disc would confound the encode's error with the
// interpolation's, which is already measured separately in REAL-CONTENT-AB.md.

if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--encode" {
    let inputPath = CommandLine.arguments[2]
    let outputPath = CommandLine.arguments[3]
    guard let width = Int(CommandLine.arguments[4]),
          let height = Int(CommandLine.arguments[5]) else {
        fail("usage: interp-harness --encode IN.packed OUT.mp4 W H [options]")
    }
    var format = FrameFormat.nv12
    var rate = FrameRate.sixtyNTSC
    var bitRate = 0
    var limit: Int? = nil
    var metadataFrom: String? = nil
    let rest = Array(CommandLine.arguments.dropFirst(6))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--format":
            k += 1
            guard k < rest.count else { fail("--format needs a value") }
            switch rest[k] {
            case "nv12": format = .nv12
            case "p010": format = .p010
            default: fail("unknown format '\(rest[k])' — expected nv12 or p010")
            }
        case "--rate":
            k += 1
            guard k < rest.count, let parsed = FrameRate.parse(rest[k]) else {
                fail("--rate needs a frame rate")
            }
            rate = parsed
        case "--bitrate":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else {
                fail("--bitrate needs a number of bits per second")
            }
            bitRate = value
        case "--max-frames":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else {
                fail("--max-frames needs a number")
            }
            limit = value
        case "--metadata-from":
            k += 1
            guard k < rest.count else { fail("--metadata-from needs a path") }
            metadataFrom = rest[k]
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }
    // Required rather than defaulted: this mode exists to measure the number, so
    // silently substituting a default would defeat it.
    guard bitRate > 0 else { fail("--bitrate is required") }

    let frameSize = format.packedByteSize(width: width, height: height)
    let descriptor = open(inputPath, O_RDONLY)
    guard descriptor >= 0 else { fail("cannot open \(inputPath)") }
    var frames = Int(lseek(descriptor, 0, SEEK_END)) / frameSize
    if let limit { frames = min(frames, limit) }
    guard frames > 0 else { fail("\(inputPath) holds no whole frames") }

    // Colour tags and HDR10 metadata come from the file the frames were interpolated
    // from, through the same `forSource` the batch converter will use — so this
    // exercises the shipping metadata path rather than a copy of it.
    var settings: VideoEncodeSettings
    if let metadataFrom {
        do {
            let info = try MediaProbe.probe(URL(fileURLWithPath: metadataFrom))
            settings = VideoEncodeSettings.forSource(info, bitRate: bitRate)
            log("metadata: from \(URL(fileURLWithPath: metadataFrom).lastPathComponent)"
                + "   colour \(info.colorPrimaries ?? "-")/\(info.transferFunction ?? "-")"
                + "   HDR10 \(info.masteringDisplay != nil ? "yes" : "no")")
        } catch {
            fail("could not probe \(metadataFrom): \(error)")
        }
    } else {
        settings = VideoEncodeSettings(bitRate: bitRate)
        log("metadata: none (no --metadata-from)")
    }
    log(String(format: "target  : %.1f Mbps  %d frames  %dx%d  %@",
               Double(bitRate) / 1_000_000, frames, width, height, "\(format.bitDepth)-bit"))

    do {
        let pool = try PixelBufferPool(width: width, height: height, format: format,
                                       capacity: 4)
        let sink = AssetWriterSink(url: URL(fileURLWithPath: outputPath), settings: settings)
        try sink.begin(SinkGeometry(width: width, height: height, format: format,
                                    sourceRate: rate, outputRate: rate,
                                    sourceFrameCount: frames, outputFrameCount: frames))
        var staging = [UInt8](repeating: 0, count: frameSize)
        let began = DispatchTime.now().uptimeNanoseconds
        for index in 0..<frames {
            let got = staging.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, frameSize, off_t(index * frameSize))
            }
            guard got == frameSize else {
                fail("short read at frame \(index): \(got) of \(frameSize)")
            }
            let buffer = try pool.makeBuffer()
            staging.withUnsafeBytes {
                format.load(packed: $0.baseAddress!, into: buffer,
                            width: width, height: height)
            }
            // One pool buffer reused for every frame, which is only safe because
            // `write` copies before it returns — the same property the batch
            // converter depends on when the pipeline reuses its slots.
            sink.write(buffer, at: index)
        }
        try sink.finish()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        close(descriptor)

        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size]
                     as? Int) ?? 0
        let megabytes = Double(bytes) / 1_000_000
        log(String(format: "encoded : %d/%d frames -> %.1f MB  %.2fs  "
                   + "(%.1f Mbps written, %.1f%% of target)",
                   sink.appended, frames, megabytes, elapsed,
                   Double(bytes * 8) / elapsed / 1_000_000,
                   Double(bytes * 8) / elapsed / Double(bitRate) * 100))
        if !sink.problems.isEmpty {
            for problem in sink.problems.prefix(5) { log("  problem: " + problem) }
            exit(1)
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// ---------------------------------------------------------------- mux mode
//
// `interp-harness --mux VIDEO SOURCE OUT [options]` runs the audio stage on its own.
//
// It exists because the shipping audio path — a whole film, no seek, no bound, so the
// track is copied bit for bit — cannot be reached any other way without rendering a
// two-hour film first, and "we could not check it" is not the same as "it works".
// Here a short extract of the real disc stands in for the film, and the copy path is
// exercised exactly as the converter would run it.

if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--mux" {
    let videoPath = CommandLine.arguments[2]
    let sourcePath = CommandLine.arguments[3]
    let outputPath = CommandLine.arguments[4]

    var policy = AudioMuxPolicy.forOutput(URL(fileURLWithPath: outputPath))
    var start: Double? = nil
    var videoSeconds = 0.0
    var bound = false

    let rest = Array(CommandLine.arguments.dropFirst(5))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--container":
            k += 1
            guard k < rest.count, let named = AudioMuxPolicy.named(rest[k]) else {
                fail("--container needs mp4 or mkv")
            }
            policy = AudioMuxPolicy(container: named.container, handling: policy.handling)
        case "--audio":
            k += 1
            guard k < rest.count,
                  let handling = AudioMuxPolicy.Handling(rawValue: rest[k]) else {
                fail("--audio needs automatic, copy, transcode or drop")
            }
            policy.handling = handling
        case "--start":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else {
                fail("--start needs a number of seconds")
            }
            start = value
        case "--video-seconds":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else {
                fail("--video-seconds needs a number")
            }
            videoSeconds = value
        case "--bound":
            bound = true
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }

    do {
        let info = try MediaProbe.probe(URL(fileURLWithPath: sourcePath))
        // The cut is decided by the same rule the converter uses, so this cannot
        // disagree with the shipping path about what is possible.
        let cutting = (start ?? 0) > 0 || bound
        let plan = try policy.plan(for: info, cutting: cutting)
        let sourceURL = URL(fileURLWithPath: sourcePath)

        let request = MuxRequest(
            video: URL(fileURLWithPath: videoPath),
            source: sourceURL,
            output: URL(fileURLWithPath: outputPath),
            plan: plan,
            audioStart: start.map { AudioMuxer.alignedStart($0, rate: info.frameRate) },
            videoSeconds: videoSeconds,
            boundAudio: bound,
            frameTolerance: 1.0 / info.frameRate.doubleValue,
            sourceChapters: info.chapterCount)

        log("source : \(sourcePath)")
        log("video  : \(videoPath)")
        log("output : \(outputPath)")
        // The picture's earliest *raw* packet time, which is what decides whether ffmpeg
        // will rebase the whole output to lift the picture to zero. A negative value here
        // is not a defect in the input — it is an encoder's reorder delay, which the source
        // container cancelled with an edit list — but it is the cause of a silent A/V
        // desync in Matroska, so it is worth stating before the mux rather than deducing
        // from the offset afterwards.
        let videoStartOffset = (try? AudioMuxer.probeMinPTS(
            at: URL(fileURLWithPath: videoPath))) ?? 0
        if videoStartOffset < 0 {
            // Stated as a fact about the input, not a promise about the output: whether it
            // is compensated for depends on the container, and that is the mux's answer to
            // give. The outcome line below says what was actually applied.
            log(String(format: "rebase : picture packets start %.1f ms below zero — an encoder "
                        + "reorder delay the source container carried as an edit list",
                        -videoStartOffset * 1000))
        }
        for track in info.audioTracks { log("         \(track)") }
        log("plan   : \(plan.summary)")
        if let aligned = request.audioStart {
            log(String(format: "seek   : %.6f s (aligned from %.6f)", aligned, start ?? 0))
        }

        let outcome = try AudioMuxer().mux(request)
        log(String(format: "muxed  : %.2f MB", Double(outcome.bytes) / 1e6))
        log("result : \(outcome.summary)")
        if outcome.audioOffset < 0 {
            log(String(format: "         audio offset %.1f ms, cancelling the picture's rebase",
                       -outcome.audioOffset * 1000))
        }
        if let streams = outcome.streams {
            log("         \(streams)")
            if let offset = outcome.offset {
                log(String(format: "         A/V offset %.1f ms", offset * 1000))
            }
        }
        if !outcome.isClean {
            for problem in outcome.problems { log("  problem: " + problem) }
            exit(1)
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// ---------------------------------------------------------------- convert

// The batch converter, end to end, on a real file. Everything here is assembly —
// probe, interpolate, encode, report what was actually delivered — and the point of
// running it from the harness is that it exercises the shipping path rather than a
// copy of it. The rate decision in particular is the same `OutputRatePolicy` the
// player will use, so a film converted here and played back there land their
// passthrough frames in the same places.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--convert" {
    let inputPath = CommandLine.arguments[2]
    let outputPath = CommandLine.arguments[3]

    var policy = OutputRatePolicy.default
    var bitRate: Int? = nil
    var limit: Int? = nil
    var start: Double? = nil
    var depth = 2
    var workers = 0
    var quality = ConversionQuality.quality
    var outputTarget = OutputTarget.source
    var fitMode = FitMode.fit
    var overwrite = false
    var force = false
    var audioPolicy: AudioMuxPolicy? = nil
    var segmentSeconds: Double? = nil
    var restart = false
    var keepSegments = false
    var activity = false
    var showProgress = false
    var hardwareDecode = true

    let rest = Array(CommandLine.arguments.dropFirst(4))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--policy":
            k += 1
            guard k < rest.count, let named = OutputRatePolicy.named(rest[k]) else {
                fail("--policy needs standard or sixty")
            }
            policy = named
        case "--quality":
            // The conversion-quality lever. `quality` interpolates at the source's resolution;
            // `fast` interpolates at 1080p and writes 1080p. It exists on the harness so the
            // speed-up can be measured on the real film rather than inferred from the curve.
            k += 1
            guard k < rest.count, let named = ConversionQuality(rawValue: rest[k]) else {
                fail("--quality needs quality or fast")
            }
            quality = named
        case "--output-size":
            // The delivered size, which is deliberately independent of `--quality`. It exists on
            // the harness so a screen-sized output can be measured on the real film — both its
            // dimensions and where the bars land — rather than looked at in the app and believed.
            k += 1
            guard k < rest.count else { fail("--output-size needs WxH, e.g. 3440x1440") }
            let parts = rest[k].lowercased().split { $0 == "x" || $0 == "×" || $0 == "*" }
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
                fail("--output-size needs WxH, e.g. 3440x1440")
            }
            outputTarget = .fixed(OutputSize(width: w, height: h))
        case "--fit":
            fitMode = .fit
        case "--fill":
            fitMode = .fill
        case "--container":
            k += 1
            guard k < rest.count, let named = AudioMuxPolicy.named(rest[k]) else {
                fail("--container needs mp4 or mkv")
            }
            audioPolicy = named
        case "--audio":
            k += 1
            guard k < rest.count,
                  let handling = AudioMuxPolicy.Handling(rawValue: rest[k]) else {
                fail("--audio needs automatic, copy, transcode or drop")
            }
            audioPolicy = AudioMuxPolicy(container: (audioPolicy ?? .default).container,
                                         handling: handling)
        case "--bitrate":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else {
                fail("--bitrate needs a number of bits per second")
            }
            bitRate = value
        case "--depth":
            k += 1
            guard k < rest.count, let value = Int(rest[k]), value >= 1 else {
                fail("--depth needs a positive number of requests")
            }
            depth = value
        case "--workers":
            k += 1
            guard k < rest.count, let value = Int(rest[k]), value >= 0 else {
                fail("--workers needs a number (0 asks the machine)")
            }
            workers = value
        case "--max-frames":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else {
                fail("--max-frames needs a number")
            }
            limit = value
        case "--start":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else {
                fail("--start needs a number of seconds")
            }
            start = value
        case "--overwrite":
            overwrite = true
        case "--no-hwaccel":
            // The control arm of the media-engine question. Decoding through VideoToolbox is
            // 2.9× faster *at decoding*; this is how the harness asks whether that 2.9× is
            // worth anything to a whole conversion, where the decoder is not the bottleneck.
            // It overrides `makeSource` below rather than the library's default. See §36.
            hardwareDecode = false
        case "--force":
            force = true
        case "--segment-seconds":
            k += 1
            guard k < rest.count, let value = Double(rest[k]), value > 0 else {
                fail("--segment-seconds needs a positive number of seconds")
            }
            segmentSeconds = value
        case "--activity":
            // Hold the same assertion the app holds while a job runs, so its effect can be
            // measured rather than asserted. See `AppModel.beginJobActivity` and invariant 47.
            activity = true
        case "--restart":
            restart = true
        case "--keep-segments":
            keepSegments = true
        case "--progress":
            // Print the bar and the projection the app would show. It exists so the estimate can
            // be checked against a real film's real clock rather than against a fixture — the
            // whole point of the estimator is how it behaves over hours, and no unit test can
            // wait for that.
            showProgress = true
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }

    let request = BatchConverter.Request(
        input: URL(fileURLWithPath: inputPath),
        output: URL(fileURLWithPath: outputPath),
        policy: policy,
        quality: quality,
        outputTarget: outputTarget,
        fitMode: fitMode,
        bitRate: bitRate,
        depth: depth,
        workers: workers,
        maximumSourceFrames: limit,
        startSeconds: start,
        overwrite: overwrite,
        convertWhenAlreadyAtTarget: force,
        audio: audioPolicy,
        segmentSeconds: segmentSeconds,
        restart: restart,
        keepSegments: keepSegments)

    log("input  : \(inputPath)")
    log("output : \(outputPath)")
    log("decode : \(hardwareDecode ? "VideoToolbox (media engine)" : "ffmpeg software — CONTROL ARM")")
    if case .fixed(let size) = outputTarget {
        log("deliver: \(size.label)  (\(fitMode.label.lowercased()) into it)")
    }

    do {
        // The same assertion the app holds for the whole of a job — `AppModel.beginJobActivity`.
        // It is here so that its effect can be *measured* rather than assumed: run this under
        // `taskpolicy -b` with and without it. See invariant 47.
        let hold = activity
            ? ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                    reason: "harness conversion")
            : nil
        defer { if let hold { ProcessInfo.processInfo.endActivity(hold) } }

        let result = try {
            var converter = BatchConverter()
            if !hardwareDecode {
                // Only the source factory differs; every other stage is the shipping converter,
                // so the two arms differ in exactly one variable.
                converter.makeSource = { request in
                    try FFmpegFrameSource(url: request.url, info: request.info,
                                          startSeconds: request.startSeconds,
                                          frameLimit: request.frameLimit,
                                          scale: request.scale,
                                          hardwareDecode: false)
                }
            }
            if showProgress {
                // The same two pieces the app uses: a throttle, because this is called once per
                // interval (172 627 times for a two-hour film), and an estimator fed **only** the
                // rendering stage. Probing and the audio work come before the render and carry no
                // fraction; muxing and joining come after it. Feeding either into the window is
                // exactly the mistake `elapsed / fraction` made, and it reads long for hours.
                let throttle = Throttle(interval: 1.0)
                let estimator = EstimateBox()
                converter.progress = { progress in
                    guard throttle.allow() else { return }
                    estimator.record(progress)
                    let fraction = progress.fraction.map { String(format: "%5.1f%%", $0 * 100) } ?? "   —  "
                    // The raw seconds as well as the human form: the app shows "about 2.0 hours"
                    // and that is the right thing for a person, but a measurement needs the
                    // number, and the number is what shows whether the projection converges.
                    let left = estimator.remaining.map {
                        String(format: "  about %@ left  (%.0f s)", interval($0), $0)
                    } ?? ""
                    log("  progress \(fraction)  \(progress.detail)\(left)")
                }
            }
            return try converter.run(request)
        }()
        let info = result.source
        log("probe  : \(info.width)x\(info.height)  \(info.frameRate)  "
            + "\(info.pixelFormat) -> \(info.format.bitDepth)-bit  "
            + "HDR \(info.isHDR ? "yes" : "no")")
        log("rate   : policy \(policy.label) -> \(result.resolution.output)"
            + "   ratio \(result.resolution.ratio.numerator)"
            + "/\(result.resolution.ratio.denominator)"
            + (result.resolution.isPassthrough ? "   (already at target)" : ""))
        if let note = result.resolution.note { log("note   : \(note)") }
        // Printed before the frame counts, because on a resumed job those counts
        // describe only the work that was done *this* run and reading them as the
        // film's would make a finished job look like a one-segment render.
        if let segments = result.segments {
            log("pieces : \(segments.summary)")
            log("         \(segments.plan.phasePeriod)-interval phase period, "
                + "\(segments.plan.intervalsPerSegment) intervals per piece, "
                + "\(segments.plan.leadIn)/\(segments.plan.leadOut) lead-in/out")
            if !segments.resumed.isEmpty {
                log("         resumed \(segments.resumed.count)")
            }
            if let joined = segments.joined {
                log("         \(joined.summary)")
            }
        }
        log("frames : \(result.report.sourceFrames) source -> "
            + "\(result.outputFrames) output   "
            + "(\(result.report.interpolatedFrames) interpolated, "
            + "\(result.report.passthroughFrames) passthrough, "
            + String(format: "%.1f%% free)", result.passthroughFraction * 100))
        log("cuts   : \(result.cutCount) detected across "
            + "\(result.report.decisions.count) intervals, "
            + "\(result.report.engineCalls) engine calls")
        log(String(format: "encode : %.1f MB   %.1f Mbps delivered   %.4f bpp   "
                   + "%.1f s of video",
                   Double(result.bytes) / 1e6, result.megabitsPerSecond,
                   result.bitsPerPixelPerFrame, result.outputSeconds))
        // The audio decision is printed in full, including what was passed over. A
        // silently transcoded soundtrack is indistinguishable from a copied one until
        // someone listens on a good system.
        log("audio  : \(result.audioPolicy.label)")
        for track in info.audioTracks {
            log("         source: \(track)"
                + (track.isLossless ? "  (lossless)" : "")
                + (track.isDefault ? "  [default]" : ""))
        }
        if let audio = result.audio {
            log("         \(audio.summary)")
            if audio.audioOffset < 0 {
                log(String(format: "         audio offset %.1f ms, cancelling the picture's rebase",
                           -audio.audioOffset * 1000))
            }
            if let streams = audio.streams {
                log("         \(streams)")
                if let offset = audio.offset {
                    log(String(format: "         A/V offset %.1f ms",
                               offset * 1000))
                }
            }
        } else {
            log("         none (the source has no audio, or it was dropped)")
        }
        // Cost per source frame is the number that projects. 2 h at 23.976 is 172 627
        // source frames; at 4K it is the difference between an evening and a night.
        let throughput = result.wallSeconds > 0
            ? Double(result.report.sourceFrames) / result.wallSeconds : 0
        log(String(format: "time   : %.1fs wall   %.1f source frames/s   "
                   + "-> %.1f h for a 2 h film",
                   result.wallSeconds, throughput,
                   172_627 / max(throughput, 0.0001) / 3600))
        // Which stage owns the wall time. `slotWait` near zero with the rest summing to
        // `wall` means the driver's own serial work is the ceiling — see `StageCosts`.
        let stages = result.report.stages
        log(String(format: "stages : %@   (driver busy %.1fs of %.1fs)",
                   stages.summary, stages.driverBusy, result.wallSeconds))
        if !result.isClean {
            for problem in result.problems.prefix(10) { log("  problem: " + problem) }
            log("RESULT : \(result.problems.count) problem(s)")
            exit(1)
        }
        log("RESULT : clean")
        exit(0)
    } catch let failure as BatchConverter.Failure {
        fail(failure.description)
    } catch {
        fail("\(error)")
    }
}

// ---------------------------------------------------------------- playback

/// A display that counts instead of drawing.
///
/// The player's pacing, its drop policy and its skip policy are all about *time*, and none
/// of them needs a window to be measured. What this cannot check is that a pixel reached a
/// screen; what it can check is that the film advanced at the rate the clock said, which is
/// the part that is arithmetic and therefore the part that is silently wrong when it is
/// wrong.
private final class CountingDisplay: VideoDisplay, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var first: Double?
    private var last: Double?

    /// A simulated cost, in milliseconds for a frame 1920 wide, **scaled by the frame's own pixel
    /// count** — because the real cost is per pixel, not per frame.
    ///
    /// That distinction is the whole reason the rate watchdog can work at all: narrowing the
    /// picture is only worth doing if it makes the thing that was too slow cheaper. A cost that
    /// did not fall with the frame size would prove the detection and not the recovery.
    ///
    /// The real display does work no probe of the *pipeline* can see: it converts, scales and
    /// composites, on the same GPU the engine is already saturating. This stub is how that cost is
    /// put back into a headless run, and the only way to check the watchdog without a screen.
    let costMilliseconds: Double

    init(costMilliseconds: Double = 0) {
        self.costMilliseconds = costMilliseconds
    }

    var isReadyForMoreMediaData: Bool { true }
    var requiresFlushToResumeDecoding: Bool { false }
    func discardQueuedFrames() {}

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if costMilliseconds > 0, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let relative = Double(CVPixelBufferGetWidth(pixels) * CVPixelBufferGetHeight(pixels))
                / Double(1920 * 816)
            let microseconds = costMilliseconds * relative * 1000
            if microseconds >= 1 { usleep(UInt32(microseconds)) }
        }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.lock()
        count += 1
        if first == nil { first = seconds }
        last = seconds
        lock.unlock()
    }

    var stats: (shown: Int, first: Double?, last: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (count, first, last)
    }
}

// The playback calibration, on a real film, as the app performs it at load.
//
// `--play` below drives the pipeline directly and never asks `PlaybackController` a question, so
// it cannot show what the *automatic* policy decides. This mode can: it walks the same ladder,
// with the same budget and the same margin, against the same engine the player uses — and prints
// every rung it probed, so the decision can be checked rather than taken on trust.
// A pure measurement, with no policy in it: what does the engine cost per interval at each
// width, on this film, right now?
//
// `--calibrate` answers "what will the app decide", which is the wrong question when the
// question is "where does the ladder's step actually fall". This walks a list of widths and
// reports each one, so a rung can be chosen from measurement rather than from a guess about
// which widths are on the same tread of the cost curve.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--measure-widths" {
    let inputPath = CommandLine.arguments[2]
    let input = URL(fileURLWithPath: inputPath)
    var startSeconds = 0.0
    var intervals = 20
    var widths: [Int] = []

    let rest = Array(CommandLine.arguments.dropFirst(3))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--start":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else {
                fail("--start needs a number")
            }
            startSeconds = value
        case "--intervals":
            k += 1
            guard k < rest.count, let value = Int(rest[k]), value > 0 else {
                fail("--intervals needs a positive number")
            }
            intervals = value
        case "--widths":
            k += 1
            guard k < rest.count else { fail("--widths needs a comma-separated list") }
            widths = rest[k].split(separator: ",").compactMap { Int($0) }
            guard !widths.isEmpty else { fail("--widths needs at least one number") }
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }
    guard !widths.isEmpty else { fail("--widths is required") }

    guard let info = try? MediaProbe.probe(input) else {
        fail("could not probe \(inputPath)")
    }
    let outputRate = OutputRatePolicy.default.resolve(source: info.frameRate).output
    let budget = InterpolationWidth.budget(sourceRate: info.frameRate)
    let perInterval = Double(outputRate.numerator) * Double(info.frameRate.denominator)
        / (Double(outputRate.denominator) * Double(info.frameRate.numerator))

    log("input   : \(inputPath)")
    log("format  : \(info.width)x\(info.height) \(info.format.bitDepth)-bit"
        + " \(info.frameRate) -> \(outputRate)")
    log(String(format: "budget  : %.2f ms per interval   (one interval of film time)", budget))
    log(String(format: "output  : %.2f frames per interval", perInterval))
    log(String(format: "probe   : %d intervals, warm-up 2, depth 2, start %.1f s",
               intervals, startSeconds))
    log("")
    log("  width     scaled        ms/interval   engine fps   vs budget   spare")
    for width in widths {
        let scaled = InterpolationWidth.scaled(info, toWidth: width)
        guard let m = try? PlaybackCalibrator.measure(
            url: input, info: info, sourceRate: info.frameRate, outputRate: outputRate,
            width: width, intervals: intervals, depth: 2, startSeconds: startSeconds) else {
            log(String(format: "  %5d     %4d x %-4d   unmeasurable",
                       width, scaled.width, scaled.height))
            continue
        }
        let engineFPS = 1000.0 / m.millisecondsPerInterval * perInterval
        log(String(format: "  %5d     %4d x %-4d   %7.2f       %6.1f       %5.2fx    %+7.2f ms",
                   width, scaled.width, scaled.height, m.millisecondsPerInterval,
                   engineFPS, budget / m.millisecondsPerInterval,
                   budget - m.millisecondsPerInterval))
    }
    exit(0)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--calibrate" {
    let inputPath = CommandLine.arguments[2]
    let input = URL(fileURLWithPath: inputPath)
    var startSeconds = 0.0
    // The shipping defaults, so the harness reports the decision the app would make. They are
    // overridable because the point of the harness is to be able to ask "what if".
    var intervals = 20
    var maximumProbes = 4
    var margin = 0.9

    let rest = Array(CommandLine.arguments.dropFirst(3))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--start":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else { fail("--start needs a number") }
            startSeconds = value
        case "--intervals":
            k += 1
            guard k < rest.count, let value = Int(rest[k]), value > 0 else {
                fail("--intervals needs a positive number")
            }
            intervals = value
        case "--probes":
            k += 1
            guard k < rest.count, let value = Int(rest[k]), value > 0 else {
                fail("--probes needs a positive number")
            }
            maximumProbes = value
        case "--margin":
            k += 1
            guard k < rest.count, let value = Double(rest[k]), value > 0 else {
                fail("--margin needs a positive number")
            }
            margin = value
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }

    guard let info = try? MediaProbe.probe(input) else {
        fail("could not probe \(inputPath)")
    }
    let outputRate = OutputRatePolicy.default.resolve(source: info.frameRate).output
    let budget = InterpolationWidth.budget(sourceRate: info.frameRate)
    let candidates = InterpolationWidth.candidates(sourceWidth: info.width)

    log("input   : \(inputPath)")
    log("format  : \(info.width)x\(info.height) \(info.format.bitDepth)-bit"
        + " \(info.frameRate) -> \(outputRate)")
    log(String(format: "budget  : %.2f ms per interval   (one interval of film time)", budget))
    log(String(format: "margin  : %.2f  ->  a rung must measure <= %.2f ms", margin, budget * margin))
    log("ladder  : \(candidates.map(String.init).joined(separator: " -> "))")

    // One interval of film time produces `perInterval` output frames, so the output rate a probe
    // can sustain is not its interval rate — it is that, times this. Printing the interval rate
    // alone invites reading 30/s as "30 fps" and concluding the rate is missed by half.
    let perInterval = Double(outputRate.numerator) * Double(info.frameRate.denominator)
        / (Double(outputRate.denominator) * Double(info.frameRate.numerator))
    log(String(format: "output  : %.2f frames per interval", perInterval))
    log("")

    var probed = 0
    let choice = PlaybackCalibrator.choose(candidates: candidates, budget: budget,
                                           margin: margin,
                                           maximumProbes: maximumProbes) { width in
        probed += 1
        let measurement = try? PlaybackCalibrator.measure(
            url: input, info: info, sourceRate: info.frameRate, outputRate: outputRate,
            width: width, intervals: intervals, depth: 2, startSeconds: startSeconds)
        guard let measurement else {
            log(String(format: "  probe %d   %4d wide                    unmeasurable",
                       probed, width))
            return nil
        }
        let fits = measurement.millisecondsPerInterval <= budget * margin
        let outputFPS = 1000.0 / measurement.millisecondsPerInterval * perInterval
        log(String(format: "  probe %d   %4d x %-4d  %7.2f ms/interval  %6.1f output fps"
                       + "  %4.2fx real time  %@",
                   probed, measurement.width, measurement.height,
                   measurement.millisecondsPerInterval,
                   outputFPS, budget / measurement.millisecondsPerInterval,
                   fits ? "fits" : "too slow"))
        return measurement.millisecondsPerInterval
    }

    let scaled = InterpolationWidth.scaled(info, toWidth: choice.width)
    log("")
    if let ms = choice.millisecondsPerInterval {
        log(String(format: "choice  : %d x %d   %.2f ms/interval   %.1f output fps"
                       + "   %.2fx real time   (%d probes)",
                   scaled.width, scaled.height, ms, 1000.0 / ms * perInterval,
                   budget / ms, choice.probes))
    } else {
        log(String(format: "choice  : %d x %d   FELL BACK (%d probes)",
                   scaled.width, scaled.height, choice.probes))
    }
    log("verdict : " + (choice.fellBack
        ? "no probed width holds the rate; the narrowest was taken"
        : "\(scaled.width) wide holds \(outputRate)"))
    exit(0)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--play" {
    let inputPath = CommandLine.arguments[2]
    let input = URL(fileURLWithPath: inputPath)
    var seconds = Double.infinity
    var outputRateText = "auto"
    var sceneDetection = true
    var depth = 2
    var withSound = false
    var startSeconds = 0.0
    var prepareOnly = false
    var displayCost = 0.0
    var policy = PlaybackResolutionPolicy.automatic

    let rest = Array(CommandLine.arguments.dropFirst(3))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--seconds":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else {
                fail("--seconds needs a number")
            }
            seconds = value
        case "--start":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else {
                fail("--start needs a number")
            }
            startSeconds = value
        case "--sound":
            withSound = true
        case "--prepare-only":
            prepareOnly = true
        case "--display-cost":
            k += 1
            guard k < rest.count, let value = Double(rest[k]), value >= 0 else {
                fail("--display-cost needs a non-negative number of milliseconds")
            }
            displayCost = value
        case "--rate":
            k += 1
            guard k < rest.count else { fail("--rate needs a value") }
            outputRateText = rest[k]
        case "--depth":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else { fail("--depth needs a number") }
            depth = value
        case "--no-scene-detect":
            sceneDetection = false
        case "--policy":
            k += 1
            guard k < rest.count,
                  let parsed = PlaybackResolutionPolicy(rawValue: rest[k]) else {
                fail("--policy needs one of "
                     + PlaybackResolutionPolicy.allCases.map(\.rawValue).joined(separator: "|"))
            }
            policy = parsed
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }

    guard let info = try? MediaProbe.probe(input) else {
        fail("could not probe \(inputPath)")
    }
    let outputRate: FrameRate
    if outputRateText.lowercased() == "auto" {
        outputRate = OutputRatePolicy.default.resolve(source: info.frameRate).output
    } else if let parsed = FrameRate.parse(outputRateText) {
        outputRate = parsed
    } else {
        fail("bad rate '\(outputRateText)'")
    }

    log("input  : \(inputPath)")
    log("format : \(info.width)x\(info.height) \(info.format.bitDepth)-bit \(info.pixelFormat)"
        + " \(info.frameRate) -> \(outputRate)")
    log("length : \(String(format: "%.1f", info.duration)) s")
    log("policy : \(policy.label)")
    if startSeconds > 0 {
        log(String(format: "start  : %.1f s", startSeconds))
    }

    // The soundtrack, if it was asked for. Prepared *before* the session is built, because
    // the clock is built over it — so there is nothing to attach it to afterwards.
    var audio: PlaybackAudio?
    if withSound {
        log("audio  : tracks the film states")
        for track in info.audioTracks {
            log("         \(track)\(track.isDefault ? "  [default]" : "")")
        }
        let plan = AudioPlaybackPlan.choose(
            for: info, containerIsPlayable: AudioPlaybackPlan.containerIsPlayable(input))
        log("         plan: \(plan)")
        if !plan.isLossless, plan.needsPreparation {
            log("         note: this disc has nothing macOS can decode, so the sound is")
            log("               re-encoded for playback — the batch converter's MKV output")
            log("               keeps the original bit for bit")
        }

        do {
            let extractor = AudioExtractor()
            let seen = LineCounter()
            let outcome = try extractor.prepare(from: input, info: info, progress: { value in
                seen.report(value)
            })
            log(String(format: "         %@ in %.2f s   %.1f MB%@",
                       outcome.fromCache ? "from cache" : "prepared",
                       outcome.wallSeconds, Double(outcome.bytes) / 1e6,
                       seen.summary))
            if prepareOnly {
                log("")
                log("[OK] the soundtrack is ready; nothing was played")
                exit(0)
            }
            audio = try waitForSound {
                try await PlaybackAudio(url: outcome.url, plan: outcome.plan)
            }
        } catch {
            fail("could not prepare the soundtrack: \(error)")
        }
    }

    let display = CountingDisplay(costMilliseconds: displayCost)
    if displayCost > 0 {
        log(String(format: "display: %.1f ms of simulated cost per frame", displayCost))
    }
    let controller = PlaybackController(
        url: input, display: display,
        configuration: .init(outputRate: outputRate, depth: depth,
                             sceneDetection: sceneDetection,
                             startSeconds: startSeconds,
                             resolutionPolicy: policy),
        info: info,
        audio: audio)

    do {
        try controller.start()
    } catch {
        fail("\(error)")
    }

    let started = DispatchTime.now().uptimeNanoseconds
    controller.play()

    // Run until the requested film time has passed, or the film ends. The clock is the
    // authority: this polls it rather than counting wall time, so what is measured is what
    // the player thinks happened.
    //
    // **The run loop, not a sleep.** AVFoundation delivers its readiness and playback
    // callbacks to the main queue, so a main thread that sleeps starves the very events that
    // make an audio item ready — measured: an item stuck at `.unknown` for three seconds with
    // `rate` reading 1.0 and the position pinned at zero. A SwiftUI app services the run loop
    // for free; a command-line tool has to say so.
    //
    // The trace is the point of the mode. A single number at the end cannot tell a constant
    // pipeline latency from a drift that accumulates, and those are different failures: the
    // first is a player working at its limit, the second is a player that will be seconds
    // out of sync by the end of a reel.
    // `--seconds` is a duration from wherever the run starts, not an absolute film time: with
    // `--start 60 --seconds 12` the clock is *already* at 60 when the loop begins, so comparing
    // against 12 ends the run before a frame is shown — measured, and it reported a film that
    // played 60 s of itself in 0.00 s of wall time.
    let stopAt = startSeconds + seconds
    var nextTrace = startSeconds + 5.0
    while controller.clock.state != .ended, controller.clock.mediaTime < stopAt {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let now = controller.clock.mediaTime
        if now >= nextTrace {
            let sample = display.stats
            let extra = audio.map { String(format: " | sound %6.2f s", $0.mediaTime) } ?? ""
            log(String(format: "  t=%6.1f s | picture %6.2f s | shown %4d | lag %5.0f ms%@",
                       now, sample.last ?? 0, sample.shown,
                       (now - (sample.last ?? 0)) * 1000, extra))
            nextTrace += 5
        }
    }

    let status = controller.status
    let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    let stats = display.stats
    let soundAtEnd = audio?.mediaTime
    controller.stop()

    let advanced = (stats.last ?? 0) - (stats.first ?? 0)
    let shown = stats.shown
    // The span this run actually covered. With a non-zero start the film's absolute position
    // is not the run's length, and dividing by it reports a player that covered 12 s of film
    // as running at 0.166× — measured, and it looked like a catastrophic failure rather than
    // the arithmetic of a seek.
    let span = status.position - startSeconds
    log("")
    log(String(format: "shown  : %d frames | skipped %d intervals",
               shown, status.skippedIntervals))
    log(String(format: "clock  : %.2f s of film in %.2f s wall  -> %.2fx",
               span, wall, wall > 0 ? span / wall : 0))
    log(String(format: "picture: %.2f s covered by %d frames -> %.1f fps presented",
               advanced, shown, wall > 0 ? Double(shown) / wall : 0))
    log(String(format: "first  : the first frame carried film time %.2f s",
               stats.first ?? 0))
    // Where the player *ended up*, which is not necessarily where it started: the rate watchdog
    // narrows the picture when the rate does not hold, and this is the only line that can show it.
    let size = controller.interpolationSize
    log(String(format: "size   : interpolated at %d x %d   (%@%@)",
               size.width, size.height, size.policy.label,
               size.calibrated ? ", calibrated" : ""))
    if let soundAtEnd {
        // With sound attached the clock *is* the sound, so this is the A/V relationship
        // itself rather than a coincidence: whatever the picture's last frame carries, the
        // sound is where the clock says the film is.
        log(String(format: "sound  : ended at %.2f s of film (%.2fx real time)",
                   soundAtEnd, wall > 0 ? soundAtEnd / wall : 0))
        log(String(format: "A/V    : picture %.0f ms behind the sound at the end",
                   (soundAtEnd - (stats.last ?? 0)) * 1000))
    }
    if !controller.problems.isEmpty {
        log("problems (\(controller.problems.count)):")
        for problem in controller.problems.prefix(10) { log("  " + problem) }
    }

    // The verdict, and the only one worth stating: does the picture keep up with the clock?
    //
    // Not the instantaneous lag — that oscillates by design, between about 90 ms and 270 ms,
    // because the renderer produces frames in bursts and the last frame handed over is
    // whatever the burst ended with. A single sample of it says nothing.
    //
    // What says everything is whether the picture *advanced* as fast as the clock did. A
    // constant latency is a player working at its limit; a rate below 1 is a player that
    // will be seconds out of sync by the end of a reel, and the two are one subtraction
    // apart.
    let pictureRate = span > 0 ? advanced / span : 0
    let lag = status.position - (stats.last ?? 0)
    var failures: [String] = []
    if pictureRate < 0.99 {
        failures.append(String(format: "the picture advanced only %.3fx the clock", pictureRate))
    }
    // The sound has to have actually played. A soundtrack that never started would leave the
    // clock pinned at zero and the picture at its first frame, and the trace above would look
    // like a film that simply did not run.
    if withSound, let soundAtEnd, soundAtEnd < status.position * 0.9 {
        failures.append(String(format: "the sound reached only %.2f s of %.2f",
                               soundAtEnd, status.position))
    }
    // A run that starts anywhere but zero must not begin with the playhead behind the
    // picture's own numbering — which is what a clock left at zero would do, and it shows as
    // minutes of black rather than as an error. Two frames of slack, because the seek lands on
    // the frame at or after the requested instant and the frame grid is not the second grid.
    if startSeconds > 0, let first = stats.first,
       abs(first - startSeconds) > 2 * (1 / info.frameRate.doubleValue) {
        failures.append(String(format: "asked to start at %.1f s but the first frame was %.2f s",
                               startSeconds, first))
    }
    let verdict = failures.isEmpty ? "PASS" : "FAIL"
    log(String(format: "[%@] the picture advanced %.3fx the clock's rate over %.1f s "
               + "(lag %.0f ms at the end, and not growing)",
               verdict, pictureRate, span, lag * 1000))
    for failure in failures { log("       \(failure)") }
    exit(verdict == "PASS" ? 0 : 1)
}

// ---------------------------------------------------------------- seek cost

/// How long a seek blocks its caller, and how long until the picture comes back.
///
/// A seek is not a move of the playhead: it tears the whole session down — both threads joined,
/// the decoder closed — and builds a new one, which means spawning ffmpeg and asking it to seek
/// into the file. **This is the number that decides whether a player freezes when the playhead is
/// grabbed**, because the app used to run this work on the main thread, which is where the window
/// is drawn.
///
/// And the cost is not a constant, because `FFmpegFrameSource` seeks with `-ss` **before** `-i`:
/// ffmpeg jumps to the keyframe at or before the target and then decodes forward to it. How far
/// back that keyframe is depends on where in the film the target happens to land — which is
/// exactly why the reported freeze is intermittent rather than every time. This mode puts a
/// number on it instead of a theory.
///
/// Since the fix, `seek` returns immediately and the rebuild runs on the controller's own session
/// queue, so the **blocked** column should read ~0 and the work shows up only in the **to first
/// frame** column. `--block` waits for the completion on a semaphore, which restores the old
/// synchronous behaviour and is how the before and after are compared on one machine.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--seek-cost" {
    let inputPath = CommandLine.arguments[2]
    let input = URL(fileURLWithPath: inputPath)

    var positions: [Double] = []
    var outputRateText = "auto"
    var depth = 2
    var settle = 1.5
    var timeout = 25.0
    var withSound = false
    var blockOnSeek = false

    let rest = Array(CommandLine.arguments.dropFirst(3))
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--at":
            k += 1
            guard k < rest.count else { fail("--at needs a comma-separated list") }
            positions = rest[k].split(separator: ",").compactMap { Double($0) }
        case "--sound":
            withSound = true
        case "--block":
            blockOnSeek = true
        case "--rate":
            k += 1
            guard k < rest.count else { fail("--rate needs a value") }
            outputRateText = rest[k]
        case "--depth":
            k += 1
            guard k < rest.count, let value = Int(rest[k]) else { fail("--depth needs a number") }
            depth = value
        case "--settle":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else { fail("--settle needs a number") }
            settle = value
        case "--timeout":
            k += 1
            guard k < rest.count, let value = Double(rest[k]) else { fail("--timeout needs a number") }
            timeout = value
        default:
            fail("unknown option '\(rest[k])'")
        }
        k += 1
    }
    guard !positions.isEmpty else { fail("--at needs at least one position") }

    guard let info = try? MediaProbe.probe(input) else { fail("could not probe \(inputPath)") }
    let outputRate: FrameRate
    if outputRateText.lowercased() == "auto" {
        outputRate = OutputRatePolicy.default.resolve(source: info.frameRate).output
    } else if let parsed = FrameRate.parse(outputRateText) {
        outputRate = parsed
    } else {
        fail("bad rate '\(outputRateText)'")
    }

    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    log("input  : \(inputPath)")
    log("format : \(info.width)x\(info.height) \(info.format.bitDepth)-bit \(info.frameRate) -> \(outputRate)")
    log("length : \(String(format: "%.1f", info.duration)) s")

    // The soundtrack, if asked for. A seek moves the sound *inside* `beginSession` and the move
    // is required to be synchronous, so with sound the seek does strictly more work on the
    // calling thread than without — and without sound this mode would report a smaller number
    // than the app produces.
    var audio: PlaybackAudio?
    if withSound {
        let plan = AudioPlaybackPlan.choose(
            for: info, containerIsPlayable: AudioPlaybackPlan.containerIsPlayable(input))
        log("audio  : \(plan)")
        do {
            let extractor = AudioExtractor()
            let outcome = try extractor.prepare(from: input, info: info, progress: { _ in })
            log(String(format: "         %@ in %.2f s",
                       outcome.fromCache ? "from cache" : "prepared", outcome.wallSeconds))
            audio = try waitForSound {
                try await PlaybackAudio(url: outcome.url, plan: outcome.plan)
            }
        } catch {
            fail("could not prepare the soundtrack: \(error)")
        }
    }
    log("")

    let display = CountingDisplay(costMilliseconds: 0)
    let controller = PlaybackController(
        url: input, display: display,
        configuration: .init(outputRate: outputRate, depth: depth,
                             sceneDetection: true, startSeconds: 0),
        info: info, audio: audio)
    do {
        try controller.start()
    } catch {
        fail("\(error)")
    }
    controller.play()

    log("  target s |  blocked ms | to first frame ms | played before")
    log("  ---------+-------------+-------------------+--------------")
    var blocks: [Double] = []
    var resumes: [Double] = []

    for target in positions {
        // Settle before *every* seek, not just the first. Measuring the next seek from the
        // previous seek's first frame measures a teardown with almost nothing in flight, which
        // is the easy case and not the one a user is in when they grab the playhead.
        let warm = Date().addingTimeInterval(settle)
        while Date() < warm { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        let playedBefore = controller.status.shown
        // The seek is asynchronous now, so what is measured here is the time the *caller* is held
        // — which is the freeze the app used to take on the main thread. `--block` restores the old
        // synchronous behaviour by waiting for the rebuild, so the two can be compared directly.
        let t0 = now()
        if blockOnSeek {
            let done = DispatchSemaphore(value: 0)
            controller.seek(to: target) { _ in done.signal() }
            done.wait()
        } else {
            controller.seek(to: target)
        }
        let blocked = (now() - t0) * 1000

        // The picture is back when the *new* session has presented its first frame. The
        // controller's own counter is the right one: a new session means a new presenter, so it
        // starts at zero and the first frame is the transition from 0 to 1.
        var toFirst: Double?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if controller.status.shown > 0 { toFirst = (now() - t0) * 1000; break }
        }
        blocks.append(blocked)
        if let toFirst { resumes.append(toFirst) }
        log(String(format: "  %8.1f | %11.0f | %17@ | %d",
                   target, blocked,
                   toFirst.map { String(format: "%.0f", $0) } ?? "TIMEOUT",
                   playedBefore))
    }

    controller.stop()

    let worstBlock = blocks.max() ?? 0
    let meanBlock = blocks.isEmpty ? 0 : blocks.reduce(0, +) / Double(blocks.count)
    let worstResume = resumes.max() ?? 0
    log("")
    log(String(format: "blocked the caller: mean %.1f ms, worst %.1f ms, over %d seeks",
               meanBlock, worstBlock, blocks.count))
    if !resumes.isEmpty {
        log(String(format: "picture was back:  mean %.0f ms, worst %.0f ms",
                   resumes.reduce(0, +) / Double(resumes.count), worstResume))
    }
    // Only when there is a block to talk about. Since the fix the caller is not held at all, and
    // the ratio of two sub-microsecond numbers is a real-looking figure that means nothing —
    // "worst block is 2.3x the mean" printed over a mean of 0.0004 ms.
    if meanBlock >= 1 {
        log(String(format: "spread: worst block is %.1fx the mean — a constant would be 1.0x",
                   worstBlock / meanBlock))
    } else {
        log("spread: n/a — the caller is not held, so there is nothing for the ratio to describe")
    }
    exit(0)
}

// ---------------------------------------------------------------- sound helpers

/// Waits for an async operation **without starving the main run loop**.
///
/// A semaphore here would be the obvious thing and the wrong one: `PlaybackAudio`'s initialiser
/// awaits `AVURLAsset.loadTracks`, whose continuation is delivered to the main queue — so
/// blocking the main thread waiting for it is waiting for a thread that is doing the waiting.
/// Measured in a standalone probe: `currentTime` pinned at 0.000 for three seconds.
func waitForSound<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = AsyncBox<T>()
    Task { box.store(await Result { try await work() }) }
    let deadline = Date().addingTimeInterval(30)
    while !box.isReady, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    guard let result = box.result else {
        throw InterpolatorError.writerFailed("the soundtrack did not open within 30 s")
    }
    return try result.get()
}

/// A result written by one task and read by another.
final class AsyncBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    func store(_ value: Result<T, Error>) { lock.lock(); stored = value; lock.unlock() }
    var result: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
    var isReady: Bool { result != nil }
}

/// Keeps the last progress value and how many there were, for one line of report.
final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private var count = 0

    func report(_ value: Double) { lock.lock(); last = value; count += 1; lock.unlock() }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return count == 0 ? "" : String(format: "   %d progress reports, last %.0f%%",
                                        count, last * 100)
    }
}

// ---------------------------------------------------------------- setup

let options = parseOptions()

guard let sourceRate = FrameRate.parse(options.sourceRate) else {
    fail("bad source rate '\(options.sourceRate)'")
}

// OUT_RATE is either a rate or the word `auto`. `auto` resolves through
// `OutputRatePolicy` — the same type the batch converter and the player will take —
// so the harness measures the decision that ships rather than a copy of it.
let outputRate: FrameRate
if options.outputRate.lowercased() == "auto" {
    let policy = options.ratePolicy ?? .default
    let resolution = policy.resolve(source: sourceRate)
    outputRate = resolution.output
    log("rate  : policy \(policy.label) -> \(resolution.output)"
        + (resolution.isPassthrough ? "  (already at target)" : ""))
    if let note = resolution.note { log("        \(note)") }
    log(String(format: "        %.4f%% of output frames are passthrough",
               resolution.passthroughFraction * 100))
} else {
    // A policy alongside an explicit rate would be silently ignored, which is the
    // kind of thing that produces a measurement nobody can account for later.
    if let policy = options.ratePolicy {
        fail("--rate-policy \(policy.label) was given with an explicit OUT_RATE "
             + "('\(options.outputRate)'); pass OUT_RATE=auto to let the policy decide")
    }
    guard let parsed = FrameRate.parse(options.outputRate) else {
        fail("bad output rate '\(options.outputRate)'")
    }
    outputRate = parsed
}

// Exact comparison, not `doubleValue`: 60000/1001 and 60/1 differ by 0.06 and the
// whole point of `FrameRate` is that this is not a rounding detail.
guard outputRate >= sourceRate else {
    fail("output rate \(outputRate) is below source rate \(sourceRate)")
}

let width = options.width
let height = options.height

// The sample width is a flag now, so the same binary drives the SDR and the HDR
// path. What this does *not* do is change the pixel format of the engine's own
// buffers — that comes from the same value, and the pool is built with it.
let format = options.format
let frameSize = format.packedByteSize(width: width, height: height)

// Packed input has no padding, so the luma stride is exactly the row length:
// `width` bytes at 8-bit, `width * 2` at 10-bit. That is *not* the same as the
// stride of a CVPixelBuffer's plane, which the pool pads — the two only coincide
// for 8-bit input.
let packedLumaStride = width * format.bytesPerSample

let inputDescriptor = open(options.input, O_RDONLY)
guard inputDescriptor >= 0 else { fail("cannot open \(options.input)") }
let inputBytes = lseek(inputDescriptor, 0, SEEK_END)
var sourceFrameCount = Int(inputBytes) / frameSize
if let cap = options.maxFrames { sourceFrameCount = min(sourceFrameCount, cap) }
guard sourceFrameCount >= 2 else {
    fail("need at least 2 source frames, found \(sourceFrameCount)")
}

log("input : \(sourceFrameCount) frames  \(width)x\(height)  \(frameSize) B/frame  "
    + "\(format.bitDepth)-bit")
log(String(format: "rates : %@ -> %@   (ratio %.6f)", "\(sourceRate)", "\(outputRate)",
           outputRate.doubleValue / sourceRate.doubleValue))

guard let plan = PhasePlan(sourceFrameCount: sourceFrameCount,
                           source: sourceRate, output: outputRate) else {
    fail("could not build a phase plan")
}

// ---------------------------------------------------------------- scene cuts

var staging = [UInt8](repeating: 0, count: frameSize)
var report = SceneChangeReport(isCut: [], histogramDistance: [], gridDistance: [],
                               threshold: [])
/// Problems found before the writer exists, folded into the failure report later.
var detectionProblems: [String] = []

if options.sceneDetect {
    // Signatures are fed to the online tracker *as they are computed*, so every run
    // over real footage doubles as an equivalence check. The two paths have to agree
    // exactly: batch uses the offline detector and playback uses the tracker, and a
    // disagreement would mean a cut handled one way when converting and another way
    // when watching. A synthetic test can only cover the shapes we thought of; real
    // film is where the ones we did not think of live.
    let tracker = SceneChangeTracker()
    var signatures: [FrameSignature] = []
    signatures.reserveCapacity(sourceFrameCount)
    for frame in 0..<sourceFrameCount {
        let got = staging.withUnsafeMutableBytes {
            pread(inputDescriptor, $0.baseAddress, frameSize, off_t(frame * frameSize))
        }
        guard got == frameSize else { shortRead(frame: frame, expected: frameSize, got: got) }
        let signature = staging.withUnsafeBytes {
            FrameSignature.compute(luma: $0.baseAddress!,
                                   format: format,
                                   width: width, height: height,
                                   bytesPerRow: packedLumaStride)
        }
        signatures.append(signature)
        tracker.push(signature)
    }
    tracker.finish()

    report = options.sceneMode == .offline
        ? SceneChangeDetector.detect(signatures: signatures)
        : tracker.report

    let online = tracker.report
    if online.isCut == report.isCut {
        log("scenes: \(report.cutCount) cut(s) in \(sourceFrameCount) frames"
            + (options.sceneMode == .offline
               ? "   [offline and online agree]" : "   [online tracker]"))
    } else {
        let differing = zip(online.isCut, report.isCut).enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map { "\($0.offset)" }
            .prefix(12)
            .joined(separator: ", ")
        log("scenes: \(report.cutCount) cut(s) in \(sourceFrameCount) frames")
        log("        [MISMATCH] the two detection paths disagree at intervals \(differing)")
        detectionProblems.append("scene detection mismatch between offline and online "
                                 + "at intervals \(differing)")
    }
    if !report.cutIntervals.isEmpty {
        let preview = report.cutIntervals.prefix(24).map { "\($0)-\($0 + 1)" }
        log("        between source frames: \(preview.joined(separator: ", "))"
            + (report.cutIntervals.count > 24 ? " ..." : ""))
    }

    if options.detectOnly {
        print("sourceFrameA\tsourceFrameB\thistogramDistance\tgridDistance\tthreshold\tverdict")
        for i in report.isCut.indices {
            print(String(format: "%d\t%d\t%.5f\t%.5f\t%.5f\t%@",
                         i, i + 1,
                         report.histogramDistance[i], report.gridDistance[i],
                         report.threshold[i],
                         report.isCut[i] ? "CUT" : ""))
        }
        exit(0)
    }
}

// ---------------------------------------------------------------- plan

let effectivePlan = (options.sceneDetect && report.cutCount > 0)
    ? plan.resolvingCuts(report)
    : plan

log("plan  : \(effectivePlan.outputFrameCount) out frames = "
    + "\(effectivePlan.interpolatedCount) interpolated + "
    + "\(effectivePlan.passthroughCount) passthrough")
if options.sceneDetect, report.cutCount > 0 {
    log("        \(plan.interpolatedCount - effectivePlan.interpolatedCount) of those "
        + "interpolations were turned into passthroughs by scene detection")
}

// ---------------------------------------------------------------- engine

/// One slot per in-flight request. A slot owns its buffers until the request that
/// borrowed them completes, and the next request to want that slot must wait.
///
/// It is NOT enough to rely on the engine's depth throttle. That throttle lives
/// inside submit(), which runs *after* the source frames have been loaded into the
/// slot, so slot (n % depth) can be refilled while request n - depth is still
/// reading it. VTFrameProcessor reads the source buffers asynchronously, so the
/// in-flight call then interpolates a mix of old and new frame data. The symptom
/// is subtle rather than obvious: a slow shot is barely wrong, a fast one is very
/// wrong, and the final interval is perfectly correct because nothing follows it
/// to clobber the buffers. Guard the slot explicitly instead.
///
/// The extracted `InterpolationPipeline` carries this same guard; it is duplicated
/// here only so the inline path can remain the reference the extraction is checked
/// against, byte for byte.
final class Slot {
    let a: CVPixelBuffer
    let b: CVPixelBuffer
    let destinations: [CVPixelBuffer]
    init(a: CVPixelBuffer, b: CVPixelBuffer, destinations: [CVPixelBuffer]) {
        self.a = a
        self.b = b
        self.destinations = destinations
    }
}

let outputDescriptor = open(options.output, O_RDWR | O_CREAT | O_TRUNC, 0o644)
guard outputDescriptor >= 0 else { fail("cannot create \(options.output)") }
let sink = PackedFileSink(descriptor: outputDescriptor, width: width, height: height,
                          format: format)

var submitted = 0
var wall = 0.0
// Hoisted out of the two paths so the report below reads the same either way.
var engineName = "InterpolationPipeline"
var engineDepth = options.depth

if options.pipeline {
    // ------------------------------------------------------------ extracted path
    //
    // The whole point of the extraction is that this is the code the app ships, so
    // running it here is not a test of the harness — it is a test of the shipping
    // loop, against the inline loop below, on real footage.
    do {
        let source = try PackedFileFrameSource(url: URL(fileURLWithPath: options.input),
                                               width: width, height: height,
                                               format: format, frameRate: sourceRate)
        let pipeline = InterpolationPipeline(
            source: source,
            sourceRate: sourceRate,
            outputRate: outputRate,
            configuration: .init(depth: options.depth,
                                 sceneDetection: options.sceneDetect,
                                 maximumSourceFrames: options.maxFrames,
                                 expectedOutputFrameCount: effectivePlan.outputFrameCount))
        let result = try pipeline.run(into: sink)
        submitted = result.engineCalls
        wall = result.wallSeconds
        log("source: \(result.sourceFrames) frames read, "
            + "\(result.engineCalls) engine calls, "
            + "\(result.outputFrames) output frames")

        for problem in result.problems { sink.record(problem) }

        // The pipeline detects cuts with the online tracker. The harness decided
        // them offline, over the whole clip, before the render started. Those two
        // have to agree — and this is the check that runs on real film rather than
        // on the shapes a synthetic test thought of.
        if options.sceneDetect {
            let online = result.decisions.map(\.isCut)
            if online == report.isCut {
                log("cuts  : pipeline's online tracker agrees with the offline "
                    + "detector on all \(online.count) intervals")
            } else {
                let differing = zip(online, report.isCut).enumerated()
                    .filter { $0.element.0 != $0.element.1 }
                    .map { "\($0.offset)" }
                    .prefix(12)
                    .joined(separator: ", ")
                log("cuts  : [MISMATCH] pipeline and offline detector disagree at "
                    + "intervals \(differing)")
                sink.record("pipeline/offline scene detection mismatch at \(differing)")
            }
        }
    } catch {
        fail("pipeline: \(error)")
    }
} else {
    // ------------------------------------------------------------ inline path
    //
    // The original loop, kept as the reference. `--pipeline` on the same input has
    // to reproduce this, which is what makes the extraction verifiable.
    let engine = VTFrameProcessorEngine(source: sourceRate, output: outputRate,
                                        depth: options.depth)
    do {
        try engine.prepare(width: width, height: height)
    } catch {
        fail("could not start the engine: \(error)")
    }

    log("engine: \(engine.name), depth \(engine.depth), up to "
        + "\(engine.maximumInterpolationsPerInterval) interpolations per interval")
    engineName = engine.name
    engineDepth = engine.depth

    let pool: PixelBufferPool
    var slots: [Slot] = []
    do {
        let capacity = engine.depth * (2 + engine.maximumInterpolationsPerInterval)
        pool = try PixelBufferPool(width: width, height: height, format: format,
                                   capacity: capacity)
        for _ in 0..<engine.depth {
            let destinations = try (0..<engine.maximumInterpolationsPerInterval).map { _ in
                try pool.makeBuffer()
            }
            slots.append(Slot(a: try pool.makeBuffer(), b: try pool.makeBuffer(),
                              destinations: destinations))
        }
    } catch {
        fail("could not allocate pipeline buffers: \(error)")
    }

    let started = DispatchTime.now().uptimeNanoseconds

    // The reference path gets the same bookkeeping as the pipeline, so a hole or a
    // frame past the end is reported here too rather than only on the new path.
    try? sink.begin(SinkGeometry(width: width, height: height, format: format,
                                 sourceRate: sourceRate, outputRate: outputRate,
                                 sourceFrameCount: sourceFrameCount,
                                 outputFrameCount: effectivePlan.outputFrameCount))

    // One semaphore per slot: acquired before a slot's buffers are touched, released
    // when the request that owns them completes.
    let slotFree = (0..<engine.depth).map { _ in DispatchSemaphore(value: 1) }

    for interval in effectivePlan.intervals {
        let slotIndex = submitted % engine.depth
        slotFree[slotIndex].wait()
        let slot = slots[slotIndex]

        var loadFailure: String?
        staging.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for (offset, buffer) in [(0, slot.a), (1, slot.b)] {
                let sourceIndex = interval.sourceIndex + offset
                let got = pread(inputDescriptor, base, frameSize,
                                off_t(sourceIndex * frameSize))
                guard got == frameSize else {
                    loadFailure = "short read at source frame \(sourceIndex): \(got)"
                    return
                }
                format.load(packed: base, into: buffer, width: width, height: height)
            }
        }
        if let loadFailure {
            sink.record(loadFailure)
            slotFree[slotIndex].signal()
            break
        }

        // Passthrough frames cost nothing and need no engine call at all. On
        // 23.976 -> 59.94 that is one output frame in five, free.
        for frame in interval.passthroughs {
            guard case .passthrough(let sourceIndex) = frame.kind else { continue }
            sink.write(sourceIndex == interval.sourceIndex ? slot.a : slot.b, at: frame.index)
        }

        let interpolations = interval.interpolations
        if interpolations.isEmpty {
            // Nothing to submit, so no completion will arrive to release the slot.
            slotFree[slotIndex].signal()
            continue
        }

        submitted += 1
        let destinations = Array(slot.destinations.prefix(interpolations.count))
        let destinationSet = BufferSet(buffers: destinations)
        let intervalIndex = interval.sourceIndex

        let request = InterpolationRequest(
            interval: interval,
            sourceA: slot.a,
            sourceB: slot.b,
            destinations: destinations
        ) { result in
            defer { slotFree[slotIndex].signal() }
            switch result {
            case .success:
                for (n, frame) in interpolations.enumerated()
                where n < destinationSet.buffers.count {
                    sink.write(destinationSet.buffers[n], at: frame.index)
                }
            case .failure(let error):
                sink.record("interval \(intervalIndex): \(error)")
            }
        }
        engine.submit(request)
    }

    do {
        try engine.drain()
    } catch {
        sink.record("engine drain: \(error)")
    }
    engine.shutdown()
    try? sink.finish()

    wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
}

ftruncate(outputDescriptor, off_t(effectivePlan.outputFrameCount * frameSize))
fsync(outputDescriptor)
close(outputDescriptor)
close(inputDescriptor)

// ---------------------------------------------------------------- verify

var passthroughChecks = 0
var passthroughMismatches = 0
let verifyDescriptor = open(options.output, O_RDONLY)
let sourceDescriptor = open(options.input, O_RDONLY)
if verifyDescriptor >= 0, sourceDescriptor >= 0 {
    var sourceBuffer = [UInt8](repeating: 0, count: frameSize)
    var outputBuffer = [UInt8](repeating: 0, count: frameSize)
    for frame in effectivePlan.frames where frame.isPassthrough {
        guard case .passthrough(let sourceIndex) = frame.kind else { continue }
        // Spot-check rather than check all of them; on a 2 h film this pass would
        // otherwise double the run time for no extra information.
        if frame.index % 37 != 0 { continue }
        let a = sourceBuffer.withUnsafeMutableBytes {
            pread(sourceDescriptor, $0.baseAddress, frameSize, off_t(sourceIndex * frameSize))
        }
        let b = outputBuffer.withUnsafeMutableBytes {
            pread(verifyDescriptor, $0.baseAddress, frameSize, off_t(frame.index * frameSize))
        }
        guard a == frameSize, b == frameSize else { continue }
        passthroughChecks += 1
        if sourceBuffer != outputBuffer { passthroughMismatches += 1 }
    }
}
if verifyDescriptor >= 0 { close(verifyDescriptor) }
if sourceDescriptor >= 0 { close(sourceDescriptor) }

// ---------------------------------------------------------------- report

let problems = sink.problems + detectionProblems
let written = sink.written

log("")
log(String(format: "RESULT %@ %dx%d %@ %@->%@ depth=%d | %d out frames | "
           + "%d interpolated | %d passthrough | %d cuts",
           engineName, width, height, "\(format.bitDepth)-bit",
           "\(sourceRate)", "\(outputRate)", engineDepth,
           effectivePlan.outputFrameCount, effectivePlan.interpolatedCount,
           effectivePlan.passthroughCount, report.cutCount))
log(String(format: "wall  : %.2fs | OUTPUT %6.1f fps | %6.2f ms/interval",
           wall, Double(effectivePlan.outputFrameCount) / wall,
           wall * 1000 / Double(max(submitted, 1))))

if !problems.isEmpty {
    log("FAILURES (\(problems.count)):")
    for problem in problems.prefix(10) { log("  " + problem) }
}
if passthroughChecks > 0 {
    let verdict = passthroughMismatches == 0 ? "PASS" : "FAIL"
    log("[\(verdict)] passthrough frames byte-identical to source "
        + "(\(passthroughChecks - passthroughMismatches)/\(passthroughChecks) sampled)")
}

let complete = written == effectivePlan.outputFrameCount && problems.isEmpty
log(complete ? "[PASS] wrote \(written)/\(effectivePlan.outputFrameCount) frames"
             : "[FAIL] wrote \(written)/\(effectivePlan.outputFrameCount) frames")
exit(complete ? 0 : 1)
