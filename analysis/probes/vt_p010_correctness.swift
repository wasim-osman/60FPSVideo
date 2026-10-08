// Is VTFrameProcessor's P010 output CORRECT, or merely written?
//
// vt_hdr_probe established that the processor accepts 10-bit P010 buffers and
// writes to them. That is necessary but not sufficient. VT fails silently in
// several ways — the async form of process() writes nothing, the low-latency path
// fails above 1080p without reporting an error, and a rejected format still lets
// startSession succeed — so "the destination buffer changed" does not prove the
// numbers in it are right.
//
// Method: feed two UNIFORM frames with known luma and interpolate at known
// phases. Uniform input makes the expected answer unambiguous — a linear blend of
// a and b at phase p is a + (b - a)·p, with no motion estimation to argue about.
// The same test runs on 8-bit NV12 as a control, so a failure can be attributed
// to 10-bit handling rather than to the test itself.
//
// P010 stores a 10-bit code in the TOP 10 bits of a 16-bit little-endian word, so
// the raw word is (code << 6) and must be shifted back down to be comparable.

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

let W = 1920, H = 1080
let TS: CMTimeScale = 90000

func log(_ m: String) { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }

func planeCount(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferIsPlanar(pb) ? max(CVPixelBufferGetPlaneCount(pb), 1) : 1
}

/// Geometry only — safe without locking.
func planeGeometry(_ pb: CVPixelBuffer, _ p: Int) -> (bpr: Int, height: Int) {
    if CVPixelBufferIsPlanar(pb) {
        return (CVPixelBufferGetBytesPerRowOfPlane(pb, p),
                CVPixelBufferGetHeightOfPlane(pb, p))
    }
    return (CVPixelBufferGetBytesPerRow(pb), CVPixelBufferGetHeight(pb))
}

/// **Only valid while the buffer is locked.**
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

/// Write a flat luma value and neutral chroma. `code` is the logical 10-bit or
/// 8-bit code value, not the raw stored word.
func fillFlat(_ pb: CVPixelBuffer, luma: Int, chroma: Int, tenBit: Bool) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    for p in 0..<planeCount(pb) {
        guard let base = planeBase(pb, p) else { continue }
        let (bpr, h) = planeGeometry(pb, p)
        let value = p == 0 ? luma : chroma
        if tenBit {
            let words = bpr / 2
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            for r in 0..<h {
                for c in 0..<words { ptr[r * words + c] = UInt16(value << 6) }
            }
        } else {
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for r in 0..<h { memset(ptr + r * bpr, Int32(value), bpr) }
        }
    }
}

func meanLuma(_ pb: CVPixelBuffer, tenBit: Bool) -> Double {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = planeBase(pb, 0) else { return .nan }
    let (bpr, h) = planeGeometry(pb, 0)
    var sum = 0.0
    if tenBit {
        let words = bpr / 2
        let ptr = base.assumingMemoryBound(to: UInt16.self)
        for r in 0..<h { for c in 0..<words { sum += Double(ptr[r * words + c] >> 6) } }
        return sum / Double(words * h)
    }
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    for r in 0..<h { for c in 0..<bpr { sum += Double(ptr[r * bpr + c]) } }
    return sum / Double(bpr * h)
}

// ---------------------------------------------------------------- run

struct Case {
    let label: String
    let format: OSType
    let a: Int          // luma of the first source frame
    let b: Int          // luma of the second source frame
    let chroma: Int     // neutral chroma for this bit depth
    let tenBit: Bool
}

let cases: [Case] = [
    Case(label: "8-bit NV12  (control)", format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         a: 50, b: 150, chroma: 128, tenBit: false),
    Case(label: "10-bit P010 (HDR)", format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         a: 200, b: 600, chroma: 512, tenBit: true),
]

let phases: [Float] = [0.25, 0.5, 0.75]

log("P010 correctness: does a known blend come out where linear interpolation says?")
log("\(W)x\(H)")
log("")

for c in cases {
    log("\(c.label)   source A luma=\(c.a)  source B luma=\(c.b)")

    guard let cfg = VTFrameRateConversionConfiguration(
        frameWidth: W, frameHeight: H, usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision) else {
        log("  configuration nil"); continue
    }

    // One fresh destination per phase, so results cannot be confused.
    guard let a = makeBuffer(c.format), let b = makeBuffer(c.format),
          let d0 = makeBuffer(c.format), let d1 = makeBuffer(c.format),
          let d2 = makeBuffer(c.format) else {
        log("  buffer allocation failed"); continue
    }
    let dests = [d0, d1, d2]

    fillFlat(a, luma: c.a, chroma: c.chroma, tenBit: c.tenBit)
    fillFlat(b, luma: c.b, chroma: c.chroma, tenBit: c.tenBit)
    for d in dests { fillFlat(d, luma: 0, chroma: 0, tenBit: c.tenBit) }

    let proc = VTFrameProcessor()
    do { try proc.startSession(configuration: cfg) } catch {
        log("  startSession failed: \(error)"); continue
    }

    guard let sf = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: TS)),
          let nf = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 3754, timescale: TS)) else {
        log("  source frame wrap failed"); continue
    }

    var destinationFrames: [VTFrameProcessorFrame] = []
    for (n, d) in dests.enumerated() {
        guard let df = VTFrameProcessorFrame(
            buffer: d,
            presentationTimeStamp: CMTime(value: CMTimeValue(1877 * (n + 1)), timescale: TS)) else { continue }
        destinationFrames.append(df)
    }

    guard let params = VTFrameRateConversionParameters(
        sourceFrame: sf, nextFrame: nf, opticalFlow: nil,
        interpolationPhase: phases, submissionMode: .sequential,
        destinationFrames: destinationFrames) else {
        log("  parameters rejected"); continue
    }

    let sem = DispatchSemaphore(value: 0)
    var errText = "no error"
    proc.process(parameters: params) { _, error in
        if let error { errText = "\(error)" }
        sem.signal()
    }
    sem.wait()

    var worst = 0.0
    for (n, d) in dests.enumerated() {
        let expected = Double(c.a) + (Double(c.b) - Double(c.a)) * Double(phases[n])
        let actual = meanLuma(d, tenBit: c.tenBit)
        let delta = actual - expected
        worst = max(worst, abs(delta))
        log(String(format: "  phase %.2f   expected %7.2f   actual %7.2f   delta %+7.2f",
                   Double(phases[n]), expected, actual, delta))
    }
    log(String(format: "  worst |delta| = %.2f   [%@]", worst, errText))
    log("")
}
