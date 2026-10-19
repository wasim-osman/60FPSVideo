import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import Interpolator

/// `FlowSupply` is the instrument §38 used to price the engine's motion estimation, and it is
/// dangerous in one direction: `.constant` replaces the interpolated frames with a **cross-fade**.
/// Nothing about that failure is visible in a stopwatch — it is *faster*, which is exactly what a
/// speed measurement wants to see — so the only thing standing between a measurement flag and a
/// shipping cross-fade is the default.
///
/// These tests guard the two seams that decide it, and they are deliberately not a picture test.
/// Comparing the picture is how §38 *proved* the flag is consumed (39.59 dB against a 55.75 dB
/// run-to-run floor), but that needs a film, a GPU and a stopwatch. At this level the question is
/// narrower and exact: does the flag reach the framework, and is the default still off?
@Suite("Engine flow supply")
struct EngineFlowSupplyTests {

    private func engine(
        _ supply: FlowSupply?
    ) -> VTFrameProcessorEngine {
        let source = FrameRate.parse("24")!
        let output = FrameRate.parse("60")!
        if let supply {
            return VTFrameProcessorEngine(source: source, output: output, depth: 2,
                                          flowSupply: supply)
        }
        return VTFrameProcessorEngine(source: source, output: output, depth: 2)
    }

    @Test("the shipping default lets the engine estimate its own motion")
    func defaultIsEngineEstimatedFlow() throws {
        // §38's numbers are all measured against this arm. If the default drifted to `.constant`,
        // every conversion and every playback session in the app would emit a cross-fade, and the
        // only symptom would be that it got faster.
        let configuration = try #require(engine(nil).makeConfiguration(width: 1920, height: 816))
        #expect(engine(nil).flowSupply == .engine,
                "the default flow supply is no longer .engine — the shipping setting changed")
        #expect(configuration.usePrecomputedFlow == false,
                "the shipping configuration asks the framework for precomputed flow")
    }

    @Test("the flag reaches the framework's own configuration, not just the initialiser")
    func supplyReachesTheConfiguration() throws {
        // The failure this guards is specific and silent: `makeConfiguration` building its
        // `VTFrameRateConversionConfiguration` with a literal `false` instead of reading
        // `flowSupply`. `--precomputed-flow` would then time the estimator it was asked to remove
        // and report ~0% — which reads as "estimation is free", the opposite of §38's finding.
        for supply in [FlowSupply.engine, .constant] {
            let configuration = try #require(engine(supply).makeConfiguration(width: 1920,
                                                                              height: 816),
                                             "the framework refused a configuration it used to accept")
            #expect(configuration.usePrecomputedFlow == (supply == .constant),
                    "the engine built a configuration for a flow supply it was not asked for")
        }
    }

    @Test("the zero field is accepted at the sizes §38 measured")
    func zeroFlowIsAcceptedAtMeasuredSizes() throws {
        // `VTFrameProcessorOpticalFlow` returns `nil` for buffers that are not IOSurface-backed or
        // whose geometry the framework will not take, and it says nothing about why. The geometry
        // here is not guesswork: `interp-harness --processors` read it out of
        // `VTOpticalFlowConfiguration.destinationPixelBufferAttributes`, which gives
        // `width = max(240, frameWidth / 8)` and `height = width * 9 / 16` — a grid that is always
        // 16:9 with a 240-wide floor, whatever the film's aspect ratio.
        //
        // Both sizes matter: 1920×816 is the rung the player actually uses, and 3840×1632 is where
        // the flag's answer was decisive.
        for (width, height) in [(1920, 816), (3840, 1632)] {
            #expect(VTFrameProcessorEngine.makeConstantFlow(width: width, height: height) != nil,
                    "the framework refused an all-zero flow field at \(width)x\(height)")
        }
    }
}
