import Foundation
import Testing
@testable import Interpolator

/// Reading a 10-bit luma plane, and the claim that it is *comparable* to 8-bit.
///
/// ## Why this needs its own suite
///
/// A 10-bit sample lives in the top ten bits of a 16-bit little-endian word, so the
/// raw word is `code << 6`. Read it without shifting and every number downstream is
/// wrong by 64× — and wrong *plausibly*: the grid saturates toward 1.0, the
/// histogram collapses into the top bin, and nothing throws. The scene detector
/// would then see a large but consistent offset between frames, which is exactly
/// the shape of "everything is fine".
///
/// So these tests are not about the shift being pretty. They pin the two claims the
/// HDR path depends on:
///
///   1. the code really is read from the top ten bits;
///   2. 8-bit and 10-bit footage of the *same* content produce the *same*
///      signature, which is what lets one set of thresholds serve both.
private enum Plane {

    /// A whole packed 10-bit frame: luma from `code`, then a neutral chroma plane.
    ///
    /// The chroma is filled rather than omitted because the frame *size* has to be
    /// the real one — `packedByteSize` — for the concatenation below to line up.
    /// Nothing reads it: a signature is luma-only.
    static func tenBit(width: Int, height: Int,
                       _ code: (Int, Int) -> Int) -> [UInt8] {
        let lumaWords = width * height
        var words = [UInt16](repeating: UInt16(512 << 6), count: lumaWords * 3 / 2)
        for y in 0..<height {
            for x in 0..<width {
                words[y * width + x] = UInt16(code(x, y) << 6)
            }
        }
        return words.withUnsafeBytes { Array($0) }
    }

    /// The same, at 8-bit.
    static func eightBit(width: Int, height: Int,
                         _ code: (Int, Int) -> Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 128, count: width * height * 3 / 2)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = UInt8(clamping: code(x, y))
            }
        }
        return bytes
    }

    /// A luma plane alone, at an arbitrary stride — the padding case. Luma only is
    /// correct here: the signature is told the stride explicitly and never looks at
    /// chroma.
    static func paddedTenBitLuma(width: Int, height: Int, stride: Int,
                                 _ code: (Int, Int) -> Int) -> [UInt8] {
        var words = [UInt16](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                words[y * stride + x] = UInt16(code(x, y) << 6)
            }
        }
        return words.withUnsafeBytes { Array($0) }
    }

    /// The 8-bit code that represents the same fraction of full scale as a 10-bit
    /// one. Studio range sits at the same fraction of full scale in both formats,
    /// so this is the mapping that should leave the signature unchanged.
    static func eightBitCode(forTenBit code: Int) -> Int {
        Int((Double(code) * 255.0 / 1023.0).rounded())
    }

    static func signature(_ plane: [UInt8], format: FrameFormat,
                          width: Int, height: Int, stride: Int) -> FrameSignature {
        plane.withUnsafeBytes {
            FrameSignature.compute(luma: $0.baseAddress!, format: format,
                                   width: width, height: height, bytesPerRow: stride)
        }
    }
}

@Suite("10-bit luma")
struct TenBitSignatureTests {

    @Test("a 10-bit sample is read from the top ten bits, not from the raw word")
    func readsTheShiftedCode() {
        let codes = [0, 1, 64, 128, 400, 940, 1023]
        let words = codes.map { UInt16($0 << 6) }
        // The packing itself, stated once: the low six bits are always zero and
        // 1023 does not overflow a UInt16.
        #expect(words.allSatisfy { $0 & 0x3F == 0 })
        #expect(words.last == 65472)

        words.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for (i, code) in codes.enumerated() {
                #expect(FrameFormat.p010.lumaCode(base, i) == code,
                        "10-bit code \(code) came back wrong")
                // The mistake this guards against, spelled out. Skipped for code 0,
                // where the raw word and the code are both 0 and the two readings
                // are genuinely indistinguishable.
                if code != 0 {
                    #expect(FrameFormat.p010.lumaCode(base, i) != Int(words[i]),
                            "the raw word must not be mistaken for the code")
                }
            }
        }
    }

    @Test("an 8-bit sample is read as the byte itself")
    func readsTheByte() {
        let bytes: [UInt8] = [0, 16, 128, 235, 255]
        bytes.withUnsafeBytes { raw in
            for (i, byte) in bytes.enumerated() {
                #expect(FrameFormat.nv12.lumaCode(raw.baseAddress!, i) == Int(byte))
            }
        }
    }

    @Test("the two formats agree on the same content")
    func formatsAgree() {
        // A horizontal ramp across the used range, plus a vertical step, so both
        // the grid and the histogram get exercised.
        let width = 640, height = 360
        let ten = Plane.tenBit(width: width, height: height) { x, y in
            64 + (940 - 64) * x / (width - 1) + (y < height / 2 ? 0 : 40)
        }
        let eight = Plane.eightBit(width: width, height: height) { x, y in
            Plane.eightBitCode(forTenBit: 64 + (940 - 64) * x / (width - 1)
                               + (y < height / 2 ? 0 : 40))
        }

        let s10 = Plane.signature(ten, format: .p010, width: width, height: height,
                                  stride: width * 2)
        let s8 = Plane.signature(eight, format: .nv12, width: width, height: height,
                                 stride: width)

        #expect(s10.gridWidth == s8.gridWidth)
        #expect(s10.gridHeight == s8.gridHeight)

        // The grid is the direct measure of luma, so it gets the tight bound. A
        // missing shift would put this off by ~0.6, not by 0.002.
        let worst = zip(s10.grid, s8.grid).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 0.002, "grid disagreed by \(worst) — the shift is not being applied")

        // The histogram can only differ where a sample lands on the other side of a
        // bin boundary, and the ramp is smooth, so this stays small.
        #expect(s10.histogramDistance(to: s8) < 0.05)
    }

    @Test("a cut is found at the same frame in 8-bit and in 10-bit")
    func sameCutBothFormats() {
        let width = 256, height = 144
        let shots = 40

        // Two shots, deliberately far apart in both what they are made of (a ramp
        // versus a flat mid-tone) and where things are (a step that flips sides).
        let ramp: (Int, Int) -> Int = { x, _ in 64 + 876 * x / (width - 1) }
        let flat: (Int, Int) -> Int = { x, _ in 300 + (x < width / 2 ? 500 : 0) }

        var cuts: [Int] = []
        for isTenBit in [true, false] {
            var plane: [UInt8] = []
            for frame in 0..<(shots * 2) {
                let source = frame < shots ? ramp : flat
                if isTenBit {
                    plane += Plane.tenBit(width: width, height: height, source)
                } else {
                    plane += Plane.eightBit(width: width, height: height) {
                        Plane.eightBitCode(forTenBit: source($0, $1))
                    }
                }
            }
            let format: FrameFormat = isTenBit ? .p010 : .nv12
            let stride = width * format.bytesPerSample
            let frameSize = format.packedByteSize(width: width, height: height)
            #expect(plane.count == frameSize * shots * 2)

            let signatures = (0..<(shots * 2)).map { frame in
                Plane.signature(Array(plane[(frame * frameSize)..<((frame + 1) * frameSize)]),
                                format: format, width: width, height: height, stride: stride)
            }
            cuts.append(SceneChangeDetector.detect(signatures: signatures)
                .cutIntervals.first ?? -1)
        }

        #expect(cuts[0] == shots - 1, "10-bit missed the cut")
        #expect(cuts[0] == cuts[1], "the two formats disagreed about where the cut is")
    }

    @Test("a padded 10-bit row stride is respected")
    func paddedStride() {
        // 100 samples is not a multiple of the 16-sample (32-byte) alignment a real
        // buffer uses, so this is the case where treating the stride as `width * 2`
        // reads padding into the picture.
        let width = 100, height = 64, stride = 128
        let padded = Plane.paddedTenBitLuma(width: width, height: height, stride: stride) { _, _ in 500 }
        let tight = Plane.paddedTenBitLuma(width: width, height: height, stride: width) { _, _ in 500 }

        let a = Plane.signature(padded, format: .p010, width: width, height: height,
                                stride: stride * 2)
        let b = Plane.signature(tight, format: .p010, width: width, height: height,
                                stride: width * 2)
        #expect(a.grid == b.grid)

        // And the padding must be *ignored*, not averaged in. Fill it with black and
        // require the answer not to move.
        var withBlackPadding = padded
        withBlackPadding.withUnsafeMutableBytes { raw in
            for y in 0..<height {
                let row = raw.baseAddress! + y * stride * 2
                for x in width..<stride { row.storeBytes(of: UInt16(0), toByteOffset: x * 2,
                                                         as: UInt16.self) }
            }
        }
        let c = Plane.signature(withBlackPadding, format: .p010, width: width, height: height,
                                stride: stride * 2)
        #expect(c.grid == a.grid, "padding leaked into the signature")
        // A flat 500/1023 frame, to state what the value actually is.
        let expected = Float(500) / 1023.0
        #expect(abs(a.grid[0] - expected) < 0.001)
    }

    @Test("normalising by the format's own maximum is what makes them comparable")
    func maxCodeValueMatters() {
        #expect(FrameFormat.nv12.maxCodeValue == 255)
        #expect(FrameFormat.p010.maxCodeValue == 1023)

        // Studio range occupies the same fraction of full scale in both formats,
        // which is the whole reason one threshold set works for both.
        let eightLow = 16.0 / 255.0, tenLow = 64.0 / 1023.0
        let eightHigh = 235.0 / 255.0, tenHigh = 940.0 / 1023.0
        #expect(abs(eightLow - tenLow) < 0.001)
        #expect(abs(eightHigh - tenHigh) < 0.005)
    }
}
