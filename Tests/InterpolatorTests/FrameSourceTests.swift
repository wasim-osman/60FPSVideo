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

    /// The decoder cannot be stopped by asking nicely, and this is the guard on that.
    ///
    /// `close()` used to send SIGTERM and then wait. A frame of 1080p NV12 is 3.1 MB and a pipe
    /// holds 64 KB, so ffmpeg is **always** part-way through a write when a reader stops — blocked
    /// there, it never reaches the point in its main loop that notices the signal, and the wait was
    /// therefore forever. The app hung with a live ffmpeg whenever a reader stopped early, which is
    /// the calibration probe, a cancelled run, and a seek taking the source away.
    ///
    /// The close runs on a detached thread so that a regression **fails in five seconds** rather
    /// than hanging the suite. The difference matters: a hung test tells you nothing, and this one
    /// has to be able to report the bug it exists for.
    @Test("closing a source whose reader stopped does not wait forever")
    func closeEndsABlockedDecoder() throws {
        guard FileManager.default.fileExists(atPath: selfTestClip.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(selfTestClip)
        let source = try FFmpegFrameSource(url: selfTestClip, info: info)

        // The test is only meaningful while one frame cannot fit in the pipe: that is exactly what
        // leaves the decoder stalled in `write()` once the reader stops. Were the frames small
        // enough to fit, nothing would block and this would pass against the broken code.
        #expect(source.frameByteSize > 65_536,
                "a \(source.frameByteSize)-byte frame fits in the pipe, so nothing blocks here")

        var staging = [UInt8](repeating: 0, count: source.frameByteSize)
        for _ in 0..<2 {
            _ = try staging.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!) }
        }
        // Stop reading, and give ffmpeg time to reach the write it cannot finish.
        Thread.sleep(forTimeInterval: 0.5)

        let returned = DispatchSemaphore(value: 0)
        let closer = Thread { source.close(); returned.signal() }
        closer.name = "interp.test.closer"
        closer.start()

        #expect(returned.wait(timeout: .now() + 5) == .success,
                "close() never returned: the decoder was blocked writing and nothing ended it")
    }

    @Test("a stop we asked for is not reported as a broken film")
    func aDeliberateStopIsNotADecoderFailure() throws {
        guard FileManager.default.fileExists(atPath: selfTestClip.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(selfTestClip)
        let source = try FFmpegFrameSource(url: selfTestClip, info: info)
        var staging = [UInt8](repeating: 0, count: source.frameByteSize)
        #expect(try staging.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!) })

        source.close()

        // `close()` ends the process with a signal, so its status is that signal number. Reading on
        // must end the stream quietly; reporting `ffmpeg exited 9` would put a fault in the log
        // every time a run was cancelled or a seek took the source away, which is how a real one
        // gets ignored.
        #expect(try staging.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!) } == false)
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

    /// `hardwareDecode: false` is the control arm of §36 — the measurement of what the media
    /// engine's decoder is worth to a *whole conversion*. That measurement only means anything
    /// if the control arm decodes the same film, so this asserts the frames rather than the
    /// argv. A flag that quietly changed the pixel format, the colour range or the frame count
    /// would move the wall-clock number and leave it looking like a real effect — which is
    /// invariant 35's failure mode wearing a different hat.
    ///
    /// Invariant 50 recorded that the two paths are bit-identical on the reference disc; this
    /// keeps that true for the parameter that now selects between them.
    ///
    /// The two sources are read in lockstep rather than collected and compared, so a difference
    /// fails on the frame it is on instead of after both streams have been buffered — 224 MB of
    /// frames at 1080p, which is not a thing to accumulate twice inside a suite that runs in
    /// parallel.
    @Test("software decode returns the same frames as the media engine")
    func softwareDecodeMatchesHardware() throws {
        guard FileManager.default.fileExists(atPath: selfTestClip.path) else {
            Issue.record("samples/test24.mp4 is missing")
            return
        }
        let info = try MediaProbe.probe(selfTestClip)

        let hardware = try FFmpegFrameSource(url: selfTestClip, info: info)
        let software = try FFmpegFrameSource(url: selfTestClip, info: info, hardwareDecode: false)
        defer { hardware.close(); software.close() }

        #expect(hardware.frameByteSize == software.frameByteSize)
        var a = [UInt8](repeating: 0, count: hardware.frameByteSize)
        var b = [UInt8](repeating: 0, count: software.frameByteSize)

        var frames = 0
        while frames < 400 {
            let moreA = try a.withUnsafeMutableBytes { try hardware.read(into: $0.baseAddress!) }
            let moreB = try b.withUnsafeMutableBytes { try software.read(into: $0.baseAddress!) }
            guard moreA == moreB else {
                Issue.record("the two paths disagree on where the stream ends, at frame \(frames)")
                return
            }
            guard moreA else { break }
            guard a == b else {
                Issue.record("frame \(frames) differs between the two decode paths")
                return
            }
            frames += 1
        }

        // The floor that makes the comparison mean something: a pair of sources that both
        // returned nothing would otherwise agree perfectly.
        #expect(frames == info.frameCount, "decoded \(frames) frames, the probe says \(info.frameCount)")
        #expect(frames > 0)
    }
}
