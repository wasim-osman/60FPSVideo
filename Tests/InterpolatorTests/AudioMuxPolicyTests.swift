import Foundation
import Testing
@testable import Interpolator

/// The audio decision, and the two facts that forced its shape.
///
/// The reference disc is the fixture throughout: stream 1 is **DTS-HD MA + DTS:X 7.1**
/// and stream 2 is an **AC-3 5.1** compatibility track. Every awkward case in this file
/// comes from those two tracks being different in every way that matters.
struct AudioMuxPolicyTests {

    // MARK: - The disc, as ffprobe reports it

    /// The reference disc's audio, exactly as measured.
    static func discTracks() -> [AudioTrack] {
        [
            AudioTrack(index: 1, codec: "dts", profile: "DTS-HD MA + DTS:X",
                       channels: 8, channelLayout: "7.1", sampleRate: 48000,
                       bitRate: nil, isDefault: true),
            AudioTrack(index: 2, codec: "ac3", profile: nil,
                       channels: 6, channelLayout: "5.1(side)", sampleRate: 48000,
                       bitRate: 384_000, isDefault: false),
        ]
    }

    static func disc() -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/dev/null"),
                  width: 3840, height: 1632,
                  frameRate: .twentyFourNTSC, frameCount: nil, duration: 6411.46,
                  pixelFormat: "yuv420p10le", format: .p010,
                  colorPrimaries: "bt2020", transferFunction: "smpte2084",
                  colorSpace: "bt2020nc", colorRange: "tv",
                  masteringDisplay: nil, contentLightLevel: nil,
                  audioTracks: discTracks(), chapterCount: 20)
    }

    static func silent() -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/dev/null"),
                  width: 1920, height: 1080, frameRate: .twentyFourNTSC,
                  frameCount: nil, duration: 60,
                  pixelFormat: "nv12", format: .nv12,
                  colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
                  colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
                  audioTracks: [], chapterCount: 0)
    }

    // MARK: - The default that matters

    @Test("MP4 keeps the 7.1 master and transcodes it, rather than copying the 5.1 track")
    func mp4KeepsTheBetterTrack() throws {
        let plan = try AudioMuxPolicy.mp4.plan(for: Self.disc())

        // The whole point of the default. Copying what *can* be copied would silently
        // drop from 7.1 to 5.1 on every conversion of this disc, and the file would
        // play perfectly — which is what makes it the wrong default.
        guard case .transcode(let track, let from, let to, let channels, let bitRate) = plan.action
        else {
            Issue.record("expected a transcode, got \(plan.action)")
            return
        }
        #expect(track == 1, "the 7.1 DTS track is the one worth keeping")
        #expect(from == "dts")
        #expect(to == "aac")
        #expect(channels == 8)
        #expect(bitRate == 640_000)

        // And it says what it passed over, so the decision can be disagreed with.
        #expect(plan.reason.contains("AC3"))
        #expect(plan.reason.contains("fewer channels"))
    }

    @Test("Matroska copies the same track bit-perfect")
    func mkvCopiesBitPerfect() throws {
        let plan = try AudioMuxPolicy.mkv.plan(for: Self.disc())

        guard case .copy(let track, let codec, let channels) = plan.action else {
            Issue.record("expected a copy, got \(plan.action)")
            return
        }
        #expect(track == 1)
        #expect(codec == "dts")
        #expect(channels == 8)
        #expect(plan.summary.contains("bit-perfect"))
    }

    @Test("the two containers want opposite answers about the same track")
    func containersDisagree() throws {
        let mp4 = try AudioMuxPolicy.mp4.plan(for: Self.disc())
        let mkv = try AudioMuxPolicy.mkv.plan(for: Self.disc())

        #expect(!mp4.action.isCopy)
        #expect(mkv.action.isCopy)
        // Same stream index both times: the *track* is not in question, only what can
        // be done with it.
        #expect(mp4.action.trackIndex == mkv.action.trackIndex)
    }

    // MARK: - Cutting

    @Test("a cut turns a copy into a transcode, and says why")
    func cuttingForcesTranscode() throws {
        let whole = try AudioMuxPolicy.mkv.plan(for: Self.disc())
        #expect(whole.action.isCopy)

        let cut = try AudioMuxPolicy.mkv.plan(for: Self.disc(), cutting: true)
        #expect(!cut.action.isCopy)
        #expect(cut.reason.contains("packet boundary"))
    }

    @Test("copy-only refuses a cut rather than quietly re-encoding")
    func copyOnlyRefusesCut() {
        let policy = AudioMuxPolicy(container: .mkv, handling: .copy)

        #expect(throws: AudioMuxError.self) {
            try policy.plan(for: Self.disc(), cutting: true)
        }
        // And the same policy is perfectly happy with a whole-film job, so the refusal
        // is about the cut and not about the policy being unusable.
        #expect(throws: Never.self) {
            try policy.plan(for: Self.disc(), cutting: false)
        }
    }

    @Test("copy-only refuses a container that cannot carry the track")
    func copyOnlyRefusesWrongContainer() {
        let policy = AudioMuxPolicy(container: .mp4, handling: .copy)
        #expect(throws: AudioMuxError.self) {
            try policy.plan(for: Self.disc())
        }
    }

    // MARK: - Silence

    @Test("a silent source needs no mux, and says so rather than failing")
    func silentSource() throws {
        let plan = try AudioMuxPolicy.mp4.plan(for: Self.silent())
        #expect(plan.isSilent)
        #expect(plan.reason.contains("no audio stream"))
    }

    @Test("dropping the audio is a decision that gets reported")
    func deliberateDrop() throws {
        let policy = AudioMuxPolicy(container: .mp4, handling: .drop)
        let plan = try policy.plan(for: Self.disc())

        #expect(plan.isSilent)
        // Silence and "nothing to do" have to read differently in a report, or a
        // forgotten mux looks exactly like a source with no sound.
        #expect(plan.reason.contains("deliberately"))
    }

    // MARK: - Choosing the track

    @Test("the track with the most channels wins, whatever it is coded in")
    func channelsBeatFidelity() {
        let ranked = AudioMuxPolicy.ranked(Self.discTracks())
        #expect(ranked.map(\.index) == [1, 2])
    }

    @Test("at equal channel counts, lossless beats lossy")
    func losslessBreaksTies() {
        let tracks = [
            AudioTrack(index: 1, codec: "ac3", channels: 6, bitRate: 640_000),
            AudioTrack(index: 2, codec: "truehd", channels: 6),
        ]
        #expect(AudioMuxPolicy.ranked(tracks).map(\.index) == [2, 1])
    }

    @Test("the container's own default track breaks a remaining tie")
    func defaultDispositionBreaksTies() {
        let tracks = [
            AudioTrack(index: 1, codec: "ac3", channels: 6),
            AudioTrack(index: 2, codec: "ac3", channels: 6, isDefault: true),
        ]
        #expect(AudioMuxPolicy.ranked(tracks).map(\.index) == [2, 1])
    }

    @Test("a lossless DTS track is not mistaken for the lossy core")
    func dtsProfileMatters() {
        // Same codec name, opposite meanings — the profile is the only thing that
        // separates a BluRay master from its lossy fallback.
        let master = AudioTrack(index: 1, codec: "dts", profile: "DTS-HD MA + DTS:X",
                                channels: 8)
        let core = AudioTrack(index: 2, codec: "dts", profile: "DTS", channels: 6)
        #expect(master.isLossless)
        #expect(!core.isLossless)

        #expect(AudioTrack(index: 3, codec: "truehd", channels: 8).isLossless)
        #expect(!AudioTrack(index: 4, codec: "ac3", channels: 6).isLossless)
        #expect(AudioTrack(index: 5, codec: "pcm_s24le", channels: 2).isLossless)
    }

    // MARK: - Bit rate

    @Test("the transcode rate follows the channel count")
    func bitRateTable() {
        #expect(AudioMuxPolicy.defaultBitRate(channels: 2) == 192_000)
        #expect(AudioMuxPolicy.defaultBitRate(channels: 6) == 448_000)
        #expect(AudioMuxPolicy.defaultBitRate(channels: 8) == 640_000)
        // Monotonic, so a wider track never gets fewer bits than a narrower one.
        let rates = (1...8).map { AudioMuxPolicy.defaultBitRate(channels: $0) }
        #expect(rates == rates.sorted())
    }

    @Test("an explicit rate overrides the derived one")
    func explicitBitRateWins() throws {
        let policy = AudioMuxPolicy(container: .mp4, bitRate: 256_000)
        guard case .transcode(_, _, _, _, let bitRate) = try policy.plan(for: Self.disc()).action
        else {
            Issue.record("expected a transcode")
            return
        }
        #expect(bitRate == 256_000)
    }

    // MARK: - Names and extensions

    @Test("policy names parse, including the handling suffix")
    func namedPolicies() {
        #expect(AudioMuxPolicy.named("mp4")?.container == .mp4)
        #expect(AudioMuxPolicy.named("mkv")?.container == .mkv)
        #expect(AudioMuxPolicy.named("MP4")?.container == .mp4)
        #expect(AudioMuxPolicy.named("mkv-copy")?.handling == .copy)
        #expect(AudioMuxPolicy.named("mp4-transcode")?.handling == .transcode)
        #expect(AudioMuxPolicy.named("mp4-drop")?.handling == .drop)
        #expect(AudioMuxPolicy.named("mkv-copy")?.container == .mkv)

        #expect(AudioMuxPolicy.named("webm") == nil)
        #expect(AudioMuxPolicy.named("mp4-nonsense") == nil)
        #expect(AudioMuxPolicy.named("") == nil)
    }

    @Test("the output's extension picks the policy, so .mkv means bit-perfect")
    func policyFromExtension() {
        #expect(AudioMuxPolicy.forOutput(URL(fileURLWithPath: "/x/f.mkv")).container == .mkv)
        #expect(AudioMuxPolicy.forOutput(URL(fileURLWithPath: "/x/f.MKV")).container == .mkv)
        #expect(AudioMuxPolicy.forOutput(URL(fileURLWithPath: "/x/f.mp4")).container == .mp4)
        // No extension at all must not be read as Matroska by accident.
        #expect(AudioMuxPolicy.forOutput(URL(fileURLWithPath: "/x/f")).container == .mp4)
    }

    // MARK: - Reporting

    @Test("no summary claims success without saying what happened")
    func summariesAreSpecific() {
        let copy = AudioMuxPolicy.Plan(
            container: .mkv,
            action: .copy(track: 1, codec: "dts", channels: 8),
            reason: "it fits")
        let transcode = AudioMuxPolicy.Plan(
            container: .mp4,
            action: .transcode(track: 1, from: "dts", to: "aac",
                               channels: 8, bitRate: 640_000),
            reason: "it does not fit")
        let none = AudioMuxPolicy.Plan(container: .mp4, action: .none,
                                       reason: "there is none")

        #expect(copy.summary.contains("DTS") && copy.summary.contains("8 ch"))
        #expect(transcode.summary.contains("DTS") && transcode.summary.contains("AAC"))
        #expect(transcode.summary.contains("640 kbps"))
        // The word that matters: a transcode is a loss, and the report says so.
        #expect(transcode.summary.contains("transcoded"))
        #expect(none.summary.contains("none"))
    }
}
