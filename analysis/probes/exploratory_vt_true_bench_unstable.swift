// CORRECT benchmark for VTFrameRateConversion.
// Uses process(parameters:completionHandler:) + semaphore, because the Swift
// `async` overlay returns before the GPU work is done and never writes output.
// Usage: vttb W H normal|quality PAIRS
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }

let args = CommandLine.arguments
guard args.count == 5, let W = Int(args[1]), let H = Int(args[2]), let N = Int(args[4]) else { log("usage"); exit(2) }
let quality: VTFrameRateConversionConfiguration.QualityPrioritization = args[3] == "quality" ? .quality : .normal

func mk(_ w: Int, _ h: Int) -> CVPixelBuffer? {
    var b: CVPixelBuffer?
    let a: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    return CVPixelBufferCreate(kCFAllocatorDefault, w, h,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, a as CFDictionary, &b) == kCVReturnSuccess ? b : nil
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
        qualityPrioritization: quality, revision: VTFrameRateConversionConfiguration.defaultRevision) else { log("cfg nil"); exit(1) }
let proc = VTFrameProcessor()
let tS = DispatchTime.now().uptimeNanoseconds
do { try proc.startSession(configuration: cfg) } catch { log("session FAIL \(error)"); exit(1) }
let load = Double(DispatchTime.now().uptimeNanoseconds - tS) / 1e9

// Distinct buffers per pair, mirroring real decoder output.
var SRC: [CVPixelBuffer] = [], DST: [CVPixelBuffer] = []
for _ in 0...N { if let b = mk(W,H) { SRC.append(b) } }
for _ in 0..<N  { if let b = mk(W,H) { DST.append(b) } }
guard SRC.count == N+1, DST.count == N else { log("alloc short \(SRC.count)/\(DST.count)"); exit(1) }
for (i,b) in SRC.enumerated() { fill(b, i) }
for b in DST { fill(b, 99) }

let sem = DispatchSemaphore(value: 0)
var cbError: Error?
var lat: [Double] = []
var verified: Bool? = nil

for i in 0..<N {
    let A = SRC[i], B = SRC[i+1], D = DST[i]
    guard let s = VTFrameProcessorFrame(buffer: A, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 24)),
          let n = VTFrameProcessorFrame(buffer: B, presentationTimeStamp: CMTime(value: CMTimeValue(i+1), timescale: 24)),
          let d = VTFrameProcessorFrame(buffer: D, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 48)),
          let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: n, opticalFlow: nil,
                interpolationPhase: [Float(0.5)], submissionMode: .sequential, destinationFrames: [d])
    else { log("wrap nil @\(i)"); break }
    let before = px(D, 64)

    let t = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p) { _, err in cbError = err; sem.signal() }
    guard sem.wait(timeout: .now() + 10) == .success else { log("TIMEOUT @\(i)"); break }
    if i % 20 == 0 { log("    .. \(i)") }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    if let e = cbError { log("cb err @\(i): \(e)"); break }
    if i >= 5 { lat.append(ms) }

    if i == 0 {
        let after = px(D, 64)
        verified = (after != before) && (after != px(A,64)) && (after != px(B,64))
        log("  correctness @0: dstChanged=\(after != before)  interpolated=\(verified!)  sample=\(after.prefix(6))")
    }
}
if lat.isEmpty { log("no samples"); exit(1) }
let avg = lat.reduce(0,+)/Double(lat.count)
let sorted = lat.sorted()
let p50 = sorted[sorted.count/2], p95 = sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))]
log(String(format: "RESULT %-4dx%-5d %-8s | load %5.2fs | n=%3d | avg %6.2f ms  p50 %6.2f  p95 %6.2f | src %5.1f fps -> OUT %5.1f fps",
    W, H, args[3], load, lat.count, avg, p50, p95, 1000/avg, 2000/avg))
log("  (teardown follows; a crash here is post-measurement)")
proc.endSession()
log("  endSession OK")
fflush(stderr)
