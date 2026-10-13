import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// The delivered size, and what a picture does inside it.
///
/// ## Two of these cases are not invented
///
/// They are the values measured from `VTPixelTransferSession` on this machine, read back from
/// the luma plane of a real transfer:
///
/// - **1920×816 into 3440×1440, letterbox.** The picture's first column lands at **x = 26** and
///   its last at **x = 3413**; columns 0…25 and 3414…3439 are video-range black (16). Bars of
///   exactly 26.
/// - **1920×816 into 1920×1080, letterbox.** The picture's first row is **y = 132** and its last
///   **y = 947**; rows 0…131 and 948…1079 are black. Bars of exactly 132.
///
/// So the geometry below is not a model of what the framework does — it is a description that
/// was checked against it. If these two ever disagree, the app is telling the user something the
/// framework is not doing, which is worse than telling them nothing.
@Suite("Output target")
struct OutputTargetTests {

    // MARK: - OutputSize

    @Test("an odd size is rounded down to even, because 4:2:0 has no odd chroma plane")
    func oddSizesAreRoundedDown() {
        let odd = OutputSize(width: 3441, height: 1441)
        #expect(odd.width == 3440)
        #expect(odd.height == 1440)

        let even = OutputSize(width: 3440, height: 1440)
        #expect(even.width == 3440)
        #expect(even.height == 1440)

        // The three displays on this machine, none of which is affected.
        #expect(OutputSize(width: 3440, height: 1440).label == "3440 × 1440")
        #expect(OutputSize(width: 2560, height: 1080).width == 2560)
        #expect(OutputSize(width: 1920, height: 1080).width == 1920)
    }

    @Test("a degenerate size still describes a frame the format can carry")
    func degenerateSizes() {
        #expect(OutputSize(width: 0, height: 0).width == 2)
        #expect(OutputSize(width: 1, height: 3).width == 2)
        #expect(OutputSize(width: 1, height: 3).height == 2)
        #expect(OutputSize(width: -4, height: -4).width == 2)
    }

    // MARK: - OutputTarget

    @Test("the default target is the film's own size, and asks for no scale pass")
    func sourceTargetIsFree() {
        let info = MediaInfo.film(3840, 1632, format: .p010)
        #expect(OutputTarget.source.size(for: info) == OutputSize(width: 3840, height: 1632))
        #expect(OutputTarget.source.needsScaling(from: info) == false)
        #expect(OutputTarget.source.label == "The film's own size")
    }

    @Test("a fixed target asks for a scale pass only when the size actually differs")
    func fixedTargetScalesOnlyWhenItDiffers() {
        let info = MediaInfo.film(1920, 816)
        #expect(OutputTarget.fixed(OutputSize(width: 3440, height: 1440))
            .needsScaling(from: info))
        #expect(OutputTarget.fixed(OutputSize(width: 1920, height: 816))
            .needsScaling(from: info) == false)
        // Same width, different height: still a scale.
        #expect(OutputTarget.fixed(OutputSize(width: 1920, height: 1080))
            .needsScaling(from: info))
    }

    // MARK: - Geometry, anchored to the framework

    @Test("fit into 3440x1440 pillarboxes at exactly 26, which is where the framework put it")
    func fitMatchesTheMeasuredPillarbox() {
        let g = OutputGeometry.fitting(source: OutputSize(width: 1920, height: 816),
                                       target: OutputSize(width: 3440, height: 1440),
                                       mode: .fit)
        #expect(g.scaledWidth == 3388)
        #expect(g.scaledHeight == 1440)
        #expect(g.pillarBars == 26)
        #expect(g.letterBars == 0)
        #expect(g.croppedColumns == 0)
        #expect(g.croppedRows == 0)

        // The bars and the picture have to add up to the target exactly, or one side of the
        // picture is off the screen.
        #expect(g.pillarBars + g.scaledWidth + g.pillarBars == 3440)
        // The measured boundary: picture starts at x = 26 and ends at x = 3413.
        #expect(g.pillarBars == 26)
        #expect(g.pillarBars + g.scaledWidth - 1 == 3413)
    }

    @Test("fit into 1920x1080 letterboxes at exactly 132, which is where the framework put it")
    func fitMatchesTheMeasuredLetterbox() {
        let g = OutputGeometry.fitting(source: OutputSize(width: 1920, height: 816),
                                       target: OutputSize(width: 1920, height: 1080),
                                       mode: .fit)
        #expect(g.scaledWidth == 1920)
        #expect(g.scaledHeight == 816)
        #expect(g.letterBars == 132)
        #expect(g.pillarBars == 0)
        #expect(g.letterBars + g.scaledHeight + g.letterBars == 1080)
        // The measured boundary: picture starts at y = 132 and ends at y = 947.
        #expect(g.letterBars == 132)
        #expect(g.letterBars + g.scaledHeight - 1 == 947)
    }

    @Test("fill into the same target crops rather than barring")
    func fillCropsRows() {
        let g = OutputGeometry.fitting(source: OutputSize(width: 1920, height: 816),
                                       target: OutputSize(width: 3440, height: 1440),
                                       mode: .fill)
        #expect(g.scaledWidth == 3440)
        #expect(g.scaledHeight == 1462)
        #expect(g.croppedRows == 11)
        #expect(g.pillarBars == 0)
        #expect(g.letterBars == 0)
        #expect(g.croppedColumns == 0)
        // Crop is symmetric: what is taken off the top is taken off the bottom.
        #expect(g.croppedRows + g.targetHeight + g.croppedRows == g.scaledHeight)
    }

    @Test("fill into a narrow target crops columns")
    func fillCropsColumns() {
        let g = OutputGeometry.fitting(source: OutputSize(width: 1920, height: 816),
                                       target: OutputSize(width: 1080, height: 1080),
                                       mode: .fill)
        // 1920 x (1080/816) = 2541.18, and fill rounds *up* to the next even number so the
        // picture always covers the target. 2542, not 2540 — rounding down here would leave a
        // one-pixel seam down each side.
        #expect(g.scaledWidth == 2542)
        #expect(g.scaledHeight == 1080)
        #expect(g.croppedColumns == 731)
        #expect(g.croppedRows == 0)
        #expect(g.croppedColumns + g.targetWidth + g.croppedColumns == g.scaledWidth)
    }

    @Test("a target the same shape as the film does nothing at all, in either mode")
    func sameShapeIsUntouched() {
        for mode in FitMode.allCases {
            let g = OutputGeometry.fitting(source: OutputSize(width: 3840, height: 1632),
                                           target: OutputSize(width: 1920, height: 816),
                                           mode: mode)
            #expect(g.scaledWidth == 1920)
            #expect(g.scaledHeight == 816)
            #expect(g.pillarBars == 0)
            #expect(g.letterBars == 0)
            #expect(g.croppedColumns == 0)
            #expect(g.croppedRows == 0)
            #expect(g.summary == "the whole picture, unchanged")
        }
    }

    @Test("the two promises hold across a grid of shapes")
    func fitNeverOverflowsAndFillNeverFallsShort() {
        let sources = [(1920, 816), (3840, 1632), (1280, 720), (720, 576), (1080, 1920)]
        let targets = [(3440, 1440), (2560, 1080), (1920, 1080), (1080, 1920), (640, 480)]

        for (sw, sh) in sources {
            for (tw, th) in targets {
                let source = OutputSize(width: sw, height: sh)
                let target = OutputSize(width: tw, height: th)

                // Fit: the picture is inside the target on both axes, so no bar is negative
                // and no part of the picture is off the screen.
                let fit = OutputGeometry.fitting(source: source, target: target, mode: .fit)
                #expect(fit.scaledWidth <= target.width,
                        "fit \(sw)x\(sh) -> \(tw)x\(th) overflowed in width")
                #expect(fit.scaledHeight <= target.height,
                        "fit \(sw)x\(sh) -> \(tw)x\(th) overflowed in height")

                // Fill: the picture covers the target on both axes, so no seam is left.
                let fill = OutputGeometry.fitting(source: source, target: target, mode: .fill)
                #expect(fill.scaledWidth >= target.width,
                        "fill \(sw)x\(sh) -> \(tw)x\(th) left a gap in width")
                #expect(fill.scaledHeight >= target.height,
                        "fill \(sw)x\(sh) -> \(tw)x\(th) left a gap in height")

                // And in both cases the shape is preserved to within a pixel, which is the
                // whole point of not simply stretching to the target.
                for g in [fit, fill] {
                    let sourceAspect = Double(source.width) / Double(source.height)
                    let scaledAspect = Double(g.scaledWidth) / Double(g.scaledHeight)
                    #expect(abs(sourceAspect - scaledAspect) < 0.01,
                            "\(sw)x\(sh) -> \(tw)x\(th) distorted: \(g.scaledWidth)x\(g.scaledHeight)")
                }
            }
        }
    }

    @Test("the summary says what will happen, and says nothing when nothing will")
    func summaries() {
        func summary(_ sw: Int, _ sh: Int, _ tw: Int, _ th: Int, _ mode: FitMode) -> String {
            OutputGeometry.fitting(source: OutputSize(width: sw, height: sh),
                                   target: OutputSize(width: tw, height: th),
                                   mode: mode).summary
        }
        #expect(summary(1920, 816, 3440, 1440, .fit) == "3388 wide picture, 26 px bars each side")
        #expect(summary(1920, 816, 1920, 1080, .fit) == "816 high picture, 132 px bars top and bottom")
        #expect(summary(1920, 816, 3440, 1440, .fill) == "1462 high picture, 11 px cropped top and bottom")
        #expect(summary(1920, 816, 1080, 1080, .fill) == "2542 wide picture, 731 px cropped each side")
        #expect(summary(1920, 816, 1920, 816, .fit) == "the whole picture, unchanged")
    }
}
