import Foundation

/// A frame rate carried as an exact rational.
///
/// ## Why this type exists (invariant 14)
///
/// Carrying a frame rate as a `Double` silently destroys throughput.
///
/// 23.976 -> 59.94 is *exactly* 2.5x, so one output frame in five lands precisely on
/// a source frame and needs no interpolation at all. Feed the pipeline `59.94`
/// instead of `60000/1001` and the interpolation phase drifts about 4e-7 per frame,
/// which is enough to lose **every one of those frames**. Measured on real film:
///
/// | conversion | passthrough frames | lost to a decimal rate |
/// |---|---|---|
/// | 23.976 -> 59.94 | 20% | all of them |
/// | 29.97 -> 59.94 | 50% | all of them |
///
/// That is a 20-50% throughput loss, not a rounding detail. Fixing it gained RIFE
/// +22% and VTFrameProcessor +8% on the same clip.
///
/// ## Parsing
///
/// ``parse(_:)`` accepts both `"60000/1001"` and the shorthand the video industry
/// writes, `"59.94"`. **The shorthand is not a decimal value.** `59.94` written as a
/// decimal is `2997/50`, which is not the NTSC rate; it is a name for `60000/1001`.
/// ``parse(_:)`` therefore maps the known NTSC shorthands onto their exact rational
/// forms, and only falls back to a literal decimal for values that are not part of
/// that family. Use ``parseLiteral(_:)`` to get the raw decimal when that is
/// genuinely what you mean.
public struct FrameRate: Hashable, Sendable, CustomStringConvertible {

    public let numerator: Int
    public let denominator: Int

    /// Fails on non-positive values. The fraction is reduced to lowest terms.
    public init?(numerator: Int, denominator: Int) {
        guard numerator > 0, denominator > 0 else { return nil }
        let g = FrameRate.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    public init?(_ value: Int) {
        self.init(numerator: value, denominator: 1)
    }

    public var doubleValue: Double {
        Double(numerator) / Double(denominator)
    }

    /// `"60000/1001"` — always the exact rational, never a decimal.
    public var description: String {
        denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }

    // MARK: - The NTSC shorthand family
    //
    // These decimals are names, not values. 23.976 is not 23.976; it is 24000/1001.
    // Getting this wrong is the single most expensive mistake available in this
    // codebase, so the table is explicit rather than computed.
    private static let ntscShorthand: [(shorthand: String, rate: FrameRate)] = {
        func r(_ n: Int, _ d: Int) -> (String, FrameRate) {
            let rate = FrameRate(numerator: n, denominator: d)!
            return (String(format: "%.3f", Double(n) / Double(d)), rate)
        }
        return [r(24000, 1001), r(30000, 1001), r(48000, 1001),
                r(60000, 1001), r(120000, 1001)]
    }()

    /// Rates that are whole numbers and need no rational treatment.
    private static let integralRates: Set<Int> = [1, 5, 10, 12, 15, 16, 18, 20, 24,
                                                  25, 30, 32, 40, 48, 50, 60, 72,
                                                  90, 96, 100, 120, 144, 240]

    // MARK: - Parsing

    /// Parse a frame rate as a user or a container would write it.
    ///
    /// - `"60000/1001"` -> exact.
    /// - `"59.94"` -> **`60000/1001`**, because that is what the shorthand means.
    /// - `"24"` -> `24/1`.
    /// - `"12.5"` -> `25/2`, a literal decimal, because it is not in the NTSC family.
    public static func parse(_ string: String) -> FrameRate? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let d = Int(parts[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return FrameRate(numerator: n, denominator: d)
        }

        guard let value = Double(trimmed), value > 0 else { return nil }

        if value.rounded() == value, let exact = Int(exactly: value.rounded()),
           integralRates.contains(exact) {
            return FrameRate(exact)
        }

        if let match = ntscRational(near: value) { return match }

        return parseLiteral(trimmed)
    }

    /// Parse a decimal *literally*: `"59.94"` -> `2997/50`.
    ///
    /// Only correct when the value really is a decimal. For video rates it almost
    /// never is; prefer ``parse(_:)``.
    public static func parseLiteral(_ string: String) -> FrameRate? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value > 0 else { return nil }
        // Scale by 1e6 and reduce, so "23.976" -> 23976/1000 -> 2997/125.
        let scaled = Int((value * 1_000_000).rounded())
        return FrameRate(numerator: scaled, denominator: 1_000_000)
    }

    /// The exact NTSC rational a shorthand decimal refers to, if it is one.
    ///
    /// Matches on the three-decimal form the industry writes (`23.976`, `29.97`,
    /// `59.94`, ...) with a tight tolerance, so a genuinely arbitrary decimal is not
    /// silently snapped onto an NTSC rate.
    public static func ntscRational(near value: Double) -> FrameRate? {
        for entry in ntscShorthand {
            let shorthandValue = Double(entry.rate.numerator) / Double(entry.rate.denominator)
            if abs(value - shorthandValue) <= 0.005 {
                return entry.rate
            }
        }
        return nil
    }

    // MARK: - Ratio

    /// The exact ratio `self / other`, as a fraction of two integers.
    ///
    /// This is the quantity the phase plan is built from. It is exact, and it is
    /// where a decimal rate goes wrong.
    public func ratio(to other: FrameRate) -> (numerator: Int, denominator: Int) {
        let n = numerator * other.denominator
        let d = denominator * other.numerator
        let g = FrameRate.greatestCommonDivisor(n, d)
        return (n / g, d / g)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}
