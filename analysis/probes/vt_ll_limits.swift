// Find the supported resolution ceiling for the low-latency frame interpolation path.
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }

let sizes = [(640,360),(1280,720),(1920,1080),(2048,1080),(2560,1440),(3840,2160),(4096,2160),(7680,4320)]
log("=== VTLowLatencyFrameInterpolationConfiguration resolution support ===")
log("  (init -> startSession -> process)")
for (w,h) in sizes {
    guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1) else {
        log(String(format: "  %4dx%-5d  config init = nil  -> UNSUPPORTED", w, h)); continue
    }
    let proc = VTFrameProcessor()
    var started = false, startErr: String? = nil
    do { try proc.startSession(configuration: cfg); started = true } catch { startErr = "\(error)" }
    if !started { log(String(format: "  %4dx%-5d  startSession FAILED: %@", w, h, startErr ?? "?")); continue }

    // try one real frame
    func mk(_ w:Int,_ h:Int)->CVPixelBuffer?{ var b:CVPixelBuffer?
        let a:[CFString:Any]=[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey:w,kCVPixelBufferHeightKey:h,kCVPixelBufferIOSurfacePropertiesKey:[:] as CFDictionary]
        return CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,a as CFDictionary,&b)==kCVReturnSuccess ? b:nil }
    guard let a = mk(w,h), let b2 = mk(w,h), let d = mk(w,h) else { log("  \(w)x\(h) alloc fail"); proc.endSession(); continue }
    for (pb,s) in [(a,0),(b2,1),(d,9)] {
        CVPixelBufferLockBaseAddress(pb,[]); let W2=CVPixelBufferGetWidthOfPlane(pb,0),H2=CVPixelBufferGetHeightOfPlane(pb,0),R=CVPixelBufferGetBytesPerRowOfPlane(pb,0)
        if let base=CVPixelBufferGetBaseAddressOfPlane(pb,0){let p=base.assumingMemoryBound(to:UInt8.self);for y in 0..<H2{for x in 0..<W2{p[y*R+x]=UInt8(truncatingIfNeeded:(x+s*9)*2+y*3)}}}
        CVPixelBufferUnlockBaseAddress(pb,[])
    }
    guard let pf = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value:0,timescale:30)),
          let sf = VTFrameProcessorFrame(buffer: b2, presentationTimeStamp: CMTime(value:1,timescale:30)),
          let df = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value:0,timescale:60)),
          let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: sf, previousFrame: pf, interpolationPhase: [Float(0.5)], destinationFrames: [df])
    else { log("  \(w)x\(h) wrap nil"); proc.endSession(); continue }
    let sem = DispatchSemaphore(value: 0)
    var err: Error?
    let t = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p) { _, e in err = e; sem.signal() }
    let ok = sem.wait(timeout: .now() + 15) == .success
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t)/1e6
    if let e = err {
        log(String(format: "  %4dx%-5d  process FAILED after %6.1f ms: %@", w, h, ms, "\(e)"))
    } else if ok {
        log(String(format: "  %4dx%-5d  OK   %7.2f ms  -> %.0f output fps (2x)", w, h, ms, 2000/ms))
    } else {
        log(String(format: "  %4dx%-5d  TIMEOUT", w, h))
    }
    proc.endSession()
}
fflush(stderr)
