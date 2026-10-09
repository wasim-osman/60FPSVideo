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

func parseOptions() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 6 else {
        FileHandle.standardError.write("""
        usage: interp-harness IN W H SRC_RATE OUT_RATE OUT [options]
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
        log("audio   : \(info.audioCodec ?? "none")"
            + (info.audioCanPassThroughToMP4 ? "" : "  (cannot be copied into MP4)"))
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
