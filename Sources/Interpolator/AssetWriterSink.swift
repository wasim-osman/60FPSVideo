import AVFoundation
import CoreVideo
import Foundation

/// What the encoder is told before the first frame arrives.
///
/// Every field here has to be set before the first sample is appended, which is why
/// it is a value assembled up front rather than something the sink discovers as it
/// goes. The colour tags and the HDR10 payloads in particular are **not** inferable
/// from the pixels: an HEVC Main10 encode with no mastering-display metadata is a
/// valid file that players have to guess about (invariant 21).
public struct VideoEncodeSettings: Sendable {

    /// Target bit rate. This is the one field here that is a *guess* rather than a
    /// measurement — see ``defaultBitRate(width:height:rate:)``.
    public var bitRate: Int
    public var maxKeyFrameInterval: Int
    public var profileLevel: String?

    /// AVFoundation's colour tag constants, already mapped from ffprobe's names.
    /// `nil` means "the source did not say", and the tag is then omitted rather than
    /// guessed — a wrong colour tag is worse than a missing one, because a player
    /// will faithfully apply it.
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var yCbCrMatrix: String?

    /// The 24-byte mastering-display SEI payload, or `nil` for SDR.
    public var masteringDisplay: Data?
    /// The 4-byte content-light-level payload, or `nil`.
    public var contentLightLevel: Data?

    public init(bitRate: Int,
                maxKeyFrameInterval: Int = 60,
                profileLevel: String? = nil,
                colorPrimaries: String? = nil,
                transferFunction: String? = nil,
                yCbCrMatrix: String? = nil,
                masteringDisplay: Data? = nil,
                contentLightLevel: Data? = nil) {
        self.bitRate = bitRate
        self.maxKeyFrameInterval = maxKeyFrameInterval
        self.profileLevel = profileLevel
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
    }

    /// Build the settings for a job from what the source actually is.
    ///
    /// This is the whole point of probing the file rather than trusting the pixels:
    /// the colour tags and the HDR10 metadata come out of the container and go back
    /// in unchanged, so the output is tagged the way the input was.
    public static func forSource(_ info: MediaInfo, bitRate: Int? = nil) -> VideoEncodeSettings {
        var settings = VideoEncodeSettings(
            bitRate: bitRate ?? defaultBitRate(width: info.width, height: info.height,
                                               rate: info.frameRate),
            profileLevel: info.format == .p010
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : nil,
            colorPrimaries: avColorPrimaries(info.colorPrimaries),
            transferFunction: avTransferFunction(info.transferFunction),
            yCbCrMatrix: avYCbCrMatrix(info.colorSpace))
        // Invariant 21: never written unless asked for, and only ever the payloads the
        // source itself carried. A zeroed mastering display is a *valid* payload
        // claiming black, so "absent" and "zero" must not be conflated.
        settings.masteringDisplay = info.masteringDisplay?.seiPayload
        settings.contentLightLevel = info.contentLightLevel?.seiPayload
        return settings
    }

    /// A bit rate for a given resolution and rate.
    ///
    /// **This is a starting point, not a measurement.** Nothing in this project has
    /// measured the rate at which HEVC loses visible detail on interpolated frames,
    /// and interpolated frames are not the same problem as camera-captured ones — the
    /// synthesised detail is lower in high-frequency content, so the usual
    /// bits-per-pixel rules are pessimistic. The coefficient below is deliberately
    /// generous for that reason, and it should be replaced with a measurement rather
    /// than tuned by taste.
    public static func defaultBitRate(width: Int, height: Int, rate: FrameRate) -> Int {
        let bitsPerPixelPerFrame = 0.12
        let raw = Double(width * height) * rate.doubleValue * bitsPerPixelPerFrame
        return max(8_000_000, Int(raw))
    }

    /// The `AVVideoCompressionPropertiesKey` dictionary.
    var compressionProperties: [String: Any] {
        var properties: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoMaxKeyFrameIntervalKey: maxKeyFrameInterval,
        ]
        if let profileLevel { properties[kVTCompressionPropertyKey_ProfileLevel as String] = profileLevel }
        // Invariant 21: the VideoToolbox keys are what actually carry HDR10 metadata
        // through an AVFoundation encode. ffmpeg's `-master_display` is a libx265-only
        // option and does not exist for hevc_videotoolbox, so there is no way to check
        // this path with ffmpeg — it has to be verified by reading the output back.
        if let masteringDisplay {
            properties[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String]
                = masteringDisplay
        }
        if let contentLightLevel {
            properties[kVTCompressionPropertyKey_ContentLightLevelInfo as String]
                = contentLightLevel
        }
        return properties
    }

    /// `nil` when any tag is unknown, so a partial set is never applied — the colour
    /// properties are a single dictionary and AVFoundation wants all three.
    var colorProperties: [String: Any]? {
        guard let colorPrimaries, let transferFunction, let yCbCrMatrix else { return nil }
        return [
            AVVideoColorPrimariesKey: colorPrimaries,
            AVVideoTransferFunctionKey: transferFunction,
            AVVideoYCbCrMatrixKey: yCbCrMatrix,
        ]
    }

    // MARK: - ffprobe names to AVFoundation constants
    //
    // ffprobe reports the short names from the H.273 enum; AVFoundation wants its own
    // string constants. An unrecognised name maps to nil, which omits the tag.

    static func avColorPrimaries(_ name: String?) -> String? {
        switch name {
        case "bt709": return AVVideoColorPrimaries_ITU_R_709_2
        case "bt2020": return AVVideoColorPrimaries_ITU_R_2020
        case "smpte432": return AVVideoColorPrimaries_P3_D65
        case "bt470bg", "smpte170m": return AVVideoColorPrimaries_ITU_R_709_2
        default: return nil
        }
    }

    static func avTransferFunction(_ name: String?) -> String? {
        switch name {
        case "bt709": return AVVideoTransferFunction_ITU_R_709_2
        case "smpte2084": return AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case "arib-std-b67": return AVVideoTransferFunction_ITU_R_2100_HLG
        case "bt470bg", "smpte170m": return AVVideoTransferFunction_ITU_R_709_2
        default: return nil
        }
    }

    /// Note `bt2020nc` and `bt2020c` both map to the same AVFoundation constant: the
    /// framework has no separate constant for constant-luminance, so a source tagged
    /// `bt2020c` is re-tagged as non-constant. That is a real (if narrow) loss, and it
    /// is recorded rather than hidden.
    static func avYCbCrMatrix(_ name: String?) -> String? {
        switch name {
        case "bt709": return AVVideoYCbCrMatrix_ITU_R_709_2
        case "bt2020nc", "bt2020c": return AVVideoYCbCrMatrix_ITU_R_2020
        case "smpte170m", "bt470bg": return AVVideoYCbCrMatrix_ITU_R_601_4
        default: return nil
        }
    }
}

/// Writes output frames into an HEVC MP4.
///
/// ## The two things that make this more than a loop
///
/// **Frames arrive out of order and concurrently** (the `FrameSink` contract), but an
/// `AVAssetWriterInput` takes samples in order. So the sink holds frames in a
/// dictionary keyed by index and releases them in sequence, which means a frame can sit
/// here while an earlier one is still in flight.
///
/// **That delay is why the sink copies.** The pipeline reuses its destination buffers
/// as soon as a completion returns — that is deliberate, it is how invariant 17 keeps
/// the pool small — so a buffer handed to `write` may be overwritten by the pipeline
/// before the writer has looked at it. Appending asynchronously without owning the
/// pixels would produce frames that are correct on a slow shot and torn on a fast one.
/// The copy is one plane-wise `memcpy` per frame, against an HEVC encode that is orders
/// of magnitude more expensive, and it buys the sink independence from the producer's
/// buffer lifetimes — which the display sink will need for exactly the same reason.
///
/// ## The deprecated calls
///
/// `AVAssetWriterInputPixelBufferAdaptor` and `AVAssetWriter.add(_:)` are deprecated as
/// of macOS 27 in favour of `inputPixelBufferReceiver(for:pixelBufferAttributes:)`. The
/// replacement is **not** a drop-in: it takes `CVReadOnlyPixelBuffer` and consumes it
/// with `sending` ownership, which belongs to CoreVideo's typed-buffer API introduced
/// in macOS 26. Adopting it means moving the whole pipeline to `CVMutablePixelBuffer`,
/// and it would raise the deployment target from 15.4 to 26. Neither is a change to
/// make as a side effect of writing a sink, so the deprecated pair is used and confined
/// to ``makeAdaptor(input:format:)``. They are deprecated, not removed, and the
/// measurement in `vt_hdr_encode.swift` confirms they still carry HDR10 metadata
/// byte-exact.
public final class AssetWriterSink: FrameSink, @unchecked Sendable {

    private let url: URL
    private let settings: VideoEncodeSettings
    private let lock = NSLock()
    private let appendQueue = DispatchQueue(label: "60fpsvideo.assetwriter.append")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var copyPool: PixelBufferPool?
    private var outputRate: FrameRate?
    private var width = 0
    private var height = 0
    private var format = FrameFormat.nv12

    /// Frames waiting for their turn. Bounded in practice by the pipeline's depth,
    /// which is 2 requests with at most a few interpolations each.
    private var pending: [Int: CVPixelBuffer] = [:]
    private var nextIndex = 0
    private var appendedCount = 0
    private var problemList: [String] = []
    private var isFinishing = false
    private var markedFinished = false

    public init(url: URL, settings: VideoEncodeSettings) {
        self.url = url
        self.settings = settings
    }

    // MARK: - FrameSink

    public func begin(_ geometry: SinkGeometry) throws {
        width = geometry.width
        height = geometry.height
        format = geometry.format
        outputRate = geometry.outputRate

        // The presentation timescale is the output rate's numerator, so a frame's time
        // is `index * denominator / numerator` with no rounding at all. For 60000/1001
        // that is a timescale of 60000 and 1001 ticks per frame: exact, and it is the
        // reason the rate has to be a rational rather than 59.94.
        guard geometry.outputRate.numerator <= Int(Int32.max) else {
            throw InterpolatorError.writerFailed(
                "output rate \(geometry.outputRate) has a numerator too large for CMTime")
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var compression = settings.compressionProperties
        compression[AVVideoExpectedSourceFrameRateKey] = geometry.outputRate.doubleValue
        var settingsDictionary: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colorProperties = settings.colorProperties {
            settingsDictionary[AVVideoColorPropertiesKey] = colorProperties
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settingsDictionary)
        // Offline: there is nothing to gain by racing the encoder, and letting it drop
        // frames would be silent data loss.
        input.expectsMediaDataInRealTime = false

        let adaptor = makeAdaptor(input: input, format: format)

        guard writer.canAdd(input) else {
            throw InterpolatorError.writerFailed("the writer refused the HEVC input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw InterpolatorError.writerFailed(
                "startWriting failed: \(writer.error?.localizedDescription ?? "no error given")")
        }
        writer.startSession(atSourceTime: .zero)

        // A pool for the sink's own copies, not for the pipeline's frames. Four is
        // enough to cover the reorder buffer without holding memory the encoder is
        // already holding.
        copyPool = try PixelBufferPool(width: width, height: height, format: format,
                                       capacity: 4)

        lock.lock()
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        lock.unlock()
    }

    /// The one place the deprecated pair is used. See the type's documentation.
    private func makeAdaptor(input: AVAssetWriterInput,
                             format: FrameFormat) -> AVAssetWriterInputPixelBufferAdaptor {
        AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: format.pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
    }

    public func write(_ buffer: CVPixelBuffer, at index: Int) {
        // Copy first, so the pipeline is free to reuse the original the moment this
        // returns. Everything after this point works on pixels the sink owns.
        let owned: CVPixelBuffer
        do {
            owned = try copy(of: buffer)
        } catch {
            record("could not copy output frame \(index): \(error)")
            return
        }

        lock.lock()
        if pending[index] != nil {
            problemList.append("output frame \(index) written twice")
        }
        pending[index] = owned
        lock.unlock()

        appendQueue.async { [weak self] in self?.drain() }
    }

    public func finish() throws {
        lock.lock()
        isFinishing = true
        lock.unlock()

        // Flush the kicks that were queued before this call.
        appendQueue.sync {}

        // Anything still pending is waiting on either an earlier frame or encoder
        // backpressure. Neither can be resolved by waiting for a callback, so pump
        // until the queue empties. Bounded, because a frame that never arrives is a
        // bug we want reported rather than hung on.
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        while true {
            lock.lock()
            let remaining = pending.count
            lock.unlock()
            if remaining == 0 { break }
            if DispatchTime.now().uptimeNanoseconds > deadline {
                let stuck = pending.keys.sorted().prefix(8).map(String.init)
                    .joined(separator: ", ")
                record("gave up waiting to append \(remaining) frame(s): \(stuck)")
                break
            }
            appendQueue.sync { self.drain() }
            usleep(500)
        }

        lock.lock()
        let writer = self.writer
        let input = self.input
        let shouldMark = !markedFinished
        markedFinished = true
        lock.unlock()

        guard let writer, let input else { return }
        if shouldMark { input.markAsFinished() }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            throw InterpolatorError.writerFailed(
                "finishWriting ended in status \(writer.status.rawValue): "
                + (writer.error?.localizedDescription ?? "no error given"))
        }

        // The whole point of the copy-and-tag design is that these survive. If they
        // did not, the file is an HDR signal with no mastering display, which players
        // handle by guessing.
        lock.lock()
        let count = appendedCount
        lock.unlock()
        if count == 0 {
            record("the writer accepted no frames at all")
        }
    }

    public var problems: [String] {
        lock.lock(); defer { lock.unlock() }
        return problemList
    }

    /// Frames the writer accepted. Read after ``finish()``.
    public var appended: Int {
        lock.lock(); defer { lock.unlock() }
        return appendedCount
    }

    // MARK: - The reorder buffer

    /// Append whatever is ready, in order, until the encoder pushes back.
    ///
    /// Runs only on `appendQueue`, so appends are serialised without a lock. When it
    /// returns because `nextIndex` has not arrived yet, the `write` that delivers that
    /// index will kick it again — so there is no polling during the run.
    private func drain() {
        while true {
            lock.lock()
            guard let writer, let input, let adaptor, let outputRate,
                  writer.status == .writing else {
                lock.unlock()
                return
            }
            guard let buffer = pending.removeValue(forKey: nextIndex) else {
                lock.unlock()
                return
            }
            let index = nextIndex
            // Backpressure. Put it back rather than block, so the pipeline is never
            // waiting on the encoder from inside an engine completion.
            guard input.isReadyForMoreMediaData else {
                pending[index] = buffer
                lock.unlock()
                return
            }
            nextIndex += 1
            lock.unlock()

            let time = CMTime(value: CMTimeValue(index) * CMTimeValue(outputRate.denominator),
                              timescale: CMTimeScale(outputRate.numerator))
            if adaptor.append(buffer, withPresentationTime: time) {
                lock.lock()
                appendedCount += 1
                lock.unlock()
            } else {
                record("append failed at output frame \(index): "
                       + (writer.error?.localizedDescription ?? "no error given"))
                return
            }
        }
    }

    // MARK: - Copying

    /// Copy every plane into a buffer from the sink's own pool.
    private func copy(of source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let pool = copyPool else {
            throw InterpolatorError.writerFailed("the sink was not started")
        }
        let destination = try pool.makeBuffer()
        AssetWriterSink.copyPlanes(from: source, into: destination)
        return destination
    }

    /// Plane-wise copy honouring each buffer's own row stride.
    ///
    /// The strides are read from the buffers rather than assumed: `CVPixelBufferPool`
    /// pads rows, and for 4K the padded stride is routinely larger than the visible
    /// width. Assuming `width * bytesPerSample` here would shear the picture.
    static func copyPlanes(from source: CVPixelBuffer, into destination: CVPixelBuffer) {
        let sourcePlanes = CVPixelBufferGetPlaneCount(source)
        let destinationPlanes = CVPixelBufferGetPlaneCount(destination)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard sourcePlanes > 0 else {
            // Non-planar: one buffer, one stride.
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(destination) else { return }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(destination)
            let rows = CVPixelBufferGetHeight(source)
            copyRows(from: src, srcStride: srcStride, to: dst, dstStride: dstStride, rows: rows)
            return
        }

        for plane in 0..<min(sourcePlanes, destinationPlanes) {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                continue
            }
            copyRows(from: src,
                     srcStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                     to: dst,
                     dstStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                     rows: CVPixelBufferGetHeightOfPlane(source, plane))
        }
    }

    private static func copyRows(from source: UnsafeMutableRawPointer, srcStride: Int,
                                 to destination: UnsafeMutableRawPointer, dstStride: Int,
                                 rows: Int) {
        if srcStride == dstStride {
            memcpy(destination, source, rows * srcStride)
            return
        }
        // Different padding: copy the visible width row by row and leave the
        // destination's padding alone. Copying the full stride would run past the end
        // of the shorter allocation.
        let bytes = min(srcStride, dstStride)
        for row in 0..<rows {
            memcpy(destination + row * dstStride, source + row * srcStride, bytes)
        }
    }

    private func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }
}
