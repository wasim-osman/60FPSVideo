// Does VTFrameProcessor accept 10-bit buffers, and which formats really work?
//
// The 8-bit shipping pipeline is hard-wired to
// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange because that is what
// VideoToolbox decodes to and encodes from. An HDR10 source is 10-bit, so doing
// HDR "properly" means staying 10-bit end to end — which means finding out
// whether the processor will take a 10-bit buffer at all.
//
// This probe does NOT trust `frameSupportedPixelFormats`. A previous probe found
// it misreports: it omits the 8-bit biplanar video-range format that is the
// native decode/encode format and the only one known to work. So the only
// trustworthy test is to run a real interpolation and check whether the
// destination buffer was actually written.
//
// The check matters because VT fails *silently*: startSession reports success, the
// completion handler reports no error, and the destination buffer is left exactly
// as it was. So the destination is pre-filled with a sentinel and we look for any
// byte that changed.
//
// Usage: vt_hdr_probe [WIDTH HEIGHT]

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

func log(_ m: String) { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }

let args = CommandLine.arguments
let W = args.count > 2 ? (Int(args[1]) ?? 1920) : 1920
let H = args.count > 2 ? (Int(args[2]) ?? 1080) : 1080

// ---------------------------------------------------------------- candidates

let candidates: [(String, OSType)] = [
    ("8-bit  420 biplanar video range  (NV12 - shipping)", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ("8-bit  420 biplanar full range", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    ("10-bit 420 biplanar video range  (P010)", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
    ("10-bit 420 biplanar full range", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
    ("8-bit  32BGRA", kCVPixelFormatType_32BGRA),
    ("8-bit  422 biplanar video range  (NV16)", kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
]

// ---------------------------------------------------------------- helpers

// TRAP: a CVPixelBuffer's base address is only valid *while the buffer is locked*.
// `CVPixelBufferGetBaseAddressOfPlane` returns nil otherwise — silently, with no
// error. Geometry (bytesPerRow / height) stays valid either way. Mixing the two
// makes a size computation return 0 and a "was it written?" check vacuously pass,
// which is exactly how the first version of this probe reported that every format
// failed when in fact none of them had been measured.
func planeCount(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferIsPlanar(pb) ? max(CVPixelBufferGetPlaneCount(pb), 1) : 1
}

/// Stride and height of plane `p`. Geometry only — safe to read without locking.
func planeGeometry(_ pb: CVPixelBuffer, _ p: Int) -> (bpr: Int, height: Int) {
    if CVPixelBufferIsPlanar(pb) {
        return (CVPixelBufferGetBytesPerRowOfPlane(pb, p),
                CVPixelBufferGetHeightOfPlane(pb, p))
    }
    return (CVPixelBufferGetBytesPerRow(pb), CVPixelBufferGetHeight(pb))
}

/// Base address of plane `p`. **Only valid while the buffer is locked.**
func planeBase(_ pb: CVPixelBuffer, _ p: Int) -> UnsafeMutableRawPointer? {
    if CVPixelBufferIsPlanar(pb) { return CVPixelBufferGetBaseAddressOfPlane(pb, p) }
    return p == 0 ? CVPixelBufferGetBaseAddress(pb) : nil
}

func makeBuffer(_ fmt: OSType) -> CVPixelBuffer? {
    var b: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: fmt,
        kCVPixelBufferWidthKey: W,
        kCVPixelBufferHeightKey: H,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt,
                              attrs as CFDictionary, &b) == kCVReturnSuccess else { return nil }
    return b
}

/// A moving diagonal ramp, so the two source frames differ and a real
/// interpolation has something to do.
func fillGradient(_ pb: CVPixelBuffer, phase: Float) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    for p in 0..<planeCount(pb) {
        guard let base = planeBase(pb, p) else { continue }
        let (bpr, hgt) = planeGeometry(pb, p)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for r in 0..<hgt {
            let rowBase = r * bpr
            for c in 0..<bpr {
                ptr[rowBase + c] = UInt8(truncatingIfNeeded:
                    Int(Float(c) * 0.35 + Float(r) * 0.15 + phase * 70))
            }
        }
    }
}

func fillSentinel(_ pb: CVPixelBuffer, _ value: UInt8) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    for p in 0..<planeCount(pb) {
        guard let base = planeBase(pb, p) else { continue }
        let (bpr, hgt) = planeGeometry(pb, p)
        memset(base, Int32(value), bpr * hgt)
    }
}

/// How many bytes still hold the sentinel value.
func sentinelCount(_ pb: CVPixelBuffer, _ value: UInt8) -> Int {
    var remaining = 0
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    for p in 0..<planeCount(pb) {
        guard let base = planeBase(pb, p) else { continue }
        let (bpr, hgt) = planeGeometry(pb, p)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let n = bpr * hgt
        for i in 0..<n where ptr[i] == value { remaining += 1 }
    }
    return remaining
}

/// Total addressable bytes across all planes. Geometry only, so no locking needed.
func totalBytes(_ pb: CVPixelBuffer) -> Int {
    var n = 0
    for p in 0..<planeCount(pb) {
        let (bpr, hgt) = planeGeometry(pb, p)
        n += bpr * hgt
    }
    return n
}

// ---------------------------------------------------------------- report config

log("VTFrameProcessor HDR / pixel-format probe   \(W)x\(H)")
log("")

guard let cfg = VTFrameRateConversionConfiguration(
    frameWidth: W, frameHeight: H,
    usePrecomputedFlow: false,
    qualityPrioritization: .normal,
    revision: VTFrameRateConversionConfiguration.defaultRevision
) else {
    log("FATAL: configuration returned nil for \(W)x\(H)")
    exit(1)
}

log("VTFrameRateConversionConfiguration.isSupported : \(VTFrameRateConversionConfiguration.isSupported)")
log("supportedRevisions                             : \(VTFrameRateConversionConfiguration.supportedRevisions)")
log("")
log("sourcePixelBufferAttributes      : \(cfg.sourcePixelBufferAttributes)")
log("destinationPixelBufferAttributes : \(cfg.destinationPixelBufferAttributes)")
log("")

/// Pixel formats are FourCCs, so print them as such — a bare hex number hides
/// what is being advertised.
func describe(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                 UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    let cc = String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    let known: String
    switch v {
    case kCVPixelFormatType_64RGBAHalf:
        known = " = kCVPixelFormatType_64RGBAHalf (64-bit RGBA half float)"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        known = " = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (NV12 video range)"
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        known = " = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange (P010 video range)"
    case kCVPixelFormatType_32BGRA:
        known = " = kCVPixelFormatType_32BGRA"
    default:
        known = ""
    }
    return String(format: "0x%08X '%@'%@", v, cc, known)
}

// `frameSupportedPixelFormats` is NS_REFINED_FOR_SWIFT, so it is unavailable under
// its ObjC name. Read it via KVC, but only after checking the selector exists —
// KVC on an unknown key raises an ObjC exception, which would abort the probe.
let selector = Selector(("frameSupportedPixelFormats"))
if cfg.responds(to: selector),
   let raw = cfg.value(forKey: "frameSupportedPixelFormats") as? [NSNumber] {
    let names = raw.map { describe($0.uint32Value) }
    log("frameSupportedPixelFormats (untrusted) : \(names.joined(separator: ", "))")
} else {
    log("frameSupportedPixelFormats : <not readable>")
}
log("")

// ---------------------------------------------------------------- run

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

let ts: CMTimeScale = 90000
log(pad("format", 50) + pad("buffers", 10) + pad("session", 10) + "destination written")
log(String(repeating: "-", count: 96))

var working: [String] = []

for (name, fmt) in candidates {
    guard let a = makeBuffer(fmt), let b = makeBuffer(fmt), let d = makeBuffer(fmt) else {
        log(pad(name, 50) + pad("FAIL", 10) + pad("-", 10) + "buffer allocation failed")
        continue
    }
    fillGradient(a, phase: 0)
    fillGradient(b, phase: 1)
    fillSentinel(d, 0xCD)

    let proc = VTFrameProcessor()
    do {
        try proc.startSession(configuration: cfg)
    } catch {
        log(pad(name, 50) + pad("ok", 10) + pad("FAIL", 10) + "\(error)")
        continue
    }

    guard let sf = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: ts)),
          let nf = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 3754, timescale: ts)),
          let df = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: 1877, timescale: ts)),
          let params = VTFrameRateConversionParameters(
            sourceFrame: sf, nextFrame: nf, opticalFlow: nil,
            interpolationPhase: [0.5], submissionMode: .sequential,
            destinationFrames: [df])
    else {
        log(pad(name, 50) + pad("ok", 10) + pad("ok", 10) + "parameters rejected")
        continue
    }

    let sem = DispatchSemaphore(value: 0)
    var reported = "no error"
    proc.process(parameters: params) { _, error in
        if let error { reported = "\(error)" }
        sem.signal()
    }
    sem.wait()

    let total = totalBytes(d)
    let left = sentinelCount(d, 0xCD)
    let percent = Double(total - left) / Double(max(total, 1)) * 100
    let verdict: String
    if total == 0 {
        verdict = "MEASUREMENT FAILED - zero bytes addressable"
    } else if percent > 50 {
        // The synthetic ramp passes through every byte value, so even a perfect
        // write leaves ~1/256 of the output coincidentally equal to the sentinel.
        // A real write therefore reads as ~99.6%, never 100%.
        verdict = String(format: "YES - %.2f%% of bytes written", percent)
        working.append(name)
    } else if percent > 1 {
        verdict = String(format: "PARTIAL - only %.2f%% written", percent)
    } else {
        let why = reported == "no error" ? "" : " [\(reported)]"
        verdict = "NO - untouched\(why)"
    }

    log(pad(name, 50) + pad("ok", 10) + pad("ok", 10) + verdict)
}

log("")
if working.isEmpty {
    log("RESULT: no candidate format produced output.")
} else {
    log("RESULT: formats that genuinely work at \(W)x\(H):")
    for w in working { log("        - \(w)") }
}
