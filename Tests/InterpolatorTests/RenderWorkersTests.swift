import Foundation
import Testing
@testable import Interpolator

@Suite("RenderWorkers")
struct RenderWorkersTests {

    /// The measured knee, and the reason the default is what it is.
    ///
    /// A single `VTFrameProcessor` session runs its requests one at a time — measured at 4K,
    /// depths 2, 4 and 8 all give 13.4–13.5 source frames/s — so the only lever is more
    /// sessions. Past four they fight: six sessions gave 17.0 against four's 23.8. This test
    /// states the arithmetic of that curve so the number cannot drift away from its evidence.
    @Test("the optimum is four, and it is the knee rather than a guess")
    func optimumIsTheKnee() {
        // Aggregate source frames/s measured on the real 4K HDR film, one whole conversion
        // per session, 480 source frames each.
        let measured: [Int: Double] = [1: 13.4, 2: 21.5, 3: 23.5, 4: 23.8, 6: 17.0]

        let best = measured.max { $0.value < $1.value }!
        #expect(best.key == RenderWorkers.optimum,
                "the best measured session count is \(best.key), the constant is \(RenderWorkers.optimum)")

        // The speed-up the app is promising, as a ratio of the single-session rate.
        let single = measured[1]!
        #expect(abs(measured[4]! / single - 1.78) < 0.02)
        // And the point that makes "use every core" the wrong instruction.
        #expect(measured[6]! < measured[4]!,
                "six sessions are supposed to be worse than four; the curve says otherwise")
    }

    @Test("the suggestion never exceeds the optimum or falls below one")
    func suggestionIsBounded() {
        for cores in 1...64 {
            let suggested = RenderWorkers.suggested(cores: cores)
            #expect(suggested >= RenderWorkers.minimum)
            #expect(suggested <= RenderWorkers.optimum)
        }
    }

    @Test("a machine with fewer cores is suggested fewer sessions")
    func suggestionScalesWithTheMachine() {
        // Scaled down because the unit being queued behind is shared, so a smaller machine
        // reaches contention sooner. These are the three machines worth naming.
        #expect(RenderWorkers.suggested(cores: 12) == 4)   // the measured machine
        #expect(RenderWorkers.suggested(cores: 10) == 3)
        #expect(RenderWorkers.suggested(cores: 8) == 2)    // an M1
        #expect(RenderWorkers.suggested(cores: 4) == 1)    // no regression, just no speed-up
    }

    @Test("the suggestion is never smaller than one, whatever the machine reports")
    func degenerateCoreCountsAreSafe() {
        // `activeProcessorCount` is a runtime reading, and a reading of 0 would otherwise
        // produce a pipeline with no sessions at all — which is not a slow conversion, it is
        // no conversion.
        #expect(RenderWorkers.suggested(cores: 0) == 1)
        #expect(RenderWorkers.suggested(cores: -4) == 1)
    }

    @Test("zero asks the machine and anything positive is honoured exactly")
    func resolvePassesThroughAnExplicitChoice() {
        #expect(RenderWorkers.resolve(0, cores: 12) == RenderWorkers.suggested(cores: 12))
        #expect(RenderWorkers.resolve(1, cores: 12) == 1)
        #expect(RenderWorkers.resolve(4, cores: 12) == 4)
        // Above the optimum is honoured rather than clamped. The measurement says six is
        // slower than four about *this* film at *this* resolution, and someone who has
        // measured their own machine is entitled to disagree with it.
        #expect(RenderWorkers.resolve(6, cores: 12) == 6)
        #expect(RenderWorkers.resolve(16, cores: 4) == 16)
    }

    @Test("a batch request asks the machine by default")
    func batchDefaultsToAutomatic() {
        let request = BatchConverter.Request(input: URL(fileURLWithPath: "/a.mkv"),
                                             output: URL(fileURLWithPath: "/a-60fps.mkv"))
        #expect(request.workers == 0)
        #expect(RenderWorkers.resolve(request.workers) == RenderWorkers.suggested())
    }

    @Test("changing the session count does not invalidate a finished job")
    func workersAreNotPartOfTheManifestFingerprint() {
        // Deliberately absent from the fingerprint. The pool is a way of arriving at the same
        // output sooner — verified on the real film at 63.7 dB between one session and four,
        // against a 67.6 dB control for the same configuration twice — so a user who changes
        // the setting between runs must not be told their finished pieces belong to a
        // different job. Adding `workers` here would do exactly that.
        let info = MediaInfo(url: URL(fileURLWithPath: "/a.mkv"),
                             width: 1920, height: 1080, frameRate: FrameRate.parse("23.976")!,
                             frameCount: 1000, duration: 41.7,
                             pixelFormat: "nv12", format: .nv12,
                             colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
                             colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
                             audioTracks: [], chapterCount: 0)
        let one = JobManifest.Fingerprint.of(source: URL(fileURLWithPath: "/a.mkv"), info: info,
                                             outputRate: FrameRate.parse("59.94")!,
                                             bitRate: nil, depth: 2, sceneDetection: true,
                                             intervalsPerSegment: 100)
        let four = JobManifest.Fingerprint.of(source: URL(fileURLWithPath: "/a.mkv"), info: info,
                                              outputRate: FrameRate.parse("59.94")!,
                                              bitRate: nil, depth: 2, sceneDetection: true,
                                              intervalsPerSegment: 100)
        #expect(one == four)
        #expect(one.difference(from: four) == nil)
    }
}
