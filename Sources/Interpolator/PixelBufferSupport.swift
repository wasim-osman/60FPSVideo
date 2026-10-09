import CoreVideo
import Foundation

/// A biplanar 4:2:0 format the pipeline can carry from decode to encode.
///
/// Both cases have the same shape — a full-size luma plane, then an interleaved
/// CbCr plane at half height — and differ only in sample width. That is why one
/// implementation covers both, and why adding 10-bit did not need a second code
/// path through the engine.
///
/// Staying inside these formats is invariant 4 and invariant 16: VideoToolbox
/// decodes *to* them and `VTCompressionSession` encodes *from* them, so there is
/// no colour conversion anywhere. Leaving for RGB and coming back is what made the
/// first engine comparison wrong by 96%.
public enum FrameFormat: Sendable {

    /// 8-bit, `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ("420v").
    /// Studio range 16..235. The native SDR decode/encode format.
    case nv12

    /// 10-bit, `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` ("x420").
    /// Studio range 64..940. The HDR path — measured correct to 0.00/1023 at every
    /// phase, and accepted by the processor at 3840×1632 as well as 1080p.
    case p010

    public var pixelFormat: OSType {
        switch self {
        case .nv12: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .p010: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
    }

    /// Bytes per sample. 1 for 8-bit, 2 for 10-bit (stored in the high 10 bits of
    /// a 16-bit little-endian word).
    public var bytesPerSample: Int {
        switch self {
        case .nv12: 1
        case .p010: 2
        }
    }

    public var bitDepth: Int {
        switch self {
        case .nv12: 8
        case .p010: 10
        }
    }

    /// The largest legal code value: 255 for 8-bit, 1023 for 10-bit.
    ///
    /// This is the right divisor for turning a sample into a 0...1 fraction, and
    /// using it rather than the bit depth matters for a non-obvious reason. Both
    /// formats are *studio range*, so the used portion is a fixed fraction of full
    /// scale in both:
    ///
    /// - NV12: 16...235, i.e. 0.0627...0.9216 of 255
    /// - P010: 64...940, i.e. 0.0626...0.9189 of 1023
    ///
    /// Dividing each by its own maximum therefore lands the two on the same scale
    /// to within 0.3%. That is what lets the scene-change thresholds, which were
    /// calibrated on 8-bit footage, carry over to 10-bit untouched — and why
    /// normalising by bit depth (`>> 8`, say) would be wrong.
    public var maxCodeValue: Int {
        switch self {
        case .nv12: 255
        case .p010: 1023
        }
    }

    /// Read one luma sample out of a row, as a raw code value.
    ///
    /// 8-bit: the byte *is* the code. 10-bit P010: the code occupies the **top ten
    /// bits of a 16-bit little-endian word**, so the raw word is `code << 6` and
    /// has to be shifted back down before it means anything. Comparing raw words
    /// against 8-bit thresholds without shifting is the obvious way to get this
    /// wrong; it produces a histogram that looks plausible and is off by 64×.
    ///
    /// `littleEndian` is stated explicitly rather than relying on the host, because
    /// P010 is defined as little-endian regardless of the machine reading it.
    @inline(__always)
    public func lumaCode(_ row: UnsafeRawPointer, _ x: Int) -> Int {
        switch self {
        case .nv12:
            Int(row.load(fromByteOffset: x, as: UInt8.self))
        case .p010:
            Int(UInt16(littleEndian: row.load(fromByteOffset: x * 2, as: UInt16.self)) >> 6)
        }
    }

    /// Bytes in one packed frame: luma at full size plus interleaved chroma at
    /// quarter size, all scaled by the sample width.
    ///
    /// `width * height * 3 / 2 * bytesPerSample` — 1.5 bytes/pixel for NV12, 3 for
    /// P010.
    public func packedByteSize(width: Int, height: Int) -> Int {
        width * height * 3 / 2 * bytesPerSample
    }

    /// Copy one packed frame into a `CVPixelBuffer`.
    ///
    /// ## The trap this exists to avoid
    ///
    /// For a 420 biplanar buffer, `CVPixelBufferGetWidthOfPlane(buffer, 1)` returns
    /// the **chroma sample width** (`width / 2`), *not* the row length. The
    /// interleaved CbCr row is `width * bytesPerSample` bytes — there are `width/2`
    /// pairs of two samples. Using the sample width as the copy length writes only
    /// half of every chroma row, which tiles into exactly the first `height / 4`
    /// rows and leaves the rest zeroed: a solid green lower half of the frame.
    ///
    /// So: copy `width * bytesPerSample` bytes per chroma row, and advance by
    /// `bytesPerRow`.
    public func load(packed: UnsafeRawPointer,
                     into buffer: CVPixelBuffer,
                     width: Int,
                     height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let rowBytes = width * bytesPerSample

        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                memcpy(luma + row * stride, packed + row * rowBytes, rowBytes)
            }
        }

        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let lumaBytes = width * height * bytesPerSample
            for row in 0..<(height / 2) {
                memcpy(chroma + row * stride,
                       packed + lumaBytes + row * rowBytes,
                       rowBytes)
            }
        }
    }

    /// Copy a `CVPixelBuffer` back out as a packed frame.
    public func store(buffer: CVPixelBuffer,
                      into destination: UnsafeMutableRawPointer,
                      width: Int,
                      height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let rowBytes = width * bytesPerSample

        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                memcpy(destination + row * rowBytes, luma + row * stride, rowBytes)
            }
        }

        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let lumaBytes = width * height * bytesPerSample
            for row in 0..<(height / 2) {
                memcpy(destination + lumaBytes + row * rowBytes,
                       chroma + row * stride,
                       rowBytes)
            }
        }
    }

    /// Run `body` with a read-only view of the luma plane, as raw bytes.
    ///
    /// The pointer is `UInt8` for both formats; for `.p010` the caller must read it
    /// as 16-bit little-endian words and shift right by 6 to get the 10-bit code.
    /// `rowBytes` is the plane stride, which is **not** `width * bytesPerSample` —
    /// buffers are padded.
    public func withLuma<T>(of buffer: CVPixelBuffer,
                            _ body: (UnsafePointer<UInt8>, Int, Int) throws -> T) rethrows -> T {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        return try body(plane,
                        CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                        CVPixelBufferGetHeightOfPlane(buffer, 0))
    }
}

/// A recycling pool of identically-shaped pixel buffers.
///
/// Invariant 2: buffers must come from a pool and be recycled. Creating one per
/// frame with `CVPixelBufferCreate` crashes after 65–90 frames.
public final class PixelBufferPool {

    private let pool: CVPixelBufferPool
    public let width: Int
    public let height: Int
    public let format: FrameFormat

    public init(width: Int, height: Int,
                format: FrameFormat = .nv12,
                capacity: Int) throws {
        self.width = width
        self.height = height
        self.format = format

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: capacity,
        ]
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as CFDictionary,
                                             bufferAttributes as CFDictionary,
                                             &created)
        guard status == kCVReturnSuccess, let created else {
            throw InterpolatorError.poolCreationFailed(status)
        }
        self.pool = created
    }

    /// Take a buffer from the pool. It returns to the pool when released.
    public func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw InterpolatorError.bufferAllocationFailed(status)
        }
        return buffer
    }
}

public enum InterpolatorError: Error, CustomStringConvertible {
    case poolCreationFailed(OSStatus)
    case bufferAllocationFailed(OSStatus)
    case shortRead(frame: Int, expected: Int, got: Int)
    case shortWrite(frame: Int, expected: Int, got: Int)
    case engineRejected(String)
    case unsupportedResolution(width: Int, height: Int, reason: String)
    /// The output could not be written. Distinct from `engineRejected` because it is
    /// the *result* that failed, not the interpolation — a run can interpolate every
    /// frame correctly and still produce nothing usable.
    case writerFailed(String)

    public var description: String {
        switch self {
        case .poolCreationFailed(let s): "pixel buffer pool creation failed (\(s))"
        case .bufferAllocationFailed(let s): "pixel buffer allocation failed (\(s))"
        case .shortRead(let f, let e, let g): "short read at frame \(f): wanted \(e) bytes, got \(g)"
        case .shortWrite(let f, let e, let g): "short write at frame \(f): wanted \(e) bytes, got \(g)"
        case .engineRejected(let m): "engine rejected the request: \(m)"
        case .unsupportedResolution(let w, let h, let r): "\(w)x\(h) unsupported: \(r)"
        case .writerFailed(let m): "could not write the output: \(m)"
        }
    }
}
