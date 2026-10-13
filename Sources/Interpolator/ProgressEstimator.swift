import Foundation

/// How much longer a long job has to run, from the progress it has actually made.
///
/// ## Why this is not `elapsed / fraction`
///
/// That is the obvious formula and it is wrong three times over for this job:
///
/// - **The clock starts before the work does.** A conversion probes the film, then extracts or
///   transcodes the audio track, and only then renders. On a feature film the audio stage can
///   take minutes, and dividing the whole elapsed time by a fraction that has not started
///   moving yet reports a number far too large — and it stays wrong until the render has
///   dominated the clock, which on a three-hour job is a long time to be wrong.
/// - **One sample is not a rate.** Interpolation cost tracks how much of the picture is moving,
///   so an action scene and a held shot differ by a factor of two or more. A projection
///   recomputed from the *start* of the job re-derives the same mistake every time; a projection
///   over a *recent window* reflects the film actually being rendered now.
/// - **A stalled job is not a slow one.** `elapsed / fraction` on a job that has stopped
///   advancing divides by a constant and reports a number that grows forever, which is the one
///   reading that is worse than no reading.
///
/// So this keeps a sliding window of `(time, fraction)` and reports the rate across it. The
/// window only ever sees samples from the rendering stage, which is what keeps the preamble out.
///
/// ## What it refuses to do
///
/// It will not invent a number. Until the window spans enough time and shows enough progress to
/// measure a rate, ``remaining`` is `nil` — a projection offered after two seconds is a guess
/// wearing a number, and this app has a four-hour progress bar to be honest about. If the window
/// shows no progress at all it reports `nil` rather than infinity.
public struct ProgressEstimator: Sendable {

    /// One observation of the job's progress.
    private struct Sample: Sendable {
        let time: TimeInterval
        let fraction: Double
    }

    /// The shortest window a rate may be measured over. Below this the estimate swings on one
    /// scene's worth of work rather than on the job.
    public let minimumWindow: TimeInterval

    /// The longest. A longer window is steadier but slower to notice that the film has changed
    /// character — and on a feature film the render is hours long, so it has time to be steady.
    public let maximumWindow: TimeInterval

    /// The least progress the window must show before a rate is claimed.
    ///
    /// Scaled to the job rather than fixed, because a fraction moves at a rate that depends
    /// entirely on how long the film is: a two-hour film at 4K advances about `7e-5` per second,
    /// so a threshold of a hundredth of a percent would never be reached and a threshold of a
    /// millionth would be measuring quantisation. This is the fraction of the job that must be
    /// covered, and `1e-4` is a hundredth of a percent of it.
    public let minimumProgress: Double

    private var samples: [Sample] = []
    /// When the current run of samples began. Not `samples.first`, which gets trimmed away.
    private var startedAt: TimeInterval?

    public init(minimumWindow: TimeInterval = 5,
                maximumWindow: TimeInterval = 120,
                minimumProgress: Double = 1e-4) {
        self.minimumWindow = max(0.5, minimumWindow)
        self.maximumWindow = max(self.minimumWindow, maximumWindow)
        self.minimumProgress = max(0, minimumProgress)
    }

    // MARK: - Feeding it

    /// Record where the job is, and when.
    ///
    /// `fraction` is the job's own 0…1 progress and must be on **one consistent scale for the
    /// whole run** — mixing a piece count with an interval count makes the rate meaningless,
    /// because the steps are different sizes. `time` is a monotonic clock in seconds, not a
    /// wall-clock date: what matters is the gap between samples.
    public mutating func observe(fraction: Double, at time: TimeInterval) {
        guard fraction.isFinite, time.isFinite else { return }
        let clamped = min(1, max(0, fraction))

        // A fraction that went *backwards* is a restart, a resume, or a new job in the same
        // slot. Averaging across the seam would report a negative rate, so the window starts
        // again from here.
        if let last = samples.last, clamped < last.fraction {
            samples.removeAll(keepingCapacity: true)
            startedAt = time
        }
        if startedAt == nil { startedAt = time }

        // A repeat of the same fraction carries no rate information and would only pad the
        // window; the newest reading is what matters, so it replaces rather than appends.
        if let last = samples.last, last.fraction == clamped {
            samples[samples.count - 1] = Sample(time: time, fraction: clamped)
            trim(now: time)
            return
        }

        samples.append(Sample(time: time, fraction: clamped))
        trim(now: time)
    }

    /// Forget everything. For a restart, a seek, or a different film in the same slot.
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        startedAt = nil
    }

    private mutating func trim(now: TimeInterval) {
        let window = windowLength(now: now)
        // Keep exactly one sample older than the window edge, so the window is never shorter
        // than asked for — trimming to the edge would leave a span that shrinks as the samples
        // age, and a rate measured over a window that is silently shrinking is worse than none.
        while samples.count > 2, samples[1].time < now - window {
            samples.removeFirst()
        }
    }

    /// How far back the rate is measured, which grows with the job.
    ///
    /// A third of the run so far, clamped. Early on that is short enough to produce a number
    /// within seconds; later it is long enough that one slow scene cannot move it.
    private func windowLength(now: TimeInterval) -> TimeInterval {
        guard let startedAt else { return minimumWindow }
        let elapsed = max(0, now - startedAt)
        return min(maximumWindow, max(minimumWindow, elapsed / 3))
    }

    // MARK: - What it can say

    /// The job's progress as last observed.
    public var fraction: Double? { samples.last?.fraction }

    /// Fraction of the job completed per second, or `nil` when the window cannot support one.
    public var rate: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= minimumWindow else { return nil }
        let progress = last.fraction - first.fraction
        guard progress >= minimumProgress else { return nil }
        return progress / span
    }

    /// Seconds left, or `nil` when there is not yet a defensible answer.
    ///
    /// Clamped at zero: the fraction is an estimate (Matroska reports no frame count), so it can
    /// reach 1 slightly before the film ends and a negative remainder is not a thing to show.
    public var remaining: TimeInterval? {
        guard let rate, rate > 0, let fraction, fraction < 1 else { return nil }
        return max(0, (1 - fraction) / rate)
    }

    /// Whether a projection is being offered at all, so a view can choose between a number and
    /// "estimating…" without repeating the arithmetic.
    public var hasEstimate: Bool { remaining != nil }
}
