import Testing
@testable import Interpolator

@Suite("FrameRate")
struct FrameRateTests {

    @Test("exact rationals survive parsing unchanged")
    func exactRationals() {
        let rate = FrameRate.parse("60000/1001")
        #expect(rate?.numerator == 60000)
        #expect(rate?.denominator == 1001)
        #expect(rate?.description == "60000/1001")
    }

    @Test("integral rates collapse to n/1")
    func integralRates() {
        #expect(FrameRate.parse("24")?.description == "24")
        #expect(FrameRate.parse("60")?.description == "60")
    }

    /// The shorthand is a *name*, not a value. This is the single most expensive
    /// mistake available in this codebase: 59.94 written as a decimal is 2997/50,
    /// which is not the NTSC rate, and using it loses every passthrough frame.
    @Test("NTSC shorthand maps onto the exact rational, not the decimal")
    func shorthandIsNotADecimal() {
        let cases: [(String, Int, Int)] = [
            ("23.976", 24000, 1001),
            ("23.98", 24000, 1001),
            ("29.97", 30000, 1001),
            ("59.94", 60000, 1001),
            ("119.88", 120000, 1001),
        ]
        for (shorthand, numerator, denominator) in cases {
            let parsed = FrameRate.parse(shorthand)
            #expect(parsed?.numerator == numerator,
                    "\(shorthand) should be \(numerator)/\(denominator)")
            #expect(parsed?.denominator == denominator,
                    "\(shorthand) should be \(numerator)/\(denominator)")
        }
    }

    @Test("the literal decimal is available when that is genuinely what you mean")
    func literalDecimal() {
        let literal = FrameRate.parseLiteral("59.94")
        #expect(literal?.description == "2997/50")
        #expect(literal != FrameRate.parse("59.94"))
    }

    @Test("a decimal outside the NTSC family stays literal")
    func nonNTSCDecimal() {
        // 12.5 is not shorthand for anything; it must not be snapped to 12 or 15.
        #expect(FrameRate.parse("12.5")?.description == "25/2")
    }

    @Test("the ratio to 59.94 is exactly 2.5, which is the whole point")
    func exactRatio() {
        let source = FrameRate.parse("23.976")!
        let output = FrameRate.parse("59.94")!
        let ratio = source.ratio(to: output)
        #expect(ratio.numerator == 2)
        #expect(ratio.denominator == 5)
    }

    @Test("a decimal rate gives a ratio that is not exactly 2.5")
    func decimalRatioIsWrong() {
        // What a container or a UI actually hands you: 23.976024 is the six-decimal
        // rounding of 24000/1001, and 59.94 the four-decimal shorthand for 60000/1001.
        // Together they reduce to a ratio of 0.4000004, which is not 2/5.
        let source = FrameRate.parseLiteral("23.976024")!
        let output = FrameRate.parseLiteral("59.94")!
        let ratio = source.ratio(to: output)
        #expect(!(ratio.numerator == 2 && ratio.denominator == 5),
                "the decimal ratio must not be exactly 2/5, got \(ratio.numerator)/\(ratio.denominator)")

        let exact = FrameRate.parse("23.976")!.ratio(to: FrameRate.parse("59.94")!)
        #expect(exact.numerator == 2 && exact.denominator == 5,
                "the shorthand must give exactly 2/5")
    }

    @Test("non-positive rates are rejected")
    func rejectsNonPositive() {
        #expect(FrameRate(numerator: 0, denominator: 1) == nil)
        #expect(FrameRate(numerator: 24, denominator: 0) == nil)
        #expect(FrameRate.parse("0") == nil)
        #expect(FrameRate.parse("-24") == nil)
        #expect(FrameRate.parse("nonsense") == nil)
    }
}
