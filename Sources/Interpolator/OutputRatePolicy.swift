import Foundation

/// Which output rate to produce for a given source rate.
///
/// ## One decision, one place
///
/// The batch converter and the player must not be able to disagree about this, for the
/// same reason `CutRule` and `CutResolution` exist. If they did, a film converted at
/// 59.94 and the same film played back at 60.000 would have different cadences: the
/// passthrough frames — the ones that are already a source picture — would land in
/// different places, so the two paths would not merely run at different speeds, they
/// would show different pictures. The policy is therefore a value both consumers take,
/// not a constant either of them owns.
///
/// ## Why 59.94 is the default
///
/// A passthrough frame exists only when the two rates are an exact rational multiple.
/// `59.94` is `60000/1001` and the common film rate `23.976` is `24000/1001` — the same
/// denominator — so `23.976 -> 59.94` is *exactly* 2.5x and **one output frame in five
/// is free**. Move the output to `60/1` and `1001` and `400` are coprime, so alignment
/// recurs once every 1001 output frames: **0.1%**, about one free frame every 16.7
/// seconds.
///
/// Measured on the reference clip: 5,000 passthroughs in 25,000 output frames at 59.94,
/// against 25 in 25,025 at 60.000. That extra 0.06 fps of output rate costs roughly
/// **25% more inference** on film, and it turns one frame in five from the original
/// picture into a reconstruction.
///
/// 59.94 also shares the `/1001` denominator with 29.97, where the ratio becomes exactly
/// 2x — which is what lets a 29.97 source take the low-latency path.
///
/// ## The cost, stated honestly
///
/// 59.94 is not uniformly better, and pretending otherwise would be the kind of thing
/// that gets discovered later as a mystery slowdown. For an **integer** source rate —
/// 24.000, 25, 30, 50 — there is no denominator to share, so the passthrough is lost
/// either way and 60.000 is the faster choice: 24.000 runs at 80.3 fps to 60.000 against
/// 74.8 to 59.94, a 7% regression. ``exactSixty`` exists for exactly that case. It is not
/// the default because the content this was built for is NTSC film.
///
/// On a 60.00 Hz display, 59.94 output repeats one frame roughly every 16.7 s. That is
/// imperceptible, and it is what every NTSC disc already does.
public struct OutputRatePolicy: Sendable, Hashable, CustomStringConvertible {

    /// The rate to produce, before the source is taken into account.
    public let rate: FrameRate

    /// How the rate is written for a person. Deliberately not `rate.description`,
    /// which is the exact rational: `60000/1001` is the correct thing to store and an
    /// unhelpful thing to show.
    public let label: String

    public init(rate: FrameRate, label: String) {
        self.rate = rate
        self.label = label
    }

    /// 59.94 (`60000/1001`). The default.
    public static let standard = OutputRatePolicy(rate: .sixtyNTSC, label: "59.94")

    /// 60.000 exactly. For integer-rate sources, where 59.94 has nothing to align with.
    public static let exactSixty = OutputRatePolicy(rate: .sixty, label: "60.000")

    /// What the app uses unless the user changes it.
    public static let `default` = OutputRatePolicy.standard

    /// Both policies, in the order a settings pane should offer them.
    public static let all: [OutputRatePolicy] = [.standard, .exactSixty]

    /// Look one up by the name used on the command line and in preferences.
    public static func named(_ name: String) -> OutputRatePolicy? {
        switch name {
        case "standard", "59.94": return .standard
        case "sixty", "60", "60.000": return .exactSixty
        default: return nil
        }
    }

    public var description: String { "\(label) (\(rate))" }

    // MARK: - Resolving against a source

    /// What a source at this rate should be converted to.
    ///
    /// The one rule beyond the target: **the output rate is never below the source.**
    /// Going the other way is a downconversion, and this app does not do that — it would
    /// drop pictures rather than invent them. The case that actually occurs is a 60.000
    /// source under the 59.94 default, and the honest answer there is that the file is
    /// already at the target and nothing needs doing.
    public func resolve(source: FrameRate) -> Resolution {
        guard rate < source else {
            return Resolution(output: rate, policyRate: rate, source: source, note: nil)
        }
        return Resolution(
            output: source,
            policyRate: rate,
            source: source,
            note: "source is already \(source), at or above the \(label) target — "
                + "nothing to convert")
    }

    /// The outcome of applying a policy to a source rate.
    ///
    /// A small type rather than a bare `FrameRate` because two callers need to explain
    /// themselves: the batch converter has to tell the user why a job did nothing, and
    /// the player has to decide whether it is converting at all.
    public struct Resolution: Sendable, Hashable, CustomStringConvertible {

        /// The rate to produce.
        public let output: FrameRate

        /// What the policy asked for, which may differ from ``output``.
        public let policyRate: FrameRate

        /// The rate being converted from.
        public let source: FrameRate

        /// Why ``output`` is not ``policyRate``, when that happens.
        public let note: String?

        /// True when source and output are the same rate, so every frame is already
        /// finished and the pipeline has nothing to do.
        public var isPassthrough: Bool { output == source }

        /// The exact upsampling ratio, reduced. `23.976 -> 59.94` is `(5, 2)`.
        public var ratio: (numerator: Int, denominator: Int) { output.ratio(to: source) }

        /// `"24000/1001 -> 60000/1001 (5/2x)"`.
        public var description: String {
            let r = ratio
            return "\(source) -> \(output) (\(r.numerator)/\(r.denominator)x)"
        }

        /// What fraction of output frames are already source pictures, computed exactly
        /// over one full alignment period rather than sampled.
        ///
        /// A passthrough is an output frame `k` with `k * pnum` a multiple of `pden`.
        /// The pattern repeats with period `pden / gcd(pnum, pden)`, so walking exactly
        /// that many output frames gives the fraction with no estimation and no
        /// dependence on how long the clip is.
        ///
        /// This is the quantity the default was chosen on, so it is worth being able to
        /// read off rather than infer: 0.2 for `23.976 -> 59.94`, 1/1001 for
        /// `23.976 -> 60.000`.
        public var passthroughFraction: Double {
            let pnum = source.numerator * output.denominator
            let pden = source.denominator * output.numerator
            let divisor = OutputRatePolicy.gcd(pnum, pden)
            let period = pden / divisor
            guard period > 0 else { return 0 }
            var free = 0
            for k in 0..<period where (k * pnum) % pden == 0 { free += 1 }
            return Double(free) / Double(period)
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}
