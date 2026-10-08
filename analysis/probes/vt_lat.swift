// Per-call latency probe. Emits one line per completed call so that a later
// teardown/race crash cannot destroy already-measured data.
// Usage: vtl W H normal|quality CALLS
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }

let args = CommandLine.arguments
guard args.count == 5, let W = Int(args[1]), let H = Int(args[2]), let N = Int(args[4]) else { exit(2) }
let q: VTFrameRateConversionConfiguration.QualityPrioritization = args[3] == "quality" ? .quality : .normal

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

guard let cfg = VTFrameRateConversionConfiguration(frameWidth: W, frameHeight: H, usePrecomputedFlow: false,
        qualityPrioritization: q, revision: VTFrameRateConversionConfiguration.defaultRevision) else { exit(1) }
let proc = VTFrameProcessor()
do { try proc.startSession(configuration: cfg) } catch { log("session FAIL \(error)"); exit(1) }

// ring of 6 to avoid IOSurface churn
var ring: [CVPixelBuffer] = []
for i in 0..<6 { if let b = mk(W,H) { fill(b,i); ring.append(b) } }
guard ring.count == 6 else { exit(1) }

let sem = DispatchSemaphore(value: 0)
for i in 0..<N {
    let A = ring[0], B = ring[1], D = ring[2]
    guard let s = VTFrameProcessorFrame(buffer: A, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 24)),
          let n = VTFrameProcessorFrame(buffer: B, presentationTimeStamp: CMTime(value: CMTimeValue(i+1), timescale: 24)),
          let d = VTFrameProcessorFrame(buffer: D, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 48)),
          let p = VTFrameRateConversionParameters(sourceFrame: s, nextFrame: n, opticalFlow: nil,
                interpolationPhase: [Float(0.5)], submissionMode: .sequential, destinationFrames: [d]) else { break }
    let t = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p) { _, _ in sem.signal() }
    guard sem.wait(timeout: .now() + 10) == .success else { log("TIMEOUT"); break }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    log("LAT \(ms)")
    fflush(stderr)
}
