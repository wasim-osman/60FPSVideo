import Foundation
import Testing
@testable import Interpolator

/// Splitting a film into pieces that can be rendered apart and joined back together.
///
/// The plan is arithmetic, so it is testable without a GPU, a file or an encoder — and it
/// has to be, because every way it can be wrong is silent. A gap loses a piece of the film,
/// an overlap plays one twice, and a segment that starts off the phase pattern turns its
/// passthrough frames into interpolations at the wrong indices. None of the three shows up
/// as an error; all three show up as a film that is subtly not the one that was rendered.
struct SegmentPlanTests {

    // MARK: - Scaffolding

    /// Rates are written the way the app writes them. A rate that will not parse is a
    /// broken fixture rather than a case under test, so it fails loudly here.
    private func rate(_ text: String) -> FrameRate { FrameRate.parse(text)! }

    /// The shipping pair, and the neighbours that stress different arithmetic.
    private func pairs() -> [(FrameRate, FrameRate)] {
        [(rate("24000/1001"), rate("60000/1001")),
         (rate("24000/1001"), rate("60")),
         (rate("24"), rate("60")),
         (rate("25"), rate("60")),
         (rate("30000/1001"), rate("60000/1001")),
         (rate("24"), rate("30"))]
    }

    private func makePlan(_ source: FrameRate, _ output: FrameRate,
                          frames: Int, target: Int) throws -> SegmentPlan {
        try #require(SegmentPlan(sourceFrameCount: frames, source: source,
                                 output: output, targetSourceFrames: target))
    }

    /// A frame reduced to what a segment boundary could break: whether it is a
    /// passthrough, and where it sits between its two source frames.
    ///
    /// The absolute indices are deliberately dropped. A segment numbers its output frames
    /// from zero, so those indices *must* differ from the film's — comparing them would
    /// test nothing. What must not differ is the sequence of frame kinds, because that is
    /// what decides which output frames are free and where the interpolations land.
    private func shape(_ frames: [OutputFrame]) -> [String] {
        frames.map { frame in
            switch frame.kind {
            case .passthrough: return "p"
            case .interpolate(_, _, let phase): return String(format: "i%.6f", phase)
            }
        }
    }

    // MARK: - The phase period

    @Test("the phase period is what the rate pair makes it, not a constant")
    func phasePeriodIsDerived() {
        // 2.5x exactly: the pattern repeats every two intervals, so the constraint on
        // segment boundaries costs nothing at all.
        #expect(IntervalPlanner(source: rate("24000/1001"),
                                output: rate("60000/1001")).phasePeriod == 2)

        // 2.5025x: 1001 and 400 share no factor, so the pattern only repeats after 400
        // intervals — 16.7 s of film. This is the case where the constraint bites, and the
        // reason it cannot be assumed away.
        #expect(IntervalPlanner(source: rate("24000/1001"),
                                output: rate("60")).phasePeriod == 400)
        // 24 -> 60 is 2.5 exactly again.
        #expect(IntervalPlanner(source: rate("24"), output: rate("60")).phasePeriod == 2)
        // 25 -> 60 is 2.4, and 25 and 60 share 5.
        #expect(IntervalPlanner(source: rate("25"), output: rate("60")).phasePeriod == 5)
    }

    @Test("a phase boundary is an interval whose output index is an exact integer")
    func phaseBoundariesAreExact() {
        let planner = IntervalPlanner(source: rate("24000/1001"),
                                      output: rate("60000/1001"))
        // Period 2, so every even interval sits on a boundary and every odd one does not.
        for j in 0..<20 {
            let index = planner.outputIndexAtPhaseBoundary(interval: j)
            if j % planner.phasePeriod == 0 {
                #expect(index == j * 5 / 2, "interval \(j) should be on a boundary")
            } else {
                #expect(index == nil, "interval \(j) is between boundaries")
            }
        }
        #expect(planner.outputIndexAtPhaseBoundary(interval: -1) == nil)
    }

    @Test("the count arithmetic agrees with the frames the planner actually produces")
    func countsMatchTheFrames() {
        // `outputFrameCount(fromInterval:count:)` exists so a plan can be built without
        // materialising a feature-length frame list. Two implementations of one piece of
        // arithmetic is one too many unless something proves they match — this is that.
        for (source, output) in pairs() {
            let planner = IntervalPlanner(source: source, output: output)
            for start in 0..<12 {
                for count in 1...12 {
                    let summed = (start..<(start + count))
                        .reduce(0) { $0 + planner.output(forInterval: $1).count }
                    #expect(planner.outputFrameCount(fromInterval: start, count: count)
                                == summed,
                            "\(source) -> \(output), intervals [\(start), \(start + count))")
                }
            }
            // And a zero or negative count is nothing, not a crash.
            #expect(planner.outputFrameCount(fromInterval: 0, count: 0) == 0)
            #expect(planner.outputFrameCount(fromInterval: 0, count: -3) == 0)
        }
    }

    // MARK: - The plan

    @Test("the plan reproduces the whole-film count the existing plan already states")
    func totalMatchesPhasePlan() throws {
        // `PhasePlan` is the verified implementation — `IntervalPlannerTests` requires it
        // to agree frame for frame. A segmented job must produce the same film, so its
        // total has to be that same number, not a number derived alongside it.
        for (source, output) in pairs() {
            for frames in [2, 3, 7, 60, 241, 1000] {
                let plan = try makePlan(source, output, frames: frames, target: 16)
                let expected = PhasePlan(sourceFrameCount: frames, source: source,
                                         output: output)?.outputFrameCount
                #expect(plan.outputFrameCount == expected,
                        "\(source) -> \(output), \(frames) frames")
            }
        }
    }

    @Test("segments cover the source and the output exactly once each")
    func segmentsTileBothTimelines() throws {
        for (source, output) in pairs() {
            for frames in [2, 3, 5, 60, 401, 1000, 7193, 100_000] {
                for target in [2, 7, 16, 100, 5000] {
                    let plan = try makePlan(source, output, frames: frames, target: target)
                    let detail = plan.problems.joined(separator: "; ")
                    #expect(plan.problems.isEmpty,
                            "\(source) -> \(output) \(frames)/\(target): \(detail)")
                    #expect(plan.segments.first?.sourceStart == 0)
                    #expect(plan.segments.last?.sourceEnd == frames)
                    #expect(plan.segments.last?.outputEnd == plan.outputFrameCount)
                    #expect(plan.segments.reduce(0) { $0 + $1.outputCount }
                                == plan.outputFrameCount)
                    #expect(plan.segments.reduce(0) { $0 + $1.sourceCount }
                                >= frames, "a boundary frame is read twice, never skipped")
                }
            }
        }
    }

    @Test("each segment's frame count is the sum of the intervals it renders")
    func segmentCountsAreSumsOfIntervals() throws {
        for (source, output) in pairs() {
            let planner = IntervalPlanner(source: source, output: output)
            let plan = try makePlan(source, output, frames: 5000, target: 400)
            for segment in plan.segments {
                let summed = (segment.sourceStart..<segment.sourceEnd - 1)
                    .reduce(0) { $0 + planner.output(forInterval: $1).count }
                #expect(segment.outputCount == summed, "\(segment.description)")
            }
        }
    }

    @Test("rendering the segments apart produces the film's frames in the film's order")
    func segmentsReproduceTheWholeFilm() throws {
        // The property the phase period exists for, stated as a test. Each segment is
        // rendered by a pipeline that counts its intervals from zero, so it computes its
        // phases from a local index. Concatenating what those local renders produce has to
        // give back the film — same passthroughs in the same places, same phases between
        // the same pair of source frames.
        for (source, output) in pairs() {
            let global = IntervalPlanner(source: source, output: output)
            let frames = 600

            var expected: [String] = []
            for j in 0..<(frames - 1) { expected += shape(global.output(forInterval: j)) }

            for target in [2, 3, 7, 16, 61, 400] {
                let plan = try makePlan(source, output, frames: frames, target: target)
                var rebuilt: [String] = []
                for segment in plan.segments {
                    // A fresh planner, exactly as a fresh segment render would have.
                    let local = IntervalPlanner(source: source, output: output)
                    for j in 0..<segment.intervalCount {
                        rebuilt += shape(local.output(forInterval: j))
                    }
                }
                let what = "\(source) -> \(output), target \(target)"
                #expect(rebuilt == expected,
                        "\(what): the joined segments do not reproduce the film")
            }
        }
    }

    @Test("every segment but the last starts on a phase boundary")
    func boundariesAreOnThePhase() throws {
        // On the shipping pair the period is 2, so this is nearly free. On 23.976 -> 60 it
        // is 400 intervals, and a segment length below that has to be rounded up rather
        // than accepted.
        let plan = try makePlan(rate("24000/1001"), rate("60"), frames: 5000, target: 10)
        #expect(plan.phasePeriod == 400)
        #expect(plan.intervalsPerSegment == 400,
                "a target below the phase period must round up to it")
        for segment in plan.segments.dropLast() {
            #expect(segment.sourceStart % 400 == 0, "\(segment.description)")
        }
        #expect(plan.problems.isEmpty)

        // A length that is not a multiple of the period is rounded up, not down.
        let odd = try makePlan(rate("25"), rate("60"), frames: 5000, target: 12)
        #expect(odd.phasePeriod == 5)
        #expect(odd.intervalsPerSegment == 15)
    }

    @Test("a one-frame tail is folded in rather than becoming an empty segment")
    func shortTailIsFoldedIn() throws {
        // The film's intervals are `[0, frames - 1)`, so a tail of one source frame is not
        // an interval and cannot become a segment. The loop that places boundaries stops one
        // short of the frame count, which is what makes that impossible rather than merely
        // unlikely.
        let plan = try makePlan(rate("24000/1001"), rate("60000/1001"),
                                frames: 401, target: 400)
        #expect(plan.segments.count == 1)
        #expect(plan.segments[0].sourceCount == 401)
        #expect(plan.segments[0].intervalCount == 400)
        #expect(plan.problems.isEmpty)

        // A tail of two frames does render an interval, so it stays — and it reads both
        // frames, one of which the previous segment already read.
        let kept = try makePlan(rate("24000/1001"), rate("60000/1001"),
                                frames: 402, target: 400)
        #expect(kept.segments.count == 2)
        #expect(kept.segments[1].sourceCount == 2)
        #expect(kept.segments[1].intervalCount == 1)
        #expect(kept.segments[1].sourceStart == 400)
        #expect(kept.segments[0].sourceEnd == 401,
                "the shared frame belongs to both segments")
        #expect(kept.problems.isEmpty)
    }

    @Test("a plan is refused when there is nothing to plan")
    func degenerateInputsAreRefused() {
        let source = rate("24000/1001")
        let output = rate("60000/1001")
        // Fewer than two source frames is no interval at all.
        #expect(SegmentPlan(sourceFrameCount: 1, source: source, output: output,
                            targetSourceFrames: 100) == nil)
        #expect(SegmentPlan(sourceFrameCount: 0, source: source, output: output,
                            targetSourceFrames: 100) == nil)
        // A non-positive segment length is not a length.
        #expect(SegmentPlan(sourceFrameCount: 1000, source: source, output: output,
                            targetSourceFrames: 0) == nil)
        #expect(SegmentPlan(sourceFrameCount: 1000, source: source, output: output,
                            targetSourceFrames: -5) == nil)
        // And a segment of zero seconds is not a duration.
        #expect(SegmentPlan(sourceFrameCount: 1000, source: source, output: output,
                            segmentSeconds: 0) == nil)
        #expect(SegmentPlan(sourceFrameCount: 1000, source: source, output: output,
                            segmentSeconds: -1) == nil)
    }

    @Test("a duration is converted to an interval count once, in one place")
    func segmentSecondsConverts() throws {
        let source = rate("24000/1001")
        let output = rate("60000/1001")
        // 300 s at 23.976 is 7192.8 source frames, which rounds to 7193 — and then up to
        // the next even number, because the phase period is 2.
        let plan = try #require(SegmentPlan(sourceFrameCount: 100_000, source: source,
                                            output: output, segmentSeconds: 300))
        #expect(plan.intervalsPerSegment == 7194)
        #expect(plan.problems.isEmpty)

        // A duration short enough to round to fewer than two source frames is not a
        // segment length at all, and is refused rather than quietly clamped. 0.01 s at
        // 23.976 is a quarter of a frame.
        #expect(SegmentPlan(sourceFrameCount: 1000, source: source, output: output,
                            segmentSeconds: 0.01) == nil)

        // A duration that does clear two frames but not the phase period lands on the
        // period. 0.1 s is 2.4 frames, which rounds to 2 — already the period.
        let short = try #require(SegmentPlan(sourceFrameCount: 1000, source: source,
                                             output: output, segmentSeconds: 0.1))
        #expect(short.intervalsPerSegment == 2)
    }

    @Test("a boundary frame belongs to the segment that reads it first")
    func lookupsFindTheRightSegment() throws {
        let plan = try makePlan(rate("24000/1001"), rate("60000/1001"),
                                frames: 1000, target: 100)
        #expect(plan.segments.count == 10)
        // Each segment renders 100 intervals and therefore reads 101 frames.
        #expect(plan.segments.dropLast().allSatisfy { $0.sourceCount == 101 })
        #expect(plan.segments.dropLast().allSatisfy { $0.intervalCount == 100 })

        for segment in plan.segments {
            // Every output frame in the segment resolves back to it, and the frames either
            // side belong to the neighbours.
            #expect(plan.segment(containingOutput: segment.outputStart)?.index == segment.index)
            #expect(plan.segment(containingOutput: segment.outputEnd - 1)?.index == segment.index)
            #expect(plan.segment(containingInterval: segment.sourceStart)?.index == segment.index)
            if segment.index + 1 < plan.segments.count {
                #expect(plan.segment(containingOutput: segment.outputEnd)?.index
                            == segment.index + 1)
            }
        }
        #expect(plan.segment(containingOutput: -1) == nil)
        #expect(plan.segment(containingOutput: plan.outputFrameCount) == nil)
        #expect(plan.segment(containingInterval: -1) == nil)
        #expect(plan.segment(containingInterval: 100_000) == nil)

        // The last interval of the film belongs to the last segment, and the shared
        // boundary frame does not confuse the interval lookup: frame 100 is the far side of
        // interval 99 and the near side of interval 100, and only interval 100 owns a
        // segment that starts there.
        #expect(plan.segment(containingInterval: 99)?.index == 0)
        #expect(plan.segment(containingInterval: 100)?.index == 1)
        #expect(plan.segment(containingInterval: 998)?.index == 9)
        #expect(plan.segment(containingInterval: 999) == nil,
                "the film's last interval is 998; there is no interval 999")
    }

    @Test("the plan's own check catches a gap, and is shown to")
    func problemsAreReported() throws {
        // A healthy plan reports nothing, which is the only reading that means anything.
        let plan = try makePlan(rate("24000/1001"), rate("60000/1001"),
                                frames: 1000, target: 100)
        #expect(plan.problems.isEmpty)

        // The check has to be able to fail, or it is decoration. It is a function of the
        // segments rather than a method so that a broken set can be handed to it — the
        // initialiser's validation is exactly what a later edit to the arithmetic breaks,
        // and a check that can only see what the initialiser already accepted proves
        // nothing about it.
        //
        // Two segments that skip 50 source frames and 124 output frames between them.
        // Neither gap would be visible in the finished file: it would open, play, and be
        // missing two seconds in the middle.
        let holed = SegmentPlan.Segment(index: 0, sourceStart: 0, sourceCount: 100,
                                        outputStart: 0, outputCount: 249)
        let other = SegmentPlan.Segment(index: 1, sourceStart: 150, sourceCount: 100,
                                        outputStart: 373, outputCount: 250)
        let found = SegmentPlan.problems(in: [holed, other],
                                         sourceFrameCount: 300,
                                         outputFrameCount: 700,
                                         phasePeriod: 2)
        #expect(found.contains { $0.contains("intervals 99…150") },
                "the interval gap has to be reported: \(found)")
        #expect(found.contains { $0.contains("output frames 249…373") },
                "the output gap has to be reported: \(found)")
        #expect(found.contains { $0.contains("does not reach the end of the source") })
        #expect(found.contains { $0.contains("does not reach the end of the output") })

        // And the same check passes the real plan, so it is not simply always unhappy.
        #expect(SegmentPlan.problems(in: plan.segments,
                                     sourceFrameCount: plan.sourceFrameCount,
                                     outputFrameCount: plan.outputFrameCount,
                                     phasePeriod: plan.phasePeriod).isEmpty)
    }
}
