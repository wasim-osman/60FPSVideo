import Testing
@testable import Interpolator

@Suite("PhasePlan")
struct PhasePlanTests {

    @Test("23.976 -> 59.94 makes exactly 20% of output frames passthrough")
    func filmToNTSC() {
        let plan = PhasePlan(sourceFrameCount: 191,
                             source: FrameRate.parse("23.976")!,
                             output: FrameRate.parse("59.94")!)!
        // 190 source intervals at a 2.5x ratio is exactly 475 output frames.
        #expect(plan.outputFrameCount == 475)
        #expect(plan.passthroughCount == 95)
        #expect(plan.interpolatedCount == 380)
        #expect(Double(plan.passthroughCount) / Double(plan.outputFrameCount) == 0.2)
    }

    @Test("29.97 -> 59.94 makes exactly 50% passthrough")
    func NTSCToNTSC() {
        let plan = PhasePlan(sourceFrameCount: 101,
                             source: FrameRate.parse("29.97")!,
                             output: FrameRate.parse("59.94")!)!
        #expect(plan.outputFrameCount == 200)
        #expect(plan.passthroughCount == 100)
        #expect(plan.interpolatedCount == 100)
    }

    /// The regression test for the bug that cost 20% of throughput.
    ///
    /// 23.976024 and 59.94 as decimals reduce to a ratio of 0.4000004, not 0.4, so
    /// the fractional part drifts and no output frame beyond the first ever lands
    /// exactly on a source frame. Result: 1 passthrough frame instead of 95, and 20%
    /// more inference than necessary.
    @Test("a decimal rate destroys the passthrough frames")
    func decimalRateLosesPassthroughs() {
        let decimal = PhasePlan(sourceFrameCount: 191,
                                source: FrameRate.parseLiteral("23.976024")!,
                                output: FrameRate.parseLiteral("59.94")!)!
        let exact = PhasePlan(sourceFrameCount: 191,
                              source: FrameRate.parse("23.976")!,
                              output: FrameRate.parse("59.94")!)!

        #expect(exact.passthroughCount == 95)
        #expect(decimal.passthroughCount <= 2,
                "a decimal rate leaves almost no passthrough frames, got \(decimal.passthroughCount)")
        #expect(decimal.interpolatedCount > exact.interpolatedCount,
                "and therefore does more inference than necessary")
        #expect(decimal.outputFrameCount == exact.outputFrameCount,
                "the output length is unaffected; only the cost changes")
    }

    @Test("every output frame is either a passthrough or an interpolation")
    func everyFrameIsClassified() {
        let plan = PhasePlan(sourceFrameCount: 191,
                             source: FrameRate.parse("23.976")!,
                             output: FrameRate.parse("59.94")!)!
        #expect(plan.passthroughCount + plan.interpolatedCount == plan.outputFrameCount)
        for frame in plan.frames where !frame.isPassthrough {
            guard case .interpolate(let before, let after, let phase) = frame.kind else {
                Issue.record("unexpected kind at output frame \(frame.index)")
                continue
            }
            #expect(after == before + 1)
            #expect(phase > 0 && phase < 1)
        }
    }

    @Test("intervals cover the sequence and stay inside bounds")
    func intervalsAreSane() {
        let sourceFrameCount = 191
        let plan = PhasePlan(sourceFrameCount: sourceFrameCount,
                             source: FrameRate.parse("23.976")!,
                             output: FrameRate.parse("59.94")!)!
        #expect(plan.intervals.count == sourceFrameCount - 1)
        for interval in plan.intervals {
            #expect(interval.sourceIndex >= 0)
            #expect(interval.sourceIndex + 1 < sourceFrameCount)
            #expect(!interval.output.isEmpty)
        }
    }

    @Test("a passthrough frame really is its own source frame")
    func passthroughIndicesAreCorrect() {
        let plan = PhasePlan(sourceFrameCount: 20,
                             source: FrameRate.parse("23.976")!,
                             output: FrameRate.parse("59.94")!)!
        for frame in plan.frames {
            guard case .passthrough(let sourceIndex) = frame.kind else { continue }
            // k * 2/5 must be a whole number equal to sourceIndex
            #expect(frame.index * 2 % 5 == 0)
            #expect(frame.index * 2 / 5 == sourceIndex)
        }
    }

    @Test("fewer than two source frames has no plan")
    func needsTwoFrames() {
        #expect(PhasePlan(sourceFrameCount: 0,
                          source: FrameRate.parse("24")!,
                          output: FrameRate.parse("60")!) == nil)
        #expect(PhasePlan(sourceFrameCount: 1,
                          source: FrameRate.parse("24")!,
                          output: FrameRate.parse("60")!) == nil)
    }

    @Test("24 -> 60 is 2.5x as well, and makes the same 20% passthrough")
    func wholeNumberRatio() {
        let plan = PhasePlan(sourceFrameCount: 191,
                             source: FrameRate.parse("24")!,
                             output: FrameRate.parse("60")!)!
        #expect(plan.outputFrameCount == 475)
        #expect(plan.passthroughCount == 95)
    }
}

@Suite("PhasePlan cut resolution")
struct CutResolutionTests {

    private func plan(_ frames: Int) -> PhasePlan {
        PhasePlan(sourceFrameCount: frames,
                  source: FrameRate.parse("23.976")!,
                  output: FrameRate.parse("59.94")!)!
    }

    private func report(cuts: Set<Int>, frames: Int) -> SceneChangeReport {
        var isCut = [Bool](repeating: false, count: frames - 1)
        for cut in cuts where cut >= 0 && cut < isCut.count { isCut[cut] = true }
        return SceneChangeReport(isCut: isCut,
                                 histogramDistance: [Float](repeating: 0, count: frames - 1),
                                 gridDistance: [Float](repeating: 0, count: frames - 1),
                                 threshold: [Float](repeating: 0, count: frames - 1))
    }

    @Test("a cut turns that interval's interpolations into passthroughs")
    func cutBecomesPassthrough() {
        let base = plan(191)
        let resolved = base.resolvingCuts(report(cuts: [6], frames: 191))

        // Interval 6 produces output frames 16 and 17, both interpolated before.
        #expect(resolved.interpolatedCount < base.interpolatedCount)
        #expect(resolved.passthroughCount > base.passthroughCount)
        #expect(resolved.outputFrameCount == base.outputFrameCount,
                "the output must stay constant-rate; the count cannot change")

        for frame in resolved.frames where frame.index == 16 || frame.index == 17 {
            #expect(frame.isPassthrough, "frame \(frame.index) should have been passed through")
        }
    }

    @Test("nearest-source: phase below 0.5 shows the outgoing shot, above shows the incoming")
    func nearestSourcePolicy() {
        let base = plan(191)
        let resolved = base.resolvingCuts(report(cuts: [6], frames: 191))

        // Output frame 16 is at t = 6.4 (phase 0.4) -> source 6
        // Output frame 17 is at t = 6.8 (phase 0.8) -> source 7
        guard case .passthrough(let first) = resolved.frames[16].kind,
              case .passthrough(let second) = resolved.frames[17].kind else {
            Issue.record("frames 16 and 17 should both be passthroughs")
            return
        }
        #expect(first == 6)
        #expect(second == 7)
    }

    @Test("a cut does not disturb any other interval")
    func cutIsLocal() {
        let base = plan(191)
        let resolved = base.resolvingCuts(report(cuts: [6], frames: 191))
        for index in base.frames.indices where index < 16 || index > 17 {
            #expect(base.frames[index].kind == resolved.frames[index].kind,
                    "frame \(index) should be untouched")
        }
    }

    @Test("no cuts means no change at all")
    func noCutsNoChange() {
        let base = plan(191)
        let resolved = base.resolvingCuts(report(cuts: [], frames: 191))
        #expect(resolved.interpolatedCount == base.interpolatedCount)
        #expect(resolved.passthroughCount == base.passthroughCount)
        #expect(resolved.frames == base.frames)
    }

    @Test("a cut at the very first interval is handled")
    func cutAtStart() {
        let base = plan(191)
        let resolved = base.resolvingCuts(report(cuts: [0], frames: 191))
        #expect(resolved.outputFrameCount == base.outputFrameCount)
        // Interval 0 (source 0 -> 1) produces output frames 1 and 2, at t = 0.4 and
        // t = 0.8. Both must stop being interpolated.
        #expect(resolved.frames[1].isPassthrough)
        #expect(resolved.frames[2].isPassthrough)
        // Frame 3 belongs to interval 1, which was not cut, so it must be untouched.
        #expect(resolved.frames[3].kind == base.frames[3].kind)
    }
}
