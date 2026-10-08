import Foundation

/// The phase plan, produced one source interval at a time.
///
/// ## Why this exists alongside ``PhasePlan``
///
/// `PhasePlan` needs the total source frame count before it can produce anything:
/// it derives an upper bound `kMax` from `lastSourceIndex`, and that bound is what
/// terminates its loop. For a packed file that is fine — the file size gives the
/// count. Neither real consumer has it:
///
/// - **Batch conversion** reads a Matroska file, and ffprobe reports
///   `nb_frames=N/A` for it. The count is not known until the whole film has been
///   decoded, which is the wrong end of the job.
/// - **Playback** has no total at all. It is a stream, and the user can stop it
///   whenever they like.
///
/// The count is only ever used to decide *where to stop*. What kind of output
/// frame `k` is depends on nothing but `k` and the two rates, so the plan can be
/// generated interval by interval and stopped when the source runs out. That is
/// what this does, and it is why the pipeline can be written once and driven by
/// both consumers.
///
/// ## The arithmetic is the same arithmetic
///
/// Output frame `k` sits at source position
///
/// ```
/// t = k * (srcNum/srcDen) / (outNum/outDen) = k * pnum / pden
/// ```
///
/// with `pnum = srcNum * outDen` and `pden = srcDen * outNum` — the identical
/// integers `PhasePlan` uses, not a restatement of them in floating point. That
/// matters for the same reason it matters there: 23.976024 against 59.94 gives a
/// ratio of 0.4000004 rather than 0.4, the fractional part drifts 4e-7 per frame,
/// and every passthrough frame beyond the first is lost.
///
/// Interval `j` — the gap between source frames `j` and `j + 1` — owns exactly
/// those `k` with
///
/// ```
/// j * pden  <=  k * pnum  <  (j + 1) * pden
/// ```
///
/// which is a closed integer range. The whole plan is the concatenation of those
/// ranges over `j = 0, 1, 2, …`, in order. `IntervalPlannerTests` requires this to
/// reproduce `PhasePlan` frame for frame, and its cut handling to reproduce
/// `PhasePlan.resolvingCuts` — the same "one rule, two paths must agree" check
/// that keeps the two scene detectors honest. Two implementations of the same
/// arithmetic is one implementation too many unless something proves they match.
public struct IntervalPlanner: Sendable {

    public let source: FrameRate
    public let output: FrameRate

    /// `srcNum * outDen`. Together with `pden` this is the whole plan.
    private let pnum: Int
    /// `srcDen * outNum`.
    private let pden: Int

    public init(source: FrameRate, output: FrameRate) {
        self.source = source
        self.output = output
        self.pnum = source.numerator * output.denominator
        self.pden = source.denominator * output.numerator
    }

    /// Whether the rates admit a plan at all. False only for a degenerate rate,
    /// which `FrameRate` already refuses to construct.
    public var isUsable: Bool { pnum > 0 && pden > 0 }

    /// True when the output rate is at least the source rate, which is the only
    /// case this project builds: the product is 60 fps output or nothing.
    public var isUpsampling: Bool { isUsable && pnum <= pden }

    /// Every output frame that belongs to source interval `j`.
    ///
    /// Empty when the output rate is *below* the source rate and this interval
    /// falls between output samples — a case the app never produces, but which
    /// the callers handle by skipping the interval rather than by trusting the
    /// rate check to have been made somewhere else.
    public func output(forInterval j: Int) -> [OutputFrame] {
        guard isUsable, j >= 0 else { return [] }

        // j * pden <= k * pnum, rounded up: the first k at or after the lower edge.
        let kMin = (j * pden + pnum - 1) / pnum
        // k * pnum < (j + 1) * pden, rounded down. `ceil(a/b) - 1 == (a - 1)/b`
        // for positive integers, which is the form that cannot go wrong.
        let kMax = ((j + 1) * pden - 1) / pnum
        guard kMin <= kMax else { return [] }

        var frames: [OutputFrame] = []
        frames.reserveCapacity(kMax - kMin + 1)
        for k in kMin...kMax {
            let t = k * pnum
            let remainder = t % pden
            if remainder == 0 {
                // Exactly on a source frame. Costs nothing, so the engine is not
                // called for it — that is one output frame in five on
                // 23.976 -> 59.94, and the reason the passthrough count is
                // reported everywhere.
                frames.append(OutputFrame(index: k, kind: .passthrough(sourceIndex: j)))
            } else {
                frames.append(OutputFrame(
                    index: k,
                    kind: .interpolate(before: j, after: j + 1,
                                       phase: Double(remainder) / Double(pden))))
            }
        }
        return frames
    }

    /// The most output frames any one interval can produce.
    ///
    /// The window `[j*pden, (j+1)*pden)` has length `pden` and therefore contains
    /// at most `(pden - 1)/pnum + 1` multiples of `pnum`. On 23.976 -> 59.94 that
    /// is 3, which is what the engine's own `maximumInterpolationsPerInterval`
    /// (5, with slack for the phase landing either side of a boundary) has to be
    /// able to cover.
    public var maximumOutputFramesPerInterval: Int {
        guard isUsable else { return 0 }
        return (pden - 1) / pnum + 1
    }

    /// The source interval that owns output frame `k`. The inverse of
    /// ``output(forInterval:)``, and exact for the same reason.
    public func interval(forOutputIndex k: Int) -> Int {
        guard isUsable, k >= 0 else { return 0 }
        return (k * pnum) / pden
    }

    /// Whether output frame `k` lands exactly on a source frame.
    public func isPassthrough(outputIndex k: Int) -> Bool {
        guard isUsable, k >= 0 else { return false }
        return (k * pnum) % pden == 0
    }
}
