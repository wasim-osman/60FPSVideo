import Foundation

/// Decides which output frame belongs on screen right now, and how many to throw away
/// to get to it.
///
/// ## The problem it exists for
///
/// A 4K render cannot keep up with 59.94 fps of output — measured at 24.5 fps against the
/// 23.976 fps source in the harness, so the *interpolation* is roughly real-time at 1080p
/// and well short of it at 4K. Something has to give, and the choice is between two
/// visible failures:
///
/// - **Fall behind.** Every frame is shown, each a little late, and the delay grows without
///   bound. The picture and the sound drift apart, and no amount of buffering fixes it
///   because the deficit is per-frame, not transient.
/// - **Drop.** Some frames are never shown. The motion stutters, and the film stays in
///   sync.
///
/// The decision — recorded in `BUILD-DECISIONS.md` — is **drop**, because the audio is a
/// stream that runs at exactly one speed and video that drifts away from it is worse than
/// video that stutters. This type is that decision, as arithmetic.
///
/// ## Why there is no tolerance parameter
///
/// The obvious-looking knob is "how late may a frame be and still be shown", and it is a
/// trap. Adding it means a frame that is one frame late is *shown* — and then the next one
/// is two frames late, and the deficit is now permanent, which is the failure this type
/// exists to prevent.
///
/// The rule that needs no tolerance is the one stated exactly: at media time `t`, the frame
/// that belongs on screen is `floor(t × rate)`. If the head of the queue is *older* than
/// that, it has already been superseded and showing it would be showing the wrong picture;
/// if it is that frame or newer, it is on time or early. There is no "slightly late"
/// category, because the frame's own presentation time is what decides it — a head that is
/// 2 ms past its own timestamp is still `floor(t × rate)` for another 16.7 ms, so it is
/// shown. A tolerance would only ever make the decision wrong in the direction that costs
/// sync.
public struct PlaybackPacer: Sendable {

    /// The output rate the film is being presented at.
    public let outputRate: FrameRate

    /// How far ahead of the playhead the producer may run, in seconds of output.
    ///
    /// This is the *only* knob, and it is about the queue rather than about dropping:
    /// enough that decode and interpolation jitter do not starve the display, small enough
    /// that a seek does not have to throw away a second of work. One second is about 60
    /// output frames at 59.94.
    public let leadSeconds: Double

    public init(outputRate: FrameRate, leadSeconds: Double = 1.0) {
        self.outputRate = outputRate
        self.leadSeconds = max(0, leadSeconds)
    }

    /// How many output frames the producer may run ahead by. The queue's capacity.
    ///
    /// Rounded **up**: a queue one frame short of a second of output drops a frame at
    /// every poll, which looks exactly like a machine that cannot keep up.
    public var leadFrames: Int {
        max(1, Int((leadSeconds * outputRate.doubleValue).rounded(.up)))
    }

    /// The output frame whose presentation interval contains `mediaTime`.
    ///
    /// Clamped at zero: there is no frame before the first one, and a negative index would
    /// index backwards off the front of the queue.
    public func targetOutputIndex(at mediaTime: Double) -> Int {
        guard mediaTime > 0 else { return 0 }
        let exact = mediaTime * outputRate.doubleValue
        // `floor`, not round: frame `n` presents at `n / rate` and stays on screen until
        // `(n + 1) / rate`, so the frame at `t` is the one whose time has been reached.
        return max(0, Int(exact.rounded(.down)))
    }

    /// The output time at which frame `index` presents.
    public func presentationTime(of index: Int) -> Double {
        Double(index) / outputRate.doubleValue
    }

    /// How many frames at the head of the queue have been superseded and should be
    /// discarded.
    ///
    /// `available` is how many frames there are to discard, so the answer can never send
    /// the caller past the end of the queue. Zero means the head is the frame to show —
    /// either exactly on time or early, and being early is not a problem: the display layer
    /// holds a sample until its timestamp arrives.
    public func staleCount(headIndex: Int, available: Int, at mediaTime: Double) -> Int {
        guard available > 0 else { return 0 }
        let target = targetOutputIndex(at: mediaTime)
        let superseded = target - headIndex
        guard superseded > 0 else { return 0 }
        return min(superseded, available)
    }

    /// Whether a frame's moment has passed, so showing it would be showing the wrong
    /// picture.
    ///
    /// The caller decides whether that matters. It does not when the frame is the newest
    /// one available: a player that refuses to show a late frame when there is nothing
    /// newer to show displays nothing at all, and a film that cannot keep up would be a
    /// black screen rather than a stutter. It matters when something newer is queued, and
    /// then the older frame is exactly the one to throw away.
    public func isSuperseded(_ index: Int, at mediaTime: Double) -> Bool {
        index < targetOutputIndex(at: mediaTime)
    }

    /// How far the head of the queue is behind the playhead, in output frames.
    ///
    /// Negative when the producer is ahead, which is the normal case. Exposed so a
    /// controller can report the deficit rather than only act on it — a machine that is
    /// dropping a third of its frames is a different problem from one dropping none, and
    /// the number is the only way to tell them apart from the outside.
    public func deficit(headIndex: Int, at mediaTime: Double) -> Int {
        targetOutputIndex(at: mediaTime) - headIndex
    }
}
