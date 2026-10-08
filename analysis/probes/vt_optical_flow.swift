// Pre-computed optical flow A/B probe.
//
//   MODE = otf   : on-the-fly flow (baseline; identical to vt_60fps.swift)
//   MODE = pre   : dedicated VTOpticalFlow session -> feed flow into FRC session
//   MODE = flow  : measure ONLY the optical flow session (no interpolation)
//
// Usage: vtof W H SRC_FPS INTERVALS MODE FMT
//   FMT = 420v | 64rgba
//
// Phases are batched per source interval: one process() call per source pair,
// carrying every interpolated phase that falls inside that pair.
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e6 }

let args = CommandLine.arguments
guard args.count == 7, let W = Int(args[1]), let H = Int(args[2]),
      let srcFps = Int(args[3]), let intervals = Int(args[4]) else {
    log("usage: vtof W H SRC_FPS INTERVALS otf|pre|flow 420v|64rgba"); exit(2)
}
let mode = args[5]
let fmtName = args[6]
let outFps = 60

let fmt: OSType = fmtName == "64rgba" ? kCVPixelFormatType_64RGBAHalf
                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let isRGBA = fmt == kCVPixelFormatType_64RGBAHalf

// ---------------------------------------------------------------- buffers
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
        // 4 x UInt16 (half) per pixel; R carries the pattern so content varies per frame
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let p = base.assumingMemoryBound(to: UInt16.self)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * bpr / 2) + x * 4
                let v = UInt16(truncatingIfNeeded: ((x + s * 9) * 2 + y * 3) * 64)
                p[o + 0] = v          // R
                p[o + 1] = v / 2      // G
                p[o + 2] = v / 3      // B
                p[o + 3] = 0x3C00     // A = 1.0 in half
            }
        }
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

// ---------------------------------------------------------------- phase plan
var phaseSets: [[Float]] = Array(repeating: [], count: intervals)
var totalOut = 0, passthrough = 0
let kMax = intervals * outFps / srcFps + 2
for k in 0..<kMax {
    let t = Double(k) * Double(srcFps) / Double(outFps)
    let j = Int(floor(t))
    if j >= intervals { break }
    let ph = Float(t - Double(j))
    totalOut += 1
    if ph == 0 { passthrough += 1; continue }     // coincides with a source frame
    phaseSets[j].append(ph)
}
let interpCalls = phaseSets.filter { !$0.isEmpty }.count
let interpFrames = totalOut - passthrough

log("== pre-computed optical flow A/B ==")
log("   \(W)x\(H)  \(srcFps) -> \(outFps) fps  |  fmt \(fmtName)")
log("   \(intervals) source intervals -> \(totalOut) output frames = \(interpFrames) interpolated + \(passthrough) passthrough")
log("   \(interpCalls) process() calls, avg \(String(format: "%.2f", Double(interpFrames) / Double(max(interpCalls,1)))) phases/call")

// ---------------------------------------------------------------- sessions
var flowProc: VTFrameProcessor? = nil
var flowDstW = 0, flowDstH = 0, flowDstFmt: OSType = 0

if mode == "pre" || mode == "flow" {
    guard let fcfg = VTOpticalFlowConfiguration(frameWidth: W, frameHeight: H,
            qualityPrioritization: .normal,
            revision: VTOpticalFlowConfiguration.defaultRevision) else { log("flow cfg nil"); exit(1) }
    let da = fcfg.destinationPixelBufferAttributes
    flowDstW = (da[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? (W / 8)
    flowDstH = (da[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? (H / 8)
    flowDstFmt = (da[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? 0
    log("   flow field: \(flowDstW)x\(flowDstH) fmt \(flowDstFmt)")
    let p = VTFrameProcessor()
    do { try p.startSession(configuration: fcfg) } catch { log("flow session FAIL \(error)"); exit(1) }
    flowProc = p
}

guard let frcCfg = VTFrameRateConversionConfiguration(frameWidth: W, frameHeight: H,
        usePrecomputedFlow: mode == "pre", qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision) else { log("frc cfg nil"); exit(1) }
let frcProc = VTFrameProcessor()
if mode != "flow" {
    do { try frcProc.startSession(configuration: frcCfg) } catch { log("frc session FAIL \(error)"); exit(1) }
}

// ---------------------------------------------------------------- rings
let RING = 8
var srcRing: [CVPixelBuffer] = []
for i in 0..<RING { if let b = mk(W, H, fmt) { fill(b, i); srcRing.append(b) } }
guard srcRing.count == RING else { log("src alloc fail"); exit(1) }

var dstRing: [CVPixelBuffer] = []
let maxPhases = phaseSets.map { $0.count }.max() ?? 1
for i in 0..<max(RING, maxPhases + 2) { if let b = mk(W, H, fmt) { fill(b, 200 + i); dstRing.append(b) } }
guard dstRing.count >= maxPhases + 1 else { log("dst alloc fail"); exit(1) }

var flowRing: [(CVPixelBuffer, CVPixelBuffer)] = []
if mode == "pre" || mode == "flow" {
    for _ in 0..<RING {
        guard let fwd = mk(flowDstW, flowDstH, flowDstFmt),
              let bwd = mk(flowDstW, flowDstH, flowDstFmt) else { log("flow alloc fail"); exit(1) }
        flowRing.append((fwd, bwd))
    }
}

// ---------------------------------------------------------------- run
let sem = DispatchSemaphore(value: 0)
var flowMs = 0.0, frcMs = 0.0, wall0 = now()
var flowCalls = 0, frcCalls = 0, interpProduced = 0
var correctness = "n/a"
var rr = 0

for (j, phases) in phaseSets.enumerated() where !phases.isEmpty {
    let A = srcRing[j % RING], B = srcRing[(j + 1) % RING]
    fill(A, j); fill(B, j + 1)

    guard let s = VTFrameProcessorFrame(buffer: A, presentationTimeStamp: CMTime(value: CMTimeValue(j), timescale: CMTimeScale(srcFps))),
          let nx = VTFrameProcessorFrame(buffer: B, presentationTimeStamp: CMTime(value: CMTimeValue(j + 1), timescale: CMTimeScale(srcFps)))
    else { log("wrap nil @\(j)"); break }

    // ---- optical flow pass
    var flowObj: VTFrameProcessorOpticalFlow? = nil
    if mode == "pre" || mode == "flow" {
        let (fwd, bwd) = flowRing[rr % RING]; rr += 1
        guard let of = VTFrameProcessorOpticalFlow(forwardFlow: fwd, backwardFlow: bwd) else { log("flow obj nil"); break }
        guard let fp = VTOpticalFlowParameters(sourceFrame: s, nextFrame: nx,
                submissionMode: .sequential, destinationOpticalFlow: of) else {
            log("flow params nil @\(j)  <-- pixel format rejected by optical flow processor"); break
        }
        let t0 = now()
        flowProc!.process(parameters: fp) { _, err in
            if let e = err { log("flow cb err: \(e)") }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 20) == .success else { log("flow TIMEOUT @\(j)"); break }
        flowMs += ms(t0, now()); flowCalls += 1
        flowObj = of
    }

    if mode == "flow" { continue }

    // ---- interpolation pass
    var dests: [VTFrameProcessorFrame] = []
    var dstBufs: [CVPixelBuffer] = []
    for n in 0..<phases.count {
        let d = dstRing[n]
        fill(d, 300 + n)
        dstBufs.append(d)
        guard let df = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: CMTimeValue(j * 3 + n), timescale: 60)) else { break }
        dests.append(df)
    }
    guard dests.count == phases.count,
          let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: nx, opticalFlow: flowObj,
                interpolationPhase: phases, submissionMode: .sequential, destinationFrames: dests)
    else { log("frc params nil @\(j)"); break }

    let t1 = now()
    frcProc.process(parameters: p) { _, err in
        if let e = err { log("frc cb err: \(e)") }
        sem.signal()
    }
    guard sem.wait(timeout: .now() + 20) == .success else { log("frc TIMEOUT @\(j)"); break }
    frcMs += ms(t1, now()); frcCalls += 1; interpProduced += phases.count

    if correctness == "n/a" && phases.count >= 2 {
        let p0 = px(dstBufs[0], 64), p1 = px(dstBufs[1], 64)
        let changed = px(dstBufs[0], 64) != Array(repeating: UInt8(0), count: 64)
        correctness = "phases \(String(format: "%.3f", phases[0])) vs \(String(format: "%.3f", phases[1])) differ=\(p0 != p1) nonBlank=\(changed)"
    }
}

let wall = Double(now() - wall0) / 1e9
let outFrames = interpProduced + passthrough

log("")
log("  correctness      : \(correctness)")
log(String(format: "  flow pass        : %d calls  %8.2f ms total  %6.2f ms/pair  %6.2f ms/frame-out", flowCalls, flowMs, flowCalls > 0 ? flowMs/Double(flowCalls) : 0, flowMs/Double(max(outFrames,1))))
log(String(format: "  interp pass      : %d calls  %8.2f ms total  %6.2f ms/pair  %6.2f ms/frame-out", frcCalls, frcMs, frcCalls > 0 ? frcMs/Double(frcCalls) : 0, frcMs/Double(max(outFrames,1))))
log(String(format: "  combined         : %8.2f ms total  |  wall %.2fs", flowMs + frcMs, wall))
log("")
log(String(format: "RESULT %dx%d %d->60  mode=%-4@ | %d out frames | wall %.2fs | OUTPUT %6.1f fps | 60 fps %@",
    W, H, srcFps, mode, outFrames, wall, Double(outFrames) / wall,
    Double(outFrames) / wall >= 60 ? "ACHIEVED" : String(format: "SHORT by %.0f%%", (60 / (Double(outFrames) / wall) - 1) * 100)))
fflush(stderr)
