import Testing
@testable import Interpolator

/// `IntervalPlanner` and `PhasePlan` compute the same plan two different ways.
///
/// `PhasePlan` makes the whole thing at once and needs the total source frame count
/// to know where to stop. `IntervalPlanner` makes it one interval at a time and
/// needs nothing up front — which is the only form that works for a Matroska file
/// (ffprobe reports `nb_frames=N/A`) or for playback (there is no total).
///
/// That is two implementations of one piece of arithmetic, and two implementations
/// of one piece of arithmetic is one too many unless something proves they agree.
/// These tests are that proof, and they are deliberately of the same shape as the
/// ones that keep the offline and online scene detectors honest: not "close
/// enough", but identical, frame for frame, over a spread of rate pairs and
/// lengths.
@Suite("IntervalPlanner")
struct IntervalPlannerTests {

    // MARK: - Helpers

    /// Concatenate the intervals the way the pipeline walks them: interval `j` for
    /// `j = 0 ..< sourceFrameCount - 1`, in order.
    ///
    /// The stopping rule is the whole point of the comparison. `PhasePlan` stops
    /// when `j` reaches `lastSourceIndex`, so the final source frame is only ever
    /// used as an interval's `after` and never emitted. The pipeline stops when the
    /// source runs out, which is the same boundary reached a different way.
    private func incrementalFrames(sourceFrameCount: Int,
                                   source: FrameRate,
                                   output: FrameRate) -> [OutputFrame] {
        let planner = IntervalPlanner(source: source, output: output)
        var frames: [OutputFrame] = []
        for j in 0..<max(0, sourceFrameCount - 1) {
            frames.append(contentsOf: planner.output(forInterval: j))
        }
        return frames
    }

    /// The rate pairs the app actually has to handle, plus the awkward ones.
    private static let ratePairs: [(String, String)] = [
        ("23.976", "59.94"),   // film -> NTSC, the primary case
        ("24000/1001", "60000/1001"),  // the same thing, written exactly
        ("23.976", "60"),      // film -> exact 60: ratio 2.5025, not 2.5
        ("24", "60"),          // 2.5x exactly
        ("25", "50"),          // 2x exactly, PAL
        ("29.97", "59.94"),    // 2x, NTSC video
        ("30", "60"),          // 2x, exact
        ("50", "60"),          // 1.2x — the ratio with the most awkward phases
        ("48", "60"),          // 1.25x
        ("60", "60"),          // 1x: every frame a passthrough
    ]

    private static let lengths = [2, 3, 4, 5, 6, 11, 47, 101, 191, 500]

    // MARK: - The equivalence

    @Test("it reproduces PhasePlan frame for frame, at every rate and length")
    func reproducesPhasePlan() {
        var compared = 0
        var mismatches: [String] = []

        for (sourceText, outputText) in Self.ratePairs {
            let source = FrameRate.parse(sourceText)!
            let output = FrameRate.parse(outputText)!

            for length in Self.lengths {
                guard let whole = PhasePlan(sourceFrameCount: length,
                                            source: source, output: output) else { continue }
                let incremental = incrementalFrames(sourceFrameCount: length,
                                                    source: source, output: output)
                compared += 1

                if whole.frames.count != incremental.count {
                    mismatches.append("\(sourceText)->\(outputText) n=\(length): "
                                      + "\(whole.frames.count) vs \(incremental.count) frames")
                    continue
                }
                for (k, (a, b)) in zip(whole.frames, incremental).enumerated() where a != b {
                    mismatches.append("\(sourceText)->\(outputText) n=\(length) k=\(k): "
                                      + "\(a.kind) vs \(b.kind)")
                    break
                }

                // The derived counts have to survive too, not just the frame list —
                // they are what the reports and the throughput numbers are made of.
                let passthroughs = incremental.filter(\.isPassthrough).count
                if passthroughs != whole.passthroughCount {
                    mismatches.append("\(sourceText)->\(outputText) n=\(length): "
                                      + "passthroughs \(whole.passthroughCount) vs \(passthroughs)")
                }
            }
        }

        #expect(compared == Self.ratePairs.count * Self.lengths.count,
                "every rate and length should have produced a plan")
        #expect(mismatches.isEmpty, "\(mismatches.prefix(6).joined(separator: "; "))")
    }

    @Test("it reproduces the interval grouping, not just the flat frame list")
    func reproducesIntervals() {
        for (sourceText, outputText) in Self.ratePairs {
            let source = FrameRate.parse(sourceText)!
            let output = FrameRate.parse(outputText)!
            let length = 191
            guard let whole = PhasePlan(sourceFrameCount: length,
                                        source: source, output: output) else { continue }
            let planner = IntervalPlanner(source: source, output: output)

            // PhasePlan drops an interval that produced nothing; the planner returns
            // an empty array for it. Compare on the non-empty ones.
            let produced = (0..<(length - 1))
                .map { planner.output(forInterval: $0) }
                .filter { !$0.isEmpty }

            #expect(produced.count == whole.intervals.count,
                    "\(sourceText)->\(outputText): \(produced.count) vs \(whole.intervals.count)")
            for (a, b) in zip(whole.intervals, produced) {
                #expect(a.sourceIndex == planner.interval(forOutputIndex: b[0].index),
                        "\(sourceText)->\(outputText): interval index")
                #expect(a.output == b, "\(sourceText)->\(outputText): interval \(a.sourceIndex)")
            }
        }
    }

    @Test("it reproduces cut resolution exactly")
    func reproducesCutResolution() {
        // Cuts chosen to hit the awkward places: the first interval, the last, and
        // two in the middle. The tail matters most — it is the one interval where
        // the online and offline evidence can differ, so it is the one where a
        // second copy of the cut rule would show up.
        let length = 191
        let cutIntervals = [0, 7, 61, 62, 100, length - 2]
        var isCut = [Bool](repeating: false, count: length)
        for interval in cutIntervals where interval < length { isCut[interval] = true }
        let report = SceneChangeReport(
            isCut: isCut,
            histogramDistance: [Float](repeating: 0, count: length),
            gridDistance: [Float](repeating: 0, count: length),
            threshold: [Float](repeating: 0, count: length))

        for (sourceText, outputText) in Self.ratePairs {
            let source = FrameRate.parse(sourceText)!
            let output = FrameRate.parse(outputText)!
            guard let whole = PhasePlan(sourceFrameCount: length,
                                        source: source, output: output) else { continue }
            let expected = whole.resolvingCuts(report)

            let planner = IntervalPlanner(source: source, output: output)
            var incremental: [OutputFrame] = []
            for j in 0..<(length - 1) {
                let frames = planner.output(forInterval: j)
                incremental.append(contentsOf: CutResolution.resolve(frames, isCut: isCut[j]))
            }

            #expect(incremental == expected.frames,
                    "\(sourceText)->\(outputText): cut-resolved frames differ")
        }
    }

    // MARK: - Properties the pipeline relies on

    @Test("one interval never produces more frames than the declared maximum")
    func maximumIsAnUpperBound() {
        for (sourceText, outputText) in Self.ratePairs {
            let planner = IntervalPlanner(source: FrameRate.parse(sourceText)!,
                                          output: FrameRate.parse(outputText)!)
            for j in 0..<400 {
                let count = planner.output(forInterval: j).count
                #expect(count <= planner.maximumOutputFramesPerInterval,
                        "\(sourceText)->\(outputText) interval \(j): \(count) frames")
            }
        }
    }

    @Test("the engine's own per-interval bound covers what the planner produces")
    func engineBoundCoversPlanner() {
        // The engine sizes its destination list from its own bound, and the harness
        // takes a prefix of that list. If the planner could ever ask for more
        // interpolations than the engine allows, the extra frames would be silently
        // dropped — so the two bounds have to be ordered the right way round.
        for (sourceText, outputText) in Self.ratePairs {
            let source = FrameRate.parse(sourceText)!
            let output = FrameRate.parse(outputText)!
            let planner = IntervalPlanner(source: source, output: output)
            let engine = VTFrameProcessorEngine(source: source, output: output)
            for j in 0..<400 {
                let interpolations = planner.output(forInterval: j)
                    .filter { !$0.isPassthrough }.count
                #expect(interpolations <= engine.maximumInterpolationsPerInterval,
                        "\(sourceText)->\(outputText) interval \(j): planner wants \(interpolations), engine allows \(engine.maximumInterpolationsPerInterval)")
            }
        }
    }

    @Test("output frame indices are contiguous and start at zero")
    func indicesAreContiguous() {
        // The sink is handed an index per frame and the file is laid out by it, so a
        // gap or a repeat would leave a hole in the output rather than fail.
        for (sourceText, outputText) in Self.ratePairs {
            let frames = incrementalFrames(sourceFrameCount: 500,
                                           source: FrameRate.parse(sourceText)!,
                                           output: FrameRate.parse(outputText)!)
            #expect(frames.first?.index == 0)
            for (expected, frame) in frames.enumerated() where frame.index != expected {
                Issue.record("\(sourceText)->\(outputText): frame \(expected) has index \(frame.index)")
                break
            }        }
    }

    @Test("the interval lookup is the inverse of the output lookup")
    func intervalLookupIsInverse() {
        for (sourceText, outputText) in Self.ratePairs {
            let planner = IntervalPlanner(source: FrameRate.parse(sourceText)!,
                                          output: FrameRate.parse(outputText)!)
            for j in 0..<200 {
                for frame in planner.output(forInterval: j) {
                    #expect(planner.interval(forOutputIndex: frame.index) == j)
                }
            }
        }
    }

    @Test("a passthrough is exactly a frame that lands on a source frame")
    func passthroughMatchesTheRemainderTest() {
        for (sourceText, outputText) in Self.ratePairs {
            let planner = IntervalPlanner(source: FrameRate.parse(sourceText)!,
                                          output: FrameRate.parse(outputText)!)
            for j in 0..<200 {
                for frame in planner.output(forInterval: j) {
                    #expect(frame.isPassthrough
                            == planner.isPassthrough(outputIndex: frame.index))
                    if case .passthrough(let sourceIndex) = frame.kind {
                        #expect(sourceIndex == j)
                    }
                }
            }
        }
    }

    // MARK: - The case the whole design exists for

    @Test("a passthrough needs the two rates to be an exact rational multiple")
    func passthroughNeedsAnExactRatio() {
        // A passthrough is an output frame that lands *exactly* on a source frame,
        // which happens when k * pnum is a multiple of pden. How often that can
        // happen is entirely a property of the rate pair, and the difference between
        // two pairs that look almost identical is not small.
        //
        // 23.976 -> 59.94 is exactly 2.5x (24000/1001 -> 60000/1001), so alignment
        // recurs every 2 source frames: 1 output frame in 5 is free, 20%.
        //
        // 23.976 -> 60 is 2.5025x, and 1001 and 400 are coprime, so alignment
        // recurs once every 1001 output frames: 0.1%. That is a passthrough every
        // ~16.7 seconds instead of five times a second, and it costs about 25% more
        // inference on film content for 0.06 fps more output.
        //
        // This is pinned because it is a product decision, not an implementation
        // detail — see reports/BUILD-DECISIONS.md §18.
        let cases: [(source: String, output: String, period: Int)] = [
            ("23.976", "59.94", 5),      // exact 2.5x
            ("24", "60", 5),             // exact 2.5x
            ("29.97", "59.94", 2),       // exact 2x
            ("30", "60", 2),             // exact 2x
            ("25", "50", 2),             // exact 2x
            ("23.976", "60", 1001),      // 2.5025x — coprime, aligns once per 1001
        ]

        for (sourceText, outputText, period) in cases {
            let planner = IntervalPlanner(source: FrameRate.parse(sourceText)!,
                                          output: FrameRate.parse(outputText)!)
            var passthroughs = 0
            var total = 0
            for j in 0..<2_000 {
                let frames = planner.output(forInterval: j)
                passthroughs += frames.filter(\.isPassthrough).count
                total += frames.count
            }
            let expected = Double(total) / Double(period)
            #expect(abs(Double(passthroughs) - expected) <= 1,
                    "\(sourceText)->\(outputText): \(passthroughs) passthroughs in \(total) frames, expected about \(Int(expected))")
        }
    }

    @Test("the passthrough fraction stays stable far into the stream")
    func passthroughFractionDoesNotDrift() {
        // The failure mode this guards is the one that cost 20% of throughput: with
        // floating point, the fractional part drifts a few e-7 per frame, so the
        // passthroughs all happen at the start and then stop. Checking the first
        // hundred intervals would pass. Checking the last hundred is the test.
        let planner = IntervalPlanner(source: FrameRate.parse("23.976")!,
                                      output: FrameRate.parse("59.94")!)
        func fraction(from first: Int, count: Int) -> Double {
            var passthroughs = 0
            var total = 0
            for j in first..<(first + count) {
                let frames = planner.output(forInterval: j)
                passthroughs += frames.filter(\.isPassthrough).count
                total += frames.count
            }
            return Double(passthroughs) / Double(total)
        }
        // 100,000 intervals in is roughly 40 minutes of film.
        #expect(abs(fraction(from: 0, count: 200) - 0.2) < 0.01)
        #expect(abs(fraction(from: 100_000, count: 200) - 0.2) < 0.01,
                "the passthrough rate must not decay with position")
    }

    @Test("a rate pair the app never builds degrades instead of trapping")
    func downsamplingDegradesGracefully() {
        // Output below source is refused by the harness, but the planner must not
        // divide by zero or spin if it is ever handed one.
        let planner = IntervalPlanner(source: FrameRate.parse("60")!,
                                      output: FrameRate.parse("24")!)
        #expect(planner.isUpsampling == false)
        var total = 0
        for j in 0..<100 { total += planner.output(forInterval: j).count }
        #expect(total > 0, "some intervals still produce output")
        #expect(planner.output(forInterval: 0).count <= planner.maximumOutputFramesPerInterval)
    }
}
