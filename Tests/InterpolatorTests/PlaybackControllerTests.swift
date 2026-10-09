import Foundation
import Testing
@testable import Interpolator

/// The player's arithmetic, and the one rule in it that has already cost this project a
/// debugging round.
struct PlaybackControllerTests {

    private func rate(_ text: String) -> FrameRate { FrameRate.parse(text)! }

    // MARK: - Where to seek for a frame

    /// `-ss` returns the first frame at or **after** the instant, so frame `n` — which
    /// presents at `n / rate` — needs an instant strictly inside `(PTS(n-1), PTS(n)]`. The
    /// midpoint is `(n - 0.5) / rate`. Aiming at `(n + 0.5) / rate` returns `n + 1`, which is
    /// invariant 32 and is why the segmented render drifted one frame per boundary.
    @Test("a seek for a frame lands inside that frame's own presentation interval")
    func seekLandsInTheRightInterval() throws {
        for text in ["24000/1001", "30000/1001", "24", "25", "60000/1001"] {
            let r = rate(text)
            for frame in 1...200 {
                let seek = try #require(PlaybackController.seekSeconds(forFrame: frame, rate: r))
                let previous = Double(frame - 1) / r.doubleValue
                let own = Double(frame) / r.doubleValue
                #expect(seek > previous, "\(text) frame \(frame): seek \(seek) is not after \(previous)")
                #expect(seek <= own, "\(text) frame \(frame): seek \(seek) is past \(own)")
            }
        }
    }

    /// The bug, stated as a test. The natural-looking "aim at the middle of the frame" is
    /// `(n + 0.5) / rate`, and it is wrong — it lands in the *next* frame's interval.
    @Test("the seek is not the half-frame-forward answer, which lands on the next frame")
    func notTheHalfFrameForwardAnswer() throws {
        let r = rate("24000/1001")
        for frame in 1...50 {
            let ours = try #require(PlaybackController.seekSeconds(forFrame: frame, rate: r))
            let wrong = (Double(frame) + 0.5) / r.doubleValue
            #expect(ours < wrong)
            // And the wrong answer is genuinely in the next frame's interval, which is what
            // makes it wrong rather than merely different.
            #expect(wrong > Double(frame) / r.doubleValue,
                    "frame \(frame): the half-forward answer is still inside frame \(frame)")
        }
    }

    @Test("frame zero has no interval to aim into, so there is no seek")
    func frameZeroNeedsNoSeek() {
        // A negative time is not a seek ffmpeg will accept, and frame 0 is where the file
        // already starts.
        #expect(PlaybackController.seekSeconds(forFrame: 0, rate: rate("24000/1001")) == nil)
        #expect(PlaybackController.seekSeconds(forFrame: -5, rate: rate("24000/1001")) == nil)
    }

    @Test("the seek is a pure function of the frame and the rate")
    func seekIsExact() throws {
        let r = rate("60000/1001")
        // Frame 1 of 59.94: (1 - 0.5) x 1001/60000 = 0.0083416...
        let one = try #require(PlaybackController.seekSeconds(forFrame: 1, rate: r))
        #expect(abs(one - 0.5 * 1001.0 / 60000.0) < 1e-12)
    }

    // MARK: - The skip policy, as the controller uses it

    /// The player renders a *subset* of intervals, and this is the rule that chooses which.
    /// Rendering all of them would advance the film at 0.4x real time at 4K (invariant
    /// territory: an interval measures 104.7 ms against the 41.7 ms the film spends on one).
    @Test("an interval is rendered while the film has not finished playing it")
    func skipPolicy() {
        let pacer = PlaybackPacer(outputRate: rate("60000/1001"), leadSeconds: 1.0)
        let source = rate("24000/1001")
        // Interval 0 runs from 0 to 1/23.976 = 0.0417 s.
        #expect(pacer.rendersInterval(0, source: source, at: 0))
        #expect(pacer.rendersInterval(0, source: source, at: 0.04))
        #expect(!pacer.rendersInterval(0, source: source, at: 0.05),
                "interval 0 is over by 0.05 s and must not be computed")
        // Interval 10 ends at 11/23.976 = 0.4588 s.
        #expect(pacer.rendersInterval(10, source: source, at: 0.45))
        #expect(!pacer.rendersInterval(10, source: source, at: 0.46))
    }

    @Test("a negative interval is never rendered")
    func negativeInterval() {
        let pacer = PlaybackPacer(outputRate: rate("60000/1001"), leadSeconds: 1.0)
        #expect(!pacer.rendersInterval(-1, source: rate("24000/1001"), at: 0))
    }

    /// At 4K the renderer needs about two intervals in five. This states the arithmetic
    /// behind that number so it cannot drift silently: one rendered interval per
    /// `renderTime / frameInterval` intervals is what keeps the film moving at 1x.
    @Test("the render cost sets how many intervals have to be skipped")
    func skipRateFollowsTheRenderCost() {
        let source = rate("24000/1001")
        let frameInterval = 1.0 / source.doubleValue          // 41.7 ms
        let renderCost = 0.1047                                // measured at 4K
        let needed = renderCost / frameInterval                // ~2.5 intervals per render
        #expect(abs(needed - 2.51) < 0.02,
                "the 4K deficit is \(needed) intervals per render, not the recorded ~2.5")
        // Which is the recorded "about two intervals in five".
        #expect(abs(1.0 / needed - 0.4) < 0.01)
    }
}
