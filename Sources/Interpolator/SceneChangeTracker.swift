import Foundation

/// Scene-cut detection for a stream, one frame at a time.
///
/// ## Why this exists alongside the offline detector
///
/// Batch conversion reads a whole clip and can look at every frame before deciding
/// anything. Playback cannot: frames arrive from the decoder and have to be judged
/// as they come, with a fixed amount of lookahead. Both paths must reach the *same*
/// answer, or a cut would be handled one way when you convert the film and another
/// way when you watch it — and the symptom would be a ghost frame that appears on
/// one path only, at some cuts, sometimes.
///
/// So this is not a second implementation of the rule. It gathers the same
/// ``IntervalEvidence`` the offline detector gathers and hands it to the same
/// ``CutRule``. What differs is only *when* the evidence becomes available.
///
/// ## How much lookahead, and why
///
/// Two things need frames from the future:
///
/// - the flash guard wants `grid(i, i+2)`, to tell a cut from a strobe that returns;
/// - the adaptive threshold wants the recent distances *before* `i`, which is the past.
///
/// So interval `i` can be judged once signature `i + 2` has arrived — a two-frame
/// delay. At 23.976 fps that is 83 ms, which playback can absorb: it is already
/// buffering ahead of the playhead.
///
/// The one place this cannot match offline exactly is the **final interval**, which
/// has no frame after next. Offline, the forward half of the flash guard simply does
/// not run there. ``finish()`` reproduces that, rather than inventing a different
/// answer for the tail.
///
/// ## Memory
///
/// Bounded, and it has to be: a 2-hour film is ~154,000 frames, and a single
/// signature carries a 64×36 grid — holding them all would be about 1.4 GB. The
/// tracker keeps four signatures (the window the rule can reach) and
/// `historyLength` distances, so it runs in a few kilobytes regardless of length.
public final class SceneChangeTracker {

    /// One interval's verdict, emitted as soon as it is final.
    public struct Decision: Sendable, Equatable {
        /// A cut between source frame `interval` and `interval + 1`.
        public let interval: Int
        public let isCut: Bool
        public let histogramDistance: Float
        public let gridDistance: Float
        /// The histogram threshold that was in force for this decision.
        public let threshold: Float

        public init(interval: Int, isCut: Bool, histogramDistance: Float,
                    gridDistance: Float, threshold: Float) {
            self.interval = interval
            self.isCut = isCut
            self.histogramDistance = histogramDistance
            self.gridDistance = gridDistance
            self.threshold = threshold
        }
    }

    private let config: SceneChangeDetector.Config

    /// The last few signatures, oldest first. Only four are reachable by the rule.
    private var recent: [FrameSignature] = []
    private var recentBase = 0

    /// Distances by absolute interval index: `histDistances[k]` is interval
    /// `distanceBase + k`.
    private var histDistances: [Float] = []
    private var gridDistances: [Float] = []
    private var distanceBase = 0

    private var signatureCount = 0
    private var nextInterval = 0
    private var decisions: [Decision] = []
    private var isFinished = false

    public init(config: SceneChangeDetector.Config = SceneChangeDetector.Config()) {
        self.config = config
    }

    /// Signatures consumed so far.
    public var count: Int { signatureCount }

    /// How much is actually being held. Internal rather than public because it
    /// exists for the test that the tracker stays bounded on a feature-length
    /// stream — the guarantee is real, and the only way to check it is to look.
    var retained: (signatures: Int, distances: Int) {
        (recent.count, histDistances.count)
    }

    /// Every decision made so far, in order. Kept because both callers want to log
    /// them; a decision is 20 bytes, so a 2-hour film costs a few megabytes.
    public var allDecisions: [Decision] { decisions }

    /// The decisions as the offline detector's report shape, for callers that want
    /// to reuse the existing logging and tests.
    public var report: SceneChangeReport {
        SceneChangeReport(
            isCut: decisions.map(\.isCut),
            histogramDistance: decisions.map(\.histogramDistance),
            gridDistance: decisions.map(\.gridDistance),
            threshold: decisions.map(\.threshold))
    }

    /// Feed the next signature in order. Returns any decisions that became final.
    ///
    /// Typically zero or one per call: one interval is decided per signature once
    /// the pipeline is primed.
    @discardableResult
    public func push(_ signature: FrameSignature) -> [Decision] {
        precondition(!isFinished, "push after finish()")
        let index = signatureCount
        recent.append(signature)
        signatureCount += 1

        // Interval `index - 1` is the gap between the previous frame and this one.
        if index >= 1, let previous = self.signature(at: index - 1) {
            histDistances.append(previous.histogramDistance(to: signature))
            gridDistances.append(previous.gridDistance(to: signature))
        }

        // Interval i is judgeable once signature i+2 exists, which is now true for
        // i = index - 2.
        let produced = decide(through: index - 2,
                             forwardAvailableThrough: index)
        trim()
        return produced
    }

    /// End of stream. Decides the tail — the intervals that never got a frame after
    /// next — with the forward half of the flash guard unavailable, exactly as the
    /// offline detector leaves it.
    @discardableResult
    public func finish() -> [Decision] {
        guard !isFinished else { return [] }
        isFinished = true
        let produced = decide(through: signatureCount - 2,
                             forwardAvailableThrough: signatureCount - 1)
        trim()
        return produced
    }

    // MARK: - Internals

    private func decide(through limit: Int,
                        forwardAvailableThrough: Int) -> [Decision] {
        var produced: [Decision] = []
        while nextInterval <= limit {
            let i = nextInterval
            guard let evidence = evidence(for: i,
                                          forwardAvailableThrough: forwardAvailableThrough)
            else { break }
            let verdict = CutRule.evaluate(evidence, config: config)
            let decision = Decision(interval: i,
                                    isCut: verdict.isCut,
                                    histogramDistance: evidence.histogramDistance,
                                    gridDistance: evidence.gridDistance,
                                    threshold: verdict.threshold)
            produced.append(decision)
            decisions.append(decision)
            nextInterval += 1
        }
        return produced
    }

    private func evidence(for i: Int,
                          forwardAvailableThrough: Int) -> IntervalEvidence? {
        // Both frames must exist for interval `i` to be a real interval: the plan only
        // produces it because it has pixels for `i` and `i + 1`, so a decision for an
        // interval without them would be a decision about a frame nobody shows. `b` is
        // the same signature the backward guard wants, so it is bound once and reused.
        guard let a = signature(at: i), let b = signature(at: i + 1) else { return nil }
        guard i >= distanceBase, i - distanceBase < histDistances.count else { return nil }

        let windowStart = max(distanceBase, i - config.historyLength)
        let history = (windowStart..<i).map { histDistances[$0 - distanceBase] }
        let historyGrid = (windowStart..<i).map { gridDistances[$0 - distanceBase] }

        var forward: Float?
        if i + 2 <= forwardAvailableThrough,
           let afterNext = signature(at: i + 2) {
            forward = a.gridDistance(to: afterNext)
        }

        var backward: Float?
        if i >= 1, let before = signature(at: i - 1) {
            backward = before.gridDistance(to: b)
        }

        return IntervalEvidence(
            histogramDistance: histDistances[i - distanceBase],
            gridDistance: gridDistances[i - distanceBase],
            historyHistogram: history,
            historyGrid: historyGrid,
            forwardGrid: forward,
            backwardGrid: backward)
    }

    /// Signatures are only reachable four frames back, so four is all we keep.
    private func signature(at index: Int) -> FrameSignature? {
        let offset = index - recentBase
        guard offset >= 0, offset < recent.count else { return nil }
        return recent[offset]
    }

    private func trim() {
        // Signatures: keep the last four, which is what the rule can reach
        // (i-1, i, i+1, i+2 for the oldest interval still pending).
        let signatureKeep = 4
        if recent.count > signatureKeep {
            let drop = recent.count - signatureKeep
            recent.removeFirst(drop)
            recentBase += drop
        }

        // Distances: the oldest any future decision can ask for is
        // `nextInterval - historyLength`.
        let oldestNeeded = max(0, nextInterval - config.historyLength)
        if oldestNeeded > distanceBase {
            let drop = min(oldestNeeded - distanceBase, histDistances.count)
            histDistances.removeFirst(drop)
            gridDistances.removeFirst(drop)
            distanceBase += drop
        }
    }
}
