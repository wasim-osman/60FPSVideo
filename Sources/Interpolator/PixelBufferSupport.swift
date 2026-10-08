import CoreVideo
import Foundation

/// NV12 as packed raw bytes, and the CVPixelBuffer ↔ raw-bytes bridge.
///
/// The pipeline stays in `420YpCbCr8BiPlanarVideoRange` from decode to encode
/// (invariant 4 and invariant 16). That is the format VideoToolbox decodes to and
/// `VTCompressionSession` encodes from, so there is no colour conversion anywhere —
/// and no chance of the range mismatch that made the first engine comparison wrong
/// by 96%.
public enum NV12 {

    public static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// Bytes in one packed NV12 frame: a full-size luma plane plus one interleaved
    /// chroma plane at quarter size.
    public static func byteSize(width: Int, height: Int) -> Int {
        width * height * 3 / 2
    }

    /// Copy one packed NV12 frame into a `CVPixelBuffer`.
    ///
    /// ## The trap this exists to avoid
    ///
    /// For a 420 biplanar buffer, `CVPixelBufferGetWidthOfPlane(buffer, 1)` returns
    /// the **chroma sample width** (`width / 2`), *not* the row length. The
    /// interleaved CbCr row is `width` bytes, and the plane's stride is
    /// `bytesPerRow`. Using the sample width as the copy length writes only half of
    /// every chroma row, which tiles into exactly the first `height / 4` rows and
    /// leaves the rest zeroed — a solid green lower half of the frame.
    ///
    /// So: copy `width` bytes per chroma row, and advance by `bytesPerRow`.
    public static func load(packed: UnsafeRawPointer,
                            into buffer: CVPixelBuffer,
                            width: Int,
                            height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let destination = yPlane.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                memcpy(destination + row * stride,
                       packed + row * width,
                       width)
            }
        }

        if let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let destination = chromaPlane.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaOffset = width * height
            for row in 0..<(height / 2) {
                memcpy(destination + row * stride,
                       packed + chromaOffset + row * width,
                       width)
            }
        }
    }

    /// Copy a `CVPixelBuffer` back out as packed NV12.
    public static func store(buffer: CVPixelBuffer,
                             into destination: UnsafeMutableRawPointer,
                             width: Int,
                             height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let source = yPlane.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                memcpy(destination + row * width,
                       source + row * stride,
                       width)
            }
        }

        if let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let source = chromaPlane.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaOffset = width * height
            for row in 0..<(height / 2) {
                memcpy(destination + chromaOffset + row * width,
                       source + row * stride,
                       width)
            }
        }
    }

    /// Run `body` with a read-only view of the luma plane.
    public static func withLuma<T>(of buffer: CVPixelBuffer,
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

    public init(width: Int, height: Int,
                format: OSType = NV12.pixelFormat,
                capacity: Int) throws {
        self.width = width
        self.height = height

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: capacity,
        ]
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
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

    public var description: String {
        switch self {
        case .poolCreationFailed(let s): "pixel buffer pool creation failed (\(s))"
        case .bufferAllocationFailed(let s): "pixel buffer allocation failed (\(s))"
        case .shortRead(let f, let e, let g): "short read at frame \(f): wanted \(e) bytes, got \(g)"
        case .shortWrite(let f, let e, let g): "short write at frame \(f): wanted \(e) bytes, got \(g)"
        case .engineRejected(let m): "engine rejected the request: \(m)"
        case .unsupportedResolution(let w, let h, let r): "\(w)x\(h) unsupported: \(r)"
        }
    }
}
