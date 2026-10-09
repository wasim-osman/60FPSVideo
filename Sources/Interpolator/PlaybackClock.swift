import Foundation

/// Media time for playback, measured against a host clock.
///
/// ## Why not just use `CMTimebase`
///
/// The display layer wants a `CMTimebase`, and it will get one — but a timebase is a
/// CoreMedia object that cannot be driven deterministically from a test, and the rules
/// below are exactly the kind that are wrong in a way nobody notices for a week. So the
/// arithmetic lives here, over a `TimeSource` that is one closure wide, and the timebase
/// is built from this rather than the other way round.
///
/// ## The one rule
///
/// Media time is **not** accumulated. It is `anchorMedia + (now - anchorHost) * rate`,
/// recomputed from the anchors every time it is asked for. Accumulating — `mediaTime +=
/// elapsed * rate` on a timer — drifts, and worse, it drifts *differently* on a machine
/// that is busy, which is the machine that is playing 4K. Recomputing cannot drift,
/// because there is nothing to accumulate: the error is bounded by the host clock's own
/// resolution rather than by the number of times the timer fired.
///
/// Every operation that changes the rate, the position or the run state **re-anchors**,
/// so media time is continuous across it. That is what stops a pause from jumping the
/// playhead and a rate change from losing the fraction of a frame in flight.
///
/// `@unchecked Sendable` is accurate: everything mutable is behind `lock`.
public final class PlaybackClock: @unchecked Sendable {

    /// Monotonic host seconds.
    ///
    /// A seam, one closure wide, because the alternative — a clock that reads the
    /// machine's uptime — is a clock no test can pin down. The shipping default is the
    /// process uptime, which is monotonic and does not jump when the wall clock is
    /// adjusted by NTP mid-film.
    public typealias TimeSource = @Sendable () -> Double

    public enum State: Sendable, Equatable {
        /// Never started, or explicitly stopped. Media time is zero.
        case stopped
        case playing
        case paused
        /// The film reached its end. Distinct from `paused` because resuming an ended
        /// film is a seek, not a play.
        case ended
    }

    private let timeSource: TimeSource
    private let lock = NSLock()
    /// Host time at which the current run of playback began.
    private var anchorHost: Double
    /// Media time at `anchorHost`.
    private var anchorMedia: Double
    private var rateValue: Double
    private var stateValue: State

    public init(rate: Double = 1,
                timeSource: @escaping TimeSource = { ProcessInfo.processInfo.systemUptime }) {
        self.timeSource = timeSource
        self.anchorHost = timeSource()
        self.anchorMedia = 0
        self.rateValue = rate
        self.stateValue = .stopped
    }

    // MARK: - Reading

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return stateValue
    }

    public var isPlaying: Bool { state == .playing }

    /// Where the playhead is now, in media seconds.
    ///
    /// Never negative. A film has no time before its first frame, and a negative value
    /// reaching a presentation timestamp is a sample the display layer would reject.
    public var mediaTime: Double {
        lock.lock(); defer { lock.unlock() }
        return mediaTimeLocked()
    }

    public var rate: Double {
        lock.lock(); defer { lock.unlock() }
        return rateValue
    }

    /// Media time as of a *given* host time.
    ///
    /// The seam the tests use: with a time source the test controls, this is a pure
    /// function and the whole clock can be checked without sleeping.
    public func mediaTime(atHostTime host: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return mediaTimeLocked(host: host)
    }

    private func mediaTimeLocked() -> Double {
        mediaTimeLocked(host: timeSource())
    }

    private func mediaTimeLocked(host: Double) -> Double {
        // Paused, stopped and ended all hold the playhead still. Only `playing` moves,
        // and it moves as a function of the anchors rather than of how often anyone
        // asked.
        guard stateValue == .playing else { return max(0, anchorMedia) }
        return max(0, anchorMedia + (host - anchorHost) * rateValue)
    }

    // MARK: - Moving

    /// Fold the time that has elapsed into the anchor, so a change can be made without
    /// the playhead jumping.
    private func reanchorLocked() {
        anchorMedia = mediaTimeLocked()
        anchorHost = timeSource()
    }

    public func play() {
        lock.lock(); defer { lock.unlock() }
        guard stateValue != .playing else { return }
        // Pressing play at the end restarts the film, which is what every player does and
        // the only reading of the request that produces anything. Resuming *from* the end
        // would play a film that has no frames left, and a playhead past the end is a
        // presentation timestamp nothing will ever display.
        if stateValue == .ended { anchorMedia = 0 }
        reanchorLocked()
        stateValue = .playing
    }

    public func pause() {
        lock.lock(); defer { lock.unlock() }
        guard stateValue == .playing else { return }
        reanchorLocked()
        stateValue = .paused
    }

    /// Stop and return to the beginning.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        anchorMedia = 0
        anchorHost = timeSource()
        stateValue = .stopped
    }

    /// Jump to a media time, keeping the current run state.
    ///
    /// Re-anchors rather than assigning to a "position" field, so that a seek while
    /// playing resumes from the new point instead of adding the time spent seeking to
    /// the new position.
    public func seek(to mediaSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        anchorMedia = max(0, mediaSeconds)
        anchorHost = timeSource()
    }

    /// Playback speed. Zero is a pause expressed as a rate, and is honoured as one.
    public func setRate(_ newRate: Double) {
        lock.lock(); defer { lock.unlock() }
        reanchorLocked()
        rateValue = newRate
    }

    /// The film has reached its end.
    ///
    /// Pins the playhead at the end rather than letting it run past it, which is what a
    /// timebase left playing would do — and a presentation timestamp past the end of the
    /// film is a sample nothing will ever display.
    public func end(at mediaSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        anchorMedia = max(0, mediaSeconds)
        anchorHost = timeSource()
        stateValue = .ended
    }
}
