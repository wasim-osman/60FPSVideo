// Pipelined (multi-in-flight) throughput probe.
//
// Hypothesis: a single VTFrameProcessor session is round-trip-latency-bound — it
// submits one call and blocks on the completion handler before submitting the
// next, leaving the accelerator idle during each handoff. Running N separate
// processes recovers the lost throughput. This probe tests whether ONE process
// can reach the same aggregate by keeping D requests in flight.
//
// Usage: vtofq W H SRC_FPS INTERVALS DEPTH [FMT]
//   DEPTH = 1 (lock-step, baseline) .. 8
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e6 }

let args = CommandLine.arguments
guard args.count >= 6, let W = Int(args[1]), let H = Int(args[2]),
      let srcFps = Double(args[3]), let intervals = Int(args[4]), let D = Int(args[5]) else {
    log("usage: vtofq W H SRC_FPS INTERVALS DEPTH [420v|64rgba]"); exit(2)
}
let fmtName = args.count > 6 ? args[6] : "420v"
// optional target rate: defaults to 60.000; pass 59.94 to test the NTSC target
let outFps = args.count > 7 ? (Double(args[7]) ?? 60.0) : 60.0
// 90000 is divisible by 24000/30000/60000/25/50, so it represents every common
// broadcast rate exactly, including the NTSC 1000/1001 rates.
let TS: Int32 = 90000
let fmt: OSType = fmtName == "64rgba" ? kCVPixelFormatType_64RGBAHalf
                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let isRGBA = fmt == kCVPixelFormatType_64RGBAHalf

func mk(_ w: Int, _ h: Int, _ f: OSType) -> CVPixelBuffer? {
    var b: CVPixelBuffer?
    let a: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: f,
        kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    return CVPixelBufferCreate(kCFAllocatorDefault, w, h, f, a as CFDictionary, &b) == kCVReturnSuccess ? b : nil
}
func fill(_ pb: CVPixelBuffer, _ s: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    if isRGBA {
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let p = base.assumingMemoryBound(to: UInt16.self)
        for y in 0..<h { for x in 0..<w {
            let o = (y * bpr / 2) + x * 4
            let v = UInt16(truncatingIfNeeded: ((x + s * 9) * 2 + y * 3) * 64)
            p[o + 0] = v; p[o + 1] = v / 2; p[o + 2] = v / 3; p[o + 3] = 0x3C00
        } }
        return
    }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { p[y * bpr + x] = UInt8(truncatingIfNeeded: (x + s * 9) * 2 + y * 3) } }
    }
    let cbr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
    if let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1), cbr > 0, ch > 0 { memset(cb, 128, ch * cbr) }
}
func px(_ pb: CVPixelBuffer, _ n: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let b = CVPixelBufferGetBaseAddressOfPlane(pb, 0) ?? CVPixelBufferGetBaseAddress(pb) else { return [] }
    return Array(UnsafeBufferPointer(start: b.assumingMemoryBound(to: UInt8.self), count: n))
}

// ---- phase plan
var phaseSets: [[Float]] = Array(repeating: [], count: intervals)
var totalOut = 0, passthrough = 0
let kMax = Int(Double(intervals) * outFps / srcFps) + 2
for k in 0..<kMax {
    let t = Double(k) * srcFps / outFps
    let j = Int(floor(t))
    if j >= intervals { break }
    let ph = Float(t - Double(j))
    totalOut += 1
    // eps matters: 23.976 -> 59.94 is mathematically an exact 2.5x ratio, but the
    // decimal approximations make the fractional part land on 0.9999999998 instead
    // of 0. Treat "within eps of 0 or 1" as a passthrough frame.
    if ph < 1e-6 || ph > 1 - 1e-6 { passthrough += 1; continue }
    phaseSets[j].append(ph)
}
let work = phaseSets.enumerated().filter { !$0.element.isEmpty }
let interpFrames = totalOut - passthrough

guard let cfg = VTFrameRateConversionConfiguration(frameWidth: W, frameHeight: H,
        usePrecomputedFlow: false, qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision) else { log("cfg nil"); exit(1) }
let proc = VTFrameProcessor()
do { try proc.startSession(configuration: cfg) } catch { log("session FAIL \(error)"); exit(1) }

let maxPhases = phaseSets.map { $0.count }.max() ?? 1
var srcSlots: [(CVPixelBuffer, CVPixelBuffer)] = []
var dstSlots: [[CVPixelBuffer]] = []
for _ in 0..<D {
    guard let a = mk(W, H, fmt), let b = mk(W, H, fmt) else { log("src alloc fail"); exit(1) }
    srcSlots.append((a, b))
    var ds: [CVPixelBuffer] = []
    // always allocate >=2 so the verification pass below can compare two phases
    for n in 0..<max(maxPhases, 2) { guard let d = mk(W, H, fmt) else { log("dst alloc fail"); exit(1) }; fill(d, 400 + n); ds.append(d) }
    dstSlots.append(ds)
}

log("== pipelined submission ==")
log("   \(W)x\(H) \(srcFps)->\(outFps) | \(work.count) calls | depth \(D) | \(maxPhases) max phases/call")
log("   \(totalOut) out frames = \(interpFrames) interpolated + \(passthrough) passthrough")

let done = DispatchSemaphore(value: 0)
var inFlight = 0, completed = 0, errors = 0
var firstCheck: String = "n/a"

let t0 = now()
for (idx, item) in work.enumerated() {
    if inFlight >= D { done.wait(); inFlight -= 1 }
    let (j, phases) = item
    let slot = idx % D
    let (A, B) = srcSlots[slot]
    fill(A, j); fill(B, j + 1)
    var dests: [VTFrameProcessorFrame] = []
    for n in 0..<phases.count {
        let d = dstSlots[slot][n]
        fill(d, 500 + n)
        let outPts = CMTime(value: CMTimeValue((Double(j * 3 + n) * Double(TS) / outFps).rounded()), timescale: TS)
        guard let df = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: outPts) else { break }
        dests.append(df)
    }
    let srcPtsA = CMTime(value: CMTimeValue((Double(j) * Double(TS) / srcFps).rounded()), timescale: TS)
    let srcPtsB = CMTime(value: CMTimeValue((Double(j + 1) * Double(TS) / srcFps).rounded()), timescale: TS)
    guard let s = VTFrameProcessorFrame(buffer: A, presentationTimeStamp: srcPtsA),
          let nx = VTFrameProcessorFrame(buffer: B, presentationTimeStamp: srcPtsB),
          dests.count == phases.count,
          let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: nx, opticalFlow: nil,
                interpolationPhase: phases, submissionMode: .sequential, destinationFrames: dests)
    else { log("params nil @\(j)"); break }

    proc.process(parameters: p) { _, err in
        if err != nil { errors += 1 }
        done.signal()
    }
    inFlight += 1

    if idx == 0 && phases.count >= 2 {
        // snapshot before completion; verified after the first drain below
        firstCheck = "pending"
    }
}
while inFlight > 0 { done.wait(); inFlight -= 1 }
let wall = Double(now() - t0) / 1e9

// correctness: re-run one call synchronously and confirm output differs per phase
do {
    let (A, B) = srcSlots[0]
    fill(A, 77); fill(B, 78)
    let d0 = dstSlots[0][0], d1 = dstSlots[0][1]
    fill(d0, 0); fill(d1, 0)
    if let s = VTFrameProcessorFrame(buffer: A, presentationTimeStamp: CMTime(value: 77, timescale: 24)),
       let n = VTFrameProcessorFrame(buffer: B, presentationTimeStamp: CMTime(value: 78, timescale: 24)),
       let f0 = VTFrameProcessorFrame(buffer: d0, presentationTimeStamp: CMTime(value: 0, timescale: 60)),
       let f1 = VTFrameProcessorFrame(buffer: d1, presentationTimeStamp: CMTime(value: 1, timescale: 60)),
       let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: n, opticalFlow: nil,
            interpolationPhase: [0.4, 0.8], submissionMode: .random, destinationFrames: [f0, f1]) {
        let s2 = DispatchSemaphore(value: 0)
        proc.process(parameters: p) { _, _ in s2.signal() }
        if s2.wait(timeout: .now() + 20) == .success {
            let a = px(d0, 64), b = px(d1, 64)
            let blank = Array(repeating: UInt8(0), count: 64)
            firstCheck = "phase0.4 vs phase0.8 differ=\(a != b)  written=\(a != blank)"
        } else { firstCheck = "verify timeout" }
    }
} catch { firstCheck = "verify failed" }

let outFrames = interpFrames + passthrough
log("   correctness      : \(firstCheck)")
log("   errors           : \(errors)")
log(String(format: "RESULT %dx%d %g->%g depth=%d | %d out frames | wall %.2fs | OUTPUT %6.1f fps | %6.2f ms/call",
    W, H, srcFps, outFps, D, outFrames, wall, Double(outFrames) / wall, wall * 1000 / Double(work.count)))
fflush(stderr)
