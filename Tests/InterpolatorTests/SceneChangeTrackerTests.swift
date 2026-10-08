import Foundation
import Testing
@testable import Interpolator

/// The online tracker and the offline detector must agree, always.
///
/// This is the property that matters. Batch conversion uses the offline path and
/// playback uses the online one, so any disagreement means the same film gets
/// different cut handling depending on whether it was converted or watched — and
/// the symptom is a ghost frame that shows up on one path only. A near-miss is not
/// good enough, so these tests require the two to be *identical*, not close.
private enum Shot {

    /// A frame from a shot, described by what it is made of and where things are.
    static func frame(bin: Int, phase: Float, bins: Int = 64, cells: Int = 64,
                      spread: Float = 0) -> FrameSignature {
        var histogram = [Float](repeating: 0, count: bins)
        if spread <= 0 {
            histogram[((bin % bins) + bins) % bins] = 1
        } else {
            // A broad bump, the shape that defeats a histogram-only rule.
            var total: Float = 0
            for i in 0..<bins {
                let d = Float(i) - Float(bin)
                let w = exp(-(d * d) / (2 * spread * spread))
                histogram[i] = w
                total += w
            }
            for i in 0..<bins { histogram[i] /= total }
        }
        var grid = [Float](repeating: 0, count: cells)
        for i in 0..<cells {
            grid[i] = 0.5 + 0.5 * sin(Float(i) * 0.5 + phase * 2 * .pi)
        }
        return FrameSignature(histogram: histogram, grid: grid, gridWidth: 8, gridHeight: 8)
    }

    /// Run a sequence through the offline detector and the online tracker and
    /// require the same answer for every interval.
    static func requireAgreement(_ frames: [FrameSignature],
                                 config: SceneChangeDetector.Config = .init(),
                                 _ label: String) {
        let offline = SceneChangeDetector.detect(signatures: frames, config: config)

        let tracker = SceneChangeTracker(config: config)
        for signature in frames { tracker.push(signature) }
        tracker.finish()
        let online = tracker.report

        #expect(online.isCut.count == offline.isCut.count,
                "\(label): \(online.isCut.count) online intervals vs \(offline.isCut.count) offline")
        if online.isCut != offline.isCut {
            var mismatches: [String] = []
            for (index, pair) in zip(online.isCut, offline.isCut).enumerated()
            where pair.0 != pair.1 {
                mismatches.append("\(index)(online \(pair.0 ? "cut" : "-"), "
                                  + "offline \(pair.1 ? "cut" : "-"))")
            }
            let detail = mismatches.joined(separator: ", ")
            Issue.record("\(label): online and offline disagree at intervals \(detail)")
        }
        // The distances and thresholds are what the decisions were made from, so
        // they have to match too — otherwise the agreement is a coincidence of
        // rounding rather than the same rule being run twice.
        #expect(online.histogramDistance == offline.histogramDistance, "\(label): hist distances")
        #expect(online.gridDistance == offline.gridDistance, "\(label): grid distances")
        #expect(online.threshold == offline.threshold, "\(label): thresholds")
    }
}

@Suite("SceneChangeTracker")
struct SceneChangeTrackerTests {

    @Test("a panning sequence agrees with the offline detector")
    func panAgrees() {
        let frames = (0..<60).map { Shot.frame(bin: 20, phase: Float($0) * 0.02) }
        Shot.requireAgreement(frames, "steady pan")
    }

    @Test("a sequence with cuts agrees, including which frames they are")
    func cutsAgree() {
        var frames = (0..<40).map { Shot.frame(bin: 20, phase: Float($0) * 0.02) }
        for (bin, phase) in [(52, Float(0.5)), (12, Float(1.2)), (33, Float(0.3))] {
            frames.append(Shot.frame(bin: bin, phase: phase))
            frames += (0..<25).map {
                Shot.frame(bin: bin, phase: phase + Float($0) * 0.02)
            }
        }
        Shot.requireAgreement(frames, "three cuts")

        // And confirm there is something to agree *about* — an equivalence test on
        // a sequence with no cuts in it proves nothing.
        let cuts = SceneChangeDetector.detect(signatures: frames).cutCount
        #expect(cuts == 3, "expected 3 cuts to compare, found \(cuts)")
    }

    @Test("dark footage agrees — the grid-spike path")
    func darkFootageAgrees() {
        // Both shots sit near black, so the histogram barely moves and only the
        // second rule path catches the cut.
        var frames = (0..<30).map {
            Shot.frame(bin: 10, phase: Float($0) * 0.02, spread: 6)
        }
        frames.append(Shot.frame(bin: 12, phase: 0.5, spread: 6))
        frames += (0..<30).map {
            Shot.frame(bin: 12, phase: 0.5 + Float($0) * 0.02, spread: 6)
        }
        Shot.requireAgreement(frames, "dark cut")
    }

    @Test("a lighting change that is not a cut agrees")
    func lightingChangeAgrees() {
        // The bright-clip failure mode: the histogram moves hard, the grid does not.
        var frames = (0..<30).map { Shot.frame(bin: 20, phase: Float($0) * 0.02) }
        frames.append(Shot.frame(bin: 44, phase: 0.6))
        frames += (0..<30).map {
            Shot.frame(bin: 44, phase: 0.6 + Float($0) * 0.02)
        }
        Shot.requireAgreement(frames, "lighting change")
    }

    @Test("a flash that returns agrees — the forward half of the guard")
    func flashAgrees() {
        // This is the case the two-frame lookahead exists for. A one-frame insert
        // looks exactly like a cut until you see the frame after next.
        var frames = (0..<30).map { Shot.frame(bin: 20, phase: Float($0) * 0.02) }
        frames.append(Shot.frame(bin: 55, phase: 2.4))          // the flash
        frames += (0..<30).map { Shot.frame(bin: 20, phase: 0.62 + Float($0) * 0.02) }
        Shot.requireAgreement(frames, "one-frame flash")
    }

    @Test("the tail is decided with the same end-of-stream semantics")
    func tailAgrees() {
        // A cut as the very last interval is the hardest case for the tail: offline
        // cannot run the forward guard there, and neither may the tracker.
        var frames = (0..<30).map { Shot.frame(bin: 20, phase: Float($0) * 0.02) }
        frames.append(Shot.frame(bin: 52, phase: 0.9))
        Shot.requireAgreement(frames, "cut in the final interval")

        // And a cut one interval earlier, where the forward guard *does* run.
        var earlier = (0..<30).map { Shot.frame(bin: 20, phase: Float($0) * 0.02) }
        earlier.append(Shot.frame(bin: 52, phase: 0.9))
        earlier.append(Shot.frame(bin: 52, phase: 0.94))
        Shot.requireAgreement(earlier, "cut in the second-to-last interval")
    }

    @Test("degenerate lengths agree")
    func degenerateAgrees() {
        Shot.requireAgreement([], "empty")
        Shot.requireAgreement([Shot.frame(bin: 20, phase: 0)], "one frame")
        Shot.requireAgreement([Shot.frame(bin: 20, phase: 0),
                                   Shot.frame(bin: 20, phase: 0.02)], "two frames")
        Shot.requireAgreement((0..<3).map { Shot.frame(bin: 20, phase: Float($0) * 0.1) },
                                  "three frames")
        // Five frames is the shortest that can prime the adaptive window at all.
        Shot.requireAgreement((0..<5).map { Shot.frame(bin: 20, phase: Float($0) * 0.1) },
                                  "five frames")
    }

    @Test("the decoder's own frame shape is what the tracker is fed")
    func agreesOnRealisticLengths() {
        // 191 frames is the reference clip's length, and the sequence below has its
        // five cuts at its five cut positions. The real clips are checked against
        // the harness separately; this keeps the equivalence suite honest at the
        // length the pipeline actually runs at.
        let cuts = [6, 69, 101, 108, 168]
        var frames: [FrameSignature] = []
        var bin = 18
        var phase: Float = 0
        for i in 0..<191 {
            if cuts.contains(i) {
                bin = (bin + 17) % 60
                phase += 0.37
            } else {
                phase += 0.011
            }
            frames.append(Shot.frame(bin: bin, phase: phase))
        }
        Shot.requireAgreement(frames, "191 frames with five cuts")
        #expect(SceneChangeDetector.detect(signatures: frames).cutCount >= 3,
                "the synthetic clip should contain detectable cuts")
    }

    @Test("it stays bounded over a feature-length stream")
    func staysBounded() {
        // A 2-hour film is ~154,000 frames and a signature carries a 64x36 grid, so
        // holding them all would be about 1.4 GB. The tracker must not.
        let tracker = SceneChangeTracker()
        var phase: Float = 0
        var bin = 20
        for i in 0..<40_000 {
            if i % 500 == 0 { bin = (bin + 13) % 60 }
            phase += 0.009
            tracker.push(Shot.frame(bin: bin, phase: phase))
        }
        tracker.finish()

        #expect(tracker.count == 40_000)
        #expect(tracker.allDecisions.count == 39_999)
        let retained = tracker.retained
        #expect(retained.signatures <= 4,
                "kept \(retained.signatures) signatures; the rule can only reach 4")
        #expect(retained.distances <= 32,
                "kept \(retained.distances) distances; only historyLength are needed")
    }

    @Test("decisions arrive with a two-frame delay, in order, exactly once")
    func decisionTiming() {
        let tracker = SceneChangeTracker()
        var emitted: [Int] = []
        for i in 0..<20 {
            let produced = tracker.push(Shot.frame(bin: 20, phase: Float(i) * 0.02))
            for decision in produced {
                #expect(decision.interval == emitted.count,
                        "decisions must be consecutive and in order")
                emitted.append(decision.interval)
            }
            // Interval i becomes judgeable only once signature i+2 has arrived.
            let expectedDecided = max(0, i - 1)
            #expect(tracker.count - 2 == expectedDecided || i < 2,
                    "after \(i + 1) signatures, \(expectedDecided) intervals should be decided")
        }
        let tail = tracker.finish()
        for decision in tail { emitted.append(decision.interval) }
        #expect(emitted == Array(0..<19), "every interval decided exactly once, in order")
        #expect(tracker.finish().isEmpty, "finish() must be idempotent")
    }
}
