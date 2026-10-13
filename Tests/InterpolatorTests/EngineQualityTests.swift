import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import Interpolator

/// The interpolator's own quality tier — the framework's `.normal` / `.quality` — is a *measured*
/// decision, and §37's conclusion rests on two facts nothing else checks: that the shipping
/// default is the faster tier, and that the parameter actually reaches the framework.
///
/// ## What these tests deliberately do **not** do
///
/// They do not compare interpolated frames between the two tiers, and that is a finding rather
/// than an omission. Two runs of the *same* tier on the real film differ on **84.4%** of output
/// frames by a mean of **58.98 dB** — VideoToolbox is not reproducible run to run (invariant 18).
/// The tier comparison differs on 79.3% of frames by 58.67 dB, which is *less* than the control.
/// So an encoded-output A/B cannot resolve the tier's picture effect at all: it sits below the
/// engine's own reproducibility floor, and any test built on it would be measuring noise.
///
/// A synthetic frame pair does not rescue it either. Probing both tiers at 128, 256, 512, 1024,
/// 1920 and 2560 wide on generated content gave identical output at 128, 1024, 1920 and 2560 and
/// differing output at 256 and 512 — non-monotonic in size, and a different answer from real film.
/// A test that asserted "the tiers differ" would therefore be asserting something about *content*
/// and *frame size*, not about the tier.
///
/// What is left is the seam that actually carries the decision, and it is cheap and exact.
@Suite("Engine quality tier")
struct EngineQualityTests {

    private func engine(
        _ tier: VTFrameRateConversionConfiguration.QualityPrioritization?
    ) -> VTFrameProcessorEngine {
        let source = FrameRate.parse("24")!
        let output = FrameRate.parse("60")!
        if let tier {
            return VTFrameProcessorEngine(source: source, output: output, depth: 2,
                                          qualityPrioritization: tier)
        }
        return VTFrameProcessorEngine(source: source, output: output, depth: 2)
    }

    @Test("the shipping default is the framework's faster tier")
    func defaultIsTheFastTier() {
        // §37's answer to "is there a cheaper drawing mode?" is "we are already on it". That
        // sentence is only true while this holds, and a default that drifted to `.quality`
        // would make every conversion in the app slower while every measurement in `reports/`
        // still described the old behaviour.
        #expect(engine(nil).qualityPrioritization == .normal,
                "the default model tier is no longer .normal — the shipping setting changed")
    }

    @Test("the tier reaches the framework's own configuration, not just the initialiser")
    func tierReachesTheConfiguration() throws {
        // The failure this guards is specific and silent: `prepare` building its
        // `VTFrameRateConversionConfiguration` with a literal `.normal` instead of the stored
        // tier. `--model-quality quality` would then measure the shipping setting and report it
        // as the cost of `.quality` — and every number in §37 would look perfectly plausible.
        for tier in [VTFrameRateConversionConfiguration.QualityPrioritization.normal, .quality] {
            let configuration = try #require(engine(tier).makeConfiguration(width: 1920, height: 1088),
                                             "the framework refused a configuration it used to accept")
            #expect(configuration.qualityPrioritization == tier,
                    "the engine built a configuration for a tier it was not asked for")
        }
    }

    @Test("omitting the argument is the .normal tier, not merely a tier named like it")
    func defaultMatchesExplicitNormal() throws {
        let omitted = try #require(engine(nil).makeConfiguration(width: 1920, height: 1088))
        let explicit = try #require(engine(.normal).makeConfiguration(width: 1920, height: 1088))
        #expect(omitted.qualityPrioritization == explicit.qualityPrioritization)
        // And the two configurations are otherwise the same object for object, so "the default
        // is .normal" is not hiding a second difference elsewhere in the initialiser.
        #expect(omitted.frameWidth == explicit.frameWidth)
        #expect(omitted.frameHeight == explicit.frameHeight)
        #expect(omitted.usePrecomputedFlow == explicit.usePrecomputedFlow)
        #expect(omitted.revision == explicit.revision)
    }
}
