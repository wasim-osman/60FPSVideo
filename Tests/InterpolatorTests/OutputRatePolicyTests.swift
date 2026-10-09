import Testing
@testable import Interpolator

/// The output rate decision, and the measurement it rests on.
///
/// The claim that picks 59.94 is a claim about passthrough frames: `23.976 -> 59.94` is
/// exactly 2.5x, so one output frame in five is already a source picture. A test that
/// only checked the arithmetic of the policy would be checking that I can multiply, so
/// the important test here is the last one — the closed-form fraction against what
/// `IntervalPlanner` really emits.
@Suite("Output rate policy")
struct OutputRatePolicyTests {

    // MARK: - The default

    @Test("the default is 59.94, and 59.94 means 60000/1001")
    func theDefaultIsTheNTSCRational() {
        let policy = OutputRatePolicy.default
        #expect(policy == OutputRatePolicy.standard)
        #expect(policy.rate == FrameRate(numerator: 60000, denominator: 1001))
        #expect(policy.rate.numerator == 60000)
        #expect(policy.rate.denominator == 1001)
        #expect(policy.label == "59.94")

        // `59.94` written as a decimal is 2997/50 — a different rate. Choosing it by
        // accident is the single most expensive mistake available here (invariant 14),
        // so the shorthand must not produce it.
        #expect(policy.rate != FrameRate.parseLiteral("59.94"))
        #expect(FrameRate.parse("59.94") == policy.rate)
    }

    @Test("the well-known statics are the exact rationals")
    func wellKnownRatesAreExact() {
        #expect(FrameRate.sixtyNTSC.description == "60000/1001")
        #expect(FrameRate.sixty.description == "60")
        #expect(FrameRate.thirtyNTSC.description == "30000/1001")
        #expect(FrameRate.twentyFourNTSC.description == "24000/1001")
        #expect(FrameRate.twentyFour.description == "24")
    }

    @Test("ordering is exact, not a decimal comparison")
    func orderingIsExact() {
        // 0.06 apart, and the difference is the whole reason this type is a rational.
        #expect(FrameRate.sixtyNTSC < FrameRate.sixty)
        #expect(FrameRate.sixty.doubleValue - FrameRate.sixtyNTSC.doubleValue > 0.05)
        #expect(!(FrameRate.sixtyNTSC < FrameRate.thirtyNTSC))
        #expect(FrameRate.thirtyNTSC < FrameRate.sixtyNTSC)
        // 23.976 is below 24.000, which is below 59.94. Comparing `doubleValue` would
        // also get these right; the point is that this never has to.
        #expect(FrameRate.twentyFourNTSC < FrameRate.twentyFour)
        #expect(FrameRate.twentyFour < FrameRate.sixtyNTSC)
    }

    @Test("the default is offered first")
    func defaultIsFirstInTheList() {
        #expect(OutputRatePolicy.all.first == OutputRatePolicy.default)
        #expect(OutputRatePolicy.all.count == 2)
    }

    @Test("policies are addressable by name")
    func namedLookups() {
        #expect(OutputRatePolicy.named("standard") == .standard)
        #expect(OutputRatePolicy.named("59.94") == .standard)
        #expect(OutputRatePolicy.named("sixty") == .exactSixty)
        #expect(OutputRatePolicy.named("60") == .exactSixty)
        #expect(OutputRatePolicy.named("60.000") == .exactSixty)
        #expect(OutputRatePolicy.named("nonsense") == nil)
    }

    // MARK: - Resolving against a source

    @Test("film converts at exactly five halves")
    func filmConvertsAtFiveHalves() {
        let resolution = OutputRatePolicy.standard.resolve(source: FrameRate.twentyFourNTSC)
        #expect(resolution.output == FrameRate.sixtyNTSC)
        #expect(resolution.ratio.numerator == 5)
        #expect(resolution.ratio.denominator == 2)
        #expect(resolution.isPassthrough == false)
        #expect(resolution.note == nil)
    }

    @Test("the default keeps one output frame in five")
    func defaultKeepsOneInFive() {
        let resolution = OutputRatePolicy.standard.resolve(source: FrameRate.twentyFourNTSC)
        #expect(abs(resolution.passthroughFraction - 0.2) < 1e-12)
    }

    @Test("exactly 60.000 is not a neat 2.5x on film, which is why it is not the default")
    func sixtyLosesThePassthrough() {
        // The ratio itself is what breaks. 59.94 shares the /1001 denominator with
        // 23.976 and reduces to 5/2; 60/1 does not, and reduces to 1001/400 = 2.5025.
        // 1001 and 400 are coprime, so alignment recurs once per 1001 output frames.
        let film = OutputRatePolicy.standard.resolve(source: FrameRate.twentyFourNTSC)
        #expect(film.ratio.numerator == 5)
        #expect(film.ratio.denominator == 2)

        let resolution = OutputRatePolicy.exactSixty.resolve(source: FrameRate.twentyFourNTSC)
        #expect(resolution.output == FrameRate.sixty)
        #expect(resolution.ratio.numerator == 1001)
        #expect(resolution.ratio.denominator == 400)
        #expect(abs(resolution.passthroughFraction - 1.0 / 1001.0) < 1e-12)
    }

    @Test("the two rate families want opposite answers")
    func familiesWantOppositeAnswers() {
        // The cleanest statement of the trade. A film source aligns at 59.94 and not at
        // 60.000; a cinema source aligns at 60.000 and not at 59.94. Neither policy is
        // right for both, which is why the override exists rather than a smarter default.
        #expect(OutputRatePolicy.standard.resolve(source: FrameRate.twentyFourNTSC).ratio
                == (5, 2))
        #expect(OutputRatePolicy.exactSixty.resolve(source: FrameRate.twentyFourNTSC).ratio
                == (1001, 400))

        #expect(OutputRatePolicy.exactSixty.resolve(source: FrameRate.twentyFour).ratio
                == (5, 2))
        #expect(OutputRatePolicy.standard.resolve(source: FrameRate.twentyFour).ratio
                == (2500, 1001))
    }

    @Test("29.97 doubles exactly, which is what the low-latency path needs")
    func ntscDoublesExactly() {
        let resolution = OutputRatePolicy.standard.resolve(source: FrameRate.thirtyNTSC)
        #expect(resolution.output == FrameRate.sixtyNTSC)
        #expect(resolution.ratio.numerator == 2)
        #expect(resolution.ratio.denominator == 1)
        // Every second output frame is a source frame.
        #expect(abs(resolution.passthroughFraction - 0.5) < 1e-12)
    }

    @Test("a source already at the target is a free passthrough")
    func sourceAtTargetIsFree() {
        let resolution = OutputRatePolicy.standard.resolve(source: FrameRate.sixtyNTSC)
        #expect(resolution.output == FrameRate.sixtyNTSC)
        #expect(resolution.isPassthrough)
        // Nothing unusual happened — the target *is* the source — so there is no note.
        #expect(resolution.note == nil)
        #expect(resolution.ratio.numerator == 1)
        #expect(resolution.ratio.denominator == 1)
        #expect(resolution.passthroughFraction == 1.0)
    }

    @Test("a 60.000 source under the 59.94 default is not downconverted")
    func sixtySourceIsNotDownconverted() {
        // This is the case that actually occurs in the wild, and the reason `resolve`
        // returns more than the policy's own rate.
        let resolution = OutputRatePolicy.standard.resolve(source: FrameRate.sixty)
        #expect(resolution.output == FrameRate.sixty)
        #expect(resolution.policyRate == FrameRate.sixtyNTSC)
        #expect(resolution.isPassthrough)
        #expect(resolution.note != nil, "the caller has to be able to explain why nothing ran")
    }

    @Test("the output rate is never below the source rate")
    func neverDownconverts() {
        let sources = ["23.976", "24", "25", "29.97", "30", "48", "50", "59.94", "60",
                       "120"]
        for text in sources {
            guard let source = FrameRate.parse(text) else {
                Issue.record("could not parse \(text)")
                continue
            }
            for policy in OutputRatePolicy.all {
                let resolution = policy.resolve(source: source)
                #expect(resolution.output >= source,
                        "\(policy.label) on \(text) produced \(resolution.output), below the source")
                // And it never invents a rate that is neither the target nor the source.
                #expect(resolution.output == policy.rate || resolution.output == source,
                        "\(policy.label) on \(text) produced \(resolution.output), which is neither the target nor the source")
            }
        }
    }

    @Test("the override exists for integer sources, and only helps there")
    func overrideHelpsIntegerSources() {
        // 24.000: no /1001 denominator to share, so 59.94 has nothing to align with.
        let integer = FrameRate.twentyFour
        #expect(OutputRatePolicy.standard.resolve(source: integer).passthroughFraction < 0.001)
        #expect(abs(OutputRatePolicy.exactSixty.resolve(source: integer).passthroughFraction
                    - 0.2) < 1e-12)

        // 23.976: the opposite — the default is the one that aligns.
        let film = FrameRate.twentyFourNTSC
        #expect(abs(OutputRatePolicy.standard.resolve(source: film).passthroughFraction
                    - 0.2) < 1e-12)
        #expect(OutputRatePolicy.exactSixty.resolve(source: film).passthroughFraction < 0.002)
    }

    // MARK: - The measurement the decision rests on

    @Test("the closed-form fraction is what the planner actually emits")
    func closedFormMatchesThePlanner() {
        // If `passthroughFraction` disagreed with `IntervalPlanner`, the default would
        // have been chosen on a number that does not describe the program. Walk real
        // intervals and compare.
        let cases: [(source: String, policy: OutputRatePolicy)] = [
            ("23.976", .standard), ("23.976", .exactSixty),
            ("29.97", .standard), ("29.97", .exactSixty),
            ("24", .standard), ("24", .exactSixty),
            ("25", .standard), ("30", .standard),
        ]
        for (text, policy) in cases {
            guard let source = FrameRate.parse(text) else {
                Issue.record("could not parse \(text)")
                continue
            }
            let resolution = policy.resolve(source: source)
            let planner = IntervalPlanner(source: source, output: resolution.output)

            var free = 0
            var total = 0
            for j in 0..<3_000 {
                for frame in planner.output(forInterval: j) {
                    total += 1
                    if frame.isPassthrough { free += 1 }
                }
            }
            let measured = Double(free) / Double(total)
            let predicted = resolution.passthroughFraction
            #expect(abs(measured - predicted) < 0.005,
                    "\(source) -> \(resolution.output): planner emitted \(measured), the closed form says \(predicted)")
        }
    }

    @Test("on film, the default is an order of magnitude more free frames")
    func defaultWinsOnFilm() {
        // The one-line justification for the decision. 20% against 0.1% — a factor of
        // 200 — and that is the ~25% of inference time the default saves.
        let film = FrameRate.twentyFourNTSC
        let standard = OutputRatePolicy.standard.resolve(source: film).passthroughFraction
        let sixty = OutputRatePolicy.exactSixty.resolve(source: film).passthroughFraction
        #expect(standard > sixty * 100,
                "59.94 gave \(standard) free frames against \(sixty) at 60.000 — the margin that justified the default is gone")
    }
}
