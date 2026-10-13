import Foundation
import Testing
@testable import Interpolator

/// The time-remaining projection.
///
/// The cases that matter are the ones `elapsed / fraction` gets wrong, because that formula is
/// the obvious one and this type exists to replace it: a job whose clock started before its work
/// did, a job whose pace changed halfway, and a job that has stopped. Each of those has a wrong
/// answer that looks plausible, which is the kind of wrong answer a four-hour progress bar must
/// not show.
struct ProgressEstimatorTests {

    /// Feed a run at a constant `perSecond` fraction rate, one sample a second.
    private func feed(_ estimator: inout ProgressEstimator,
                      from start: Double, through end: Double,
                      startingAt fraction: Double, perSecond: Double) -> Double {
        var f = fraction
        var t = start
        while t <= end {
            estimator.observe(fraction: f, at: t)
            t += 1
            f += perSecond
        }
        return f
    }

    // MARK: - Saying nothing

    @Test("with nothing observed it claims nothing")
    func empty() {
        let e = ProgressEstimator()
        #expect(e.remaining == nil)
        #expect(e.rate == nil)
        #expect(e.fraction == nil)
        #expect(!e.hasEstimate)
    }

    @Test("a window that shows no progress reports nothing rather than forever")
    func stalled() {
        var e = ProgressEstimator()
        // The job is running but not advancing. `elapsed / fraction` here divides by a
        // constant and grows without bound; a stalled job is a different thing from a slow one.
        for t in stride(from: 0.0, through: 60.0, by: 1.0) {
            e.observe(fraction: 0.4, at: t)
        }
        #expect(e.rate == nil)
        #expect(e.remaining == nil)
    }

    @Test("one sample is not a rate")
    func oneSample() {
        var e = ProgressEstimator()
        e.observe(fraction: 0.5, at: 0)
        #expect(e.remaining == nil)
    }

    @Test("a span shorter than the window is not a rate")
    func tooShort() {
        var e = ProgressEstimator(minimumWindow: 10)
        e.observe(fraction: 0.0, at: 0)
        e.observe(fraction: 0.01, at: 3)
        #expect(e.remaining == nil, "3 s of evidence cannot support a 10 s window")
    }

    // MARK: - The projection itself

    @Test("a steady rate projects the rest of the job")
    func steady() throws {
        var e = ProgressEstimator()
        // 1% of the job per second, 20 s in.
        _ = feed(&e, from: 0, through: 20, startingAt: 0, perSecond: 0.01)
        let remaining = try #require(e.remaining)
        // 20% done at 1%/s leaves 80 s.
        #expect(abs(remaining - 80) < 5, "got \(remaining)")
    }

    /// The bug this type was written for. A conversion probes the film and works on its audio
    /// *before* it renders, and the old formula started its clock at the probe — so every second
    /// of audio extraction was counted as a second of rendering, and the projection read long
    /// for the rest of the job.
    @Test("time that produced no progress does not inflate the projection")
    func slowStart() throws {
        var e = ProgressEstimator()
        // Sixty seconds of preamble: the clock is running, the fraction is not moving.
        for t in stride(from: 0.0, through: 60.0, by: 1.0) {
            e.observe(fraction: 0.0, at: t)
        }
        // Then the render proper, 0.5% per second for twenty seconds.
        _ = feed(&e, from: 61, through: 80, startingAt: 0.005, perSecond: 0.005)

        let remaining = try #require(e.remaining)
        // 10% done at 0.5%/s leaves 180 s.
        #expect(abs(remaining - 180) < 20, "got \(remaining)")
        // The whole-run formula would divide 80 s of clock by 10% of job and say 720 s.
        #expect(remaining < 400, "the preamble must not be in the rate")
    }

    @Test("a change of pace is followed, not averaged away")
    func paceChange() throws {
        var e = ProgressEstimator()
        // A minute at 1% per second.
        _ = feed(&e, from: 0, through: 60, startingAt: 0, perSecond: 0.01)
        // Then an action scene: half the rate, for another minute.
        _ = feed(&e, from: 61, through: 120, startingAt: 0.60, perSecond: 0.005)

        let remaining = try #require(e.remaining)
        // 90% done at 0.5%/s leaves 20 s. `elapsed / fraction` would say 13 s — the old pace
        // is still in the average and it has no way to forget it.
        #expect(abs(remaining - 20) < 8, "got \(remaining)")
    }

    /// The old formula refused to say anything for thirty seconds. A 4K feature film advances
    /// about 7e-5 of itself per second, and a rate measured over a few seconds is already stable
    /// enough to be worth saying.
    @Test("an estimate exists within seconds, not after the old thirty-second gate")
    func prompt() {
        var e = ProgressEstimator()
        // A two-hour film at 23.976 is about 172 627 intervals; 4K renders about 12.5 a second.
        let intervals = 172_627.0
        var done = 0.0
        for t in stride(from: 0.0, through: 8.0, by: 1.0) {
            e.observe(fraction: done / intervals, at: t)
            done += 12.5
        }
        #expect(e.remaining != nil, "8 s of a 3.8 h job must be enough to say something")
    }

    @Test("a feature-film rate projects the feature film")
    func featureFilm() throws {
        var e = ProgressEstimator()
        let intervals = 172_627.0
        let perSecond = 12.5
        var done = 0.0
        for t in stride(from: 0.0, through: 40.0, by: 1.0) {
            e.observe(fraction: done / intervals, at: t)
            done += perSecond
        }
        let remaining = try #require(e.remaining)
        // 500 of 172 627 intervals done at 12.5/s leaves 13 770 s — 3.83 hours.
        #expect(abs(remaining - 13_770) < 300, "got \(remaining)")
    }

    // MARK: - Edges

    @Test("a fraction that goes backwards is a new run, not a negative rate")
    func backwards() {
        var e = ProgressEstimator()
        _ = feed(&e, from: 0, through: 30, startingAt: 0, perSecond: 0.01)
        #expect(e.remaining != nil)

        // A restart, or a different film in the same slot.
        e.observe(fraction: 0.0, at: 31)
        #expect(e.fraction == 0)
        #expect(e.remaining == nil, "the old window must not survive the seam")
    }

    @Test("a finished job has nothing left")
    func finished() {
        var e = ProgressEstimator()
        _ = feed(&e, from: 0, through: 30, startingAt: 0, perSecond: 0.03)
        e.observe(fraction: 1.0, at: 31)
        #expect(e.fraction == 1)
        #expect(e.remaining == nil)
    }

    @Test("the remainder is never negative, even when the fraction overshoots")
    func neverNegative() {
        var e = ProgressEstimator()
        _ = feed(&e, from: 0, through: 30, startingAt: 0, perSecond: 0.03)
        // The fraction is an estimate — Matroska states no frame count — so it can pass 1.
        e.observe(fraction: 1.4, at: 31)
        #expect(e.fraction == 1, "clamped, not trusted")
        #expect(e.remaining == nil)
    }

    @Test("nonsense input is ignored rather than propagated")
    func nonsense() {
        var e = ProgressEstimator()
        e.observe(fraction: .nan, at: 0)
        e.observe(fraction: 0.5, at: .infinity)
        #expect(e.fraction == nil)

        // A negative fraction is clamped to zero rather than becoming a negative rate.
        e.observe(fraction: -0.5, at: 1)
        #expect(e.fraction == 0)
    }

    @Test("reset forgets the run")
    func resetting() {
        var e = ProgressEstimator()
        _ = feed(&e, from: 0, through: 30, startingAt: 0, perSecond: 0.01)
        #expect(e.remaining != nil)

        e.reset()
        #expect(e.remaining == nil)
        #expect(e.fraction == nil)
        #expect(!e.hasEstimate)
    }
}
