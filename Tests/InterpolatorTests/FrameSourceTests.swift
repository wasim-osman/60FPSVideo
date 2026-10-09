import CoreVideo
import Foundation
import Testing
@testable import Interpolator

@Suite("FrameSource")
struct FrameSourceTests {

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // InterpolatorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private var selfTestClip: URL {
        packageRoot.appendingPathComponent("samples/test24.mp4")
    }

    // MARK: - Packed files

    @Test("a packed file reads back exactly what was written")
    func packedFileRoundTrip() throws {
        let width = 64, height = 48
        for format in [FrameFormat.nv12, .p010] {
            let size = format.packedByteSize(width: width, height: height)
            let frames = 3
            // A distinct pattern per frame, so a source that returns the same frame
            // repeatedly or shifts by one cannot pass.
            var bytes: [UInt8] = []
            for frame in 0..<frames {
                bytes += (0..<size).map { UInt8(truncatingIfNeeded: $0 &+ frame &* 7) }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("packed-\(format.bitDepth)-\(UUID().uuidString).raw")
            try Data(bytes).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let source = try PackedFileFrameSource(url: url, width: width, height: height,
                                                   format: format,
                                                   frameRate: FrameRate(numerator: 24,
                                                                        denominator: 1)!)
            #expect(source.frameByteSize == size)
            #expect(source.info.frameCount == frames)
            #expect(source.info.duration == 3.0 / 24.0)

            var readBack: [UInt8] = []
            var staging = [UInt8](repeating: 0, count: size)
            // Parenthesised rather than trailing: `while try x { ... } { ... }` is two
            // closures in a row and the compiler cannot tell which belongs to which.
            while try staging.withUnsafeMutableBytes({ raw in
                try source.read(into: raw.baseAddress!)
            }) {
                readBack += staging
            }
            #expect(readBack == bytes, "\(format.bitDepth)-bit round trip")
            #expect(source.count == frames)
            // End of stream is not an error, and reading past it stays false.
            #expect(try staging.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!) } == false)
            source.close()
            source.close()   // idempotent
        }
    }

    @Test("a truncated packed file reports the short read rather than ending quietly")
    func truncatedFileIsReported() throws {
        let width = 32, height = 32
        let size = FrameFormat.nv12.packedByteSize(width: width, height: height)
        // One whole frame, then half of another. Ending silently here would look
        // like a two-frame file that happens to be missing its last frame — and the
        // pipeline would produce a short output with no explanation.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("truncated-\(UUID().uuidString).raw")
        try Data(repeating: 9, count: size + size / 2).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try PackedFileFrameSource(url: url, width: width, height: height,
                                               format: .nv12,
                                               frameRate: FrameRate(numerator: 24,
                                                                    denominator: 1)!)
        // The frame count is derived from the file size, so a partial frame is not
        // counted as a frame at all — which is the point: it is never advertised.
        #expect(source.info.frameCount == 1)
        var staging = [UInt8](repeating: 0, count: size)
        #expect(try staging.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!) })
        #expect(try staging.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!) } == false)
        source.close()
    }

    // MARK: - Decoding through ffmpeg

    @Test("ffmpeg decodes the self-test clip through the shipping path")
    func decodesRealFile() throws {
        guard FileManager.default.fileExists(atPath: selfTestClip.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(selfTestClip)
        #expect(info.format == .nv12)

        let source = try FFmpegFrameSource(url: selfTestClip, info: info)
        defer { source.close() }

        let size = source.frameByteSize
        #expect(size == info.format.packedByteSize(width: info.width, height: info.height))

        var staging = [UInt8](repeating: 0, count: size)
        var frames = 0
        var nonZeroFrames = 0
        var sums: [Int] = []
        while try staging.withUnsafeMutableBytes({ try source.read(into: $0.baseAddress!) }) {
            frames += 1
            // Sample the luma plane rather than all of it; this is a liveness check,
            // not a measurement.
            let luma = staging.prefix(info.width * info.height)
            let sum = luma.reduce(0) { $0 + Int($1) }
            if sum > 0 { nonZeroFrames += 1 }
            sums.append(sum)
            if frames > 200 { break }   // never loop forever on a decoder bug
        }

        // The clip is 3 s at 24 fps, so ~72 frames. Allow a frame either way for
        // container rounding.
        #expect(frames >= 71 && frames <= 73, "decoded \(frames) frames")
        #expect(nonZeroFrames == frames, "every frame should have content")
        // Not all frames identical — the clip moves, so a source stuck on one frame
        // would show up here.
        #expect(Set(sums).count > 1, "every frame had the same luma sum")
    }

    @Test("a frame limit is honoured")
    func honoursFrameLimit() throws {
        guard FileManager.default.fileExists(atPath: selfTestClip.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(selfTestClip)
        let source = try FFmpegFrameSource(url: selfTestClip, info: info, frameLimit: 10)
        defer { source.close() }
        var staging = [UInt8](repeating: 0, count: source.frameByteSize)
        var frames = 0
        while try staging.withUnsafeMutableBytes({ try source.read(into: $0.baseAddress!) }) {
            frames += 1
        }
        #expect(frames == 10)
    }

    @Test("seeking starts where it is asked to")
    func honoursSeek() throws {
        guard FileManager.default.fileExists(atPath: selfTestClip.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(selfTestClip)

        /// The luma sum of the first frame read from a given start time.
        func firstFrameSum(start: Double?) throws -> Int {
            let source = try FFmpegFrameSource(url: selfTestClip, info: info,
                                               startSeconds: start, frameLimit: 1)
            defer { source.close() }
            var staging = [UInt8](repeating: 0, count: source.frameByteSize)
            guard try staging.withUnsafeMutableBytes({ try source.read(into: $0.baseAddress!) })
            else { return -1 }
            return staging.prefix(info.width * info.height).reduce(0) { $0 + Int($1) }
        }

        let atStart = try firstFrameSum(start: nil)
        let atOneSecond = try firstFrameSum(start: 1.0)
        #expect(atStart > 0 && atOneSecond > 0)
        // The clip moves, so a second in the frame must differ from the first.
        #expect(atStart != atOneSecond, "the seek returned the same frame as the start")
    }

    @Test("a file with no video is refused rather than producing nothing")
    func refusesUnreadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-media-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try MediaProbe.probe(url)
        }
    }
}
