// 60 fps output test.
// Simulates a real 24 fps source being converted to exactly 60 fps using the
// arbitrary-phase VTFrameRateConversion path, batching per source interval.
// Usage: vts60 W H SRC_FPS INTERVALS
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }

let args = CommandLine.arguments
guard args.count == 5, let W = Int(args[1]), let H = Int(args[2]),
      let srcFps = Int(args[3]), let intervals = Int(args[4]) else { log("usage: vts60 W H SRC_FPS INTERVALS"); exit(2) }
let outFps = 60

func mk(_ w: Int, _ h: Int) -> CVPixelBuffer? {
    var b: CVPixelBuffer?
    let a: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    return CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, a as CFDictionary, &b) == kCVReturnSuccess ? b : nil
}
func fill(_ pb: CVPixelBuffer, _ s: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    let w = CVPixelBufferGetWidthOfPlane(pb,0), h = CVPixelBufferGetHeightOfPlane(pb,0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb,0)
    if let base = CVPixelBufferGetBaseAddressOfPlane(pb,0) {
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { p[y*bpr+x] = UInt8(truncatingIfNeeded: (x+s*9)*2 + y*3) } }
    }
    let cbr = CVPixelBufferGetBytesPerRowOfPlane(pb,1), ch = CVPixelBufferGetHeightOfPlane(pb,1)
    if let cb = CVPixelBufferGetBaseAddressOfPlane(pb,1), cbr>0, ch>0 { memset(cb,128,ch*cbr) }
    CVPixelBufferUnlockBaseAddress(pb, [])
}
func px(_ pb: CVPixelBuffer, _ n: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let b = CVPixelBufferGetBaseAddressOfPlane(pb,0) else { return [] }
    return Array(UnsafeBufferPointer(start: b.assumingMemoryBound(to: UInt8.self), count: n))
}

guard let cfg = VTFrameRateConversionConfiguration(frameWidth: W, frameHeight: H, usePrecomputedFlow: false,
        qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision) else { log("cfg nil"); exit(1) }
let proc = VTFrameProcessor()
do { try proc.startSession(configuration: cfg) } catch { log("session FAIL \(error)"); exit(1) }

var ring: [CVPixelBuffer] = []
for i in 0..<8 { if let b = mk(W,H) { fill(b, i); ring.append(b) } }
guard ring.count == 8 else { log("alloc fail"); exit(1) }

// Phase pattern for srcFps -> 60: for output index k, phase = frac(k * srcFps / 60)
// Group by source interval j -> the set of phases needed between src[j] and src[j+1].
var phaseSets: [[Float]] = []
var totalOut = 0
var passthrough = 0
for k in 0..<(intervals * outFps / srcFps + 2) {
    let t = Double(k) * Double(srcFps) / Double(outFps)
    let j = Int(floor(t))
    let ph = Float(t - Double(j))
    if j >= intervals { break }
    if ph == 0 { totalOut += 1; passthrough += 1; continue }   // passthrough, no interpolation
    if phaseSets.count <= j { phaseSets.append([]) }
    while phaseSets.count <= j { phaseSets.append([]) }
    phaseSets[j].append(ph)
    totalOut += 1
}
log("  source \(srcFps) fps -> \(outFps) fps | \(intervals) source intervals")
log("  phase sets per interval: \(phaseSets.prefix(4).map { $0.map { String(format: "%.2f", $0) } })")
log("  output frames: \(totalOut) total = \(totalOut - passthrough) interpolated + \(passthrough) passthrough")

let sem = DispatchSemaphore(value: 0)
var calls = 0, produced = 0, firstPair: ([UInt8],[UInt8])? = nil
var lat: [Double] = []

let t0 = DispatchTime.now().uptimeNanoseconds
for (j, phases) in phaseSets.enumerated() where !phases.isEmpty {
    let A = ring[0], B = ring[1]
    fill(A, j); fill(B, j+1)
    var dests: [VTFrameProcessorFrame] = []
    var buffers: [CVPixelBuffer] = []
    for (n, _) in phases.enumerated() { buffers.append(ring[2 + n]) }
    for (n, b) in buffers.enumerated() { fill(b, 200 + n) }
    guard let s = VTFrameProcessorFrame(buffer: A, presentationTimeStamp: CMTime(value: CMTimeValue(j), timescale: CMTimeScale(srcFps))),
          let nx = VTFrameProcessorFrame(buffer: B, presentationTimeStamp: CMTime(value: CMTimeValue(j+1), timescale: CMTimeScale(srcFps)))
    else { log("wrap nil @\(j)"); break }
    for (n, b) in buffers.enumerated() {
        guard let d = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: CMTimeValue(j*3+n), timescale: 60)) else { break }
        dests.append(d)
    }
    guard dests.count == phases.count,
          let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: nx, opticalFlow: nil,
                interpolationPhase: phases, submissionMode: .sequential, destinationFrames: dests)
    else { log("params nil @\(j) (phases \(phases))"); break }

    let t = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p) { _, err in if err != nil { log("cb err: \(err!)") }; sem.signal() }
    guard sem.wait(timeout: .now() + 10) == .success else { log("TIMEOUT @\(j)"); break }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    calls += 1; produced += phases.count
    if j >= 4 { lat.append(ms) }

    // correctness: two different phases on the same source pair must differ
    if firstPair == nil && phases.count >= 2 {
        let p0 = px(buffers[0], 48), p1 = px(buffers[1], 48)
        firstPair = (p0, p1)
        log("  correctness: phase \(String(format: "%.2f", phases[0])) vs \(String(format: "%.2f", phases[1])) differ = \(p0 != p1)")
    }
}
let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
let avg = lat.isEmpty ? 0 : lat.reduce(0,+)/Double(lat.count)

// Sustained output fps: produced interpolated frames + passthrough frames over elapsed time
let outFrames = produced + passthrough
log(String(format: "RESULT %dx%d  %d->60fps | calls %d | interp frames %d | %.2fs | OUTPUT %6.1f fps | avg call %6.2f ms (2 frames/call)",
    W, H, srcFps, calls, produced, dt, Double(outFrames)/dt, avg))
log(String(format: "       60 fps required -> %@", Double(outFrames)/dt >= 60 ? "ACHIEVED" : String(format: "SHORT by %.0f%%", (60/(Double(outFrames)/dt) - 1)*100)))
fflush(stderr)
