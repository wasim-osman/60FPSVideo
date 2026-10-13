import Foundation
import Testing
@testable import Interpolator

/// How wide an interpolation may be, and how the answer is arrived at.
///
/// The cases that matter are the ones where the *obvious* rule gives a plausible wrong answer:
/// a ladder walked narrowest-first (which throws away resolution the machine can afford), a
/// budget that ignores the film's own rate, and a calibration that reports a width it never
/// measured.
struct InterpolationResolutionTests {

    /// A film description with nothing but a geometry and, optionally, a colour description.
    ///
    /// Built here rather than shared with `BatchConverterTests`' fixture because these tests care
    /// about exactly two fields and a shared fixture would invite them to care about more.
    static func info(width: Int, height: Int,
                     transferFunction: String? = nil,
                     colorPrimaries: String? = nil) -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/dev/null"),
                  width: width, height: height, frameRate: .twentyFourNTSC,
                  frameCount: 100, duration: 4,
                  pixelFormat: "nv12", format: .nv12,
                  colorPrimaries: colorPrimaries, transferFunction: transferFunction,
                  colorSpace: nil, colorRange: nil,
                  masteringDisplay: nil, contentLightLevel: nil,
                  audioTracks: [], chapterCount: 0)
    }

    // MARK: - The budget

    /// One interval of film time, in milliseconds, at the reference rate.
    ///
    /// 24000/1001 is 23.976, so an interval is 1/23.976 s = 41.708… ms. Every figure in §29 is
    /// expressed against this number, so it is worth pinning rather than deriving twice.
    @Test func theBudgetIsOneIntervalOfFilmTime() {
        #expect(abs(InterpolationWidth.budget(sourceRate: .twentyFourNTSC) - 41.7083) < 0.001)
        #expect(abs(InterpolationWidth.budget(sourceRate: .twentyFour) - 41.6667) < 0.001)
        #expect(abs(InterpolationWidth.budget(sourceRate: .sixty) - 16.6667) < 0.001)
    }

    // MARK: - The ladder

    /// The source's own width is always the first rung.
    ///
    /// This is what stops the policy downscaling a film the machine can already handle: a 1080p
    /// source must be probed at 1920 and pass, not skipped straight to 960.
    ///
    /// One rung per measured cost tread — 1600 and 1280 are deliberately absent because they cost
    /// the same as 1920 (invariant 54), and a ladder carrying them spends its probe budget walking
    /// rungs that cannot change the answer.
    @Test func theSourceWidthIsTheFirstRung() {
        #expect(InterpolationWidth.candidates(sourceWidth: 3840) == [3840, 2560, 1920, 960])
        #expect(InterpolationWidth.candidates(sourceWidth: 1920) == [1920, 960])
        #expect(InterpolationWidth.candidates(sourceWidth: 1280) == [1280, 960])
    }

    /// A source narrower than every rung has exactly one candidate, itself.
    @Test func aNarrowSourceHasOnlyItself() {
        #expect(InterpolationWidth.candidates(sourceWidth: 720) == [720])
    }

    /// Rungs are strictly below the source's width — never equal to it, or the same size would
    /// be probed twice.
    @Test func rungsNeverRepeatTheSourceWidth() {
        for width in [960, 1280, 1600, 1920, 2560, 3840] {
            let candidates = InterpolationWidth.candidates(sourceWidth: width)
            #expect(candidates.first == width)
            #expect(Set(candidates).count == candidates.count)
            #expect(candidates.allSatisfy { $0 <= width })
        }
    }

    // MARK: - Giving ground

    /// The next rung down — what the rate watchdog gives up when the picture is short.
    @Test func theNextRungDownIsTheLaddersNeighbour() {
        #expect(InterpolationWidth.narrower(than: 3840, sourceWidth: 3840) == 2560)
        #expect(InterpolationWidth.narrower(than: 2560, sourceWidth: 3840) == 1920)
        #expect(InterpolationWidth.narrower(than: 1920, sourceWidth: 3840) == 960)
    }

    /// A 1080p source steps to 960 rather than skipping to a rung it does not have.
    @Test func aNarrowSourceStepsToItsOnlyRung() {
        #expect(InterpolationWidth.narrower(than: 1920, sourceWidth: 1920) == 960)
    }

    /// The narrowest rung has nothing below it, and says so rather than guessing at a neighbour.
    ///
    /// A player that kept narrowing past the last rung would rebuild a session every second and a
    /// half forever, which is worse than a picture that is honestly short of the rate.
    @Test func theNarrowestRungHasNothingBelowIt() {
        #expect(InterpolationWidth.narrower(than: 960, sourceWidth: 3840) == nil)
        #expect(InterpolationWidth.narrower(than: 720, sourceWidth: 720) == nil)
    }

    /// A width that is **not on the ladder** is not stepped from.
    ///
    /// The rungs are absolute widths on a curve that *steps*, so "80% of the current width" is not
    /// a rung and may well cost exactly what the rung above it costs. Returning a neighbour anyway
    /// would turn a measurement into a guess, and this function exists to replace a guess with a
    /// measurement.
    @Test func aWidthOffTheLadderIsNotSteppedFrom() {
        #expect(InterpolationWidth.narrower(than: 1600, sourceWidth: 3840) == nil)
        #expect(InterpolationWidth.narrower(than: 2048, sourceWidth: 3840) == nil)
    }

    // MARK: - Scaling

    /// The reference film's geometry, which every measurement was taken at.
    @Test func theReferenceFilmHalvesExactly() {
        let info = Self.info(width: 3840, height: 1632)
        let scaled = InterpolationWidth.scaled(info, toWidth: 1920)
        #expect(scaled.width == 1920)
        #expect(scaled.height == 816)
    }

    /// A 16:9 4K source has an **even** height when halved, and a source that would not is
    /// forced even anyway.
    ///
    /// 4:2:0 chroma is subsampled by two in both directions, so an odd height is not a slightly
    /// wrong picture — it is a frame the pixel format cannot describe, and the failure arrives
    /// far away as a buffer that will not allocate.
    @Test func heightIsAlwaysEven() {
        let sixteenNine = Self.info(width: 3840, height: 2160)
        #expect(InterpolationWidth.scaled(sixteenNine, toWidth: 1920).height == 1080)

        // 1633 halves to 816.5, which rounds to 817 and must come back as 816.
        let odd = Self.info(width: 3840, height: 1633)
        let scaled = InterpolationWidth.scaled(odd, toWidth: 1920)
        #expect(scaled.height % 2 == 0)
        #expect(scaled.height == 816)
    }

    /// A width at or above the source's is returned untouched. Upscaling to interpolate would be
    /// work spent to lose information.
    @Test func aWidthAtOrAboveTheSourceIsNotApplied() {
        let info = Self.info(width: 1920, height: 816)
        #expect(InterpolationWidth.scaled(info, toWidth: 1920).width == 1920)
        #expect(InterpolationWidth.scaled(info, toWidth: 3840).width == 1920)
    }

    /// Scaling does not disturb the colour description. A 10-bit HDR frame that acquires an SDR
    /// description because it was resized is invariant 16's failure arrived at from a new angle.
    @Test func scalingKeepsTheColourDescription() {
        let hdr = Self.info(width: 3840, height: 1632,
                            transferFunction: "smpte2084", colorPrimaries: "bt2020")
        let scaled = InterpolationWidth.scaled(hdr, toWidth: 1920)
        #expect(scaled.transferFunction == "smpte2084")
        #expect(scaled.colorPrimaries == "bt2020")
        #expect(scaled.format == hdr.format)
    }

    // MARK: - Conversion width

    /// Quality keeps the source's resolution; Fast reduces to 1080p — but never *up* to it.
    @Test func conversionWidthFollowsTheQualitySetting() {
        #expect(InterpolationWidth.conversionWidth(.quality, sourceWidth: 3840) == 3840)
        #expect(InterpolationWidth.conversionWidth(.fast, sourceWidth: 3840) == 1920)

        // A source already at or below 1080p is left alone: Fast must not be slower than Quality
        // on material that is already small.
        #expect(InterpolationWidth.conversionWidth(.fast, sourceWidth: 1280) == 1280)
        #expect(InterpolationWidth.conversionWidth(.fast, sourceWidth: 1920) == 1920)
    }

    // MARK: - The calibration decision

    private let budget = 41.7083
    private let margin = 0.9
    private let ladder = [3840, 2560, 1920, 960]

    /// The measured shape of this machine, as a closure: wide rungs miss, 1920 and below fit.
    ///
    /// The numbers are the real 30-interval figures from the reference film, so the decision the
    /// test asserts is the decision the app makes on it. They are also the *corrected* figures:
    /// the same rungs timed over 8 intervals report 1920 at 43–46 ms and push the answer down to
    /// 960, which is invariant 54's subject.
    private func measured(_ width: Int) -> Double? {
        switch width {
        case 3840: 82.28
        case 2560: 79.02
        case 1920: 36.53
        case 960: 27.49
        default: nil
        }
    }

    /// The whole point: the ladder is walked **widest first** and stops at the first rung that
    /// fits. On this machine, for this film, that is 1920 — the answer §29 measured and the one
    /// §30's corrected calibration reaches.
    @Test func itTakesTheWidestRungThatFits() {
        let choice = PlaybackCalibrator.choose(candidates: ladder, budget: budget,
                                               margin: margin, measure: measured)
        #expect(choice.width == 1920)
        #expect(choice.millisecondsPerInterval == 36.53)
        #expect(choice.fellBack == false)
        // 3840 and 2560 were probed and rejected, then 1920 was accepted.
        #expect(choice.probes == 3)
    }

    /// A machine that can afford the source's own width is not downscaled at all.
    @Test func aFastMachineKeepsTheSourceResolution() {
        let choice = PlaybackCalibrator.choose(candidates: ladder, budget: budget,
                                               margin: margin) { _ in 20.0 }
        #expect(choice.width == 3840)
        #expect(choice.probes == 1)
        #expect(choice.fellBack == false)
    }

    /// The margin is real: a width that *technically* fits the budget but leaves nothing for
    /// decoding and presenting is rejected.
    ///
    /// 1920×1080 measures 40.73 ms against a 41.708 ms budget — it fits on paper and not with
    /// anything to spare, so a machine that reports it is asked for the next rung down instead.
    @Test func aWidthThatOnlyJustFitsIsRejected() {
        let choice = PlaybackCalibrator.choose(candidates: [1920, 1600], budget: budget,
                                               margin: margin) { width in
            width == 1920 ? 40.73 : 28.0
        }
        #expect(choice.width == 1600)
        #expect(choice.fellBack == false)
    }

    /// Without the margin the same measurement would be accepted — the guard is the margin and
    /// not something else.
    @Test func theMarginIsWhatRejectsIt() {
        let choice = PlaybackCalibrator.choose(candidates: [1920, 1600], budget: budget,
                                               margin: 1.0) { width in
            width == 1920 ? 40.73 : 28.0
        }
        #expect(choice.width == 1920)
    }

    /// A rung that cannot be measured is skipped, not guessed at.
    @Test func anUnmeasurableRungIsSkipped() {
        let choice = PlaybackCalibrator.choose(candidates: ladder, budget: budget,
                                               margin: margin) { width in
            width >= 2560 ? nil : measured(width)
        }
        #expect(choice.width == 1920)
        #expect(choice.fellBack == false)
    }

    /// When nothing fits, the **fastest rung the walk actually measured** is taken, and
    /// `fellBack` says so.
    ///
    /// Not the narrowest rung on the list. That is a guess about a width no probe reached, and
    /// guessing it is how a 4K film came to be interpolated at 960×408 while the rung that would
    /// have held its rate sat measured and rejected on the floor (invariant 54).
    @Test func nothingFittingTakesTheFastestMeasuredAndSaysSo() {
        let choice = PlaybackCalibrator.choose(candidates: ladder, budget: budget,
                                               margin: margin) { width in
            width == 2560 ? 60.0 : 80.0
        }
        #expect(choice.width == 2560)
        #expect(choice.millisecondsPerInterval == 60.0)
        #expect(choice.fellBack == true)
    }

    /// A rung that was never measured is never returned, even as a fallback — and when every
    /// measured rung is equally slow the **widest** measured one wins, because going narrower has
    /// been measured to buy nothing.
    @Test func anUnmeasuredRungIsNeverGuessedAt() {
        let choice = PlaybackCalibrator.choose(candidates: ladder, budget: budget,
                                               margin: margin, maximumProbes: 2) { _ in 500.0 }
        #expect(choice.width == 3840)
        #expect(choice.probes == 2)
        #expect(choice.fellBack == true)
    }

    /// The probe budget is respected, so a calibration cannot run for a minute on a film where
    /// every rung is slow.
    @Test func probesAreCapped() {
        var probed: [Int] = []
        let choice = PlaybackCalibrator.choose(candidates: ladder, budget: budget,
                                               margin: margin, maximumProbes: 2) { width in
            probed.append(width)
            return 500.0
        }
        #expect(probed == [3840, 2560])
        #expect(choice.probes == 2)
    }

    /// A calibration that finds a fit early does not keep probing — this is the difference
    /// between a two-second start-up and a six-second one.
    @Test func itStopsProbingOnceItHasAnAnswer() {
        var probed: [Int] = []
        _ = PlaybackCalibrator.choose(candidates: ladder, budget: budget, margin: margin) { width in
            probed.append(width)
            return measured(width)
        }
        #expect(probed == [3840, 2560, 1920])
    }
}
