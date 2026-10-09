import Foundation
import Testing
@testable import Interpolator

/// The playback clock, and the one property that matters: media time is a function of the
/// anchors, not a running total.
///
/// Every test here drives a host clock the test owns, so none of them sleeps. That is not
/// only for speed — a test that sleeps is a test that measures the machine it runs on, and
/// the failures it produces are the ones that cannot be reproduced.
struct PlaybackClockTests {

    /// A host clock the test advances by hand.
    private final class Hand: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Double
        init(_ start: Double = 1000) { now = start }
        var source: PlaybackClock.TimeSource {
            { self.value }
        }
        var value: Double {
            lock.lock(); defer { lock.unlock() }
            return now
        }
        func advance(_ seconds: Double) {
            lock.lock(); now += seconds; lock.unlock()
        }
    }

    private func makeClock(_ hand: Hand, rate: Double = 1) -> PlaybackClock {
        PlaybackClock(rate: rate, timeSource: hand.source)
    }

    // MARK: - The anchor rule

    @Test("a stopped clock does not move, however much time passes")
    func stoppedHoldsStill() {
        let hand = Hand()
        let clock = makeClock(hand)
        hand.advance(30)
        #expect(clock.mediaTime == 0)
        #expect(clock.state == .stopped)
    }

    @Test("playing advances with the host clock, at the rate")
    func playingAdvances() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(1.5)
        #expect(abs(clock.mediaTime - 1.5) < 1e-9)
    }

    @Test("the rate scales the advance")
    func rateScales() {
        let hand = Hand()
        let clock = makeClock(hand, rate: 0.5)
        clock.play()
        hand.advance(4)
        #expect(abs(clock.mediaTime - 2.0) < 1e-9, "half speed over 4 s is 2 s of film")
    }

    /// The reason the clock recomputes instead of accumulating. A clock that added
    /// `elapsed * rate` on every read would give a different answer for the same instant
    /// depending on how often it was asked, and the answer would be the wrong one.
    @Test("reading the clock does not change it")
    func readingIsPure() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(2)
        let first = clock.mediaTime
        for _ in 0..<1000 { _ = clock.mediaTime }
        hand.advance(0)
        #expect(clock.mediaTime == first, "a thousand reads advanced the playhead")
    }

    @Test("asking for a past host time gives the media time that host time had")
    func mediaTimeAtHostTime() {
        let hand = Hand(500)
        let clock = makeClock(hand)
        clock.play()
        hand.advance(3)
        #expect(abs(clock.mediaTime(atHostTime: 501.25) - 1.25) < 1e-9)
        #expect(abs(clock.mediaTime(atHostTime: 503.0) - 3.0) < 1e-9)
    }

    // MARK: - Transitions

    @Test("a pause holds the playhead where it was, and resuming continues from there")
    func pauseIsContinuous() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(2)
        clock.pause()
        let atPause = clock.mediaTime
        #expect(abs(atPause - 2.0) < 1e-9)

        // Time passes while paused, and the playhead does not move.
        hand.advance(10)
        #expect(abs(clock.mediaTime - atPause) < 1e-9,
                "a paused clock advanced by \(clock.mediaTime - atPause) s")

        clock.play()
        hand.advance(1)
        #expect(abs(clock.mediaTime - 3.0) < 1e-9,
                "the ten paused seconds were counted as playback")
    }

    @Test("pausing twice is not a jump")
    func doublePause() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(1)
        clock.pause()
        let first = clock.mediaTime
        hand.advance(5)
        clock.pause()
        #expect(abs(clock.mediaTime - first) < 1e-9)
    }

    @Test("playing twice does not restart the clock")
    func doublePlay() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(1)
        clock.play()
        hand.advance(1)
        #expect(abs(clock.mediaTime - 2.0) < 1e-9,
                "the second play() re-anchored and lost a second")
    }

    @Test("a seek while playing resumes from the new position")
    func seekWhilePlaying() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(5)
        clock.seek(to: 100)
        #expect(abs(clock.mediaTime - 100) < 1e-9)
        #expect(clock.isPlaying, "seeking should not stop playback")

        hand.advance(1)
        #expect(abs(clock.mediaTime - 101) < 1e-9,
                "the five seconds before the seek were added to the new position")
    }

    @Test("a seek while paused stays paused")
    func seekWhilePaused() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(1)
        clock.pause()
        clock.seek(to: 42)
        hand.advance(3)
        #expect(abs(clock.mediaTime - 42) < 1e-9)
        #expect(clock.state == .paused)
    }

    @Test("a negative seek clamps to zero, because there is no frame before the first")
    func seekClampsAtZero() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(10)
        clock.seek(to: -5)
        #expect(clock.mediaTime == 0)
    }

    @Test("changing the rate keeps the playhead continuous")
    func rateChangeIsContinuous() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(2)
        clock.setRate(2)
        #expect(abs(clock.mediaTime - 2.0) < 1e-9,
                "the rate change moved the playhead to \(clock.mediaTime)")
        hand.advance(3)
        #expect(abs(clock.mediaTime - 8.0) < 1e-9, "2 s + 3 s at double speed")
    }

    @Test("stop returns to the beginning and does not run")
    func stopRewinds() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(9)
        clock.stop()
        #expect(clock.mediaTime == 0)
        hand.advance(4)
        #expect(clock.mediaTime == 0)
        #expect(clock.state == .stopped)
    }

    @Test("an ended film holds at its end rather than running past it")
    func endPinsThePlayhead() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.play()
        hand.advance(100)
        clock.end(at: 137.5)
        #expect(abs(clock.mediaTime - 137.5) < 1e-9)
        hand.advance(10)
        #expect(abs(clock.mediaTime - 137.5) < 1e-9,
                "an ended clock ran past the end of the film")
        #expect(clock.state == .ended)
    }

    @Test("playing an ended film restarts it")
    func endThenPlay() {
        let hand = Hand()
        let clock = makeClock(hand)
        clock.end(at: 10)
        // Pressing play at the end restarts the film — the only reading of the request
        // that produces anything, since there are no frames left after the end.
        clock.play()
        #expect(clock.mediaTime == 0)
        hand.advance(2)
        #expect(abs(clock.mediaTime - 2.0) < 1e-9)
    }

    @Test("media time is never negative, whatever the host clock does")
    func neverNegative() {
        let hand = Hand(0)
        let clock = makeClock(hand)
        clock.play()
        // A host clock that goes backwards — which a wall clock does when NTP steps it,
        // and the reason the default is the process uptime.
        hand.advance(-5)
        #expect(clock.mediaTime >= 0)
    }
}
