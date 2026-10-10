import Foundation

/// How many interpolating sessions to run at once.
///
/// ## Why one session cannot be hurried
///
/// `VTFrameProcessor` runs its own work one request at a time. Asking a single session for
/// more requests in flight does not make it work on more than one — it only makes it hold
/// more. Measured on the real 4K HDR film, 480 source frames, 23.976 → 59.94, at depths 2,
/// 4 and 8:
///
///     depth   source frames/s
///       2         13.4
///       4         13.5
///       8         13.5
///
/// Which is the recorded invariant 3 restated: depth 2 is the minimum that *works*, and past
/// it the knob is inert. It is not a speed control and the app does not present it as one.
///
/// ## Why separate sessions do help
///
/// The queue they wait in is VideoToolbox's, not their own, so four sessions overlap the
/// parts of each other's work that are idle. Measured the same way — N whole conversions of
/// 480 frames at once, aggregate throughput across all of them:
///
///     sessions   aggregate   speed-up   CPU      GPU      wall for a 2 h film
///        1        13.4/s      1.00x     116%     50%      3.5 h
///        2        21.5/s      1.60x     ~200%    63%      2.2 h
///        3        23.5/s      1.75x     227%     65%      2.0 h
///        4        23.8/s      1.78x     234%     69%      2.0 h
///        6        17.0/s      1.27x     382%     63%      2.8 h
///
/// ## Why the answer is four and not "as many as there are cores"
///
/// Six sessions are **slower than four**, on 382% of the CPU. The sessions fight over the
/// same unit and the losers spend their time queueing; the aggregate falls by a quarter
/// while the machine gets hotter. "Use every core" is a reasonable thing to want and a
/// wrong thing to implement literally — the measurement is what says where the knee is, and
/// the knee is at four. The recorded decision of *four batch workers* turns out to have been
/// the measured optimum all along rather than a guess that happened to stick.
///
/// ## Why the machine still gets a say
///
/// Four is the knee on the machine this was measured on — an M2 Max, 12 CPU cores and a
/// 38-core GPU. A smaller GPU saturates sooner, and four sessions on a machine with a
/// quarter of the throughput would spend more time contending than interpolating, so the
/// suggestion is scaled down with the core count. It is a heuristic and it is labelled as
/// one: the setting that uses it can be overridden, and the number it chose is shown.
public enum RenderWorkers {

    /// The measured optimum, before the machine is consulted.
    ///
    /// This is the number of *sessions*, which for batch conversion is also the number of
    /// films' worth of work in flight at once. It is not a thread count and it is not meant
    /// to track the core count.
    public static let optimum = 4

    /// The smallest suggestion. One session is the old behaviour, so this is also what a
    /// machine too small to benefit gets: no regression, just no speed-up.
    public static let minimum = 1

    /// How many sessions to run, for this machine.
    ///
    /// Calibrated at the measured knee (``optimum``) and scaled down on machines with fewer
    /// cores, because the unit being queued behind is shared and a smaller machine reaches
    /// contention sooner. `cores / 3` puts an 8-core machine at 2, a 10-core at 3 and this
    /// 12-core at 4 — which is the measured curve read backwards: 2 sessions are worth
    /// 1.60× and the third and fourth are worth 1.09× and 1.02×, so a machine that can only
    /// afford two of them loses very little by stopping there.
    public static func suggested(cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        min(optimum, max(minimum, cores / 3))
    }

    /// Turn a request into a count.
    ///
    /// `0` means "whatever this machine is good for" and is what the app sends by default.
    /// A positive number is honoured exactly, including a number above ``optimum``: the
    /// measurement says six is slower than four, but it says so about *this* film at *this*
    /// resolution, and someone who has measured their own machine is entitled to disagree.
    public static func resolve(_ requested: Int, cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        requested > 0 ? requested : suggested(cores: cores)
    }
}
