import CoreVideo
import Foundation

/// Decides how wide the player may interpolate and still hold the film's rate.
///
/// ## Why this is measured rather than assumed
///
/// The width ladder in ``InterpolationWidth`` says which widths are *worth trying*; it does not
/// say which one this machine can afford for this film at this rate. That depends on the GPU, on
/// the source, on the output rate and on whatever else is running — and a player that guesses
/// wrong either judders (guessed too wide) or is soft for no reason (guessed too narrow).
///
/// SVP answers the same question with `fi_auto: true`. This is that answer, done once at load
/// instead of continuously: **probe the real pipeline, on the real film, at each rung widest
/// first, and take the first that fits.**
///
/// ## What it costs
///
/// Each probe is a short real run — by default 8 intervals plus two discarded for warm-up. On the
/// reference film that is 3840 (≈0.9 s) → 2560 (≈0.7 s) → 1920 (≈0.3 s), so about **two seconds**,
/// once per film, before the clock starts. A film the machine can already handle is probed at its
/// own width only, finds it fits, and stops.
public enum PlaybackCalibrator {

    /// What one probe measured.
    public struct Measurement: Sendable {
        public let width: Int
        public let height: Int
        public let millisecondsPerInterval: Double
        /// How many intervals the figure is derived from, after warm-up.
        public let samples: Int
    }

    /// Which rung the ladder settled on, and why.
    public struct Choice: Sendable {
        public let width: Int
        public let millisecondsPerInterval: Double?
        /// How many rungs were probed.
        public let probes: Int
        /// True when **no** probed rung met the budget and the fastest measured one was taken
        /// anyway. The caller should say so rather than pretend the film will hold its rate.
        public let fellBack: Bool
    }

    /// The decision, as arithmetic: walk the candidates widest-first and take the first whose
    /// measurement fits the budget with `margin` to spare.
    ///
    /// `measure` returns milliseconds per interval, or `nil` when that width could not be probed
    /// at all — a rung that cannot be measured is skipped rather than guessed at.
    ///
    /// **When nothing fits, the fastest rung that was actually measured wins** — not the narrowest
    /// one on the list. The narrowest is a guess about a rung no probe reached; the fastest
    /// measured is the best thing the walk actually learned. Getting this backwards is how a 4K
    /// film came to be interpolated at 960×408: three probes spent on rungs that all cost the same
    /// (~33–37 ms, invariant 54), nothing fitted the margin, and the code jumped to the bottom of
    /// the ladder without ever having measured it.
    public static func choose(candidates: [Int],
                              budget: Double,
                              margin: Double,
                              maximumProbes: Int = 4,
                              measure: (Int) -> Double?) -> Choice {
        var probes = 0
        var fastest: (width: Int, milliseconds: Double)?
        for width in candidates {
            guard probes < maximumProbes else { break }
            probes += 1
            guard let milliseconds = measure(width) else { continue }
            if fastest == nil || milliseconds < fastest!.milliseconds {
                fastest = (width, milliseconds)
            }
            if milliseconds <= budget * margin {
                return Choice(width: width, millisecondsPerInterval: milliseconds,
                              probes: probes, fellBack: false)
            }
        }
        // Nothing fitted. Take the fastest rung the walk measured, and say that it is a fallback
        // rather than a measurement that met the budget.
        if let fastest {
            return Choice(width: fastest.width, millisecondsPerInterval: fastest.milliseconds,
                          probes: probes, fellBack: true)
        }
        return Choice(width: candidates.last ?? candidates.first ?? 0, millisecondsPerInterval: nil,
                      probes: probes, fellBack: true)
    }

    /// Probe one width: run the real pipeline for `intervals` intervals and time them.
    ///
    /// A real run of the real pipeline — the same source, the same engine, the same scene
    /// detector, the same depth — because anything cheaper would measure something the player
    /// does not do. The frames go to a sink that counts them and keeps nothing.
    ///
    /// **`intervals` is 20 and not 8, and that is a correction rather than a preference.** Timed
    /// over 8 intervals the same rung at the same film position reports figures that differ by
    /// more than 30% between runs — 1920×816 measured 43.55 and 46.48 ms at two positions with 8
    /// intervals, and 36.53 ms at the same position with 30 — and the error is *upward*, so a
    /// short probe systematically under-reports what the machine can afford. That is what turned
    /// a 1920 answer into a 960 fallback. See invariant 54.
    public static func measure(url: URL,
                               info: MediaInfo,
                               sourceRate: FrameRate,
                               outputRate: FrameRate,
                               width: Int,
                               intervals: Int = 20,
                               warmUp: Int = 3,
                               depth: Int = 2,
                               startSeconds: Double = 0,
                               makeSource: (@Sendable (SourceRequest) throws -> FrameSource)? = nil,
                               makeEngine: @Sendable (FrameRate, FrameRate, Int) throws -> InterpolationEngine
                                   = { source, output, depth in
                                       VTFrameProcessorEngine(source: source, output: output,
                                                              depth: depth)
                                   }) throws -> Measurement {

        let scaled = InterpolationWidth.scaled(info, toWidth: width)
        let total = intervals + warmUp

        // The scaling is the point of the probe, so the default opener has to honour it: a probe
        // that read 4K frames into a 1080p-sized pipeline would measure the wrong thing and then
        // report it as the cost of 1080p.
        let open: @Sendable (SourceRequest) throws -> FrameSource = makeSource ?? { request in
            try FFmpegFrameSource(url: request.url, info: request.info,
                                  startSeconds: request.startSeconds,
                                  frameLimit: request.frameLimit,
                                  scale: request.scale)
        }
        let source = try open(SourceRequest(url: url, info: scaled,
                                            startSeconds: startSeconds > 0 ? startSeconds : nil,
                                            frameLimit: nil,
                                            scale: scaled.width != info.width))
        let engine = try makeEngine(sourceRate, outputRate, depth)
        let planner = IntervalPlanner(source: sourceRate, output: outputRate)

        let startInterval = max(0, Int((startSeconds * sourceRate.doubleValue).rounded(.down)))
        let outputStart = planner.output(forInterval: startInterval).first?.index ?? 0

        let clock = ProbeClock()
        let pipeline = InterpolationPipeline(
            source: source, sourceRate: sourceRate, outputRate: outputRate, engine: engine,
            configuration: .init(depth: depth, engines: 1, sceneDetection: true,
                                 window: .init(readFromInterval: startInterval,
                                               renderFromInterval: startInterval,
                                               renderToInterval: startInterval + total,
                                               outputStart: outputStart),
                                 progress: { interval in clock.record(interval) }))

        let sink = DiscardSink()
        defer {
            engine.shutdown()
            source.close()
        }
        try pipeline.run(into: sink)

        return Measurement(width: scaled.width, height: scaled.height,
                           millisecondsPerInterval: clock.millisecondsPerInterval(intervals: intervals,
                                                                                  warmUp: warmUp),
                           samples: clock.samples)
    }

    /// The whole calibration: walk the ladder and return the size to interpolate at.
    ///
    /// `margin`, `maximumProbes` and `intervals` are parameters rather than constants so that a
    /// test can drive the decision without a GPU.
    ///
    /// **The margin is 0.9, and it was 0.85 for the wrong reason.** It is meant to cover the work
    /// the probe cannot see — decoding, uploading and presenting — and 0.85 was picked from a
    /// 4K figure where the app presented 18.5 fps against the engine's ~23. But the same report
    /// measured the app's own playback at **19.6 fps** against the harness's **18.5–19.0** for the
    /// same content: two instruments, one number, so presentation is nearly free and the 20% was
    /// never there. What the margin has to cover is *variance*, and a 20-interval probe leaves
    /// little: 10% is generous. At 0.85 the film's 1920 rung — 33.99 to 36.53 ms against a
    /// 41.708 ms budget — was rejected for being 1.4% over the line, and the film fell to 960.
    public static func calibrate(url: URL,
                                 info: MediaInfo,
                                 sourceRate: FrameRate,
                                 outputRate: FrameRate,
                                 depth: Int = 2,
                                 margin: Double = 0.9,
                                 maximumProbes: Int = 4,
                                 intervals: Int = 20,
                                 startSeconds: Double = 0) -> (choice: Choice, info: MediaInfo) {
        let budget = InterpolationWidth.budget(sourceRate: sourceRate)
        let candidates = InterpolationWidth.candidates(sourceWidth: info.width)

        var measurements: [Int: Measurement] = [:]
        let choice = choose(candidates: candidates, budget: budget, margin: margin,
                            maximumProbes: maximumProbes) { width in
            let measurement = try? measure(url: url, info: info, sourceRate: sourceRate,
                                           outputRate: outputRate, width: width,
                                           intervals: intervals, depth: depth,
                                           startSeconds: startSeconds)
            if let measurement { measurements[width] = measurement }
            return measurement?.millisecondsPerInterval
        }

        return (choice, InterpolationWidth.scaled(info, toWidth: choice.width))
    }
}

// MARK: - Support

/// Times the intervals a probe runs.
///
/// The probe measures the **cadence of intervals**, not the wall clock of the whole run: the run
/// includes session start-up and the drain at the end, and neither is something the player pays
/// per interval. The first `warmUp` samples are dropped for the same reason — the first requests
/// into a fresh session are slower than the steady state, and averaging them in would make every
/// width look worse than it is.
private final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [(interval: Int, at: Double)] = []

    func record(_ interval: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        stamps.append((interval, now))
        lock.unlock()
    }

    var samples: Int {
        lock.lock(); defer { lock.unlock() }
        return stamps.count
    }

    /// Milliseconds per interval across the steady-state portion of the probe.
    func millisecondsPerInterval(intervals: Int, warmUp: Int) -> Double {
        lock.lock()
        let all = stamps
        lock.unlock()

        let steady = all.dropFirst(warmUp)
        if let first = steady.first, let last = steady.last, steady.count >= 3 {
            let span = last.at - first.at
            let count = last.interval - first.interval
            if count > 0, span > 0 { return span * 1000 / Double(count) }
        }
        // Too few usable samples: fall back to the whole run, which is pessimistic but never
        // invents a number out of nothing.
        guard let first = all.first, let last = all.last, all.count >= 2 else { return .infinity }
        let count = last.interval - first.interval
        guard count > 0 else { return .infinity }
        return (last.at - first.at) * 1000 / Double(count)
    }
}

/// Counts frames and keeps none.
///
/// A calibration probe renders real frames and throws them away. At 4K a `MemoryFrameSink` would
/// hold a gigabyte for eight intervals, which is exactly the kind of cost a probe must not have.
private final class DiscardSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func begin(_ geometry: SinkGeometry) throws {}
    func write(_ buffer: CVPixelBuffer, at outputIndex: Int) {
        lock.lock(); count += 1; lock.unlock()
    }
    func finish() throws {}
    var problems: [String] { [] }

    var written: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
