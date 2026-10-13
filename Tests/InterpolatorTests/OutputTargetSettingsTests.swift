import Foundation
import Testing
@testable import Interpolator
@testable import InterpolatorApp

/// The app-side half of the output-size setting: the picker's value, the settings blob, and the
/// file name.
///
/// ## Why these live here and not with the library's tests
///
/// `OutputTarget`, `OutputSize` and `OutputGeometry` are the library's, and their tests are
/// `OutputTargetTests`. What is tested here is what the *app* does with them: the picker's
/// three-state value, the persisted blob, and the name the file comes out with. Those are the
/// places a mistake is silent — a picker that cannot round-trip its own tag shows a blank row, a
/// settings blob that fails to decode resets every preference without a message, and a name that
/// ignores the size makes two conversions of one film collide.
@Suite("Output size setting")
struct OutputTargetSettingsTests {

    // MARK: - The picker's value

    /// Every tag a row can carry must come back as the same choice.
    ///
    /// This is the property that keeps the picker honest: SwiftUI matches a `Picker`'s selection
    /// against the tags of its rows, and a tag that does not survive the round trip produces a
    /// **blank row** and, on dismissal, silently rewrites the setting to whatever SwiftUI
    /// settled on. Neither is visible in a build.
    @Test("a choice's tag round-trips")
    func tagRoundTrip() throws {
        let choices: [OutputTargetChoice] = [
            .source,
            .display(69733154),
            .display(1),
            .size(OutputSize(width: 3440, height: 1440)),
            .size(OutputSize(width: 3840, height: 2160)),
            .size(OutputSize(width: 1920, height: 1080)),
        ]
        for choice in choices {
            let tag = choice.tag
            let restored = try #require(OutputTargetChoice(tag: tag),
                                        "tag \(tag) did not decode")
            #expect(restored == choice, "\(tag) came back as \(restored)")
        }
    }

    /// The tags are distinct, so no two rows collide in one `Picker`.
    @Test("no two choices share a tag")
    func tagsAreDistinct() {
        let tags = [OutputTargetChoice.source.tag,
                    OutputTargetChoice.display(1).tag,
                    OutputTargetChoice.display(2).tag,
                    OutputTargetChoice.size(OutputSize(width: 1920, height: 1080)).tag]
        #expect(Set(tags).count == tags.count, "\(tags)")
    }

    /// A tag nothing wrote is refused rather than guessed at.
    ///
    /// `nil` and not `.source`: a picker that fell back to the default on an unrecognised tag
    /// would turn a decoding mistake into a silent change of setting, which is the failure this
    /// whole type exists to make impossible.
    @Test("an unknown tag decodes to nothing")
    func unknownTagsAreRefused() {
        for tag in ["", "source:", "display:", "display:notanumber", "size:1920",
                    "size:a x b", "nonsense", "size:1920x", "size:1920x1080x2160"] {
            #expect(OutputTargetChoice(tag: tag) == nil, "\(tag) should not decode")
        }
    }

    /// The size that goes in is the size that comes out, whatever the machine is attached to.
    ///
    /// Machine-independent on purpose. `resolve` maps a stored size onto a connected display
    /// when one matches and leaves it alone when none does — two different answers on two
    /// different desks — but both must resolve *back* to the size that was stored. That is the
    /// property the setting depends on, and it is the one thing here that can be asserted
    /// without knowing what is plugged in.
    @Test("a stored size resolves back to itself")
    @MainActor
    func resolveRoundTrips() {
        for size in [OutputSize(width: 1920, height: 1080),
                     OutputSize(width: 3440, height: 1440),
                     OutputSize(width: 3840, height: 2160),
                     OutputSize(width: 3024, height: 1964)] {
            let choice = OutputTargetChoice.resolve(from: size)
            let back = String(describing: choice.target)
            #expect(choice.target == size, "\(size.label) resolved to \(choice) and back to \(back)")
        }
    }

    /// No stored size is the film's own size, and it stays that way.
    @Test("no size resolves to the film's own")
    @MainActor
    func nilResolvesToSource() {
        #expect(OutputTargetChoice.resolve(from: nil) == .source)
        #expect(OutputTargetChoice.resolve(from: nil).target == nil)
    }

    // MARK: - The settings blob

    /// A blob written before the delivered size existed must not reset the rest of the settings.
    ///
    /// **This is invariant 55's failure, and it was silent and total.** A new non-optional
    /// property, a stored blob that predates it, a throwing decode, and `load` returns the
    /// defaults — so upgrading reset the volume, the playback speed, the output folder, the
    /// worker count, the container and everything else, with no message. Three fields were added
    /// to this blob for the delivered size, so the case is tested rather than assumed.
    @Test("a blob from before the delivered size keeps every other setting")
    func legacyBlobSurvives() throws {
        let legacy = """
        {
          "policyLabel": "59.94",
          "playbackResolution": "source",
          "conversionQuality": "fast",
          "depth": 4,
          "workers": 6,
          "sceneDetection": false,
          "container": "mkv",
          "keepSegments": true,
          "overwrite": true,
          "previewSeconds": 90,
          "outputDirectory": "/tmp/elsewhere",
          "useSound": false,
          "volume": 0.25,
          "playbackSpeed": 1.5
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        // The fields that predate the change are exactly as stored.
        #expect(decoded.playbackResolution == .source)
        #expect(decoded.conversionQuality == .fast)
        #expect(decoded.depth == 4)
        #expect(decoded.workers == 6)
        #expect(decoded.sceneDetection == false)
        #expect(decoded.container == "mkv")
        #expect(decoded.keepSegments == true)
        #expect(decoded.overwrite == true)
        #expect(decoded.previewSeconds == 90)
        #expect(decoded.outputDirectory == "/tmp/elsewhere")
        #expect(decoded.useSound == false)
        #expect(decoded.volume == 0.25)
        #expect(decoded.playbackSpeed == 1.5)

        // And the new ones fall back to the defaults rather than taking the blob down with them.
        #expect(decoded.batchOutputSize == nil)
        #expect(decoded.batchFitMode == .fit)
        #expect(decoded.playbackFitMode == .fit)
    }

    /// The new fields survive a round trip, including the `nil` that means "the film's own size".
    @Test("the delivered size round-trips through the blob")
    func deliveredSizeRoundTrips() throws {
        var settings = AppSettings()
        settings.batchOutputSize = OutputSize(width: 3440, height: 1440)
        settings.batchFitMode = .fill
        settings.playbackFitMode = .fill

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.batchOutputSize == OutputSize(width: 3440, height: 1440))
        #expect(decoded.batchFitMode == .fill)
        #expect(decoded.playbackFitMode == .fill)

        // And back to none, because `nil` is a value here and not an absence.
        settings.batchOutputSize = nil
        let cleared = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(settings))
        #expect(cleared.batchOutputSize == nil)
    }

    /// An explicit `null` reads as the default, not as a decoding failure.
    ///
    /// `decodeIfPresent` collapses "key absent" and "key present but null" onto the same answer,
    /// which is what is wanted here: both mean the film's own size.
    @Test("an explicit null reads as no target")
    func explicitNullIsNoTarget() throws {
        let blob = #"{"batchOutputSize": null, "batchFitMode": "fill"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(blob.utf8))
        #expect(decoded.batchOutputSize == nil)
        #expect(decoded.batchFitMode == .fill)
    }

    // MARK: - What the setting becomes

    /// The setting maps onto the library's target type, and only there.
    @Test("the setting becomes an output target")
    func settingBecomesTarget() {
        var settings = AppSettings()
        #expect(settings.batchOutputTarget == .source)
        #expect(settings.batchOutputTarget.needsScaling(
            from: MediaInfo.film(1920, 816)) == false)

        settings.batchOutputSize = OutputSize(width: 3440, height: 1440)
        #expect(settings.batchOutputTarget == .fixed(OutputSize(width: 3440, height: 1440)))
        #expect(settings.batchOutputTarget.needsScaling(
            from: MediaInfo.film(1920, 816)) == true)
    }

    // MARK: - The file name

    /// The delivered size is in the name, so two sizes of one film are two files.
    ///
    /// Without it both conversions resolve to the same path, `overwrite` is off, and the second
    /// job stops with "an output already exists" — which is a correct refusal and a confusing
    /// one, because the user's intent ("give me this film at my screen's size as well") is
    /// perfectly reasonable.
    @Test("the delivered size is in the file name")
    func outputNameCarriesTheSize() {
        let input = URL(fileURLWithPath: "/films/Film.mkv")

        var settings = AppSettings()
        #expect(settings.outputURL(for: input).lastPathComponent == "Film-60fps.mp4")

        settings.batchOutputSize = OutputSize(width: 3440, height: 1440)
        #expect(settings.outputURL(for: input).lastPathComponent == "Film-60fps-3440x1440.mp4")

        // And the two are different files, which is the whole point.
        settings.batchOutputSize = nil
        let plain = settings.outputURL(for: input)
        settings.batchOutputSize = OutputSize(width: 1920, height: 1080)
        let sized = settings.outputURL(for: input)
        #expect(plain != sized)
    }

    /// The extension still follows the container, size or no size.
    @Test("the container still decides the extension")
    func extensionFollowsContainer() {
        let input = URL(fileURLWithPath: "/films/Film.mkv")
        var settings = AppSettings()
        settings.container = AudioMuxPolicy.Container.mkv.rawValue
        settings.batchOutputSize = OutputSize(width: 3840, height: 2160)
        #expect(settings.outputURL(for: input).lastPathComponent == "Film-60fps-3840x2160.mkv")
    }

    // MARK: - What the queue says

    /// The footer states both sizes, because either one alone is ambiguous about a four-hour job.
    @Test("the footer names the size and the mode")
    func footerLabel() {
        var settings = AppSettings()
        #expect(settings.batchOutputLabel.contains("own size"))

        settings.batchOutputSize = OutputSize(width: 3440, height: 1440)
        #expect(settings.batchOutputLabel.contains("3440 × 1440"))
        #expect(settings.batchOutputLabel.contains("fit"))

        settings.batchFitMode = .fill
        #expect(settings.batchOutputLabel.contains("fill"))
    }
}
