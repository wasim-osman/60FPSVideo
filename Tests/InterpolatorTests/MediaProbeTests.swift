import Foundation
import Testing
@testable import Interpolator

@Suite("MediaProbe")
struct MediaProbeTests {

    // MARK: - Format negotiation

    @Test("the pipeline format follows the source depth")
    func negotiatesFormat() {
        // 10-bit and deeper go to P010.
        #expect(MediaProbe.negotiateFormat("yuv420p10le") == .p010)
        #expect(MediaProbe.negotiateFormat("yuv420p10be") == .p010)
        #expect(MediaProbe.negotiateFormat("p010le") == .p010)
        #expect(MediaProbe.negotiateFormat("p016le") == .p010)
        // 8-bit goes to NV12.
        #expect(MediaProbe.negotiateFormat("yuv420p") == .nv12)
        #expect(MediaProbe.negotiateFormat("nv12") == .nv12)
        #expect(MediaProbe.negotiateFormat("yuvj420p") == .nv12)
        // A format we do not recognise must not be mistaken for 10-bit: reading an
        // 8-bit plane as 16-bit words is worse than the reverse, because every
        // sample becomes two half-samples and the picture turns to noise.
        #expect(MediaProbe.negotiateFormat("") == .nv12)
        #expect(MediaProbe.negotiateFormat("rgb24") == .nv12)
    }

    // MARK: - HDR10 metadata payloads

    @Test("the mastering display payload is the disc's own bytes")
    func masteringPayload() {
        // The reference disc's values, verbatim from its SEI.
        let display = MasteringDisplay(
            redX: 34000, redY: 16000,
            greenX: 13250, greenY: 34500,
            blueX: 7500, blueY: 3000,
            whiteX: 15635, whiteY: 16450,
            minLuminance: 50, maxLuminance: 10_000_000)

        // 24 bytes, big-endian, in the spec's order: green, blue, red, white point,
        // then max luminance and min luminance.
        let expected: [UInt8] = [
            0x33, 0xC2, 0x86, 0xC4,      // green  13250, 34500
            0x1D, 0x4C, 0x0B, 0xB8,      // blue    7500,  3000
            0x84, 0xD0, 0x3E, 0x80,      // red    34000, 16000
            0x3D, 0x13, 0x40, 0x42,      // white  15635, 16450
            0x00, 0x98, 0x96, 0x80,      // max 10000000 = 1000 nits
            0x00, 0x00, 0x00, 0x32,      // min 50 = 0.005 nits
        ]
        #expect(Array(display.seiPayload) == expected)
        #expect(display.seiPayload.count == 24)
    }

    @Test("the primaries are ordered green, blue, red — not RGB")
    func primariesOrder() {
        // Same three primaries, two orders. If the payload were written RGB the two
        // would be identical, so this fails loudly rather than producing a picture
        // with the primaries rotated — which looks plausible and is wrong.
        let gbr = MasteringDisplay(redX: 1, redY: 2, greenX: 3, greenY: 4,
                                   blueX: 5, blueY: 6, whiteX: 7, whiteY: 8,
                                   minLuminance: 0, maxLuminance: 0)
        let bytes = Array(gbr.seiPayload)
        #expect(Array(bytes[0..<4]) == [0x00, 0x03, 0x00, 0x04], "green must come first")
        #expect(Array(bytes[4..<8]) == [0x00, 0x05, 0x00, 0x06], "then blue")
        #expect(Array(bytes[8..<12]) == [0x00, 0x01, 0x00, 0x02], "then red")
    }

    @Test("luminance is in 0.0001 cd/m2, not nits")
    func luminanceUnits() {
        // 1000 nits must be 10,000,000 — writing 1000 produces a display that claims
        // to peak at 0.1 nits, which decoders accept without complaint.
        let display = MasteringDisplay(redX: 0, redY: 0, greenX: 0, greenY: 0,
                                       blueX: 0, blueY: 0, whiteX: 0, whiteY: 0,
                                       minLuminance: 50, maxLuminance: 10_000_000)
        #expect(display.maxNits == 1000.0)
        #expect(display.minNits == 0.005)
        let bytes = Array(display.seiPayload)
        #expect(Array(bytes[16..<20]) == [0x00, 0x98, 0x96, 0x80])
    }

    @Test("the content light level payload is four bytes, MaxCLL then MaxFALL")
    func lightLevelPayload() {
        let level = ContentLightLevel(maxContent: 1000, maxAverage: 221)
        #expect(Array(level.seiPayload) == [0x03, 0xE8, 0x00, 0xDD])
        #expect(level.seiPayload.count == 4)
    }

    // MARK: - Parsing

    @Test("ffprobe's rationals are parsed, not approximated")
    func parsesRationals() {
        let display = MediaProbe.parseMastering([
            "red_x": "34000/50000", "red_y": "16000/50000",
            "green_x": "13250/50000", "green_y": "34500/50000",
            "blue_x": "7500/50000", "blue_y": "3000/50000",
            "white_point_x": "15635/50000", "white_point_y": "16450/50000",
            "min_luminance": "50/10000", "max_luminance": "10000000/10000",
        ])
        #expect(display == MasteringDisplay(
            redX: 34000, redY: 16000, greenX: 13250, greenY: 34500,
            blueX: 7500, blueY: 3000, whiteX: 15635, whiteY: 16450,
            minLuminance: 50, maxLuminance: 10_000_000))
    }

    @Test("a malformed mastering display is refused, not zeroed")
    func refusesMalformedMastering() {
        // A zeroed mastering display is a *valid* payload — it claims the content is
        // black — so silently substituting one would be worse than failing.
        #expect(MediaProbe.parseMastering(["red_x": "34000/50000"]) == nil)
        #expect(MediaProbe.parseMastering([:]) == nil)
        #expect(MediaProbe.parseMastering([
            "red_x": "not a number", "red_y": "16000/50000",
            "green_x": "13250/50000", "green_y": "34500/50000",
            "blue_x": "7500/50000", "blue_y": "3000/50000",
            "white_point_x": "15635/50000", "white_point_y": "16450/50000",
            "min_luminance": "50/10000", "max_luminance": "10000000/10000",
        ]) == nil)
        // A zero denominator must not divide by zero.
        #expect(MediaProbe.parseMastering([
            "red_x": "34000/0", "red_y": "16000/50000",
            "green_x": "13250/50000", "green_y": "34500/50000",
            "blue_x": "7500/50000", "blue_y": "3000/50000",
            "white_point_x": "15635/50000", "white_point_y": "16450/50000",
            "min_luminance": "50/10000", "max_luminance": "10000000/10000",
        ]) == nil)
    }

    @Test("the exact frame rate survives the probe")
    func exactRate() throws {
        // The whole point of going through ffprobe: this must come back as the exact
        // rational, not 23.976 and not 23.975872.
        let json = """
        {"streams":[{"width":3840,"height":1632,"pix_fmt":"yuv420p10le",
          "r_frame_rate":"24000/1001","avg_frame_rate":"24000/1001",
          "color_primaries":"bt2020","color_transfer":"smpte2084",
          "color_space":"bt2020nc","color_range":"tv","duration":"6411.0"}]}
        """.data(using: .utf8)!
        let info = try MediaProbe.parse(json, url: URL(fileURLWithPath: "/tmp/x.mkv"))
        #expect(info.frameRate == FrameRate(numerator: 24000, denominator: 1001))
        #expect(info.frameRate.description == "24000/1001")
        #expect(info.format == .p010)
        #expect(info.isHDR, "smpte2084 is an HDR transfer function")
        #expect(info.width == 3840 && info.height == 1632)
    }

    @Test("SDR is recognised as SDR")
    func sdrIsNotHDR() throws {
        let json = """
        {"streams":[{"width":1920,"height":1080,"pix_fmt":"yuv420p",
          "r_frame_rate":"25/1","color_transfer":"bt709"}]}
        """.data(using: .utf8)!
        let info = try MediaProbe.parse(json, url: URL(fileURLWithPath: "/tmp/x.mp4"))
        #expect(!info.isHDR)
        #expect(info.format == .nv12)
        #expect(info.frameRate == FrameRate(numerator: 25, denominator: 1))
    }

    @Test("a stream with no usable frame rate is refused")
    func refusesMissingRate() {
        let json = """
        {"streams":[{"width":1920,"height":1080,"pix_fmt":"yuv420p"}]}
        """.data(using: .utf8)!
        #expect(throws: MediaProbeError.self) {
            try MediaProbe.parse(json, url: URL(fileURLWithPath: "/tmp/x.mp4"))
        }
    }

    @Test("a frame count is read from the string ffprobe actually emits")
    func frameCountIsAString() throws {
        // ffprobe writes `"nb_frames": "28"` — a *string*, because the same field is
        // also allowed to be `"N/A"`. Casting it to `Int` therefore yields nil for
        // every file that does state a count, and every check downstream that guards on
        // the count passes vacuously instead of failing. The batch converter's
        // read-back check was dead for exactly this reason, and nothing noticed.
        let json = """
        {"streams":[{"width":3840,"height":1632,"pix_fmt":"yuv420p10le",
          "r_frame_rate":"60000/1001","nb_frames":"28"}]}
        """.data(using: .utf8)!
        let info = try MediaProbe.parse(json, url: URL(fileURLWithPath: "/tmp/x.mp4"))
        #expect(info.frameCount == 28)

        // "N/A" means not known — never a number, and never zero.
        let absent = """
        {"streams":[{"width":3840,"height":1632,"pix_fmt":"yuv420p10le",
          "r_frame_rate":"60000/1001","nb_frames":"N/A"}]}
        """.data(using: .utf8)!
        #expect(try MediaProbe.parse(absent,
                                     url: URL(fileURLWithPath: "/tmp/x.mkv")).frameCount == nil)

        // A Matroska file does not state one at all.
        let silent = """
        {"streams":[{"width":3840,"height":1632,"pix_fmt":"yuv420p10le",
          "r_frame_rate":"24000/1001"}]}
        """.data(using: .utf8)!
        #expect(try MediaProbe.parse(silent,
                                     url: URL(fileURLWithPath: "/tmp/x.mkv")).frameCount == nil)
    }

    @Test("audio that cannot go into MP4 is called out")
    func audioPassthrough() {
        // The reference disc carries DTS-X 7.1, which MP4 cannot hold. Silently
        // dropping it would be worse than saying so, so the flag exists to be
        // consulted. The video-only probe does not report audio, so the default is
        // "nothing known, nothing to refuse" — and the batch converter supplies the
        // real value from its own probe of the audio stream.
        #expect(ContentLightLevel(maxContent: 0, maxAverage: 0).seiPayload.count == 4)
        #expect(MediaInfo.audioPassThroughCodecs.contains("aac"))
        #expect(!MediaInfo.audioPassThroughCodecs.contains("dts"))
        #expect(!MediaInfo.audioPassThroughCodecs.contains("truehd"))
    }

    // MARK: - Against real files

    @Test("ffprobe is found")
    func findsFFprobe() {
        #expect(FileManager.default.isExecutableFile(atPath: MediaProbe.ffprobePath),
                "resolved to \(MediaProbe.ffprobePath)")
    }

    @Test("a real SDR file probes correctly")
    func probesRealFile() throws {
        // The committed self-test clip, so this runs anywhere.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // InterpolatorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("samples/test24.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(url)
        #expect(info.width == 1920 && info.height == 1080)
        #expect(info.format == .nv12)
        #expect(!info.isHDR)
        #expect(info.frameRate.doubleValue > 23 && info.frameRate.doubleValue < 25)
    }
}
