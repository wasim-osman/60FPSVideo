import Foundation

/// One frame of output: either a source frame handed through untouched, or a frame
/// the engine has to synthesise.
public struct OutputFrame: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Emit source frame `sourceIndex` verbatim. Costs nothing.
        case passthrough(sourceIndex: Int)
        /// Synthesise the frame at `phase` between `before` and `after`, where
        /// phase 0 is `before` and phase 1 is `after`.
        case interpolate(before: Int, after: Int, phase: Double)
    }

    /// Position in the output sequence.
    public let index: Int
    public let kind: Kind

    public var isPassthrough: Bool {
        if case .passthrough = kind { return true }
        return false
    }
}

/// The work for one adjacent pair of source frames, as the engine wants it.
///
/// VTFrameProcessor is handed a source pair plus a list of phases and returns all
/// those frames from one call. Its cost is per *call*, not per output frame, so
/// grouping by interval is not just convenient — it is where the speed comes from.
public struct SourceInterval: Sendable {
    public let sourceIndex: Int
    /// Every output frame this interval produces, in output order.
    public let output: [OutputFrame]

    public var passthroughs: [OutputFrame] { output.filter(\.isPassthrough) }
    public var interpolations: [OutputFrame] {
        output.filter { if case .interpolate = $0.kind { return true }; return false }
    }
}

/// Which output frames to produce, and how.
///
/// ## The arithmetic is exact, and that is the point (invariant 14)
///
/// Output frame `k` sits at source position
///
/// ```
/// t = k * (srcNum/srcDen) / (outNum/outDen) = k * srcNum * outDen / (srcDen * outNum)
/// ```
///
/// which is a ratio of integers. When `t` lands on a whole number the output frame
/// *is* a source frame and needs no interpolation. That test is `remainder == 0` —
/// exact, and the only form of it that survives a long sequence.
///
/// The first version of this used floating point with an epsilon, on the theory that
/// 0.9999999998 should count as zero. That was the wrong fix: 23.976024 against
/// 59.94 gives a ratio of 0.4000004, not 0.4, so the fractional part drifts 4e-7 per
/// frame and the epsilon is blown by frame 5. Result: 1 passthrough frame instead of
/// 95, and 20% more inference than necessary.
public struct PhasePlan: Sendable {

    /// Every output frame, in order.
    public let frames: [OutputFrame]
    /// The same frames grouped by source interval, ready to hand to the engine.
    public let intervals: [SourceInterval]

    public let passthroughCount: Int
    public let interpolatedCount: Int

    public var outputFrameCount: Int { frames.count }

    /// Build the plan. Returns `nil` for fewer than two source frames, since there
    /// is no interval to interpolate across.
    public init?(sourceFrameCount: Int, source: FrameRate, output: FrameRate) {
        guard sourceFrameCount >= 2 else { return nil }

        let pnum = source.numerator * output.denominator
        let pden = source.denominator * output.numerator
        guard pnum > 0, pden > 0 else { return nil }

        let lastSourceIndex = sourceFrameCount - 1
        // An upper bound on how many output frames there can be, plus slack.
        let kMax = (lastSourceIndex * pden) / pnum + 2

        var frames: [OutputFrame] = []
        var byInterval: [Int: [OutputFrame]] = [:]
        var passthroughs = 0
        var interpolations = 0

        for k in 0..<kMax {
            let t = k * pnum
            let j = t / pden
            if j >= lastSourceIndex { break }

            let remainder = t % pden
            let frame: OutputFrame
            if remainder == 0 {
                frame = OutputFrame(index: k, kind: .passthrough(sourceIndex: j))
                passthroughs += 1
            } else {
                let phase = Double(remainder) / Double(pden)
                frame = OutputFrame(index: k, kind: .interpolate(before: j, after: j + 1,
                                                                phase: phase))
                interpolations += 1
            }
            frames.append(frame)
            byInterval[j, default: []].append(frame)
        }

        guard !frames.isEmpty else { return nil }

        self.frames = frames
        self.intervals = byInterval.keys.sorted().map {
            SourceInterval(sourceIndex: $0, output: byInterval[$0]!)
        }
        self.passthroughCount = passthroughs
        self.interpolatedCount = interpolations
    }

    private init(frames: [OutputFrame], intervals: [SourceInterval],
                 passthroughCount: Int, interpolatedCount: Int) {
        self.frames = frames
        self.intervals = intervals
        self.passthroughCount = passthroughCount
        self.interpolatedCount = interpolatedCount
    }

    /// Return a plan in which no output frame interpolates across a scene cut
    /// (invariant 15).
    ///
    /// ## What happens at a cut
    ///
    /// The frames in a cut interval are not blended — blending them is precisely the
    /// double-exposure this exists to prevent. Instead each one is replaced by the
    /// **nearest source frame**: phases below 0.5 show the outgoing shot, phases at
    /// or above 0.5 show the incoming one.
    ///
    /// This does duplicate one frame at the cut, because the last output frame of the
    /// outgoing shot and the first of the incoming shot are the same source picture.
    /// At 59.94 fps that is a 16.7 ms hold — which is what a cut looks like anyway.
    /// A held frame is not an artefact; a ghost is.
    public func resolvingCuts(_ report: SceneChangeReport) -> PhasePlan {
        var resolvedFrames: [OutputFrame] = []
        resolvedFrames.reserveCapacity(frames.count)
        var resolvedIntervals: [SourceInterval] = []
        resolvedIntervals.reserveCapacity(intervals.count)
        var passthroughs = 0
        var interpolations = 0

        for interval in intervals {
            let isCut = interval.sourceIndex < report.isCut.count
                && report.isCut[interval.sourceIndex]

            var output: [OutputFrame] = []
            output.reserveCapacity(interval.output.count)
            for frame in interval.output {
                guard case .interpolate(let before, let after, let phase) = frame.kind else {
                    output.append(frame)
                    passthroughs += 1
                    continue
                }
                if isCut {
                    let source = phase < 0.5 ? before : after
                    output.append(OutputFrame(index: frame.index,
                                              kind: .passthrough(sourceIndex: source)))
                    passthroughs += 1
                } else {
                    output.append(frame)
                    interpolations += 1
                }
            }
            resolvedIntervals.append(SourceInterval(sourceIndex: interval.sourceIndex,
                                                    output: output))
        }

        for interval in resolvedIntervals { resolvedFrames.append(contentsOf: interval.output) }

        return PhasePlan(frames: resolvedFrames, intervals: resolvedIntervals,
                         passthroughCount: passthroughs, interpolatedCount: interpolations)
    }
}
