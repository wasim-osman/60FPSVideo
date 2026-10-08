// Real-content renderer: raw NV12 in -> VTFrameProcessor -> raw NV12 out.
//
// This is the A/B instrument. Unlike vt_pipeline.swift (which synthesises frames
// to measure throughput), this reads actual decoded frames so the OUTPUT can be
// looked at. Everything it knows about VTFrameProcessor is the same:
//   - completion-handler form of process()   (the async form silently does nothing)
//   - depth-2 pipelining                     (depth 1 fails 23.976->60)
//   - 420YpCbCr8BiPlanarVideoRange           (native decode/encode format)
//   - explicit error checking                (the low-latency path fails silently)
//
// Output frames are pwrite()n at their own byte offset, so completions may land
// in any order without corrupting the stream.
//
// Usage: vtrender IN.nv12 W H SRC_FPS OUT_FPS OUT.nv12 [DEPTH] [MAXFRAMES]
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Darwin

func log(_ m: String) { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// Rates are accepted as an exact rational ("60000/1001") or as a decimal.
// EXACT RATES MATTER. 23.976 -> 59.94 is a 2.5x ratio exactly, so one output
// frame in five lands precisely on a source frame and needs no interpolation at
// all. Hand this a 6-decimal 59.94 instead of 60000/1001 and the phase drifts
// 4e-7 per frame, which is enough to lose every single one of them.
func parseRate(_ s: String) -> (Int, Int) {
    if let slash = s.firstIndex(of: "/") {
        let n = Int(s[s.startIndex..<slash]) ?? 1
        let d = Int(s[s.index(after: slash)...]) ?? 1
        return (n, d)
    }
    if let v = Double(s), v > 0 {
        return (Int((v * 1_000_000).rounded()), 1_000_000)
    }
    return (1, 1)
}

let args = CommandLine.arguments
guard args.count >= 7, let W = Int(args[2]), let H = Int(args[3]) else {
    log("usage: vtrender IN.nv12 W H SRC_RATE OUT_RATE OUT.nv12 [DEPTH] [MAXFRAMES]")
    log("       rates: decimal (59.94) or exact rational (60000/1001) - prefer rational")
    exit(2)
}
let (srcNum, srcDen) = parseRate(args[4])
let (outNum, outDen) = parseRate(args[5])
let srcFps = Double(srcNum) / Double(srcDen)
let outFps = Double(outNum) / Double(outDen)
let inPath = args[1], outPath = args[6]
let D = args.count > 7 ? (Int(args[7]) ?? 2) : 2
let maxFramesArg: Int? = args.count > 8 ? Int(args[8]) : nil

let frameSize = W * H * 3 / 2
let TS: Int32 = 90000
let fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

// ---------------------------------------------------------------- input
let fin = open(inPath, O_RDONLY)
guard fin >= 0 else { log("cannot open \(inPath)"); exit(1) }
let inBytes = lseek(fin, 0, SEEK_END)
var N = Int(inBytes) / frameSize
if let m = maxFramesArg, m < N { N = m }
guard N >= 2 else { log("need >= 2 frames, found \(N)"); exit(1) }
log("input : \(N) frames  \(W)x\(H)  \(frameSize) B/frame  src \(args[4]) -> out \(args[5])")

// ---------------------------------------------------------------- output
let fout = open(outPath, O_RDWR | O_CREAT | O_TRUNC, 0o644)
guard fout >= 0 else { log("cannot create \(outPath)"); exit(1) }

// ---------------------------------------------------------------- phase plan
// EXACT integer arithmetic, no epsilon.
//   t = k * (srcNum/srcDen) / (outNum/outDen)
//     = k * srcNum * outDen / (srcDen * outNum)
// An output frame is a pure passthrough when that ratio is an integer, i.e. when
// the remainder is exactly zero. For 23.976 -> 59.94 that happens every 5th
// frame: 20% of the output costs nothing.
struct OutFrame { let k: Int; let passSrc: Int; let phase: Float }   // passSrc: 0 = j, -1 = interpolate
var plan: [[OutFrame]] = Array(repeating: [], count: N)
var totalOut = 0, passthrough = 0, interpolated = 0
let pnum = srcNum * outDen
let pden = srcDen * outNum
let kMax = (N - 1) * pden / max(pnum, 1) + 8
for k in 0..<kMax {
    let t = k * pnum
    let j = t / pden
    if j >= N - 1 { break }
    let rem = t % pden
    if rem == 0 {
        plan[j].append(OutFrame(k: k, passSrc: 0, phase: 0)); totalOut += 1; passthrough += 1
    } else {
        plan[j].append(OutFrame(k: k, passSrc: -1, phase: Float(Double(rem) / Double(pden)))); totalOut += 1; interpolated += 1
    }
}
log("plan  : \(totalOut) out frames = \(interpolated) interpolated + \(passthrough) passthrough")

// ---------------------------------------------------------------- buffers
func mkBuf() -> CVPixelBuffer? {
    var b: CVPixelBuffer?
    let a: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: fmt,
        kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    return CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, a as CFDictionary, &b) == kCVReturnSuccess ? b : nil
}

var stage = [UInt8](repeating: 0, count: frameSize)   // main-thread only

// raw NV12 (unpadded) -> CVPixelBuffer (possibly padded rows)
//
// TRAP: for 420 biplanar, CVPixelBufferGetWidthOfPlane(pb,1) returns the CHROMA
// SAMPLE width (W/2 = 960), not the row length. The interleaved CbCr row is W
// bytes (bytesPerRow = 1920). Using the sample width as the copy length writes
// only half of every chroma row, which tiles into exactly the first H/4 rows and
// leaves the rest zeroed -> a solid green lower half. Always copy W bytes per row
// and use bytesPerRow as the stride.
func loadFrame(_ pb: CVPixelBuffer, index: Int) -> Bool {
    let off = off_t(index * frameSize)
    let got = stage.withUnsafeMutableBytes { pread(fin, $0.baseAddress, frameSize, off) }
    guard got == frameSize else { log("short read at frame \(index): \(got)"); return false }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    if let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        let d = yp.assumingMemoryBound(to: UInt8.self)
        stage.withUnsafeBufferPointer { s in
            let base = s.baseAddress!
            for r in 0..<H { memcpy(d + r * ybpr, base + r * W, W) }
        }
    }
    let ubpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    if let up = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
        let d = up.assumingMemoryBound(to: UInt8.self)
        let yOff = W * H
        stage.withUnsafeBufferPointer { s in
            let base = s.baseAddress!
            for r in 0..<(H / 2) { memcpy(d + r * ubpr, base + yOff + r * W, W) }
        }
    }
    return true
}

// CVPixelBuffer -> raw NV12 -> pwrite at this frame's own offset.
// Own staging buffer: completions can run concurrently, so this must not share.
func storeFrame(_ pb: CVPixelBuffer, index: Int) -> Bool {
    var buf = [UInt8](repeating: 0, count: frameSize)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let ubpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    buf.withUnsafeMutableBufferPointer { out in
        let o = out.baseAddress!
        if let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let s = yp.assumingMemoryBound(to: UInt8.self)
            for r in 0..<H { memcpy(o + r * W, s + r * ybpr, W) }
        }
        if let up = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let s = up.assumingMemoryBound(to: UInt8.self)
            let yOff = W * H
            for r in 0..<(H / 2) { memcpy(o + yOff + r * W, s + r * ubpr, W) }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    let off = off_t(index * frameSize)
    let wrote = buf.withUnsafeBytes { pwrite(fout, $0.baseAddress, frameSize, off) }
    return wrote == frameSize
}

// ---------------------------------------------------------------- session
guard let cfg = VTFrameRateConversionConfiguration(frameWidth: W, frameHeight: H,
        usePrecomputedFlow: false, qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision) else {
    log("config nil"); exit(1)
}
let proc = VTFrameProcessor()
do { try proc.startSession(configuration: cfg) } catch { log("startSession FAIL \(error)"); exit(1) }

let maxInterp = Int(ceil(outFps / srcFps)) + 2
final class Slot { let a: CVPixelBuffer; let b: CVPixelBuffer; let dst: [CVPixelBuffer]
    init(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ d: [CVPixelBuffer]) { self.a = a; self.b = b; self.dst = d } }
var slots: [Slot] = []
for _ in 0..<D {
    guard let a = mkBuf(), let b = mkBuf() else { log("src alloc fail"); exit(1) }
    var ds: [CVPixelBuffer] = []
    for _ in 0..<maxInterp { guard let d = mkBuf() else { log("dst alloc fail"); exit(1) }; ds.append(d) }
    slots.append(Slot(a, b, ds))
}

// ---------------------------------------------------------------- run
let sem = DispatchSemaphore(value: 0)
let lock = NSLock()
var inFlight = 0, errors = 0, completed = 0, lastErr = ""

let t0 = now()
var submitted = 0
for j in 0..<(N - 1) {
    let frames = plan[j]
    if frames.isEmpty { continue }
    if inFlight >= D { sem.wait(); inFlight -= 1 }
    let slot = slots[submitted % D]
    submitted += 1
    guard loadFrame(slot.a, index: j), loadFrame(slot.b, index: j + 1) else { break }

    var interp: [OutFrame] = []
    for f in frames {
        if f.passSrc >= 0 {
            let src = f.passSrc == 0 ? slot.a : slot.b
            if storeFrame(src, index: f.k) { completed += 1 }
        } else {
            interp.append(f)
        }
    }
    if interp.isEmpty { continue }

    var dests: [VTFrameProcessorFrame] = []
    var phases: [Float] = []
    for (n, f) in interp.enumerated() where n < slot.dst.count {
        let pts = CMTime(value: CMTimeValue((Double(f.k) * Double(outDen) * Double(TS) / Double(outNum)).rounded()), timescale: TS)
        if let df = VTFrameProcessorFrame(buffer: slot.dst[n], presentationTimeStamp: pts) {
            dests.append(df); phases.append(f.phase)
        }
    }
    guard dests.count == interp.count, !dests.isEmpty else { log("dest build fail @\(j)"); continue }

    let ptsA = CMTime(value: CMTimeValue((Double(j) * Double(srcDen) * Double(TS) / Double(srcNum)).rounded()), timescale: TS)
    let ptsB = CMTime(value: CMTimeValue((Double(j + 1) * Double(srcDen) * Double(TS) / Double(srcNum)).rounded()), timescale: TS)
    guard let s = VTFrameProcessorFrame(buffer: slot.a, presentationTimeStamp: ptsA),
          let nx = VTFrameProcessorFrame(buffer: slot.b, presentationTimeStamp: ptsB),
          let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: nx, opticalFlow: nil,
                interpolationPhase: phases, submissionMode: .sequential, destinationFrames: dests)
    else { log("params fail @\(j)"); continue }

    let ks = interp.map { $0.k }
    let bufs = interp.enumerated().map { slot.dst[$0.offset] }
    proc.process(parameters: p) { _, err in
        lock.lock()
        if let e = err { errors += 1; lastErr = "\(e)" }
        lock.unlock()
        for (n, k) in ks.enumerated() where n < bufs.count { _ = storeFrame(bufs[n], index: k) }
        lock.lock(); completed += 1; lock.unlock()
        sem.signal()
    }
    inFlight += 1
}
while inFlight > 0 { sem.wait(); inFlight -= 1 }
let wall = Double(now() - t0) / 1e9

ftruncate(fout, off_t(totalOut * frameSize))
fsync(fout)
close(fout)
close(fin)

let expected = interpolated + passthrough
log("output: \(outPath)")
// NB: `completed` counts VT CALLS (one per source interval, each yielding several
// frames) plus passthrough stores - not output frames.
log("calls : completed \(completed) / \(submitted) intervals + \(passthrough) passthrough  errors \(errors)")
if !lastErr.isEmpty { log("lastErr: \(lastErr)") }
log(String(format: "RESULT vtrender %dx%d %@->%@ depth=%d | %d out frames | wall %.2fs | OUTPUT %6.1f fps | %6.2f ms/call",
    W, H, args[4], args[5], D, totalOut, wall, Double(totalOut) / wall,
    wall * 1000 / Double(max(submitted, 1))))
fflush(stderr)
