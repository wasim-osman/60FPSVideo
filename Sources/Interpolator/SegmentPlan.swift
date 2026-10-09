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
///
/// ## Why a segment reads more than it renders
///
/// The cut decision for interval `i` is not a function of interval `i`. The adaptive
/// threshold looks back over ``SceneChangeDetector/Config/historyLength`` intervals, and the
/// flash guard looks one frame forward. A segment that began reading at its own first
/// interval would judge that interval with a short history and no backward evidence, and
/// would judge its last one with no forward evidence at all — because the tracker calls
/// `finish()` when its source ends, and end-of-stream semantics are deliberately not
/// mid-stream semantics.
///
/// So each segment reads a **lead-in** before its first interval and a **lead-out** after
/// its last, feeds every frame it reads to the tracker, and renders only its own intervals.
/// With `leadIn >= historyLength` the first rendered interval sees exactly the history the
/// whole-film render would have given it, and with `leadOut >= 2` the last one keeps its
/// forward guard. The result is that a segment's output is the corresponding slice of the
/// whole-film output, not merely a similar one — which is the property the entire segmented
/// design rests on, and which is why it is worth 33 extra decoded frames per segment.
///
/// At the film's own ends the margins are clamped away rather than faked: the first segment
/// has no lead-in because the film has nothing before it, and the last one's lead-out runs
/// off the end and stops. Both are what the whole-film render does there too.
public struct SegmentPlan: Sendable {

    /// One piece of the job.
    public struct Segment: Sendable, Equatable, CustomStringConvertible {
        /// Position in the plan, and the number that names its file.
        public let index: Int
        /// First interval rendered, as a global source interval index. Also the first
        /// source frame the segment's *own* picture begins at.
        public let sourceStart: Int
        /// Intervals rendered. The segment's identity: what it owns, and what no other
        /// segment renders.
        public let sourceCount: Int
        /// First source frame read, which is ``sourceStart`` less the lead-in and never
        /// below zero.
        public let readStart: Int
        /// Source frames read: the intervals rendered, plus one for the far side of the
        /// last interval, plus the lead-in and lead-out the tracker needs.
        public let readCount: Int
        /// The first output frame of the film this segment produces.
        public let outputStart: Int
        public let outputCount: Int

        /// One past the last interval rendered. The next segment starts here, so this is
        /// the anchor the tiling is checked against.
        public var intervalEnd: Int { sourceStart + sourceCount }
        /// One past the last source frame read. Half-open, like every other range here.
        public var readEnd: Int { readStart + readCount }
        /// One past the last output frame.
        public var outputEnd: Int { outputStart + outputCount }
        /// Intervals read but not rendered, before the first rendered one.
        public var leadIn: Int { sourceStart - readStart }
        /// Intervals read but not rendered, after the last rendered one. One less than the
        /// frame margin, because the far side of the last rendered interval is itself read.
        public var leadOut: Int { readEnd - intervalEnd - 1 }

        public var description: String {
            "segment \(index): intervals [\(sourceStart), \(intervalEnd)) "
                + "-> output [\(outputStart), \(outputEnd)) "
                + "(\(sourceCount) intervals, \(readCount) frames read "
                + "from \(readStart))"
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
    /// one more source frame than this, plus the lead-in and lead-out.
    public let intervalsPerSegment: Int
    /// Context read before a segment's first interval, and after its last. See the note
    /// on the type.
    public let leadIn: Int
    public let leadOut: Int

    // MARK: - Context

    /// Context a segment reads before its first rendered interval.
    ///
    /// `SceneChangeDetector.Config.historyLength` is 30, and the adaptive threshold reaches
    /// that far back; one more covers the backward half of the flash guard, which needs the
    /// interval before the one being judged.
    public static let defaultLeadIn = 31
    /// Context a segment reads after its last rendered interval: the forward half of the
    /// flash guard needs the frame after next.
    public static let defaultLeadOut = 2

    // MARK: - Building

    /// Split a source of `sourceFrameCount` frames into segments of about
    /// `targetSourceFrames` intervals.
    ///
    /// `nil` when there is nothing to plan: fewer than two source frames is no interval,
    /// and a non-positive target is not a segment length.
    public init?(sourceFrameCount: Int,
                 source: FrameRate,
                 output: FrameRate,
                 targetSourceFrames: Int,
                 leadIn: Int = SegmentPlan.defaultLeadIn,
                 leadOut: Int = SegmentPlan.defaultLeadOut) {
        let planner = IntervalPlanner(source: source, output: output)
        let period = planner.phasePeriod
        guard planner.isUsable, period > 0,
              sourceFrameCount >= 2, targetSourceFrames >= 2,
              leadIn >= 0, leadOut >= 0 else { return nil }

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
            // The context, clamped at the film's own ends rather than invented. A segment
            // that ran off either end would read frames that do not exist, and a segment
            // that pretended to have context it does not have would judge its first
            // intervals differently from the whole-film render.
            let readStart = max(0, start - leadIn)
            // Frames read: the far side of the last interval, plus the context on each
            // side, and never past the end of the film.
            let readEnd = min(end + 1 + leadOut, sourceFrameCount)
            segments.append(Segment(
                index: index,
                sourceStart: start,
                sourceCount: end - start,
                readStart: readStart,
                readCount: readEnd - readStart,
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
        self.leadIn = leadIn
        self.leadOut = leadOut
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
                 segmentSeconds: Double,
                 leadIn: Int = SegmentPlan.defaultLeadIn,
                 leadOut: Int = SegmentPlan.defaultLeadOut) {
        guard segmentSeconds > 0, source.doubleValue > 0 else { return nil }
        let frames = Int((segmentSeconds * source.doubleValue).rounded())
        self.init(sourceFrameCount: sourceFrameCount, source: source, output: output,
                  targetSourceFrames: frames, leadIn: leadIn, leadOut: leadOut)
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

        if segments.map(\.sourceCount).contains(where: { $0 < 1 }) {
            found.append("a segment renders no interval")
        }
        if segments.map(\.outputCount).contains(where: { $0 <= 0 }) {
            found.append("a segment produces no output frames")
        }
        if segments.first?.sourceStart != 0 {
            found.append("the first segment does not start at source frame 0")
        }
        // The last interval index is `sourceFrameCount - 1`, so the last segment's
        // half-open interval range has to end there.
        if segments.last?.intervalEnd != sourceFrameCount - 1 {
            found.append("the last segment does not reach the end of the source")
        }
        if segments.last?.outputEnd != outputFrameCount {
            found.append("the last segment does not reach the end of the output")
        }
        // A segment has to read the far side of its last interval, or it cannot render that
        // interval at all; and it must not read past the film.
        for segment in segments {
            if segment.readCount < segment.sourceCount + 1 {
                found.append("segment \(segment.index) reads \(segment.readCount) frames "
                             + "for \(segment.sourceCount) intervals, so the far side of "
                             + "its last interval is missing")
            }
            if segment.readStart > segment.sourceStart {
                found.append("segment \(segment.index) reads from frame \(segment.readStart) "
                             + "but renders intervals from \(segment.sourceStart)")
            }
            if segment.readEnd > sourceFrameCount {
                found.append("segment \(segment.index) reads to frame \(segment.readEnd), "
                             + "past the source's \(sourceFrameCount)")
            }
            if segment.leadIn < 0 || segment.leadOut < 0 {
                found.append("segment \(segment.index) has a negative margin")
            }
        }
        // The intervals tile exactly — no gap and no overlap. A gap loses a piece of the
        // film, an overlap plays one twice, and neither is visible in the finished file
        // until someone watches the join. The *read* ranges deliberately overlap, which is
        // why this checks intervals and not frames.
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
