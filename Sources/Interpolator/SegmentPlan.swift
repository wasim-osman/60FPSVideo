import Foundation

/// A feature-length job split into pieces that can each be rendered, verified and kept.
///
/// ## Why the job is split at all
///
/// A 4K HDR conversion of a two-hour film is hours of work. As one indivisible render it
/// has one failure mode that matters: it either finishes or it does not, and a crash at
/// hour three costs the whole three hours. Splitting it does not make it faster — it makes
/// the work *survivable*, which is a different property and the one that decides whether
/// this is usable on a real film.
///
/// Three things follow from that, and they are the whole design:
///
/// - **A segment is the unit of trust.** It is written to its own file, and it is only
///   believed once it has been finished and checked. A segment interrupted by a crash is
///   not "mostly done" — it is discarded, because a partially written `AVAssetWriter` file
///   is not a short film, it is a corrupt one, and there is no way to tell the two apart
///   from the outside.
/// - **The audio is not segmented.** It is muxed once, over the joined picture. This is
///   not an optimisation: a compressed audio stream can only be cut at a packet boundary,
///   so cutting it per segment would mean re-encoding a DTS-HD MA master that the whole
///   point of the MKV path is to keep bit for bit. Segmenting the picture and muxing the
///   sound once keeps the shipping path identical to the unsegmented one.
/// - **The boundaries are not free.** See ``IntervalPlanner/phasePeriod``.
///
/// ## What a segment covers
///
/// Interval `j` is the gap between source frames `j` and `j + 1`, so a segment rendering
/// intervals `[a, b)` reads source frames `[a, b]` **inclusive** — one more frame than it
/// renders intervals, because the last frame is the far side of the last interval.
/// Consecutive segments therefore share exactly one source frame: the far side of one is
/// the near side of the next. That frame is decoded twice, which is the price of not
/// needing the previous segment's tail to render this one's head — and it is worth it,
/// because it is what makes every segment independently renderable, which is what resume
/// requires.
///
/// The distinction between frames and intervals is where this got written wrong the first
/// time: the segments were stepped by a frame count while each rendered a frame count
/// *minus one* intervals, so the interval at every boundary belonged to neither segment.
/// The output showed it as a two-frame gap at each join and nothing else — a plan that
/// looked right, tiled right in the source, and silently dropped a fiftieth of a second
/// per boundary.
public struct SegmentPlan: Sendable {

    /// One piece of the job.
    public struct Segment: Sendable, Equatable, CustomStringConvertible {
        /// Position in the plan, and the number that names its file.
        public let index: Int
        /// First source frame read. Also the first interval rendered, since they share
        /// a number.
        public let sourceStart: Int
        /// Source frames read. One more than the intervals rendered.
        public let sourceCount: Int
        /// The first output frame of the film this segment produces.
        public let outputStart: Int
        public let outputCount: Int

        /// Intervals rendered, which is one fewer than the frames read.
        public var intervalCount: Int { max(0, sourceCount - 1) }
        /// One past the last source frame read. Half-open, like every other range here.
        public var sourceEnd: Int { sourceStart + sourceCount }
        /// One past the last interval rendered. This is `sourceEnd - 1`, because the last
        /// frame read is the far side of the last interval and no interval starts at it.
        public var intervalEnd: Int { sourceStart + intervalCount }
        /// One past the last output frame.
        public var outputEnd: Int { outputStart + outputCount }

        public var description: String {
            "segment \(index): source [\(sourceStart), \(sourceEnd)) "
                + "-> output [\(outputStart), \(outputEnd)) "
                + "(\(sourceCount) frames read, \(intervalCount) intervals rendered)"
        }
    }

    public let segments: [Segment]
    /// Source frames the plan accounts for. The whole film, when it is complete.
    public let sourceFrameCount: Int
    /// Output frames the plan accounts for.
    public let outputFrameCount: Int
    /// The rate pair's phase period, in source intervals. Every segment but the last
    /// begins on a multiple of it.
    public let phasePeriod: Int
    /// Intervals a full segment renders, after rounding up to a phase boundary. It reads
    /// one more source frame than this.
    public let intervalsPerSegment: Int

    // MARK: - Building

    /// Split a source of `sourceFrameCount` frames into segments of about
    /// `targetSourceFrames` intervals.
    ///
    /// `nil` when there is nothing to plan: fewer than two source frames is no interval,
    /// and a non-positive target is not a segment length.
    public init?(sourceFrameCount: Int,
                 source: FrameRate,
                 output: FrameRate,
                 targetSourceFrames: Int) {
        let planner = IntervalPlanner(source: source, output: output)
        let period = planner.phasePeriod
        guard planner.isUsable, period > 0,
              sourceFrameCount >= 2, targetSourceFrames >= 2 else { return nil }

        // Every segment but the last has to begin where the phase pattern begins, so the
        // length is rounded *up* to the next multiple of the period. Rounding down would
        // be worse than useless: it would land the very next boundary off the pattern.
        var length = max(2, targetSourceFrames)
        if length % period != 0 { length += period - (length % period) }

        // Where each segment begins, as an *interval* index. The film's intervals are
        // `[0, sourceFrameCount - 1)`, so the loop stops one short of the frame count —
        // which is also what keeps a tail of one frame from becoming a segment that
        // renders nothing. There is no fold-up case, because the loop cannot produce one.
        var starts: [Int] = []
        var cursor = 0
        while cursor < sourceFrameCount - 1 {
            starts.append(cursor)
            cursor += length
        }

        var segments: [Segment] = []
        segments.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            // The intervals this segment renders, clipped to the end of the film.
            let end = min(start + length, sourceFrameCount - 1)
            // The rounding above puts every start on a phase boundary, so this cannot be
            // nil. It is written as a guard rather than a force-unwrap because "cannot
            // happen" is exactly the claim that is wrong when it matters, and a plan that
            // silently mis-phases a segment produces a film that stutters on a schedule.
            guard let outputStart = planner.outputIndexAtPhaseBoundary(interval: start) else {
                return nil
            }
            segments.append(Segment(
                index: index,
                sourceStart: start,
                // Frames read, which is the intervals rendered plus the one frame on the
                // far side of the last of them.
                sourceCount: end - start + 1,
                outputStart: outputStart,
                outputCount: planner.outputFrameCount(fromInterval: start,
                                                      count: end - start)))
        }

        self.segments = segments
        self.sourceFrameCount = sourceFrameCount
        self.outputFrameCount = planner.outputFrameCount(fromInterval: 0,
                                                        count: sourceFrameCount - 1)
        self.phasePeriod = period
        self.intervalsPerSegment = length
    }

    /// Split by a target duration rather than an interval count.
    ///
    /// The duration is what a person sets; the interval count is what the arithmetic needs.
    /// Converting here rather than at the call site keeps the one rounding decision in one
    /// place, and it is a rounding decision: a target of 300 s at 23.976 is 7192.8 source
    /// frames.
    public init?(sourceFrameCount: Int,
                 source: FrameRate,
                 output: FrameRate,
                 segmentSeconds: Double) {
        guard segmentSeconds > 0, source.doubleValue > 0 else { return nil }
        let frames = Int((segmentSeconds * source.doubleValue).rounded())
        self.init(sourceFrameCount: sourceFrameCount, source: source, output: output,
                  targetSourceFrames: frames)
    }

    // MARK: - Lookups

    /// The segment that renders output frame `index`, if any.
    ///
    /// Used to answer "how far through is this job?" without a running total, and by
    /// resume to find the first segment that is not finished.
    public func segment(containingOutput index: Int) -> Segment? {
        guard index >= 0 else { return nil }
        return segments.first { index >= $0.outputStart && index < $0.outputEnd }
    }

    /// The segment that renders source interval `index`, if any.
    ///
    /// This is the unambiguous lookup. A *frame* at a boundary belongs to two segments —
    /// it is the far side of one and the near side of the next — so a lookup by frame
    /// index has no single right answer and is deliberately not offered. An interval has
    /// exactly one owner, always.
    public func segment(containingInterval index: Int) -> Segment? {
        guard index >= 0 else { return nil }
        return segments.first { index >= $0.sourceStart && index < $0.intervalEnd }
    }

    // MARK: - What has to be true

    /// Everything wrong with the plan. Empty is the only usable plan.
    public var problems: [String] {
        Self.problems(in: segments,
                      sourceFrameCount: sourceFrameCount,
                      outputFrameCount: outputFrameCount,
                      phasePeriod: phasePeriod)
    }

    /// Everything wrong with a set of segments claiming to cover a film.
    ///
    /// A function of the segments rather than a method, so the check can be handed a broken
    /// set and shown to fail. A check that can only ever be run against something the
    /// initialiser already validated is a check nobody can tell from a no-op — and the
    /// initialiser's validation is exactly what a later edit to the arithmetic would break.
    public static func problems(in segments: [Segment],
                                sourceFrameCount: Int,
                                outputFrameCount: Int,
                                phasePeriod: Int) -> [String] {
        var found: [String] = []
        guard !segments.isEmpty else { return ["the plan has no segments"] }

        if segments.map(\.sourceCount).contains(where: { $0 < 2 }) {
            found.append("a segment of fewer than 2 source frames renders no interval")
        }
        if segments.map(\.outputCount).contains(where: { $0 <= 0 }) {
            found.append("a segment produces no output frames")
        }
        if segments.first?.sourceStart != 0 {
            found.append("the first segment does not start at source frame 0")
        }
        if segments.last?.sourceEnd != sourceFrameCount {
            found.append("the last segment does not reach the end of the source")
        }
        if segments.last?.outputEnd != outputFrameCount {
            found.append("the last segment does not reach the end of the output")
        }
        // The intervals tile exactly — no gap and no overlap — and the source frames
        // overlap by exactly the one frame that two neighbouring segments share. Both
        // conditions are the same condition, because a segment's last frame read is the far
        // side of its last interval and no interval begins there. A gap in the intervals
        // loses a piece of the film; an overlap plays one twice; and neither is visible in
        // the finished file until someone watches the join.
        for (previous, next) in zip(segments, segments.dropFirst()) {
            if next.sourceStart != previous.intervalEnd {
                found.append("intervals \(previous.intervalEnd)…\(next.sourceStart) "
                             + "are not covered exactly once")
            }
            if next.outputStart != previous.outputEnd {
                found.append("output frames \(previous.outputEnd)…\(next.outputStart) "
                             + "are not covered exactly once")
            }
        }
        // The reason the segment length is rounded up: a segment that begins off the phase
        // pattern renders its passthrough frames at the wrong output indices. The last
        // segment is exempt because nothing follows it.
        if phasePeriod > 0 {
            for segment in segments.dropLast()
            where segment.sourceStart % phasePeriod != 0 {
                found.append("segment \(segment.index) starts at source frame "
                             + "\(segment.sourceStart), which is not a multiple of the "
                             + "\(phasePeriod)-interval phase period")
            }
        }
        return found
    }
}
