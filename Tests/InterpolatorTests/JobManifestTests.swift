import Foundation
import Testing
@testable import Interpolator

/// The record that makes a crash cost one segment instead of a whole film.
///
/// The thing being tested is mostly a *refusal*: every way this file could be believed when
/// it should not be is a way to join half of one job to half of another and produce a film
/// that plays perfectly and is wrong. So the tests are mostly about what must not resume.
struct JobManifestTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rate(_ text: String) -> FrameRate { FrameRate.parse(text)! }

    private func plan(frames: Int = 1000, target: Int = 100) throws -> SegmentPlan {
        try #require(SegmentPlan(sourceFrameCount: frames,
                                 source: rate("24000/1001"),
                                 output: rate("60000/1001"),
                                 targetSourceFrames: target))
    }

    private func fingerprint(intervals: Int = 100) -> JobManifest.Fingerprint {
        JobManifest.Fingerprint(sourcePath: "/tmp/film.mkv", sourceBytes: 42_000_000_000,
                                sourceModified: 1_700_000_000, sourceHead: "abc123",
                                sourceRate: "24000/1001", outputRate: "60000/1001",
                                width: 3840, height: 1632, format: "yuv420p10le",
                                bitRate: nil, depth: 2, sceneDetection: true,
                                intervalsPerSegment: intervals)
    }

    /// A manifest with an entry for every segment, and a file of the right size for each.
    private func finished(_ plan: SegmentPlan, in directory: URL,
                          bytesPerSegment: Int64 = 4096) throws -> JobManifest {
        var manifest = JobManifest(fingerprint: fingerprint())
        for segment in plan.segments {
            let name = JobManifest.segmentFileName(index: segment.index,
                                                   of: plan.segments.count)
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path,
                                           contents: Data(repeating: 3,
                                                          count: Int(bytesPerSegment)))
            manifest.record(JobManifest.Entry(
                index: segment.index, file: name, bytes: bytesPerSegment,
                frames: segment.outputCount,
                sourceStart: segment.sourceStart, sourceCount: segment.sourceCount,
                outputStart: segment.outputStart, outputCount: segment.outputCount,
                wallSeconds: 12.5))
        }
        return manifest
    }

    // MARK: - Round trip

    @Test("a manifest survives being written and read")
    func roundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        let written = try finished(plan, in: directory)
        try written.write(to: directory)

        let read = try #require(try JobManifest.load(from: directory))
        #expect(read.version == JobManifest.currentVersion)
        #expect(read.fingerprint == written.fingerprint)
        #expect(read.segments == written.segments)
        #expect(read.segments.count == plan.segments.count)
    }

    @Test("no manifest is a different answer from an unusable one")
    func absentIsNotCorrupt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Absent: there is no job to resume, and that is not an error.
        #expect(try JobManifest.load(from: directory) == nil)

        // Present but damaged: an error, because the alternative is treating a damaged
        // record of three hours of work as "nothing done yet" without saying so.
        try Data("{ not json at all".utf8)
            .write(to: directory.appendingPathComponent(JobManifest.fileName))
        #expect(throws: ManifestError.self) {
            _ = try JobManifest.load(from: directory)
        }
    }

    @Test("a manifest from a newer build is refused rather than guessed at")
    func futureVersionIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = JobManifest(fingerprint: fingerprint())
        manifest.version = JobManifest.currentVersion + 1
        try manifest.write(to: directory)

        // It might mean something this build cannot express. Reading the fields it happens
        // to recognise would be inventing an interpretation.
        do {
            _ = try JobManifest.load(from: directory)
            Issue.record("a future version must not be read as if it were this one")
        } catch let error as ManifestError {
            guard case .futureVersion(let found, let supported) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(found == JobManifest.currentVersion + 1)
            #expect(supported == JobManifest.currentVersion)
        }
    }

    @Test("the manifest is replaced, not appended to")
    func rewritingReplaces() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        let first = try finished(plan, in: directory)
        try first.write(to: directory)

        // A second write has to replace the record, or a resumed-then-rerun job would
        // accumulate a history rather than a state.
        var second = JobManifest(fingerprint: fingerprint())
        second.record(JobManifest.Entry(index: 0, file: "000.mp4", bytes: 10, frames: 249,
                                        sourceStart: 0, sourceCount: 101,
                                        outputStart: 0, outputCount: 249,
                                        wallSeconds: 1))
        try second.write(to: directory)

        let read = try #require(try JobManifest.load(from: directory))
        #expect(read.segments.count == 1)
    }

    @Test("recording the same segment twice leaves one entry, not two")
    func recordingReplaces() {
        var manifest = JobManifest(fingerprint: fingerprint())
        // A segment re-rendered after its file went missing must not be recorded twice with
        // two different sizes, or a later resume would have to choose between them.
        manifest.record(JobManifest.Entry(index: 3, file: "003.mp4", bytes: 100, frames: 10,
                                          sourceStart: 300, sourceCount: 101,
                                          outputStart: 747, outputCount: 10,
                                          wallSeconds: 1))
        manifest.record(JobManifest.Entry(index: 3, file: "003.mp4", bytes: 999, frames: 10,
                                          sourceStart: 300, sourceCount: 101,
                                          outputStart: 747, outputCount: 10,
                                          wallSeconds: 2))
        #expect(manifest.segments.count == 1)
        #expect(manifest.entry(for: 3)?.bytes == 999)
        // And entries stay in index order however they were recorded.
        manifest.record(JobManifest.Entry(index: 1, file: "001.mp4", bytes: 1, frames: 1,
                                          sourceStart: 100, sourceCount: 101,
                                          outputStart: 249, outputCount: 1,
                                          wallSeconds: 1))
        #expect(manifest.segments.map(\.index) == [1, 3])
    }

    // MARK: - What may be resumed

    @Test("a finished job resumes to everything done")
    func everythingResumes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        let manifest = try finished(plan, in: directory)
        try manifest.write(to: directory)

        let read = try #require(try JobManifest.load(from: directory))
        #expect(read.completed(in: directory, plan: plan)
                    == Set(plan.segments.map(\.index)))
    }

    @Test("a segment whose file is gone does not count as done")
    func missingFileIsNotDone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        let manifest = try finished(plan, in: directory)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(JobManifest.segmentFileName(index: 4,
                                                                            of: 10)))

        let done = manifest.completed(in: directory, plan: plan)
        #expect(!done.contains(4))
        #expect(done.count == plan.segments.count - 1)
    }

    @Test("a segment file of the wrong size does not count as done")
    func truncatedFileIsNotDone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        let manifest = try finished(plan, in: directory)
        // Truncated by something after it was written — a full disk, a copy that stopped, a
        // cleanup that got the wrong file. The manifest's size is what was recorded when the
        // segment was finished and checked, so a mismatch means the file is not that file.
        try Data(repeating: 0, count: 100).write(
            to: directory.appendingPathComponent(JobManifest.segmentFileName(index: 2, of: 10)))

        let done = manifest.completed(in: directory, plan: plan)
        #expect(!done.contains(2))
        #expect(done.contains(1))
        #expect(done.contains(3))
    }

    @Test("entries that describe a different geometry do not resume")
    func changedSegmentLengthIsNotResumed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Rendered with 100-interval segments...
        let original = try plan(target: 100)
        let manifest = try finished(original, in: directory)

        // ...and resumed with 200-interval segments. The files are there and the right
        // size, but they are not the segments this plan has. Joining them would produce a
        // film whose boundaries are at the wrong places while every individual piece looks
        // perfectly finished.
        let changed = try plan(target: 200)
        let done = manifest.completed(in: directory, plan: changed)
        #expect(done.isEmpty)
    }

    @Test("an entry whose frame count disagrees with the plan does not resume")
    func wrongFrameCountIsNotResumed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        var manifest = try finished(plan, in: directory)
        // A segment that claims to have produced a different number of output frames than
        // the plan says it should is describing a different render.
        manifest.record(JobManifest.Entry(
            index: 0, file: JobManifest.segmentFileName(index: 0, of: 10),
            bytes: 4096, frames: 999,
            sourceStart: plan.segments[0].sourceStart,
            sourceCount: plan.segments[0].sourceCount,
            outputStart: plan.segments[0].outputStart,
            outputCount: plan.segments[0].outputCount,
            wallSeconds: 1))

        let done = manifest.completed(in: directory, plan: plan)
        #expect(!done.contains(0))
        #expect(done.contains(1))
    }

    @Test("an entry for a segment the plan does not have is ignored")
    func strayEntryIsIgnored() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try plan()
        var manifest = try finished(plan, in: directory)
        manifest.record(JobManifest.Entry(index: 500, file: "500.mp4", bytes: 4096, frames: 1,
                                          sourceStart: 50_000, sourceCount: 2,
                                          outputStart: 124_999, outputCount: 1,
                                          wallSeconds: 1))
        let done = manifest.completed(in: directory, plan: plan)
        #expect(done == Set(plan.segments.map(\.index)))
    }

    // MARK: - Names

    @Test("segment file names sort the way they read")
    func fileNamesSortNumerically() {
        // The concat list is read in the order it is written, and `10.mp4` sorts before
        // `9.mp4` — so a join built from sorted names would play the film out of order.
        let names = (0..<12).map { JobManifest.segmentFileName(index: $0, of: 12) }
        #expect(names == names.sorted())
        #expect(names.first == "000.mp4")
        #expect(names.last == "011.mp4")

        // The width grows with the job, so a film with a thousand segments still sorts.
        #expect(JobManifest.segmentFileName(index: 7, of: 1200) == "0007.mp4")
        #expect(JobManifest.segmentFileName(index: 1199, of: 1200) == "1199.mp4")
    }

    @Test("the job directory sits beside the output")
    func directoryIsBesideTheOutput() {
        let output = URL(fileURLWithPath: "/Users/someone/Movies/Film.mkv")
        let directory = JobManifest.directory(beside: output)
        #expect(directory.path == "/Users/someone/Movies/Film.mkv.segments")
        // Beside, not in a cache directory: a crashed job has to leave something obviously
        // unfinished next to the file the user asked for.
        #expect(directory.deletingLastPathComponent() == output.deletingLastPathComponent())
    }

    // MARK: - The fingerprint

    @Test("a fingerprint says which field differs, not just that one does")
    func fingerprintNamesTheDifference() {
        let base = fingerprint()
        #expect(base.difference(from: base) == nil)

        // Each field that could change between two runs has to be caught. The failure this
        // prevents is joining two halves of different jobs, which plays perfectly.
        func differs(_ other: JobManifest.Fingerprint) -> String? {
            base.difference(from: other)
        }
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: "/tmp/other.mkv", sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("source file") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes + 1,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("bytes") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: "different",
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("64 KB") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: "60",
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("rate pair") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: 1920, height: 1080, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("resolution") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: "nv12",
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("pixel format") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: 45_000_000, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("bit rate") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: 3,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("depth") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: false,
            intervalsPerSegment: base.intervalsPerSegment))?.contains("scene detection") == true)
        #expect(differs(JobManifest.Fingerprint(
            sourcePath: base.sourcePath, sourceBytes: base.sourceBytes,
            sourceModified: base.sourceModified, sourceHead: base.sourceHead,
            sourceRate: base.sourceRate, outputRate: base.outputRate,
            width: base.width, height: base.height, format: base.format,
            bitRate: base.bitRate, depth: base.depth,
            sceneDetection: base.sceneDetection,
            intervalsPerSegment: 250))?.contains("segment length") == true)
    }

    @Test("the head hash tells two files of the same length apart")
    func headHashSeesContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("a.bin")
        let b = directory.appendingPathComponent("b.bin")
        try Data(repeating: 1, count: 100_000).write(to: a)
        try Data(repeating: 2, count: 100_000).write(to: b)

        let ha = JobManifest.Fingerprint.headHash(of: a)
        let hb = JobManifest.Fingerprint.headHash(of: b)
        #expect(!ha.isEmpty)
        #expect(ha != hb, "same length, different content, different hash")
        #expect(JobManifest.Fingerprint.headHash(of: a) == ha, "and it is stable")

        // A file that cannot be read gives the same answer every time, so an unreadable
        // source refuses to resume rather than appearing to match.
        let missing = directory.appendingPathComponent("nothing.bin")
        #expect(JobManifest.Fingerprint.headHash(of: missing) == "")
        #expect(JobManifest.Fingerprint.headHash(of: missing)
                    == JobManifest.Fingerprint.headHash(of: missing))
    }

    @Test("a manifest accounts for what it holds")
    func summaryCounts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try finished(try plan(), in: directory)
        let summary = manifest.summary
        #expect(summary.contains("10 finished segments"))
        #expect(summary.contains("s of work kept"))
    }
}
