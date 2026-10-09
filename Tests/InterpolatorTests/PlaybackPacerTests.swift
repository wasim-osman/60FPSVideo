import Foundation
import Testing
@testable import Interpolator

/// The drop policy: which output frame belongs on screen at a given moment.
///
/// The interesting cases are all near a frame boundary, because that is where a policy with
/// a tolerance gets it wrong — it shows a frame that has been superseded, which costs sync
/// permanently rather than for one frame.
struct PlaybackPacerTests {

    private func rate(_ text: String) -> FrameRate { FrameRate.parse(text)! }
    private var ntsc: FrameRate { rate("60000/1001") }

    private func pacer(lead: Double = 1.0) -> PlaybackPacer {
        PlaybackPacer(outputRate: ntsc, leadSeconds: lead)
    }

    // MARK: - Which frame is due

    @Test("at zero the first frame is due")
    func atZero() {
        #expect(pacer().targetOutputIndex(at: 0) == 0)
        #expect(pacer().targetOutputIndex(at: -1) == 0, "there is no frame before the first")
    }

    /// One frame of 59.94 is `1001/60000` s = 0.0166833…, so the boundary is just after
    /// 0.016683 s — not at 0.0167 and not at 1/60 = 0.016667, which is a *different* rate.
    @Test("a frame stays due until the next frame's time arrives")
    func boundaryIsExact() {
        let p = pacer()
        let frame = 1001.0 / 60000.0
        #expect(p.targetOutputIndex(at: frame * 0.5) == 0)
        #expect(p.targetOutputIndex(at: frame * 0.999) == 0)
        #expect(p.targetOutputIndex(at: frame * 1.001) == 1)
        #expect(p.targetOutputIndex(at: frame * 1.999) == 1)
        #expect(p.targetOutputIndex(at: frame * 2.001) == 2)
    }

    @Test("the boundary is the frame's own time, not a rounded 60 fps")
    func boundaryIsNotSixty() {
        let p = pacer()
        // 1/60 = 0.0166667 s is *before* frame 1's own time of 0.0166833 s. A pacer built
        // on 60.000 would call frame 1 due 16.7 µs early, and over a two-hour film that is
        // 0.12 s of drift — the same class of error invariant 14 exists for.
        #expect(p.targetOutputIndex(at: 1.0 / 60.0) == 0)
        #expect(abs(p.presentationTime(of: 1) - 1001.0 / 60000.0) < 1e-12)
    }

    @Test("a second in is a second of frames")
    func oneSecond() {
        #expect(pacer().targetOutputIndex(at: 1.0) == 59)
        #expect(pacer().targetOutputIndex(at: 2.0) == 119)
    }

    @Test("presentation time and index invert each other")
    func roundTrip() {
        let p = pacer()
        for index in [0, 1, 59, 60, 3600, 154_000] {
            let t = p.presentationTime(of: index)
            #expect(p.targetOutputIndex(at: t) == index,
                    "frame \(index) at \(t) s came back as \(p.targetOutputIndex(at: t))")
        }
    }

    // MARK: - What to throw away

    /// The rule that needs no tolerance: a frame is superseded only once a *later* frame's
    /// time has arrived. A frame 2 ms past its own timestamp is still the frame that
    /// belongs on screen, so it is shown — and that is what keeps a player that is keeping
    /// up from dropping a frame at every poll.
    @Test("a frame barely past its time is not superseded")
    func slightlyLateIsFine() {
        let p = pacer()
        let frame = 1001.0 / 60000.0
        // Frame 0 presents at 0 and stays on screen until frame 1's time; 2 ms past its own
        // timestamp it is still the frame that belongs there.
        #expect(!p.isSuperseded(0, at: 0.002),
                "a frame 2 ms past its own time was treated as superseded")
        // The same, one frame later: 0.5 ms past frame 1's own time is still frame 1.
        #expect(!p.isSuperseded(1, at: frame + 0.0005),
                "half a millisecond late was treated as superseded")
        #expect(p.targetOutputIndex(at: frame + 0.0005) == 1,
                "the boundary is the frame's own time, not a rounded 60 fps")
    }

    @Test("a frame is superseded once the next one is due")
    func supersededAfterNextIsDue() {
        let p = pacer()
        let frame = 1001.0 / 60000.0
        #expect(p.isSuperseded(0, at: frame * 1.5), "frame 0 is past once frame 1 is due")
        #expect(!p.isSuperseded(1, at: frame * 1.5))
    }

    @Test("the count to discard is the distance behind the clock, capped by what there is")
    func staleCount() {
        let p = pacer()
        let frame = 1001.0 / 60000.0
        // The clock is at frame 10, the head is frame 7: three to discard.
        #expect(p.staleCount(headIndex: 7, available: 5, at: frame * 10.5) == 3)
        // Only two are queued, so at most two can go.
        #expect(p.staleCount(headIndex: 7, available: 2, at: frame * 10.5) == 2)
        // On time, and ahead of time: nothing to discard.
        #expect(p.staleCount(headIndex: 10, available: 5, at: frame * 10.5) == 0)
        #expect(p.staleCount(headIndex: 40, available: 5, at: frame * 10.5) == 0)
        // An empty queue cannot have anything discarded from it.
        #expect(p.staleCount(headIndex: 0, available: 0, at: frame * 100) == 0)
    }

    @Test("the deficit is negative while the producer is ahead")
    func deficit() {
        let p = pacer()
        let frame = 1001.0 / 60000.0
        #expect(p.deficit(headIndex: 5, at: frame * 10.5) == 5)
        #expect(p.deficit(headIndex: 20, at: frame * 10.5) == -10)
    }

    // MARK: - The queue's depth

    @Test("the lead rounds up, so the queue is never one frame short of a second")
    func leadRoundsUp() {
        // 1 s at 59.94 is 59.94 frames. A queue of 59 would be one short of a full second
        // and would drop a frame at every poll — indistinguishable from a slow machine.
        #expect(PlaybackPacer(outputRate: ntsc, leadSeconds: 1.0).leadFrames == 60)
        #expect(PlaybackPacer(outputRate: ntsc, leadSeconds: 0.5).leadFrames == 30)
        #expect(PlaybackPacer(outputRate: rate("60"), leadSeconds: 1.0).leadFrames == 60)
    }

    @Test("a lead of zero still leaves a queue of one, which cannot deadlock")
    func zeroLeadStillHasCapacity() {
        #expect(PlaybackPacer(outputRate: ntsc, leadSeconds: 0).leadFrames == 1)
        #expect(PlaybackPacer(outputRate: ntsc, leadSeconds: -5).leadFrames == 1)
    }

    @Test("a shorter lead is a smaller queue")
    func leadScales() {
        let two = PlaybackPacer(outputRate: ntsc, leadSeconds: 2.0)
        let one = PlaybackPacer(outputRate: ntsc, leadSeconds: 1.0)
        #expect(two.leadFrames > one.leadFrames)
    }
}
