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

/// Writes packed frames at their own file offsets.
///
/// `pwrite` at an explicit offset means completions may land in any order without
/// corrupting the stream, which matters because the engine's completions arrive on
/// its own threads. `@unchecked Sendable` is accurate: everything mutable is behind
/// `lock`.
final class OutputWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let width: Int
    private let height: Int
    private let format: FrameFormat
    private let frameSize: Int
    private let lock = NSLock()
    private var writtenCount = 0
    private var problemList: [String] = []

    init(descriptor: Int32, width: Int, height: Int, format: FrameFormat = .nv12) {
        self.descriptor = descriptor
        self.width = width
        self.height = height
        self.format = format
        self.frameSize = format.packedByteSize(width: width, height: height)
    }

    func write(_ buffer: CVPixelBuffer, at index: Int) {
        // Own staging buffer: completions can run concurrently, so this must not be
        // shared between them.
        var packed = [UInt8](repeating: 0, count: frameSize)
        packed.withUnsafeMutableBytes { raw in
            format.store(buffer: buffer, into: raw.baseAddress!,
                         width: width, height: height)
        }
        let wrote = packed.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress, frameSize, off_t(index * frameSize))
        }
        lock.lock()
        if wrote == frameSize {
            writtenCount += 1
        } else {
            problemList.append("short write at output frame \(index): \(wrote)")
        }
        lock.unlock()
    }

    func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }

    var written: Int {
        lock.lock(); defer { lock.unlock() }
        return writtenCount
    }

    var problems: [String] {
        lock.lock(); defer { lock.unlock() }
        return problemList
    }
}

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
    var format = FrameFormat.nv12
    var sceneMode = SceneMode.offline
    var depth = 2
    var maxFrames: Int? = nil
    var detectOnly = false
    var sceneDetect = true
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

        Rates accept an exact rational ("60000/1001") or the industry shorthand
        ("59.94"). The shorthand is mapped onto the exact NTSC rational, because
        "59.94" is a name for 60000/1001 and not a decimal value.

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
        default:
            fail("unknown option '\(args[i])'")
        }
        i += 1
    }
    return options
}

// ---------------------------------------------------------------- setup

let options = parseOptions()

guard let sourceRate = FrameRate.parse(options.sourceRate) else {
    fail("bad source rate '\(options.sourceRate)'")
}
guard let outputRate = FrameRate.parse(options.outputRate) else {
    fail("bad output rate '\(options.outputRate)'")
}
guard outputRate.doubleValue >= sourceRate.doubleValue else {
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

let outputDescriptor = open(options.output, O_RDWR | O_CREAT | O_TRUNC, 0o644)
guard outputDescriptor >= 0 else { fail("cannot create \(options.output)") }
let writer = OutputWriter(descriptor: outputDescriptor, width: width, height: height,
                          format: format)

let engine = VTFrameProcessorEngine(source: sourceRate, output: outputRate,
                                    depth: options.depth)
do {
    try engine.prepare(width: width, height: height)
} catch {
    fail("could not start the engine: \(error)")
}

log("engine: \(engine.name), depth \(engine.depth), up to "
    + "\(engine.maximumInterpolationsPerInterval) interpolations per interval")

// One slot per in-flight request. A slot owns its buffers until the request that
// borrowed them completes, and the next request to want that slot must wait.
//
// It is NOT enough to rely on the engine's depth throttle. That throttle lives
// inside submit(), which runs *after* the source frames have been loaded into the
// slot, so slot (n % depth) can be refilled while request n - depth is still
// reading it. VTFrameProcessor reads the source buffers asynchronously, so the
// in-flight call then interpolates a mix of old and new frame data. The symptom
// is subtle rather than obvious: a slow shot is barely wrong, a fast one is very
// wrong, and the final interval is perfectly correct because nothing follows it
// to clobber the buffers. Guard the slot explicitly instead.
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

// ---------------------------------------------------------------- run

let started = DispatchTime.now().uptimeNanoseconds
var submitted = 0

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
        writer.record(loadFailure)
        slotFree[slotIndex].signal()
        break
    }

    // Passthrough frames cost nothing and need no engine call at all. On
    // 23.976 -> 59.94 that is one output frame in five, free.
    for frame in interval.passthroughs {
        guard case .passthrough(let sourceIndex) = frame.kind else { continue }
        writer.write(sourceIndex == interval.sourceIndex ? slot.a : slot.b, at: frame.index)
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
                writer.write(destinationSet.buffers[n], at: frame.index)
            }
        case .failure(let error):
            writer.record("interval \(intervalIndex): \(error)")
        }
    }
    engine.submit(request)
}

do {
    try engine.drain()
} catch {
    writer.record("engine drain: \(error)")
}
engine.shutdown()

let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
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

let problems = writer.problems + detectionProblems
let written = writer.written

log("")
log(String(format: "RESULT %@ %dx%d %@ %@->%@ depth=%d | %d out frames | "
           + "%d interpolated | %d passthrough | %d cuts",
           engine.name, width, height, "\(format.bitDepth)-bit",
           "\(sourceRate)", "\(outputRate)", engine.depth,
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
