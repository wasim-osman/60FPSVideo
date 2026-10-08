import AVFoundation
import CoreVideo
import Foundation

// Can the production encode path carry HDR10 static metadata?
//
// This is the question that actually decides whether "do HDR properly" is
// deliverable. It is NOT the same question as "can ffmpeg encode HDR10", because
// the app will encode with VideoToolbox (AVAssetWriter / VTCompressionSession),
// not libx265 — and the two take completely different routes to the same SEI
// messages. ffmpeg's `-master_display` is a libx265 wrapper option and does not
// exist for hevc_videotoolbox, which is the first hint that this needs proving
// rather than assuming.
//
// So: encode real 10-bit P010 frames with the source's own HDR10 metadata,
// through AVAssetWriter, and report exactly what the writer accepted. Then
// ffprobe the result — the metadata either comes out the far end or it does not.
//
// usage: vt_hdr_encode IN.p010 OUT.mp4 W H [FRAMES]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ message: String) {
    print(message)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    fail("usage: vt_hdr_encode IN.p010 OUT.mp4 W H [FRAMES]")
}
let inputPath = args[0]
let outputPath = args[1]
guard let width = Int(args[2]), let height = Int(args[3]) else { fail("bad width/height") }
let frameCount = args.count > 4 ? (Int(args[4]) ?? 48) : 48

let format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
let frameBytes = width * height * 3

// ---------------------------------------------------------------- HDR10 metadata
//
// Taken verbatim from the source disc's SEI, so this is a real round trip and not
// a plausible-looking invention:
//
//   Mastering display metadata:
//     red   (34000/50000, 16000/50000)      green (13250/50000, 34500/50000)
//     blue  ( 7500/50000,  3000/50000)      white (15635/50000, 16450/50000)
//     min_luminance 50/10000 cd/m2   max_luminance 10000000/10000 cd/m2
//   Content light level: max_content 1000, max_average 221

/// The mastering-display SEI payload, 24 bytes, big-endian, in the order the
/// HEVC spec lists it: green, blue, red, white point, then the two luminances.
///
/// The luminances are the part worth getting right and the part easiest to get
/// wrong. They are in units of 0.0001 cd/m², so 1000 nits is 10,000,000 — not
/// 1000 — and the minimum is 50, meaning 0.005 nits. Writing the nits value
/// directly produces a display that claims to peak at 0.1 nits, which decoders
/// accept without complaint.
func masteringDisplayPayload() -> Data {
    var bytes: [UInt8] = []
    func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    func u32(_ v: UInt32) {
        bytes += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                  UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    // display_primaries: green, blue, red
    u16(13250); u16(34500)      // green x, y
    u16(7500);  u16(3000)       // blue  x, y
    u16(34000); u16(16000)      // red   x, y
    u16(15635); u16(16450)      // white point x, y
    u32(10_000_000)             // max luminance, 0.0001 cd/m2 -> 1000 nits
    u32(50)                     // min luminance, 0.0001 cd/m2 -> 0.005 nits
    return Data(bytes)
}

/// Content light level, 4 bytes: MaxCLL then MaxFALL, both uint16 nits.
func contentLightLevelPayload() -> Data {
    var bytes: [UInt8] = []
    func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    u16(1000)   // MaxCLL
    u16(221)    // MaxFALL
    return Data(bytes)
}

let mastering = masteringDisplayPayload()
let lightLevel = contentLightLevelPayload()
log("metadata: mastering display \(mastering.count) bytes, "
    + "content light level \(lightLevel.count) bytes")
log("          max luminance \(10_000_000) (= \(Double(10_000_000) * 0.0001) nits), "
    + "min \(50) (= \(Double(50) * 0.0001) nits)")
log("          MaxCLL 1000 nits, MaxFALL 221 nits")

// ---------------------------------------------------------------- read source

guard let inputHandle = FileHandle(forReadingAtPath: inputPath) else {
    fail("cannot open \(inputPath)")
}
let inputSize = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? Int) ?? 0
let available = inputSize / frameBytes
let frames = min(frameCount, available)
guard frames > 0 else { fail("\(inputPath) holds no whole frames") }
log("source  : \(available) frames available, encoding \(frames)")

// NOTE for the batch converter: on macOS 27 `AVAssetWriterInputPixelBufferAdaptor`
// and `AVAssetWriter.add(_:)` are deprecated in favour of
// `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)` and
// `inputReceiver(for:)`. The old calls still work, so this probe keeps them, but
// new code should use the receivers.

// A pool, not CVPixelBufferCreate per frame — invariant 2.
var pool: CVPixelBufferPool?
let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 8]
let bufferAttributes: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: format,
    kCVPixelBufferWidthKey: width,
    kCVPixelBufferHeightKey: height,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    kCVPixelBufferMetalCompatibilityKey: true,
]
guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                              bufferAttributes as CFDictionary, &pool) == kCVReturnSuccess,
      let pool else { fail("could not create the pixel buffer pool") }

func makeBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            == kCVReturnSuccess, let buffer else { fail("pool exhausted") }
    return buffer
}

/// Copy one packed P010 frame into `buffer`, respecting the plane strides.
func load(_ packed: UnsafeRawPointer, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let rowBytes = width * 2
    if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            memcpy(luma + row * stride, packed + row * rowBytes, rowBytes)
        }
    }
    if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let lumaBytes = width * height * 2
        for row in 0..<(height / 2) {
            memcpy(chroma + row * stride, packed + lumaBytes + row * rowBytes, rowBytes)
        }
    }
}

// ---------------------------------------------------------------- writer

try? FileManager.default.removeItem(atPath: outputPath)
let writer: AVAssetWriter
do {
    writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: outputPath), fileType: .mp4)
} catch {
    fail("could not create the asset writer: \(error)")
}

// The compression properties. The two metadata keys are VideoToolbox property
// keys passed through AVFoundation's dictionary — which is the whole question:
// whether AVFoundation forwards them, or silently drops what it does not know.
let compression: [String: Any] = [
    AVVideoAverageBitRateKey: 80_000_000,
    AVVideoExpectedSourceFrameRateKey: 60000.0 / 1001.0,
    AVVideoMaxKeyFrameIntervalKey: 60,
    // VideoToolbox keys, forwarded verbatim if AVFoundation plays along.
    kVTCompressionPropertyKey_MasteringDisplayColorVolume as String: mastering,
    kVTCompressionPropertyKey_ContentLightLevelInfo as String: lightLevel,
    kVTCompressionPropertyKey_ProfileLevel as String:
        kVTProfileLevel_HEVC_Main10_AutoLevel as String,
]

let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: compression,
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ],
]

let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: format,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
guard writer.canAdd(input) else { fail("the writer refused the HEVC input") }
writer.add(input)
guard writer.startWriting() else {
    fail("startWriting failed: \(writer.error?.localizedDescription ?? "no error given")")
}
writer.startSession(atSourceTime: .zero)

// ---------------------------------------------------------------- encode

var staging = [UInt8](repeating: 0, count: frameBytes)
var encoded = 0
let frameDuration = CMTime(value: 1001, timescale: 60000)

for index in 0..<frames {
    inputHandle.seek(toFileOffset: UInt64(index * frameBytes))
    let data = inputHandle.readData(ofLength: frameBytes)
    guard data.count == frameBytes else { fail("short read at frame \(index)") }
    data.copyBytes(to: &staging, count: frameBytes)

    let buffer = makeBuffer()
    staging.withUnsafeBytes { load($0.baseAddress!, into: buffer) }

    let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
    // Wait for the writer to be ready rather than dropping frames — this is an
    // offline encode, so there is nothing to gain by racing it.
    while !input.isReadyForMoreMediaData { usleep(1000) }
    if adaptor.append(buffer, withPresentationTime: time) {
        encoded += 1
    } else {
        fail("append failed at frame \(index): "
             + "\(writer.error?.localizedDescription ?? "no error given")")
    }
}
input.markAsFinished()

let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()

if writer.status != .completed {
    fail("finishWriting ended in \(writer.status.rawValue): "
         + "\(writer.error?.localizedDescription ?? "no error given")")
}

let outSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
log("encoded : \(encoded)/\(frames) frames -> \(outputPath) "
    + "(\((outSize ?? 0) / 1024) KiB)")
log("")
log("Now check whether the metadata survived: ffprobe -show_frames on the output.")
