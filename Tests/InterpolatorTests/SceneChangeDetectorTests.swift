import Foundation
import Testing
@testable import Interpolator

/// Synthetic signatures, so cut detection can be tested without a video file.
///
/// Two independent axes, which is exactly what the detector keys on:
///   - `histogramBin` — what the frame is made of. Constant through a pan.
///   - `gridPhase`    — where things are. Moves for a pan *and* for a cut.
private func signature(histogramBin: Int,
                       gridPhase: Float,
                       bins: Int = 64,
                       cells: Int = 64) -> FrameSignature {
    var histogram = [Float](repeating: 0, count: bins)
    histogram[((histogramBin % bins) + bins) % bins] = 1
    var grid = [Float](repeating: 0, count: cells)
    for i in 0..<cells {
        grid[i] = 0.5 + 0.5 * sin(Float(i) * 0.5 + gridPhase * 2 * .pi)
    }
    return FrameSignature(histogram: histogram, grid: grid, gridWidth: 8, gridHeight: 8)
}

/// A run of frames that pans gently: the grid drifts, the histogram does not move.
private func gentlePan(count: Int, startingBin: Int = 20,
                       startingPhase: Float = 0) -> [FrameSignature] {
    (0..<count).map {
        signature(histogramBin: startingBin, gridPhase: startingPhase + Float($0) * 0.02)
    }
}

/// A frame from a dark shot: the tonal distribution is a broad, low bump, and the
/// spatial layout is set by `gridPhase`.
///
/// This is the shape that defeats a histogram-only cut rule. Two of these bumps
/// centred a bin apart overlap almost completely, so the histogram distance stays
/// tiny even though the picture has completely changed — which is what real night
/// footage does. The reference clip's cut at source frames 168→169 moves the
/// histogram by 0.074 against a 0.12 floor.
private func darkShot(centerBin: Float, gridPhase: Float,
                      spread: Float = 6, bins: Int = 64,
                      cells: Int = 64) -> FrameSignature {
    var histogram = [Float](repeating: 0, count: bins)
    var total: Float = 0
    for i in 0..<bins {
        let d = Float(i) - centerBin
        let weight = exp(-(d * d) / (2 * spread * spread))
        histogram[i] = weight
        total += weight
    }
    for i in 0..<bins { histogram[i] /= total }

    var grid = [Float](repeating: 0, count: cells)
    for i in 0..<cells {
        grid[i] = 0.5 + 0.5 * sin(Float(i) * 0.5 + gridPhase * 2 * .pi)
    }
    return FrameSignature(histogram: histogram, grid: grid, gridWidth: 8, gridHeight: 8)
}

@Suite("SceneChangeDetector")
struct SceneChangeDetectorTests {

    @Test("a steady pan produces no cuts")
    func panIsNotACut() {
        let report = SceneChangeDetector.detect(signatures: gentlePan(count: 60))
        #expect(report.cutCount == 0, "fast motion must not read as a shot change")
    }

    @Test("a shot change is found")
    func findsACut() {
        var frames = gentlePan(count: 40)
        // New shot: different tonal distribution AND a different spatial layout.
        // It lands at index 40, so the transition is between 39 and 40.
        frames.append(signature(histogramBin: 52, gridPhase: 0.5))
        frames += (0..<40).map { signature(histogramBin: 52, gridPhase: 0.5 + Float($0) * 0.02) }

        let report = SceneChangeDetector.detect(signatures: frames)
        #expect(report.cutCount == 1)
        #expect(report.cutIntervals == [39])
    }

    @Test("several cuts are all found, at the right places")
    func findsSeveralCuts() {
        var frames = gentlePan(count: 30)               // 0...29
        var expected: [Int] = []
        for (bin, phase) in [(50, Float(0.4)), (12, Float(0.9)), (33, Float(1.7))] {
            expected.append(frames.count - 1)           // transition into the new shot
            frames.append(signature(histogramBin: bin, gridPhase: phase))
            frames += (0..<20).map {
                signature(histogramBin: bin, gridPhase: phase + Float($0) * 0.02)
            }
        }
        let report = SceneChangeDetector.detect(signatures: frames)
        #expect(report.cutCount == 3)
        #expect(report.cutIntervals == expected)
    }

    /// The regression that motivated the second classification path. On dark
    /// footage the histogram stops discriminating, so a rule that needs both
    /// measures to jump misses the cut entirely.
    @Test("a cut in dark footage is found even when the histogram barely moves")
    func findsCutInDarkFootage() {
        var frames: [FrameSignature] = []
        for i in 0..<30 {
            frames.append(darkShot(centerBin: 20, gridPhase: Float(i) * 0.01))
        }
        let cutAt = frames.count - 1          // transition into the new shot
        frames.append(darkShot(centerBin: 21, gridPhase: 0.25))
        for i in 0..<30 {
            frames.append(darkShot(centerBin: 21, gridPhase: 0.25 + Float(i) * 0.01))
        }

        let report = SceneChangeDetector.detect(signatures: frames)
        let config = SceneChangeDetector.Config()

        // The premise: the histogram path on its own would miss this one. If this
        // ever stops holding, the test is no longer exercising the grid-spike path.
        #expect(report.histogramDistance[cutAt] < config.histogramFloor,
                "dark shots must overlap enough that the histogram alone is not decisive")
        #expect(report.histogramDistance[cutAt] > config.mildHistogramFloor,
                "but the histogram must still be clearly not flat")
        #expect(report.gridDistance[cutAt] > config.gridFloor,
                "the spatial layout must have jumped hard")

        #expect(report.isCut[cutAt], "a hard grid spike must count as a cut on dark footage")
        #expect(report.cutCount == 1, "and it must not invent cuts elsewhere")
    }

    /// A flash — a camera flash, an explosion, a one-frame insert — moves both the
    /// histogram and the grid, so it looks exactly like a cut. What distinguishes it
    /// is that the content comes straight back. Cutting there would insert a held
    /// frame into the middle of a continuous shot.
    @Test("a flash that returns is not a cut")
    func flashIsNotACut() {
        var frames = gentlePan(count: 40)
        let phase = Float(0.8)
        frames.append(signature(histogramBin: 20, gridPhase: phase))          // normal
        frames.append(signature(histogramBin: 60, gridPhase: phase + 0.5))    // flash
        frames.append(signature(histogramBin: 20, gridPhase: phase))          // back
        frames += (0..<40).map { signature(histogramBin: 20, gridPhase: phase + Float($0) * 0.02) }

        let report = SceneChangeDetector.detect(signatures: frames)
        #expect(report.cutCount == 0, "a flash returns to the same content, so it is not a cut")
    }

    @Test("a quiet sequence does not produce a cut from noise")
    func quietSequenceIsStable() {
        // Tiny, uniform jitter — well under the absolute floor.
        let frames = (0..<60).map { i -> FrameSignature in
            var histogram = [Float](repeating: 0, count: 64)
            histogram[20] = 0.98
            histogram[21] = 0.02 * (i % 2 == 0 ? 1 : -1) + 0.02
            var grid = [Float](repeating: 0.5, count: 64)
            grid[0] = 0.5 + Float(i % 3) * 0.001
            return FrameSignature(histogram: histogram, grid: grid,
                                  gridWidth: 8, gridHeight: 8)
        }
        let report = SceneChangeDetector.detect(signatures: frames)
        #expect(report.cutCount == 0)
    }

    @Test("a global luminance ramp is not a cut")
    func fadeIsNotACut() {
        // A fade moves the histogram but barely moves the grid, so the grid floor
        // rejects it. Not a complete solution to fades — see the note in the source.
        let frames = (0..<50).map { i -> FrameSignature in
            var histogram = [Float](repeating: 0, count: 64)
            histogram[min(63, i)] = 1
            var grid = [Float](repeating: 0, count: 64)
            for j in 0..<64 { grid[j] = Float(i) / 100 + Float(j) * 0.001 }
            return FrameSignature(histogram: histogram, grid: grid,
                                  gridWidth: 8, gridHeight: 8)
        }
        let report = SceneChangeDetector.detect(signatures: frames)
        #expect(report.cutCount == 0)
    }

    @Test("the threshold adapts to the sequence")
    func thresholdIsAdaptive() {
        // A cut of a given magnitude is found in a quiet sequence but not in a
        // sequence that is already that jumpy — which is the whole reason the
        // threshold is derived from the recent window rather than fixed.
        var quiet = gentlePan(count: 40)
        quiet.append(signature(histogramBin: 52, gridPhase: 0.5))
        quiet += gentlePan(count: 40, startingBin: 52)
        let quietReport = SceneChangeDetector.detect(signatures: quiet)

        var noisy: [FrameSignature] = []
        for i in 0..<80 {
            noisy.append(signature(histogramBin: 20 + (i * 7) % 40, gridPhase: Float(i) * 0.3))
        }
        let noisyReport = SceneChangeDetector.detect(signatures: noisy)

        #expect(quietReport.cutCount >= 1)
        #expect(noisyReport.cutCount < 40, "a jumpy sequence must not flag every frame")
    }

    @Test("degenerate inputs are handled")
    func degenerateInputs() {
        #expect(SceneChangeDetector.detect(signatures: []).cutCount == 0)
        #expect(SceneChangeDetector.detect(signatures: [signature(histogramBin: 1,
                                                                  gridPhase: 0)]).cutCount == 0)
    }

    @Test("the report lines up with the signature count")
    func reportShape() {
        let frames = gentlePan(count: 25)
        let report = SceneChangeDetector.detect(signatures: frames)
        #expect(report.isCut.count == frames.count - 1)
        #expect(report.histogramDistance.count == frames.count - 1)
        #expect(report.gridDistance.count == frames.count - 1)
        #expect(report.threshold.count == frames.count - 1)
    }
}

@Suite("FrameSignature")
struct FrameSignatureTests {

    @Test("a signature built from a plane has a normalised histogram")
    func histogramIsNormalised() {
        let width = 64, height = 64
        var plane = [UInt8](repeating: 0, count: width * height)
        for i in 0..<plane.count { plane[i] = UInt8(i % 256) }
        let signature = plane.withUnsafeBufferPointer {
            FrameSignature.compute(luma: $0.baseAddress!, width: width, height: height,
                                   bytesPerRow: width)
        }
        let total = signature.histogram.reduce(0, +)
        #expect(abs(total - 1.0) < 1e-4, "histogram should sum to 1, got \(total)")
        #expect(signature.grid.count == 64 * 36)
        #expect(signature.grid.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("identical frames are at distance zero on both measures")
    func identicalFrames() {
        let a = signature(histogramBin: 20, gridPhase: 0.3)
        #expect(a.histogramDistance(to: a) == 0)
        #expect(a.gridDistance(to: a) == 0)
    }

    @Test("histogram distance is symmetric and bounded")
    func histogramDistanceProperties() {
        let a = signature(histogramBin: 10, gridPhase: 0)
        let b = signature(histogramBin: 60, gridPhase: 0)
        #expect(abs(a.histogramDistance(to: b) - b.histogramDistance(to: a)) < 1e-6)
        #expect(a.histogramDistance(to: b) <= 1.0)
        #expect(a.histogramDistance(to: b) > 0.9, "disjoint bins should be near 1")
    }

    @Test("a plane's stride is respected")
    func respectsStride() {
        // Same visible content, one with padding between rows. The signatures must
        // agree, or every CVPixelBuffer read is silently wrong.
        let width = 32, height = 32
        let stride = 48
        var padded = [UInt8](repeating: 99, count: stride * height)
        var tight = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((x * 7 + y * 3) % 256)
                padded[y * stride + x] = value
                tight[y * width + x] = value
            }
        }
        let paddedSignature = padded.withUnsafeBufferPointer {
            FrameSignature.compute(luma: $0.baseAddress!, width: width, height: height,
                                   bytesPerRow: stride)
        }
        let tightSignature = tight.withUnsafeBufferPointer {
            FrameSignature.compute(luma: $0.baseAddress!, width: width, height: height,
                                   bytesPerRow: width)
        }
        #expect(paddedSignature == tightSignature,
                "padding bytes must not leak into the signature")
    }
}
