import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// The packed-bytes ↔ `CVPixelBuffer` bridge, for both 8-bit and 10-bit.
///
/// This is the layer where a silent layout mistake is most expensive: it produces a
/// plausible-looking frame with the wrong pixels, and no error anywhere. Both the
/// chroma half-row trap and the 10-bit sample width are covered here.
@Suite("FrameFormat")
struct FrameFormatTests {

    private func makeBuffer(_ format: FrameFormat, _ width: Int, _ height: Int,
                            rowAlignment: Int? = nil) -> CVPixelBuffer? {
        var attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        if let rowAlignment { attributes[kCVPixelBufferBytesPerRowAlignmentKey] = rowAlignment }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format.pixelFormat,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    /// Every byte a distinct function of its position, so a copy that drops,
    /// duplicates, shifts or truncates bytes cannot accidentally pass.
    private func pattern(count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    private func roundTrip(_ format: FrameFormat, width: Int, height: Int,
                           source: [UInt8], rowAlignment: Int? = nil) throws {
        let buffer = try #require(makeBuffer(format, width, height, rowAlignment: rowAlignment))
        source.withUnsafeBytes { raw in
            format.load(packed: raw.baseAddress!, into: buffer, width: width, height: height)
        }
        var restored = [UInt8](repeating: 0, count: source.count)
        restored.withUnsafeMutableBytes { raw in
            format.store(buffer: buffer, into: raw.baseAddress!, width: width, height: height)
        }
        #expect(restored == source)
    }

    @Test("packed size is 1.5 bytes per pixel at 8-bit and 3 at 10-bit")
    func packedSizes() {
        #expect(FrameFormat.nv12.packedByteSize(width: 1920, height: 1080) == 1920 * 1080 * 3 / 2)
        #expect(FrameFormat.p010.packedByteSize(width: 1920, height: 1080) == 1920 * 1080 * 3)
        #expect(FrameFormat.p010.packedByteSize(width: 3840, height: 1632) == 3840 * 1632 * 3)
        #expect(FrameFormat.nv12.packedByteSize(width: 3840, height: 1632) == 3840 * 1632 * 3 / 2)
    }

    @Test("the formats are the video-range biplanar ones, not full range")
    func pixelFormats() {
        // Video range matters: full range is a different colour space and mixing the
        // two is invariant 16, the bug that made the first comparison wrong by 96%.
        #expect(FrameFormat.nv12.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(FrameFormat.p010.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(FrameFormat.nv12.bytesPerSample == 1)
        #expect(FrameFormat.p010.bytesPerSample == 2)
        #expect(FrameFormat.nv12.bitDepth == 8)
        #expect(FrameFormat.p010.bitDepth == 10)
    }

    @Test("a packed frame round-trips unchanged", arguments: [FrameFormat.nv12, FrameFormat.p010])
    func roundTrips(format: FrameFormat) throws {
        let width = 192, height = 108
        let source = pattern(count: format.packedByteSize(width: width, height: height))
        try roundTrip(format, width: width, height: height, source: source)
    }

    @Test("a 10-bit frame round-trips at 4K")
    func roundTripsAt4K() throws {
        let width = 3840, height = 1632
        let source = pattern(count: FrameFormat.p010.packedByteSize(width: width, height: height))
        try roundTrip(.p010, width: width, height: height, source: source)
    }

    @Test("the last chroma row survives — the half-row copy trap")
    func chromaRowsAreNotHalved() throws {
        // The trap: `CVPixelBufferGetWidthOfPlane(buffer, 1)` returns the chroma
        // SAMPLE width (width/2), not the row length. Using it as the copy length
        // writes only half of every chroma row, which tiles into the first
        // height/4 rows and leaves the rest zeroed — a solid green lower half.
        //
        // So: mark the final chroma row specifically. A half-row copy never reaches it.
        let width = 64, height = 32
        let format = FrameFormat.nv12
        var source = [UInt8](repeating: 0,
                             count: format.packedByteSize(width: width, height: height))
        let lumaBytes = width * height
        let lastChromaRow = lumaBytes + (height / 2 - 1) * width
        for column in 0..<width { source[lastChromaRow + column] = 0xAB }

        try roundTrip(format, width: width, height: height, source: source)
    }

    @Test("a padded row stride is respected", arguments: [FrameFormat.nv12, FrameFormat.p010])
    func respectsStride(format: FrameFormat) throws {
        // 100 is not a multiple of the alignment, so the buffer pads its rows and
        // `bytesPerRow` exceeds the packed row length. Copying `rowBytes` per row
        // instead of `bytesPerRow` would shear the image.
        let width = 100, height = 20
        let source = pattern(count: format.packedByteSize(width: width, height: height))
        try roundTrip(format, width: width, height: height,
                      source: source, rowAlignment: 64)
    }

    @Test("a buffer's luma plane is exposed with its real stride")
    func lumaStrideIsReported() throws {
        let width = 192, height = 108
        let buffer = try #require(makeBuffer(.nv12, width, height))
        let source = pattern(count: FrameFormat.nv12.packedByteSize(width: width, height: height))
        source.withUnsafeBytes { raw in
            FrameFormat.nv12.load(packed: raw.baseAddress!, into: buffer,
                                  width: width, height: height)
        }

        let (stride, planeHeight) = FrameFormat.nv12.withLuma(of: buffer) { pointer, rowBytes, rows in
            // The first row must match the packed source exactly.
            let firstRow = Array(UnsafeBufferPointer(start: pointer, count: width))
            #expect(firstRow == Array(source[0..<width]))
            return (rowBytes, rows)
        }
        #expect(stride >= width, "stride must cover a full row")
        #expect(planeHeight == height)
    }
}
