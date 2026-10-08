import Foundation

/// A cheap description of one frame, enough to tell a cut from motion.
///
/// Two views of the same luma plane, because a cut and a fast pan look alike in
/// either one alone:
///
/// - the **histogram** says what the frame is *made of*. It barely moves during a
///   pan or a whip, and jumps when the shot changes.
/// - the **grid** says where things *are*. It moves for both.
///
/// A cut is therefore high on both. A pan is high on the grid and flat on the
/// histogram. Requiring both is what keeps fast motion from being mistaken for a
/// cut — which matters here, because the clip this was built against is an action
/// film whose fastest motion was deliberately selected.
public struct FrameSignature: Sendable, Equatable {

    /// Normalised luma histogram; sums to 1.
    public let histogram: [Float]
    /// Downsampled luma, each sample in 0...1, row-major.
    public let grid: [Float]
    public let gridWidth: Int
    public let gridHeight: Int

    public init(histogram: [Float], grid: [Float], gridWidth: Int, gridHeight: Int) {
        self.histogram = histogram
        self.grid = grid
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    /// Build a signature from a luma plane.
    ///
    /// - Parameters:
    ///   - luma: base address of the luma plane.
    ///   - format: sample width of that plane. Both formats are normalised by their
    ///     own maximum code value, which puts them on the same 0...1 scale — see
    ///     `FrameFormat.maxCodeValue`. That is what makes one set of thresholds
    ///     valid for SDR and HDR alike.
    ///   - bytesPerRow: the plane's stride, which is not `width` on a CVPixelBuffer
    ///     and is not `width * bytesPerSample` for packed input either.
    public static func compute(luma: UnsafeRawPointer,
                               format: FrameFormat,
                               width: Int,
                               height: Int,
                               bytesPerRow: Int,
                               gridWidth: Int = 64,
                               gridHeight: Int = 36,
                               histogramBins: Int = 64) -> FrameSignature {
        let gw = max(1, min(gridWidth, width))
        let gh = max(1, min(gridHeight, height))

        // Hoisted so the inner loops stay branch-free: this is called once per
        // source frame against a ~105 ms engine call, so it is nowhere near the
        // critical path, but a predictable branch costs nothing anyway.
        let fullScale = Float(format.maxCodeValue)
        let binCount = format.maxCodeValue + 1

        // ---- grid: box-average each cell, capped at 4x4 samples per cell so the
        // cost stays flat as resolution rises.
        var grid = [Float](repeating: 0, count: gw * gh)
        let cellW = Double(width) / Double(gw)
        let cellH = Double(height) / Double(gh)
        for gy in 0..<gh {
            let y0 = min(height - 1, Int(Double(gy) * cellH))
            let y1 = max(y0 + 1, min(height, Int(Double(gy + 1) * cellH)))
            for gx in 0..<gw {
                let x0 = min(width - 1, Int(Double(gx) * cellW))
                let x1 = max(x0 + 1, min(width, Int(Double(gx + 1) * cellW)))
                let stepX = max(1, (x1 - x0) / 4)
                let stepY = max(1, (y1 - y0) / 4)
                var sum = 0
                var count = 0
                var y = y0
                while y < y1 {
                    let row = luma + y * bytesPerRow
                    var x = x0
                    while x < x1 {
                        sum += format.lumaCode(row, x)
                        count += 1
                        x += stepX
                    }
                    y += stepY
                }
                grid[gy * gw + gx] = count > 0 ? Float(sum) / Float(count) / fullScale : 0
            }
        }

        // ---- histogram: stride-sample the full plane so the true distribution is
        // kept rather than the grid's already-averaged one.
        var bins = [Int](repeating: 0, count: histogramBins)
        var total = 0
        let stride = max(1, min(width, height) / 256)
        var y = 0
        while y < height {
            let row = luma + y * bytesPerRow
            var x = 0
            while x < width {
                let bin = min(histogramBins - 1,
                              format.lumaCode(row, x) * histogramBins / binCount)
                bins[bin] += 1
                total += 1
                x += stride
            }
            y += stride
        }
        var histogram = [Float](repeating: 0, count: histogramBins)
        if total > 0 {
            for i in 0..<histogramBins { histogram[i] = Float(bins[i]) / Float(total) }
        }

        return FrameSignature(histogram: histogram, grid: grid,
                              gridWidth: gw, gridHeight: gh)
    }

    /// Build a signature from an 8-bit luma plane. Kept because most callers have
    /// exactly that, and because it is the shape the tests were written against.
    public static func compute(luma: UnsafePointer<UInt8>,
                               width: Int,
                               height: Int,
                               bytesPerRow: Int,
                               gridWidth: Int = 64,
                               gridHeight: Int = 36,
                               histogramBins: Int = 64) -> FrameSignature {
        compute(luma: UnsafeRawPointer(luma), format: .nv12,
                width: width, height: height, bytesPerRow: bytesPerRow,
                gridWidth: gridWidth, gridHeight: gridHeight,
                histogramBins: histogramBins)
    }

    /// Total-variation distance between two histograms, in 0...1.
    /// 0 is identical, 1 is no shared mass at all.
    public func histogramDistance(to other: FrameSignature) -> Float {
        var sum: Float = 0
        for i in 0..<min(histogram.count, other.histogram.count) {
            sum += abs(histogram[i] - other.histogram[i])
        }
        return sum / 2
    }

    /// Mean absolute difference of the grids, in 0...1.
    public func gridDistance(to other: FrameSignature) -> Float {
        guard grid.count == other.grid.count, !grid.isEmpty else { return 0 }
        var sum: Float = 0
        for i in 0..<grid.count { sum += abs(grid[i] - other.grid[i]) }
        return sum / Float(grid.count)
    }
}

/// Where the cuts are, and the evidence for each.
public struct SceneChangeReport: Sendable {
    /// `isCut[i]` means a cut between source frame `i` and `i + 1`.
    public let isCut: [Bool]
    public let histogramDistance: [Float]
    public let gridDistance: [Float]
    public let threshold: [Float]

    public init(isCut: [Bool], histogramDistance: [Float], gridDistance: [Float],
                threshold: [Float]) {
        self.isCut = isCut
        self.histogramDistance = histogramDistance
        self.gridDistance = gridDistance
        self.threshold = threshold
    }

    public var cutCount: Int { isCut.filter { $0 }.count }
    public var cutIntervals: [Int] { isCut.indices.filter { isCut[$0] } }
}

/// Finds scene cuts so the interpolator can refuse to interpolate across them
/// (invariant 15).
///
/// ## Why this is mandatory rather than nice to have
///
/// Neither `VTFrameProcessor` nor RIFE detects cuts, and both produce a visible
/// double-exposure when asked to interpolate across one — verified on real film, on
/// the same frame, in both engines. A 2-hour action film has roughly 2000 cuts, so
/// without this every one of them becomes a ghost frame.
///
/// The correct behaviour at a cut is not a better blend. It is to **not blend at
/// all**: pass the source frame through.
///
/// ## Thresholding
///
/// The threshold is adaptive, because a fixed one cannot work across content. This
/// project's own reference clip is a night scene where half the frame sits below
/// 0.17 nits; an absolute histogram threshold tuned on normal footage would miss
/// every cut in it. So the threshold is derived from a rolling window of the recent
/// distances: `median + k * 1.4826 * MAD`, floored, with MAD standing in for the
/// standard deviation because a window of cut distances is exactly the kind of
/// spiky distribution a standard deviation handles badly.
public enum SceneChangeDetector {

    public struct Config: Sendable {
        /// Rolling window used to estimate what "normal motion" looks like here.
        public var historyLength = 30
        /// How many robust sigmas above the recent median a distance must be.
        public var sigmaMultiplier: Float = 8.0
        /// Never call a cut on the histogram below this, however quiet the sequence.
        public var histogramFloor: Float = 0.12
        /// Never call a cut on the grid below this.
        ///
        /// This is the constraint that actually separates a shot change from
        /// everything else, and it was originally set to 0.02 — which is *below*
        /// ordinary motion, so it constrained nothing. Measured across two real
        /// clips (a dark night chase and a bright desert daylight scene), ordinary
        /// motion never exceeds a grid distance of **0.037**, while the smallest
        /// genuine cut in either clip is **0.105**. 0.07 sits between them with
        /// roughly 1.9× margin below and 1.5× above.
        ///
        /// What this catches, concretely: on the bright clip a flare or exposure
        /// shift swept the blown-out sky and moved the histogram to 0.121 and
        /// 0.163 — clear of the 0.12 histogram floor — while moving the spatial
        /// grid by only 0.036 and 0.040, i.e. no more than ordinary motion. Those
        /// are lighting changes, not cuts, and the histogram alone cannot tell them
        /// apart. The grid can.
        public var gridFloor: Float = 0.07
        /// The grid spike path also requires the histogram to be at least this many
        /// times the recent median. It does not have to be *high* — see the note on
        /// dark footage below — only clearly not flat.
        public var mildHistogramFactor: Float = 4.0
        /// Absolute floor for the mild histogram test, so a very quiet sequence
        /// cannot pass it on noise alone.
        public var mildHistogramFloor: Float = 0.03
        /// Flash guard. If the content is back where it started on the far side of
        /// the transition, the "cut" was a flash or a one-frame insert.
        public var flashReturnRatio: Float = 0.45

        public init() {}
    }

    /// Detect cuts across a whole sequence.
    ///
    /// This is a pure function over pre-computed signatures, which is what makes it
    /// testable without a video. For streaming playback the caller computes
    /// signatures as frames arrive and keeps one frame of lookahead, since the flash
    /// guard needs to see `i + 2`.
    public static func detect(signatures: [FrameSignature],
                              config: Config = Config()) -> SceneChangeReport {
        let n = signatures.count
        guard n >= 2 else {
            return SceneChangeReport(isCut: [], histogramDistance: [], gridDistance: [],
                                     threshold: [])
        }

        var histD = [Float](repeating: 0, count: n - 1)
        var gridD = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            histD[i] = signatures[i].histogramDistance(to: signatures[i + 1])
            gridD[i] = signatures[i].gridDistance(to: signatures[i + 1])
        }

        // Pairwise grid distances used only by the flash guard. Two directions,
        // because a one-frame flash has two transitions and only checking forwards
        // catches just one of them.
        var forwardGridD = [Float](repeating: 0, count: n)
        for i in 0..<max(0, n - 2) {
            forwardGridD[i] = signatures[i].gridDistance(to: signatures[i + 2])
        }
        var backwardGridD = [Float](repeating: 0, count: n)
        for i in 1..<max(1, n - 1) {
            backwardGridD[i] = signatures[i - 1].gridDistance(to: signatures[i + 1])
        }

        var thresholds = [Float](repeating: config.histogramFloor, count: n - 1)
        var isCut = [Bool](repeating: false, count: n - 1)

        for i in 0..<(n - 1) {
            let windowStart = max(0, i - config.historyLength)
            let histWindow = histD[windowStart..<i]
            let gridWindow = gridD[windowStart..<i]

            let histThreshold = SceneChangeDetector.robustThreshold(
                histWindow, sigmaMultiplier: config.sigmaMultiplier,
                floor: config.histogramFloor)
            let gridThreshold = SceneChangeDetector.robustThreshold(
                gridWindow, sigmaMultiplier: config.sigmaMultiplier,
                floor: config.gridFloor)
            thresholds[i] = histThreshold

            // Two ways to be a cut.
            //
            // A. The classic: both measures jump. A pan moves the grid but leaves
            //    the histogram alone, so requiring both is what keeps fast motion
            //    from being mistaken for a shot change.
            let strongOnBoth = histD[i] > histThreshold && gridD[i] > config.gridFloor

            // B. The grid jumps hard and the histogram is at least *not flat*.
            //
            //    This path exists because of measured failure on real film. The
            //    reference clip is a night scene, and one of its cuts — source
            //    frames 168 to 169 — moves the grid by 0.105 while moving the
            //    histogram by only 0.074, because both shots sit near black and
            //    their tonal distributions are genuinely similar. Path A misses it.
            //    The histogram is still required to move clearly (several times the
            //    recent median), which is what separates this from a pan.
            let median = histWindow.isEmpty ? 0 : histWindow.sorted()[histWindow.count / 2]
            let mildHistogram = max(config.mildHistogramFloor,
                                    config.mildHistogramFactor * median)
            let gridSpike = gridD[i] > gridThreshold && histD[i] > mildHistogram

            guard strongOnBoth || gridSpike else { continue }

            // Flash guard. A flash, a camera strobe or a one-frame insert moves both
            // measures exactly like a cut does; what marks it out is that the content
            // either side of it is the same. Check both sides, or a one-frame insert
            // is caught on the way in and missed on the way out.
            let limit = config.flashReturnRatio * gridD[i]
            if i + 2 < n, forwardGridD[i] < limit { continue }
            if i >= 1, backwardGridD[i] < limit { continue }

            isCut[i] = true
        }

        return SceneChangeReport(isCut: isCut, histogramDistance: histD,
                                 gridDistance: gridD, threshold: thresholds)
    }

    /// Median plus `sigmaMultiplier` robust sigmas, floored.
    ///
    /// MAD stands in for the standard deviation because the window being measured
    /// contains cuts, and a cut is exactly the kind of outlier a standard deviation
    /// handles badly — one cut in thirty frames would inflate sigma enough to hide
    /// the next one. 1.4826 converts a MAD into a sigma estimate for normal data.
    private static func robustThreshold(_ values: ArraySlice<Float>,
                                        sigmaMultiplier: Float,
                                        floor: Float) -> Float {
        guard values.count >= 4 else { return floor }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        return max(floor, median + sigmaMultiplier * 1.4826 * mad)
    }

    /// Convenience: compute signatures and detect in one pass.
    ///
    /// `base` is raw rather than `UnsafePointer<UInt8>` because the plane may be
    /// 10-bit, in which case the samples are 16-bit words and a `UInt8` view would
    /// silently describe half as many, wrong, samples.
    public static func detect(lumaPlanes: [(base: UnsafeRawPointer, width: Int,
                                            height: Int, bytesPerRow: Int)],
                              format: FrameFormat = .nv12,
                              config: Config = Config()) -> SceneChangeReport {
        let signatures = lumaPlanes.map {
            FrameSignature.compute(luma: $0.base, format: format,
                                   width: $0.width, height: $0.height,
                                   bytesPerRow: $0.bytesPerRow)
        }
        return detect(signatures: signatures, config: config)
    }
}
