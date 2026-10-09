import Foundation
import Testing
@testable import Interpolator

/// The step that puts the segments back into one film.
///
/// This is the one place where the segmented design can be silently undone. Each segment is
/// a complete, correct MP4 on its own; the join is a container operation over them, and the
/// failure it can produce is not an error — it is a film with a lost or duplicated frame at
/// every boundary, which plays, which has roughly the right length, and which stutters on a
/// schedule. Nothing downstream would notice.
///
/// So the tests are about the two things that catch that: the list is built the way ffmpeg
/// reads it, and the result is checked against the plan's own frame count rather than
/// against "ffmpeg exited zero".
struct SegmentJoinerTests {

    /// A box that can be captured by the `@Sendable` seams and read back from the test.
    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ initial: Value) { storage = initial }
        var value: Value {
            get {
                lock.lock(); defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock(); storage = newValue; lock.unlock()
            }
        }
        func mutate(_ body: (inout Value) -> Void) {
            lock.lock(); body(&storage); lock.unlock()
        }
    }

    /// The argument that follows `flag`, which is how ffmpeg's options are read.
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rate(_ text: String) -> FrameRate { FrameRate.parse(text)! }

    /// A joiner whose ffmpeg is a stub. `/bin/sh` is used as the "executable" because the
    /// check is that the path *is* executable — the stub never runs it.
    private func stubbedJoiner(
        probe: @escaping @Sendable (URL) throws -> (frames: Int?, rate: String?),
        onRun: @escaping @Sendable ([String]) -> Void = { _ in }
    ) -> SegmentJoiner {
        SegmentJoiner(runFFmpeg: { arguments in
            onRun(arguments)
            return ""
        }, probeVideo: probe, ffmpegPath: { "/bin/sh" })
    }

    /// The frames the plan for `count` segments expects, as the probe would report them.
    private func expectedFrames(of plan: SegmentPlan) -> Int { plan.outputFrameCount }

    // MARK: - The list

    @Test("the concat list names one file per line")
    func listNamesEachFile() {
        let joiner = SegmentJoiner()
        let contents = joiner.listContents(files: ["000.mp4", "001.mp4", "002.mp4"])
        #expect(contents == "file '000.mp4'\nfile '001.mp4'\nfile '002.mp4'\n")
    }

    @Test("an empty list is empty rather than malformed")
    func emptyList() {
        #expect(SegmentJoiner().listContents(files: []).isEmpty)
    }

    /// The format gives meaning to exactly one character. Our own names are `%04d.mp4` and
    /// can never contain it, which is precisely why the escape needs a test — it would never
    /// be exercised in practice, so it would rot unnoticed until the day the naming changed.
    @Test("a file name containing a quote cannot break out of the list")
    func quotesAreEscaped() {
        let contents = SegmentJoiner().listContents(files: ["it's.mp4"])
        // Close the quote, emit an escaped quote, reopen: `'\''`.
        #expect(contents == "file 'it'\\''s.mp4'\n")
    }

    // MARK: - The command

    @Test("the join copies the picture rather than re-encoding it")
    func joinCopies() {
        let arguments = SegmentJoiner().arguments(
            listPath: URL(fileURLWithPath: "/tmp/list.txt"),
            output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(value(after: "-c", in: arguments) == "copy")
    }

    @Test("the join reads its list in a way that tolerates absolute paths")
    func joinUsesSafeZero() {
        let arguments = SegmentJoiner().arguments(
            listPath: URL(fileURLWithPath: "/tmp/list.txt"),
            output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(value(after: "-safe", in: arguments) == "0")
    }

    @Test("the output is the last argument, so ffmpeg cannot read it as an input")
    func outputComesLast() {
        let output = URL(fileURLWithPath: "/tmp/out.mp4")
        let arguments = SegmentJoiner().arguments(
            listPath: URL(fileURLWithPath: "/tmp/list.txt"), output: output)
        #expect(arguments.last == output.path)
        // `-y` immediately before it, so the output position is unambiguous.
        #expect(arguments.dropLast().last == "-y")
    }

    @Test("the list is the only input, and it is named")
    func listIsTheInput() {
        let list = URL(fileURLWithPath: "/tmp/job/concat.txt")
        let arguments = SegmentJoiner().arguments(
            listPath: list, output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(value(after: "-i", in: arguments) == list.path)
        #expect(arguments.contains("concat"))
    }

    // MARK: - Refusals before any work

    @Test("there is nothing to join when there are no segments")
    func nothingToJoin() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")

        let joiner = stubbedJoiner(probe: { _ in (frames: 0, rate: nil) })
        #expect(throws: SegmentJoinError.self) {
            try joiner.join(files: [], output: output,
                            expectedFrames: nil, expectedRate: nil)
        }
    }

    @Test("a missing ffmpeg is refused before the list is written")
    func ffmpegMissing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        let joiner = SegmentJoiner(runFFmpeg: { _ in "" },
                                   probeVideo: { _ in (frames: 0, rate: nil) },
                                   ffmpegPath: { "/nonexistent/ffmpeg" })
        #expect(throws: SegmentJoinError.self) {
            try joiner.join(files: [segment], output: output,
                            expectedFrames: nil, expectedRate: nil)
        }
        // Nothing was written, so the refusal cost nothing.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("concat.txt").path))
    }

    // MARK: - Running

    @Test("the join runs ffmpeg with the executable first")
    func executableIsFirst() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        let seen = Recorder<[String]>([])
        let joiner = stubbedJoiner(probe: { _ in (frames: 10, rate: "60000/1001") },
                                   onRun: { seen.value = $0 })
        try joiner.join(files: [segment], output: output,
                        expectedFrames: 10, expectedRate: rate("60000/1001"))

        let arguments = try #require(seen.value.first)
        #expect(arguments == "/bin/sh")
    }

    @Test("the list is written beside the segments and taken away afterwards")
    func listIsTemporary() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        let listPath = directory.appendingPathComponent("concat.txt")
        let sawList = Recorder<Bool>(false)
        let contents = Recorder<String>("")

        let joiner = stubbedJoiner(probe: { _ in (frames: 10, rate: "60000/1001") },
                                   onRun: { _ in
            sawList.value = FileManager.default.fileExists(atPath: listPath.path)
            contents.value = (try? String(contentsOf: listPath, encoding: .utf8)) ?? ""
        })
        try joiner.join(files: [segment], output: output,
                        expectedFrames: 10, expectedRate: rate("60000/1001"))

        // It existed while ffmpeg ran, and it named the segment by file name — not by path,
        // because ffmpeg resolves the names against the list's own directory.
        #expect(sawList.value)
        #expect(contents.value == "file '000.mp4'\n")
        // And it is gone, so a finished job leaves segments and a manifest and nothing else.
        #expect(!FileManager.default.fileExists(atPath: listPath.path))
    }

    @Test("the join says what it produced")
    func cleanJoinReports() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        let joiner = stubbedJoiner(probe: { _ in (frames: 478, rate: "60000/1001") })
        let outcome = try joiner.join(files: [segment], output: output,
                                      expectedFrames: 478,
                                      expectedRate: rate("60000/1001"))

        #expect(outcome.isClean)
        #expect(outcome.frames == 478)
        #expect(outcome.rate == "60000/1001")
        #expect(outcome.problems.isEmpty)
        #expect(outcome.summary.contains("478 frames"))
        #expect(outcome.summary.contains("60000/1001"))
    }

    // MARK: - The checks that catch a lost boundary

    /// The one that matters. A join that drops a boundary is not an error to ffmpeg — it is a
    /// shorter file, which is a valid file.
    @Test("a join that produced fewer frames than the plan says is not clean")
    func shortJoinIsNotClean() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        let joiner = stubbedJoiner(probe: { _ in (frames: 476, rate: "60000/1001") })
        let outcome = try joiner.join(files: [segment], output: output,
                                      expectedFrames: 478,
                                      expectedRate: rate("60000/1001"))

        #expect(!outcome.isClean)
        #expect(outcome.problems.count == 1)
        #expect(outcome.problems.first?.contains("476") == true)
        #expect(outcome.problems.first?.contains("478") == true)
        #expect(outcome.problems.first?.contains("boundary") == true)
    }

    @Test("a join that produced more frames than the plan says is not clean")
    func longJoinIsNotClean() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        let joiner = stubbedJoiner(probe: { _ in (frames: 480, rate: "60000/1001") })
        let outcome = try joiner.join(files: [segment], output: output,
                                      expectedFrames: 478,
                                      expectedRate: rate("60000/1001"))
        #expect(!outcome.isClean)
        #expect(outcome.problems.first?.contains("480") == true)
    }

    /// A wrong rate is the subtler one: the frame count can be right and the film still play
    /// at the wrong speed, because a join that lost the exact rational rate re-times every
    /// frame after the first boundary.
    @Test("a join at the wrong rate is not clean")
    func wrongRateIsNotClean() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        // The whole-number rate the container would report if the timescale were lost —
        // invariant 27, one layer down.
        let joiner = stubbedJoiner(probe: { _ in (frames: 478, rate: "60/1") })
        let outcome = try joiner.join(files: [segment], output: output,
                                      expectedFrames: 478,
                                      expectedRate: rate("60000/1001"))
        #expect(!outcome.isClean)
        #expect(outcome.problems.count == 1)
        #expect(outcome.problems.first?.contains("60/1") == true)
    }

    @Test("a joined file that cannot be read back is a problem, not a crash")
    func unreadableJoinIsAProblem() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        struct Boom: Error {}
        let joiner = stubbedJoiner(probe: { _ in throw Boom() })
        let outcome = try joiner.join(files: [segment], output: output,
                                      expectedFrames: 478, expectedRate: nil)
        #expect(!outcome.isClean)
        #expect(outcome.problems.count == 1)
        #expect(outcome.problems.first?.contains("read the joined file back") == true)
    }

    @Test("a plan that states no frame count is not checked against one")
    func unstatedExpectationIsNotAFailure() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")
        let segment = directory.appendingPathComponent("000.mp4")
        FileManager.default.createFile(atPath: segment.path, contents: Data([1, 2, 3]))

        // Matroska reports `nb_frames=N/A`, and the plan is allowed to say "I do not know"
        // rather than to guess. A guess here would fail a correct join.
        let joiner = stubbedJoiner(probe: { _ in (frames: nil, rate: nil) })
        let outcome = try joiner.join(files: [segment], output: output,
                                      expectedFrames: nil, expectedRate: nil)
        #expect(outcome.isClean)
        #expect(outcome.frames == nil)
        #expect(outcome.summary.contains("an unstated frame count"))
    }

    // MARK: - Reading the result back

    /// `nb_frames` is a string when it comes out of a container — invariant 29, which has
    /// cost this project three afternoons. A parse that casts to `Int` reads nil, and every
    /// check guarding on it then passes vacuously.
    @Test("the frame count is read from the index as a string, not as a number")
    func frameCountIsAString() throws {
        let json = Data(#"{"streams":[{"nb_frames":"478","avg_frame_rate":"60000/1001"}]}"#.utf8)
        let read = try SegmentJoiner.parseVideo(json)
        #expect(read.frames == 478)
        #expect(read.rate == "60000/1001")
    }

    @Test("an unstated frame count is absent, not zero")
    func unstatedFrameCount() throws {
        let json = Data(#"{"streams":[{"nb_frames":"N/A","avg_frame_rate":"60000/1001"}]}"#.utf8)
        let read = try SegmentJoiner.parseVideo(json)
        // Zero would compare equal to nothing and pass every guard; nil is the honest answer.
        #expect(read.frames == nil)
        #expect(read.rate == "60000/1001")
    }

    @Test("a stream that states nothing at all still reports what it has")
    func sparseStream() throws {
        let json = Data(#"{"streams":[{"avg_frame_rate":"60000/1001"}]}"#.utf8)
        let read = try SegmentJoiner.parseVideo(json)
        #expect(read.frames == nil)
        #expect(read.rate == "60000/1001")
    }

    @Test("a probe with no video stream is an error rather than an empty answer")
    func noVideoStream() throws {
        let json = Data(#"{"streams":[]}"#.utf8)
        #expect(throws: MediaProbeError.self) {
            try SegmentJoiner.parseVideo(json)
        }
    }

    @Test("output that is not JSON is an error rather than an empty answer")
    func notJSON() throws {
        #expect(throws: (any Error).self) {
            try SegmentJoiner.parseVideo(Data("not json at all".utf8))
        }
    }

    // MARK: - The plan's count is the one the join is measured against

    /// Ties the joiner to the planner, so the number the join checks against is the number
    /// the segments were built to produce rather than one written out by hand here.
    @Test("the count the join checks is the plan's own output count")
    func checksAgainstThePlan() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mp4")

        let plan = try #require(SegmentPlan(sourceFrameCount: 1000,
                                            source: rate("24000/1001"),
                                            output: rate("60000/1001"),
                                            targetSourceFrames: 100))
        let files = plan.segments.map { segment -> URL in
            let url = directory.appendingPathComponent(
                JobManifest.segmentFileName(index: segment.index,
                                            of: plan.segments.count))
            FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
            return url
        }

        let joiner = stubbedJoiner(probe: { _ in
            (frames: expectedFrames(of: plan), rate: "60000/1001")
        })
        let outcome = try joiner.join(files: files, output: output,
                                      expectedFrames: plan.outputFrameCount,
                                      expectedRate: rate("60000/1001"))
        #expect(outcome.isClean)
        #expect(outcome.frames == plan.outputFrameCount)
    }
}
