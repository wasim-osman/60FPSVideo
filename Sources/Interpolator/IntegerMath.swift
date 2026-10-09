import Foundation

/// The integer arithmetic the rate types share.
///
/// ## Why this is a file rather than two private functions
///
/// The standard library carries no `gcd` for `Int`, so each place that needed one grew
/// its own: `FrameRate` normalises its rational with one, and `OutputRatePolicy` walks a
/// passthrough period with another. They were byte-for-byte identical and nobody had
/// noticed, which is the state duplication is in right before it diverges.
///
/// A third caller — the phase period that decides where a segment may begin — is the point
/// at which this stops being harmless. `SegmentPlan` rounds a segment length up to a
/// multiple of that period, and if two of the three copies disagreed about a zero, one
/// path would segment a film correctly and another would mis-phase every boundary. The
/// failure would be a stutter at regular intervals in the finished file, which is the
/// hardest kind of defect to trace back to a division.
enum IntegerMath {

    /// Greatest common divisor, by Euclid's algorithm.
    ///
    /// Returns 1 rather than 0 when both inputs are zero. That is not the mathematical
    /// answer — every integer divides zero — but it is the useful one: every caller is
    /// dividing by the result to reduce a ratio or to find a period, and a zero there is a
    /// crash rather than a wrong number. A degenerate rate cannot reach here anyway;
    /// `FrameRate` refuses to construct one.
    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}
