import CoreVideo
import Foundation
import Testing
@testable import Interpolator

// MARK: - Doubles

/// An engine that does nothing but complete.
///
/// Synchronous on purpose. These tests are about the converter's ordering, its count
/// check and its cleanup, and a background engine would only add nondeterminism to
/// them. Whether a borrowed buffer is respected across threads is
/// `InterpolationPipelineTests`' subject, not this file's.
final class NoopEngine: InterpolationEngine, @unchecked Sendable {
    let name = "noop"
    let maximumInterpolationsPerInterval = 4
    let depth = 2

    func prepare(width: Int, height: Int) throws {}
    func submit(_ request: InterpolationRequest) { request.completion(.success(())) }
    func drain() throws {}
    func shutdown() {}
}

/// A sink that accepts nothing at all.
///
/// The failure this stands in for is the quiet one: a real sink that has stopped
/// accepting frames still finalises a *valid* file, and every check that only asks
/// "did the writer succeed?" answers yes.
final class DroppingSink: FrameCountingSink, @unchecked Sendable {
    func begin(_ geometry: SinkGeometry) throws {}
    func write(_ buffer: CVPixelBuffer, at index: Int) {}
    func finish() throws {}
    var problems: [String] { [] }
    var written: Int { 0 }
}

/// A writer that creates its file and then fails.
///
/// A real writer creates its output before it knows it will fail, so the double has to
/// as well — otherwise the test would pass against a converter that cleans up nothing,
/// because there would be nothing to clean up.
final class FailingSink: FrameCountingSink, @unchecked Sendable {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "the writer gave up" }
    }

    private let url: URL

    init(url: URL) { self.url = url }

    func begin(_ geometry: SinkGeometry) throws {
        try Data(repeating: 0, count: 4096).write(to: url)
    }

    func write(_ buffer: CVPixelBuffer, at index: Int) {}
    func finish() throws { throw Boom() }
    var problems: [String] { [] }
    var written: Int { 0 }
}

/// Keeps the packed sink so the test can close its descriptor.
final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PackedFileSink?

    func store(_ sink: PackedFileSink) {
        lock.lock(); stored = sink; lock.unlock()
    }

    var value: PackedFileSink? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private extension MediaInfo {
    /// The same media with a different *stated* frame count.
    ///
    /// Used for the read-back check: the converter probes the input and then the
    /// output, and the second answer has to be able to be wrong on purpose.
    func statingFrameCount(_ count: Int?) -> MediaInfo {
        MediaInfo(url: url, width: width, height: height, frameRate: frameRate,
                  frameCount: count, duration: duration,
                  pixelFormat: pixelFormat, format: format,
                  colorPrimaries: colorPrimaries, transferFunction: transferFunction,
                  colorSpace: colorSpace, colorRange: colorRange,
                  masteringDisplay: masteringDisplay,
                  contentLightLevel: contentLightLevel,
                  audioCodec: audioCodec, audioChannels: audioChannels)
    }
}

// MARK: - Tests

struct BatchConverterTests {

    static let width = 64
    static let height = 16

    // MARK: Scaffolding

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-converter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeInfo(frames: Int?, rate: FrameRate = .twentyFourNTSC) -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/dev/null"),
                  width: Self.width, height: Self.height, frameRate: rate,
                  frameCount: frames, duration: 0,
                  pixelFormat: "nv12", format: .nv12,
                  colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
                  colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
                  audioCodec: nil, audioChannels: nil)
    }

    /// A converter whose three stages are all doubles.
    ///
    /// The probe answers twice — once for the input, once for the output — and the two
    /// answers differ on purpose, because the read-back check is one of the things
    /// under test. Nothing here touches ffmpeg, VideoToolbox or a display.
    private func makeConverter(input: URL,
                               info: MediaInfo,
                               outputFrameCount: Int?,
                               box: SinkBox? = nil,
                               sink: (@Sendable (URL) -> FrameCountingSink)? = nil) -> BatchConverter {
        BatchConverter(
            probe: { url in
                url == input ? info : info.statingFrameCount(outputFrameCount)
            },
            makeSource: { _, _, _, _ in
                SyntheticFrameSource(width: info.width, height: info.height,
                                     format: info.format, frameRate: info.frameRate,
                                     totalFrames: info.frameCount ?? 0)
            },
            makeSink: { url, _ in
                if let sink { return sink(url) }
                let descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
                let packed = PackedFileSink(descriptor: descriptor,
                                            width: info.width, height: info.height,
                                            format: info.format)
                box?.store(packed)
                return packed
            },
            makeEngine: { _, _, _ in NoopEngine() })
    }

    private func leftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("partial") }
    }

    // MARK: A clean run

    @Test("a clean run puts the output where it was asked for and leaves nothing partial")
    func cleanRun() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")
        let box = SinkBox()
        defer { box.value?.closeFile() }

        let converter = makeConverter(input: input, info: makeInfo(frames: 12),
                                      outputFrameCount: nil, box: box)
        let result = try converter.run(.init(input: input, output: output,
                                             sceneDetection: false))

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(result.written == result.outputFrames)
        #expect(result.isClean)

        // The count the converter states up front has to be the count the run produces.
        // `PackedFileSink` treats that hint as the authority for the file's length and
        // records a problem when it is wrong, so `isClean` above is this check passing
        // — and the explicit comparison says which two numbers had to agree.
        let plan = try #require(PhasePlan(sourceFrameCount: 12, source: .twentyFourNTSC,
                                          output: .sixtyNTSC))
        #expect(result.outputFrames == plan.outputFrameCount)
        #expect(result.report.passthroughFrames == plan.passthroughCount)

        // 23.976 -> 59.94 is exactly 5/2, so one output frame in five is the original
        // picture and costs no inference at all.
        #expect(abs(result.passthroughFraction - 0.2) < 0.05)
        #expect(result.cutCount == 0)

        #expect(try leftovers(in: directory).isEmpty)
    }

    @Test("the reported rate is derived from the bytes written, not from the target")
    func reportedRateIsMeasured() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")
        let box = SinkBox()
        defer { box.value?.closeFile() }

        let converter = makeConverter(input: input, info: makeInfo(frames: 12),
                                      outputFrameCount: nil, box: box)
        let result = try converter.run(.init(input: input, output: output,
                                             sceneDetection: false))

        // A packed NV12 stream is exactly 1.5 bytes per sample, so its bits per pixel
        // per frame is exactly 12 — an identity, not a tolerance. It holds only if the
        // count and the byte size both describe the same file.
        #expect(abs(result.bitsPerPixelPerFrame - 12.0) < 0.0001)
        #expect(result.bytes == Int64(result.written * Self.width * Self.height * 3 / 2))
        #expect(abs(result.outputSeconds
                    - Double(result.written) / FrameRate.sixtyNTSC.doubleValue) < 1e-9)
        #expect(result.megabitsPerSecond > 0)
    }

    // MARK: Refusals

    @Test("a source already at the target rate is refused rather than re-encoded")
    func alreadyAtTarget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")
        let box = SinkBox()
        defer { box.value?.closeFile() }

        // Exactly the default policy's rate: there is no conversion to do, and
        // re-encoding would spend a generation of quality to change nothing.
        let info = makeInfo(frames: 12, rate: .sixtyNTSC)
        let converter = makeConverter(input: input, info: info,
                                      outputFrameCount: nil, box: box)

        do {
            _ = try converter.run(.init(input: input, output: output,
                                        sceneDetection: false))
            Issue.record("a 59.94 source under the 59.94 default should not be converted")
        } catch let failure as BatchConverter.Failure {
            guard case .alreadyAtTarget(let detail) = failure else {
                Issue.record("expected alreadyAtTarget, got \(failure)")
                return
            }
            #expect(detail.contains("already"))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // The override does convert it, which is the case for normalising a container
        // when the cadence is already what was asked for.
        let forced = try converter.run(.init(input: input, output: output,
                                             sceneDetection: false,
                                             convertWhenAlreadyAtTarget: true))
        #expect(forced.written == forced.outputFrames)
        #expect(forced.resolution.isPassthrough)
        #expect(forced.report.interpolatedFrames == 0)
    }

    @Test("an existing output is not replaced unless asked")
    func refusesToOverwrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")
        let box = SinkBox()
        defer { box.value?.closeFile() }

        let original = Data(repeating: 7, count: 64)
        try original.write(to: output)

        let converter = makeConverter(input: input, info: makeInfo(frames: 12),
                                      outputFrameCount: nil, box: box)
        do {
            _ = try converter.run(.init(input: input, output: output,
                                        sceneDetection: false))
            Issue.record("an existing output should not be replaced without being asked")
        } catch let failure as BatchConverter.Failure {
            guard case .outputExists = failure else {
                Issue.record("expected outputExists, got \(failure)")
                return
            }
        }
        #expect(try Data(contentsOf: output) == original)

        let result = try converter.run(.init(input: input, output: output,
                                             sceneDetection: false, overwrite: true))
        #expect(result.isClean)
    }

    // MARK: The two things the converter exists to prevent

    @Test("a sink that drops every frame fails the job instead of producing a short file")
    func shortOutputIsCaught() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")

        let converter = makeConverter(input: input, info: makeInfo(frames: 12),
                                      outputFrameCount: nil,
                                      sink: { _ in DroppingSink() })
        do {
            _ = try converter.run(.init(input: input, output: output,
                                        sceneDetection: false))
            Issue.record("a sink that placed no frames must not produce a file")
        } catch let failure as BatchConverter.Failure {
            guard case .shortOutput(let expected, let written) = failure else {
                Issue.record("expected shortOutput, got \(failure)")
                return
            }
            #expect(written == 0)
            #expect(expected > 0)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try leftovers(in: directory).isEmpty)
    }

    @Test("a writer that fails leaves nothing behind, partial or otherwise")
    func failureLeavesNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")

        let converter = makeConverter(input: input, info: makeInfo(frames: 12),
                                      outputFrameCount: nil,
                                      sink: { FailingSink(url: $0) })
        do {
            _ = try converter.run(.init(input: input, output: output,
                                        sceneDetection: false))
            Issue.record("a writer that fails to finish must fail the job")
        } catch {
            // Expected — the sink's own error, not the converter's.
        }

        #expect(!FileManager.default.fileExists(atPath: output.path))
        // The sink created a file before it failed, so this is a real check: the
        // directory has to be empty afterwards.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.isEmpty, "the partial output was left behind: \(remaining)")
    }

    // MARK: Reading the result back

    @Test("a container that reports the wrong frame count is reported, not ignored")
    func readBackMismatch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mkv")
        let output = directory.appendingPathComponent("out.mp4")
        let box = SinkBox()
        defer { box.value?.closeFile() }

        // Only the output's answer is wrong; the input's is the real one.
        let converter = makeConverter(input: input, info: makeInfo(frames: 12),
                                      outputFrameCount: 9_999, box: box)
        let result = try converter.run(.init(input: input, output: output,
                                             sceneDetection: false))

        #expect(!result.isClean)
        #expect(result.problems.contains { $0.contains("9999") })
        // The file is still delivered. The pictures are there; what disagrees is the
        // container's own count, and discarding a finished render over it would be
        // worse than saying so.
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: Helpers, in isolation

    @Test("the working file is a sibling that cannot be mistaken for the finished one")
    func temporaryPath() {
        let output = URL(fileURLWithPath: "/tmp/film/out.mp4")
        let temporary = BatchConverter.temporaryURL(beside: output)

        // A sibling, so the final move is a rename inside one volume.
        #expect(temporary.deletingLastPathComponent() == output.deletingLastPathComponent())
        #expect(temporary.pathExtension == "mp4")
        #expect(temporary.lastPathComponent.contains("partial"))
        #expect(temporary != output)
        // Two jobs in one directory cannot collide.
        #expect(BatchConverter.temporaryURL(beside: output) != temporary)
        // An extension-less destination still gets a usable one.
        #expect(BatchConverter.temporaryURL(
            beside: URL(fileURLWithPath: "/tmp/film/out")).pathExtension == "mp4")
    }

    @Test("no frame count is stated when the source does not give one")
    func expectedOutputFrames() {
        let request = BatchConverter.Request(input: URL(fileURLWithPath: "/dev/null"),
                                             output: URL(fileURLWithPath: "/dev/null"))

        // Matroska reports `nb_frames=N/A`, and this value is a hint a sink may size a
        // file from — so it has to be either right or absent.
        let unknown = makeInfo(frames: nil)
        #expect(BatchConverter.expectedOutputFrames(
            request: request, info: unknown,
            resolution: request.policy.resolve(source: unknown.frameRate)) == nil)

        // When the source does state one, the hint has to be the plan's own count. The
        // two must not be derived separately, or they will disagree and a sink that
        // sizes itself from the hint will be wrong.
        let known = makeInfo(frames: 12)
        let resolution = request.policy.resolve(source: known.frameRate)
        let plan = PhasePlan(sourceFrameCount: 12, source: .twentyFourNTSC, output: .sixtyNTSC)
        #expect(BatchConverter.expectedOutputFrames(request: request, info: known,
                                                    resolution: resolution)
                == plan?.outputFrameCount)

        // A cap lowers it, because the run stops early.
        var capped = request
        capped.maximumSourceFrames = 7
        let cappedPlan = PhasePlan(sourceFrameCount: 7, source: .twentyFourNTSC,
                                   output: .sixtyNTSC)
        #expect(BatchConverter.expectedOutputFrames(request: capped, info: known,
                                                    resolution: resolution)
                == cappedPlan?.outputFrameCount)
    }

    @Test("the default policy is what the converter uses when none is named")
    func defaultPolicy() {
        // 23.976 -> 59.94 exactly, which is the shipping answer. A converter that
        // defaulted to 60.000 would still work and would quietly cost a quarter more
        // inference on every film.
        let request = BatchConverter.Request(input: URL(fileURLWithPath: "/dev/null"),
                                             output: URL(fileURLWithPath: "/dev/null"))
        let resolution = request.policy.resolve(source: .twentyFourNTSC)
        #expect(resolution.output == .sixtyNTSC)
        #expect(resolution.ratio.numerator == 5)
        #expect(resolution.ratio.denominator == 2)
    }
}
