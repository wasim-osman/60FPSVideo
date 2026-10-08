// Low-latency path test: 30 -> 60 fps (exact 2x, single phase 0.5).
// Usage: vtll W H CALLS
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }

let args = CommandLine.arguments
guard args.count == 4, let W = Int(args[1]), let H = Int(args[2]), let N = Int(args[3]) else { log("usage: vtll W H CALLS"); exit(2) }

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

guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: W, frameHeight: H, numberOfInterpolatedFrames: 1) else { log("cfg nil"); exit(1) }
let proc = VTFrameProcessor()
let tS = DispatchTime.now().uptimeNanoseconds
do { try proc.startSession(configuration: cfg) } catch { log("session FAIL \(error)"); exit(1) }
log(String(format: "  session start %.2fs | supported pixel formats %@", Double(DispatchTime.now().uptimeNanoseconds - tS)/1e9, "\(cfg.__frameSupportedPixelFormats)"))

var ring: [CVPixelBuffer] = []
for i in 0..<6 { if let b = mk(W,H) { fill(b, i); ring.append(b) } }
guard ring.count == 6 else { exit(1) }

let sem = DispatchSemaphore(value: 0)
let errLock = NSLock()
var produced = 0
var errors = 0
var lastErr = ""
var lat: [Double] = []
var verified = false

for i in 0..<N {
    let prev = ring[0], src = ring[1], dst = ring[2]
    fill(prev, i); fill(src, i+1)
    if i == 0 { fill(dst, 250) }
    let before = px(dst, 48)
    guard let pf = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30)),
          let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: CMTime(value: CMTimeValue(i+1), timescale: 30)),
          let df = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60)),
          let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: sf, previousFrame: pf,
                    interpolationPhase: [Float(0.5)], destinationFrames: [df])
    else { log("wrap nil @\(i)"); break }
    let t = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p) { _, err in
        if let e = err { errLock.lock(); errors += 1; lastErr = "\(e)"; errLock.unlock() }
        sem.signal()
    }
    guard sem.wait(timeout: .now() + 10) == .success else { log("TIMEOUT @\(i)"); break }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t)/1e6
    produced += 1
    if i >= 4 { lat.append(ms) }
    if !verified {
        let after = px(dst, 48)
        verified = after != before
        log("  correctness: destination written = \(verified)")
    }
}
if errors > 0 {
    log("FAIL low-latency \(W)x\(H): \(errors)/\(produced) calls errored | \(lastErr)")
    fflush(stderr)
    exit(3)
}
let avg = lat.isEmpty ? 0 : lat.reduce(0,+)/Double(lat.count)
let outFrames = produced * 2
let fps = Double(outFrames) / (Double(produced) * avg / 1000)
log(String(format: "RESULT low-latency %dx%d 30->60fps | calls %d | avg %6.2f ms | OUTPUT %6.1f fps | %@",
    W, H, produced, avg, fps, fps >= 60 ? "ACHIEVED" : String(format: "SHORT by %.0f%%", (60/fps - 1)*100)))
fflush(stderr)
