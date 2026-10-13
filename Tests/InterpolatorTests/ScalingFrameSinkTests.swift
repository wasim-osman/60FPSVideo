import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// The stage that delivers frames at a size other than the one they were interpolated at.
///
/// The cases here are chosen so that the geometry is small enough to reason about exactly and
/// the expected numbers are written down: a 320×180 source into a 480×480 target is
/// **480×270 with 105-pixel bars top and bottom** for fit, and **854×480 cropped 187 columns
/// each side** for fill. If a change makes either of those wrong, the test says which number
/// moved.
///
/// The bars are asserted to be *video-range black* (16 in NV12, 64 in P010), not merely dark.
/// That distinction is the whole reason the framework does this rather than a hand-rolled
/// composite: 16 is what a decoder and a display both read as black, and a bar filled with 0
/// is out of range and can come back as anything.
@Suite("Scaling sink")
struct ScalingFrameSinkTests {

    // MARK: - Scaffolding

    private func makeBuffer(_ width: Int, _ height: Int, _ format: FrameFormat) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format.pixelFormat,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    /// A uniform frame: luma at `luma`, chroma neutral.
    ///
    /// Uniform on purpose. A pattern with edges would make the bars ambiguous — the scaler's
    /// filter bleeds the picture a pixel or two into the bar, which is correct behaviour and
    /// would turn an exact assertion into a fuzzy one. A flat source has nothing to bleed, so
    /// the boundary between 16 and 235 is the boundary the framework chose.
    private func fill(_ buffer: CVPixelBuffer, luma: Int, _ format: FrameFormat) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let code = plane == 0 ? luma : (format == .p010 ? 512 : 128)
            for row in 0..<height {
                if format == .p010 {
                    let words = base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width { words[x] = UInt16(code << 6) }
                } else {
                    memset(base + row * stride, Int32(code), width)
                }
            }
        }
    }

    /// Read one luma sample out of a packed frame, in that format's own code units.
    private func luma(_ packed: [UInt8], x: Int, y: Int, width: Int, _ format: FrameFormat) -> Int {
        let rowBytes = width * format.bytesPerSample
        return packed.withUnsafeBytes { raw in
            format.lumaCode(raw.baseAddress! + y * rowBytes, x)
        }
    }

    private func geometry(width: Int, height: Int, _ format: FrameFormat) -> SinkGeometry {
        SinkGeometry(width: width, height: height, format: format,
                     sourceRate: .twentyFourNTSC, outputRate: .sixtyNTSC,
                     sourceFrameCount: nil, outputFrameCount: nil)
    }

    // MARK: - Delivery

    @Test("the wrapped sink is told the delivered size, not the interpolated one")
    func forwardsTheTargetGeometry() throws {
        let inner = MemoryFrameSink(width: 480, height: 480, format: .nv12)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 480, height: 480),
                                    mode: .fit)
        try sink.begin(geometry(width: 320, height: 180, .nv12))

        let received = try #require(inner.receivedGeometry)
        #expect(received.width == 480)
        #expect(received.height == 480)
        // The rates and the format are carried through untouched: a scaled picture is the same
        // picture at a different size, not a different stream.
        #expect(received.format == .nv12)
        #expect(received.sourceRate == .twentyFourNTSC)
        #expect(received.outputRate == .sixtyNTSC)
    }

    @Test("fit draws black bars where the geometry says, and the picture between them")
    func fitBarsAreWhereTheGeometrySays() throws {
        let format = FrameFormat.nv12
        let source = try #require(makeBuffer(320, 180, format))
        fill(source, luma: 235, format)

        let inner = MemoryFrameSink(width: 480, height: 480, format: format)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 480, height: 480),
                                    mode: .fit)
        try sink.begin(geometry(width: 320, height: 180, format))
        sink.write(source, at: 0)
        try sink.finish()

        // The geometry this asserts against, computed independently of the implementation.
        let expected = OutputGeometry.fitting(source: OutputSize(width: 320, height: 180),
                                              target: OutputSize(width: 480, height: 480),
                                              mode: .fit)
        #expect(expected.scaledHeight == 270)
        #expect(expected.letterBars == 105)

        let frame = try #require(inner.frame(at: 0))
        // Well inside the top bar, the picture, and the bottom bar.
        #expect(luma(frame, x: 240, y: 50, width: 480, format) == 16)
        #expect(luma(frame, x: 240, y: 240, width: 480, format) == 235)
        #expect(luma(frame, x: 240, y: 430, width: 480, format) == 16)
        // And the picture starts where the geometry says it does, within the scaler's own
        // filter transition. 105 is the first picture row; row 120 is unambiguously inside it.
        #expect(luma(frame, x: 240, y: 120, width: 480, format) == 235)
        #expect(luma(frame, x: 240, y: 95, width: 480, format) == 16)
        // No bars at the sides: fit on this target is limited by width, so the picture is full
        // width and the bars are top and bottom only.
        #expect(luma(frame, x: 5, y: 240, width: 480, format) == 235)
        #expect(luma(frame, x: 474, y: 240, width: 480, format) == 235)
    }

    @Test("fill leaves no bars at any edge")
    func fillLeavesNoBars() throws {
        let format = FrameFormat.nv12
        let source = try #require(makeBuffer(320, 180, format))
        fill(source, luma: 235, format)

        let inner = MemoryFrameSink(width: 480, height: 480, format: format)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 480, height: 480),
                                    mode: .fill)
        try sink.begin(geometry(width: 320, height: 180, format))
        sink.write(source, at: 0)
        try sink.finish()

        let expected = OutputGeometry.fitting(source: OutputSize(width: 320, height: 180),
                                              target: OutputSize(width: 480, height: 480),
                                              mode: .fill)
        #expect(expected.croppedColumns == 187)

        let frame = try #require(inner.frame(at: 0))
        // Every edge is picture. A bar here would be the failure the mode exists to avoid.
        for (x, y) in [(0, 0), (479, 0), (0, 479), (479, 479), (240, 0), (0, 240), (479, 240)] {
            #expect(luma(frame, x: x, y: y, width: 480, format) == 235,
                    "fill left a bar at (\(x), \(y))")
        }
    }

    @Test("a target the same size as the frame is passed through untouched")
    func equalSizeIsPassedThrough() throws {
        let format = FrameFormat.nv12
        let source = try #require(makeBuffer(320, 180, format))
        fill(source, luma: 200, format)

        let inner = MemoryFrameSink(width: 320, height: 180, format: format)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 320, height: 180),
                                    mode: .fit)
        try sink.begin(geometry(width: 320, height: 180, format))
        sink.write(source, at: 0)
        try sink.finish()

        let frame = try #require(inner.frame(at: 0))
        // Every sample is the source's own value, including the corners — no scaling, no bars,
        // no resampling. This is the case that keeps `.source` conversions byte-for-byte what
        // they were before the target existed.
        for (x, y) in [(0, 0), (319, 0), (0, 179), (319, 179), (160, 90)] {
            #expect(luma(frame, x: x, y: y, width: 320, format) == 200)
        }
    }

    @Test("bars are black on every frame, including one that reuses a buffer")
    func barsAreBlackOnEveryFrame() throws {
        let format = FrameFormat.nv12
        let bright = try #require(makeBuffer(320, 180, format))
        let dark = try #require(makeBuffer(320, 180, format))
        fill(bright, luma: 235, format)
        fill(dark, luma: 40, format)

        let inner = MemoryFrameSink(width: 480, height: 480, format: format)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 480, height: 480),
                                    mode: .fit)
        try sink.begin(geometry(width: 320, height: 180, format))
        // A bright frame first, so the pool's buffers hold a bright picture when the second
        // frame asks for one. A transfer that wrote only the picture would show 235 here.
        sink.write(bright, at: 0)
        sink.write(dark, at: 1)
        try sink.finish()

        for index in 0..<2 {
            let frame = try #require(inner.frame(at: index))
            #expect(luma(frame, x: 240, y: 20, width: 480, format) == 16,
                    "frame \(index) has a non-black top bar")
            #expect(luma(frame, x: 240, y: 460, width: 480, format) == 16,
                    "frame \(index) has a non-black bottom bar")
        }
        // And the pictures differ, so the test is not passing because everything is black.
        let first = try #require(inner.frame(at: 0))
        let second = try #require(inner.frame(at: 1))
        #expect(luma(first, x: 240, y: 240, width: 480, format) == 235)
        #expect(luma(second, x: 240, y: 240, width: 480, format) == 40)
    }

    // MARK: - Formats

    @Test("ten-bit frames scale, and their bars are ten-bit black")
    func tenBitBars() throws {
        let format = FrameFormat.p010
        let source = try #require(makeBuffer(320, 180, format))
        fill(source, luma: 940, format)

        let inner = MemoryFrameSink(width: 480, height: 480, format: format)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 480, height: 480),
                                    mode: .fit)
        try sink.begin(geometry(width: 320, height: 180, format))
        sink.write(source, at: 0)
        try sink.finish()

        let frame = try #require(inner.frame(at: 0))
        // 64 is video-range black at ten bits, and it is preserved exactly: no range conversion
        // happens on the way through, which is the thing a scale pass could quietly introduce.
        #expect(luma(frame, x: 240, y: 50, width: 480, format) == 64)
        #expect(luma(frame, x: 240, y: 240, width: 480, format) == 940)
        #expect(luma(frame, x: 240, y: 430, width: 480, format) == 64)
    }

    // MARK: - Concurrency

    @Test("frames written concurrently all land, at the right size, with nothing reported")
    func concurrentWritesAreSafe() async throws {
        let format = FrameFormat.nv12
        let count = 48

        let inner = MemoryFrameSink(width: 480, height: 480, format: format)
        let sink = ScalingFrameSink(wrapping: inner,
                                    target: OutputSize(width: 480, height: 480),
                                    mode: .fit)
        try sink.begin(geometry(width: 320, height: 180, format))

        // Each index gets its own source buffer and its own luma value, so a frame delivered
        // into the wrong slot or scaled from another thread's buffer is visible rather than
        // merely possible. This is the shape the pipeline actually calls in: completions arrive
        // out of order and, with depth > 1, at the same time.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    guard let source = makeBuffer(320, 180, format) else { return }
                    fill(source, luma: 20 + index * 4, format)
                    sink.write(source, at: index)
                }
            }
        }
        try sink.finish()

        #expect(sink.problems.isEmpty, "\(sink.problems)")
        #expect(inner.count == count)

        for index in 0..<count {
            let frame = try #require(inner.frame(at: index))
            // The bar is black on every one of them — a shared destination buffer would show up
            // here as one frame's picture appearing in another's bars.
            #expect(luma(frame, x: 240, y: 20, width: 480, format) == 16,
                    "frame \(index) has a non-black bar")
            #expect(luma(frame, x: 240, y: 240, width: 480, format) == 20 + index * 4,
                    "frame \(index) holds the wrong picture")
        }
    }
}
