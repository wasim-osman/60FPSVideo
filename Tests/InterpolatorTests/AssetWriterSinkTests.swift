import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// The batch converter's output stage.
///
/// The two things worth testing here are the ones that would be silent if wrong: that
/// frames written out of order still land in the file in order, and that the HDR10
/// metadata and colour tags reach the container. Both are checked by reading the
/// written file back rather than by inspecting the objects that wrote it.
@Suite("Asset writer sink")
struct AssetWriterSinkTests {

    // MARK: - Helpers

    /// A frame of uniform luma, so the index survives a lossy encode.
    ///
    /// A flat frame is the only shape that makes an order check possible at all: HEVC
    /// is lossy, so a detailed pattern cannot be compared exactly, but a uniform field
    /// decodes back to (nearly) the value it went in as. Luma is placed in studio range
    /// 16...235, and chroma sits at 128 — neutral.
    static func uniformFrame(width: Int, height: Int, format: FrameFormat,
                             luma: UInt8) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: width, height: height, format: format,
                                       capacity: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if format == .nv12 {
            if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                for row in 0..<height { memset(y + row * stride, Int32(luma), width) }
            }
            if let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                for row in 0..<(height / 2) { memset(c + row * stride, 128, width) }
            }
        } else {
            // P010: the 10-bit code lives in the top ten bits of a 16-bit word.
            let code = UInt16(luma) << 6
            if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let words = y.assumingMemoryBound(to: UInt16.self)
                for row in 0..<height {
                    let base = row * stride / 2
                    for column in 0..<width { words[base + column] = code }
                }
            }
            if let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                let words = c.assumingMemoryBound(to: UInt16.self)
                for row in 0..<(height / 2) {
                    let base = row * stride / 2
                    for column in 0..<width { words[base + column] = 512 << 6 }
                }
            }
        }
        return buffer
    }

    /// Mean luma of every frame in a file, decoded through ffmpeg.
    ///
    /// Decoded to `yuv420p` and the luma plane read directly, *not* to `gray`.
    /// `-pix_fmt gray` asks ffmpeg for full-range 8-bit, so it stretches the studio
    /// range 16...235 back out to 0...255 on the way — which would make every value
    /// here wrong by a scale factor and look exactly like a sink bug. Reading the
    /// plane the encoder wrote keeps the numbers comparable to what went in.
    static func perFrameLuma(_ url: URL, width: Int, height: Int) throws -> [Double] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MediaProbe.ffmpegPath)
        process.arguments = ["-hide_banner", "-v", "error", "-nostdin", "-i", url.path,
                             "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InterpolatorError.writerFailed("ffmpeg could not decode \(url.lastPathComponent)")
        }
        let frameSize = width * height * 3 / 2
        let frames = data.count / frameSize
        return (0..<frames).map { index in
            let start = index * frameSize
            let slice = data[start..<(start + width * height)]
            let total = slice.reduce(0) { $0 + Int($1) }
            return Double(total) / Double(width * height)
        }
    }

    /// A `CVPixelBuffer` cannot cross into a `@Sendable` closure, and each of these
    /// really is touched by one thread only — one buffer per index, written once. So
    /// the box is accurate rather than a way around the checker.
    struct BufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// `ffprobe -show_streams`, as text, so a test can assert on tags without a parser.
    static func streamText(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MediaProbe.ffprobePath)
        process.arguments = ["-hide_banner", "-v", "error", "-show_streams", "-show_frames",
                             "-read_intervals", "%+#1", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static var temporaryDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assetwriter-sink-\(UUID().uuidString)")
    }

    // MARK: - Settings, without encoding anything

    @Test("ffprobe's colour names map onto AVFoundation's, and unknown ones are omitted")
    func colourNameMapping() {
        #expect(VideoEncodeSettings.avColorPrimaries("bt2020") == AVVideoColorPrimaries_ITU_R_2020)
        #expect(VideoEncodeSettings.avColorPrimaries("bt709") == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(VideoEncodeSettings.avTransferFunction("smpte2084")
                == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(VideoEncodeSettings.avTransferFunction("arib-std-b67")
                == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(VideoEncodeSettings.avYCbCrMatrix("bt2020nc") == AVVideoYCbCrMatrix_ITU_R_2020)

        // A name nobody recognises must produce no tag at all. A wrong colour tag is
        // worse than a missing one, because a player will faithfully apply it.
        #expect(VideoEncodeSettings.avColorPrimaries("something-else") == nil)
        #expect(VideoEncodeSettings.avTransferFunction(nil) == nil)
        #expect(VideoEncodeSettings.avYCbCrMatrix("") == nil)
    }

    @Test("a partial colour tag set is dropped entirely rather than applied half-way")
    func partialColourTagsAreDropped() {
        // AVFoundation takes the three tags as one dictionary, so applying two of them
        // is not a thing. This asserts we do not try.
        let partial = VideoEncodeSettings(bitRate: 1_000_000,
                                          colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                                          transferFunction: nil,
                                          yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020)
        #expect(partial.colorProperties == nil)
    }

    @Test("the settings carry the source's own HDR10 payloads, byte for byte")
    func settingsCarryTheSourcePayloads() {
        // The reference disc's values, through the same builders the probe used.
        let mastering = MasteringDisplay(
            redX: 34000, redY: 16000, greenX: 13250, greenY: 34500,
            blueX: 7500, blueY: 3000, whiteX: 15635, whiteY: 16450,
            minLuminance: 50, maxLuminance: 10_000_000)
        let light = ContentLightLevel(maxContent: 1000, maxAverage: 221)
        let info = MediaInfo(
            url: URL(fileURLWithPath: "/dev/null"), width: 3840, height: 1632,
            frameRate: .twentyFourNTSC, frameCount: nil, duration: 0,
            pixelFormat: "yuv420p10le", format: .p010,
            colorPrimaries: "bt2020", transferFunction: "smpte2084",
            colorSpace: "bt2020nc", colorRange: "tv",
            masteringDisplay: mastering, contentLightLevel: light,
            audioTracks: [], chapterCount: 0)

        let settings = VideoEncodeSettings.forSource(info)
        #expect(settings.masteringDisplay == mastering.seiPayload)
        #expect(settings.contentLightLevel == light.seiPayload)
        #expect(settings.transferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(settings.profileLevel == kVTProfileLevel_HEVC_Main10_AutoLevel as String)

        // And an SDR source asks for neither, rather than asking for zeroes — a zeroed
        // mastering display is a *valid* payload claiming black (invariant 21).
        let sdr = MediaInfo(
            url: URL(fileURLWithPath: "/dev/null"), width: 1920, height: 1080,
            frameRate: .twentyFour, frameCount: nil, duration: 0,
            pixelFormat: "yuv420p", format: .nv12,
            colorPrimaries: "bt709", transferFunction: "bt709",
            colorSpace: "bt709", colorRange: "tv",
            masteringDisplay: nil, contentLightLevel: nil,
            audioTracks: [], chapterCount: 0)
        let sdrSettings = VideoEncodeSettings.forSource(sdr)
        #expect(sdrSettings.masteringDisplay == nil)
        #expect(sdrSettings.contentLightLevel == nil)
    }

    // MARK: - The rate

    @Test("the container keeps the exact rate instead of rounding it to a whole number")
    func exactRateSurvivesTheContainer() throws {
        // 60000/1001 is the shipping rate, and one frame of it is 1001/60000 s — which
        // is **10.01** ticks at the timescale AVAssetWriter gives a video track by
        // default (600). Rounded to 10, the file becomes 60.000: a different rate,
        // arrived at silently, with every frame present and every duration uniform.
        //
        // Measured before this was fixed, on a 12-source-frame render of the real film:
        // `mdhd` 600, `stts` 28 x 10 ticks, 0.46667 s where the same 28 frames are
        // 0.46713 s. `movieTimeScale` does not fix it — that sets `mvhd` only, which is
        // why the first attempt at this changed nothing. It is `mediaTimeScale` on the
        // input, and it is only visible by reading the container back.
        let width = 320, height = 240
        let directory = AssetWriterSinkTests.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("rate.mp4")

        let frameCount = 5
        let sink = AssetWriterSink(url: output,
                                   settings: VideoEncodeSettings(bitRate: 4_000_000))
        try sink.begin(SinkGeometry(width: width, height: height, format: .nv12,
                                    sourceRate: .twentyFourNTSC, outputRate: .sixtyNTSC,
                                    sourceFrameCount: frameCount,
                                    outputFrameCount: frameCount))
        for index in 0..<frameCount {
            sink.write(try AssetWriterSinkTests.uniformFrame(
                width: width, height: height, format: .nv12, luma: UInt8(20 + index * 16)),
                       at: index)
        }
        try sink.finish()
        #expect(sink.appended == frameCount)

        let text = try AssetWriterSinkTests.streamText(output)
        #expect(text.contains("avg_frame_rate=60000/1001"))
        #expect(text.contains("r_frame_rate=60000/1001"))

        // And the same answer through the shipping probe, so the rate the rest of the
        // app would read back is the rate that went in.
        let check = try MediaProbe.probeStreamOnly(output)
        #expect(check.frameRate == .sixtyNTSC)
        #expect(check.frameCount == frameCount)
    }

    // MARK: - Copying

    @Test("copying honours each buffer's own row stride")
    func copyHonoursStrides() throws {
        // Two pools whose padding differs, because that is the case a naive
        // `memcpy(width * bytesPerSample)` gets wrong — it shears the picture, and at
        // 4K the padded stride is routinely wider than the visible width.
        let width = 100, height = 8
        let source = try AssetWriterSinkTests.uniformFrame(
            width: width, height: height, format: .nv12, luma: 200)

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: FrameFormat.nv12.pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferBytesPerRowAlignmentKey: 256,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  FrameFormat.nv12.pixelFormat,
                                  attributes as CFDictionary, &destination) == kCVReturnSuccess,
              let destination else {
            Issue.record("could not create the destination buffer")
            return
        }

        AssetWriterSink.copyPlanes(from: source, into: destination)

        // Every visible pixel of the copy must be the luma that went in, and the
        // destination's padding must not have been written past.
        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(destination, 0) else {
            Issue.record("no luma plane")
            return
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let bytes = plane.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width where bytes[row * stride + column] != 200 {
                Issue.record("row \(row) column \(column) is \(bytes[row * stride + column]), expected 200")
                return
            }
        }
    }

    // MARK: - The real thing

    @Test("frames written out of order land in the file in order")
    func outOfOrderWritesLandInOrder() throws {
        let width = 320, height = 240
        let directory = AssetWriterSinkTests.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("order.mp4")

        let frameCount = 12
        let sink = AssetWriterSink(url: output,
                                   settings: VideoEncodeSettings(bitRate: 4_000_000))
        try sink.begin(SinkGeometry(width: width, height: height, format: .nv12,
                                    sourceRate: .twentyFour, outputRate: .twentyFour,
                                    sourceFrameCount: frameCount,
                                    outputFrameCount: frameCount))

        // Build all the frames first: each one is a distinct flat luma, so the index is
        // recoverable from the decoded picture. Luma 20, 36, 52, ... stays inside
        // studio range and far enough apart to survive the encode.
        var frames: [CVPixelBuffer] = []
        for index in 0..<frameCount {
            frames.append(try AssetWriterSinkTests.uniformFrame(
                width: width, height: height, format: .nv12, luma: UInt8(20 + index * 16)))
        }

        // Write them in reverse, and from several threads at once, which is exactly
        // what the pipeline does. The sink's contract says it must not care.
        let boxed = frames.map(BufferBox.init)
        let group = DispatchGroup()
        for index in (0..<frameCount).reversed() {
            group.enter()
            DispatchQueue.global().async {
                sink.write(boxed[index].buffer, at: index)
                group.leave()
            }
        }
        group.wait()

        try sink.finish()
        #expect(sink.problems.isEmpty, "\(sink.problems)")
        #expect(sink.appended == frameCount)

        let luma = try AssetWriterSinkTests.perFrameLuma(output, width: width, height: height)
        #expect(luma.count == frameCount, "decoded \(luma.count) frames, expected \(frameCount)")
        let expected = (0..<frameCount).map { Double(20 + $0 * 16) }
        let rounded = luma.map { ($0 * 10).rounded() / 10 }
        #expect(rounded == expected.map { ($0 * 10).rounded() / 10 },
                "decoded \(rounded), expected \(expected)")
    }

    @Test("the colour tags and HDR10 metadata reach the container")
    func hdrMetadataReachesTheContainer() throws {
        let width = 320, height = 240
        let directory = AssetWriterSinkTests.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("hdr.mp4")

        let mastering = MasteringDisplay(
            redX: 34000, redY: 16000, greenX: 13250, greenY: 34500,
            blueX: 7500, blueY: 3000, whiteX: 15635, whiteY: 16450,
            minLuminance: 50, maxLuminance: 10_000_000)
        let light = ContentLightLevel(maxContent: 1000, maxAverage: 221)

        let settings = VideoEncodeSettings(
            bitRate: 4_000_000,
            profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
            yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020,
            masteringDisplay: mastering.seiPayload,
            contentLightLevel: light.seiPayload)

        let sink = AssetWriterSink(url: output, settings: settings)
        let frameCount = 6
        try sink.begin(SinkGeometry(width: width, height: height, format: .p010,
                                    sourceRate: .twentyFour, outputRate: .twentyFour,
                                    sourceFrameCount: frameCount,
                                    outputFrameCount: frameCount))
        for index in 0..<frameCount {
            sink.write(try AssetWriterSinkTests.uniformFrame(
                width: width, height: height, format: .p010, luma: UInt8(20 + index * 8)),
                       at: index)
        }
        try sink.finish()
        #expect(sink.problems.isEmpty, "\(sink.problems)")

        // The claim being checked is the one invariant 21 makes: an HEVC Main10 encode
        // with the right colour tags still carries *no* mastering display unless it is
        // asked for, so this has to be read back rather than assumed.
        let text = try AssetWriterSinkTests.streamText(output)
        #expect(text.contains("bt2020"), "no bt2020 in:\n\(text.prefix(1200))")
        #expect(text.contains("smpte2084"), "no PQ transfer tag in:\n\(text.prefix(1200))")
        #expect(text.contains("Main 10") || text.contains("main 10"),
                "not Main 10 in:\n\(text.prefix(1200))")
        // The payloads are what proves the metadata made it rather than the profile.
        #expect(text.contains("mastering") || text.contains("Mastering"),
                "no mastering display in:\n\(text.prefix(2000))")
        #expect(text.contains("10000000") || text.contains("1000"),
                "no luminance in:\n\(text.prefix(2000))")
    }
}
