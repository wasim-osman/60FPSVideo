// Diagnostic: what does the optical flow processor require?
// Usage: vtofdiag W H
import Foundation
import VideoToolbox
import CoreVideo
func log(_ m: String) { FileHandle.standardError.write((m+"\n").data(using: .utf8)!) }

let args = CommandLine.arguments
let W = Int(args.count > 1 ? args[1] : "1920") ?? 1920
let H = Int(args.count > 2 ? args[2] : "1080") ?? 1080

log("== VTOpticalFlowConfiguration ==")
log("  isSupported            = \(VTOpticalFlowConfiguration.isSupported)")
log("  defaultRevision        = \(VTOpticalFlowConfiguration.defaultRevision.rawValue)")
log("  supportedRevisions     = \(VTOpticalFlowConfiguration.supportedRevisions)")

guard let cfg = VTOpticalFlowConfiguration(frameWidth: W, frameHeight: H,
        qualityPrioritization: .normal,
        revision: VTOpticalFlowConfiguration.defaultRevision) else {
    log("  cfg = nil  (dimensions rejected)"); exit(1)
}
log("  cfg ok  \(cfg.frameWidth)x\(cfg.frameHeight)")
log("  frameSupportedPixelFormats = \(cfg.__frameSupportedPixelFormats.map { $0.uint32Value })")
log("  sourcePixelBufferAttributes:")
for (k, v) in cfg.sourcePixelBufferAttributes { log("      \(k) = \(v)") }
log("  destinationPixelBufferAttributes:")
for (k, v) in cfg.destinationPixelBufferAttributes { log("      \(k) = \(v)") }

log("")
log("== VTFrameRateConversionConfiguration (usePrecomputedFlow: true) ==")
guard let fcfg = VTFrameRateConversionConfiguration(frameWidth: W, frameHeight: H,
        usePrecomputedFlow: true, qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision) else {
    log("  cfg = nil"); exit(1)
}
log("  usePrecomputedFlow = \(fcfg.usePrecomputedFlow)")
log("  frameSupportedPixelFormats = \(fcfg.__frameSupportedPixelFormats.map { $0.uint32Value })")

// Can both sessions actually start at the same time on this machine?
let p1 = VTFrameProcessor()
let p2 = VTFrameProcessor()
do { try p1.startSession(configuration: cfg); log("  flow session      : STARTED") }
catch { log("  flow session      : FAILED \(error)") }
do { try p2.startSession(configuration: fcfg); log("  frc(pre) session  : STARTED") }
catch { log("  frc(pre) session  : FAILED \(error)") }
p1.endSession(); p2.endSession()
log("  both sessions coexisted = yes (two VTFrameProcessor instances)")
fflush(stderr)
