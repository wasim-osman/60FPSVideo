import Foundation
import Testing
@testable import Interpolator

/// The mux command, and the checks that read the result back.
///
/// Nothing here runs ffmpeg. The command is built by a function that can be read, and
/// the read-back is a parser that can be handed the shapes ffprobe really emits — which
/// is the only way to test the two cases that actually break: a container that states
/// no per-stream duration, and a stream that starts somewhere other than zero.
struct AudioMuxerTests {

    // MARK: - Scaffolding

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-muxer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let video = URL(fileURLWithPath: "/tmp/video.mp4")
    private static let source = URL(fileURLWithPath: "/tmp/source.mkv")
    private static let output = URL(fileURLWithPath: "/tmp/output.mkv")

    private func copyPlan() -> AudioMuxPolicy.Plan {
        AudioMuxPolicy.Plan(container: .mkv,
                            action: .copy(track: 1, codec: "dts", channels: 8),
                            reason: "test")
    }

    private func transcodePlan(container: AudioMuxPolicy.Container = .mp4) -> AudioMuxPolicy.Plan {
        AudioMuxPolicy.Plan(container: container,
                            action: .transcode(track: 1, from: "dts", to: "aac",
                                               channels: 8, bitRate: 640_000),
                            reason: "test")
    }

    private func request(plan: AudioMuxPolicy.Plan,
                         output: URL? = nil,
                         audioStart: Double? = nil,
                         bound: Bool = false,
                         videoSeconds: Double = 0.467133,
                         sourceChapters: Int = 0) -> MuxRequest {
        MuxRequest(video: Self.video, source: Self.source,
                   output: output ?? Self.output,
                   plan: plan, audioStart: audioStart, videoSeconds: videoSeconds,
                   boundAudio: bound, frameTolerance: 1.0 / 23.976,
                   sourceChapters: sourceChapters)
    }

    private func arguments(for plan: AudioMuxPolicy.Plan,
                           audioStart: Double? = nil,
                           bound: Bool = false,
                           videoSeconds: Double = 0.467133) -> [String] {
        AudioMuxer().arguments(for: request(plan: plan, audioStart: audioStart,
                                           bound: bound, videoSeconds: videoSeconds))
    }

    // MARK: - The frame grid

    @Test("the audio seek snaps up to the frame the picture starts on")
    func alignedStartSnapsUp() {
        // `-ss` discards frames until the requested instant, so the first frame out is
        // the first one *at or after* the request. Seeking the audio to the raw request
        // would put it up to a frame early — 41.7 ms at 23.976, on every conversion.
        let rate = FrameRate.twentyFourNTSC
        let frame = 1001.0 / 24000.0

        let aligned = AudioMuxer.alignedStart(3204.5, rate: rate)
        #expect(aligned > 3204.5, "the alignment must never land before the request")
        #expect(aligned - 3204.5 <= frame, "and never more than one frame after it")

        // On a frame boundary it must not move at all.
        #expect(abs(AudioMuxer.alignedStart(3204.0 * frame / 1.0, rate: rate)
                    - (3204.0 * frame)) < 1e-9)

        // Zero and negatives mean "no seek", not "seek to a negative frame".
        #expect(AudioMuxer.alignedStart(0, rate: rate) == 0)
        #expect(AudioMuxer.alignedStart(-5, rate: rate) == 0)
    }

    @Test("the aligned start is exactly representable at the source rate")
    func alignedStartIsExact() {
        // The whole reason the rate is a rational: `frameIndex / rate` must be exact,
        // not a decimal that drifts the phase.
        let rate = FrameRate.twentyFourNTSC
        let aligned = AudioMuxer.alignedStart(1234.567, rate: rate)
        let frames = aligned * Double(rate.numerator) / Double(rate.denominator)
        #expect(abs(frames - frames.rounded()) < 1e-9)
    }

    // MARK: - The command

    @Test("the picture is never re-encoded")
    func videoIsCopied() {
        for plan in [copyPlan(), transcodePlan()] {
            let arguments = arguments(for: plan)
            let index = arguments.firstIndex(of: "-c:v")
            #expect(index != nil, "the mux must state a video codec explicitly")
            #expect(index.map { arguments[$0 + 1] } == "copy")
        }
    }

    @Test("the chosen stream is the one that gets mapped")
    func mapsTheChosenTrack() {
        let arguments = arguments(for: copyPlan())
        let mapIndex = arguments.firstIndex(of: "-map")
        #expect(mapIndex != nil)
        // Input 0 is the finished video, input 1 is the original film.
        #expect(arguments[mapIndex! + 1] == "0:v:0")
        #expect(arguments[mapIndex! + 2] == "-map")
        #expect(arguments[mapIndex! + 3] == "1:1", "the plan's track index is the map")
    }

    @Test("a copy says copy and a transcode says how")
    func audioCodecArguments() {
        let copy = arguments(for: copyPlan())
        #expect(copy.contains("-c:a") && copy[copy.firstIndex(of: "-c:a")! + 1] == "copy")
        #expect(!copy.contains("-ac"))

        let transcode = arguments(for: transcodePlan())
        let codec = transcode.firstIndex(of: "-c:a")!
        #expect(transcode[codec + 1] == "aac")
        #expect(transcode[transcode.firstIndex(of: "-ac")! + 1] == "8")
        #expect(transcode[transcode.firstIndex(of: "-b:a")! + 1] == "640000")
    }

    @Test("the audio seek comes after the video input, so it seeks the audio")
    func seekAppliesToTheRightInput() {
        // `-ss` is an input option: it binds to the *next* `-i`. Before the first one it
        // would seek the finished video, which is already the right piece of the film.
        let arguments = arguments(for: copyPlan(), audioStart: 3204.534722)
        let seek = arguments.firstIndex(of: "-ss")!
        let videoInput = arguments.firstIndex(of: Self.video.path)!
        let sourceInput = arguments.firstIndex(of: Self.source.path)!

        #expect(seek > videoInput, "the seek must not apply to the video")
        #expect(seek < sourceInput, "the seek must apply to the source")
    }

    @Test("no seek is passed when there is nothing to seek to")
    func noSeekWhenZero() {
        #expect(!arguments(for: copyPlan()).contains("-ss"))
        #expect(!arguments(for: copyPlan(), audioStart: 0).contains("-ss"))
    }

    @Test("the audio is only bounded when the render is partial")
    func boundOnlyWhenPartial() {
        // A full conversion's score legitimately runs past the last frame of picture, so
        // cutting it would be wrong. A partial render's audio must not outlive its video.
        #expect(!arguments(for: copyPlan(), bound: false).contains("-t"))
        let bounded = arguments(for: copyPlan(), bound: true)
        let index = bounded.firstIndex(of: "-t")!
        #expect(bounded[index + 1] == "0.467133")
    }

    @Test("faststart is asked for on MP4 and not on Matroska")
    func faststartOnlyForMP4() {
        #expect(arguments(for: transcodePlan(container: .mp4)).contains("+faststart"))
        #expect(!arguments(for: copyPlan()).contains("+faststart"))
    }

    @Test("the output is the last argument, so nothing can be read as an input")
    func outputComesLast() {
        let arguments = arguments(for: copyPlan(), audioStart: 1, bound: true)
        #expect(arguments.last == Self.output.path)
        #expect(arguments.contains("-y"))
    }

    // MARK: - The picture's rebase

    @Test("a picture that starts below zero gets the audio offset to match")
    func rebaseIsCompensatedOnMatroska() {
        // The measured failure: a video input whose raw packets start at -0.250 (a
        // 6-frame HEVC reorder delay) but which presents from zero, because the MP4 it
        // came from carried the difference as an edit list. Matroska cannot carry one, so
        // ffmpeg rebases every stream by +0.250 — and the audio came out at 0.253 against
        // a picture at 0.000. Measured on the reference film, and real.
        let plan = copyPlan()
        let plain = AudioMuxer().arguments(for: request(plan: plan))
        #expect(!plain.contains("-itsoffset"), "nothing to correct when the picture starts at zero")

        let corrected = AudioMuxer().arguments(for: request(plan: plan),
                                               videoStartOffset: -0.250)
        let index = corrected.firstIndex(of: "-itsoffset")
        #expect(index != nil, "a picture starting below zero must be compensated for")
        #expect(corrected[index! + 1] == "-0.250000")
    }

    @Test("the offset is applied to the audio input, not to the picture")
    func offsetAppliesToTheAudio() {
        // `-itsoffset` is an input option like `-ss`: it binds to the next `-i`. Put it
        // before the video and it would move the picture instead, doubling the error
        // rather than cancelling it — measured: the audio went to 0.503.
        let arguments = AudioMuxer().arguments(for: request(plan: copyPlan()),
                                               videoStartOffset: -0.250)
        let offset = arguments.firstIndex(of: "-itsoffset")!
        let videoInput = arguments.firstIndex(of: Self.video.path)!
        let sourceInput = arguments.firstIndex(of: Self.source.path)!

        #expect(offset > videoInput, "the offset must not apply to the picture")
        #expect(offset < sourceInput, "the offset must apply to the source's audio")
    }

    @Test("MP4 is not given the offset, because it keeps the edit list")
    func noOffsetForMP4() {
        // The container decides. MP4 carries the edit list through, so nothing is
        // rebased — and the same offset would push the audio early by that much instead.
        // Measured: the audio went to 0.000 where it should have stayed at 0.003.
        let arguments = AudioMuxer().arguments(for: request(plan: transcodePlan(container: .mp4)),
                                               videoStartOffset: -0.250)
        #expect(!arguments.contains("-itsoffset"))
    }

    @Test("a positive or zero start needs no correction")
    func onlyNegativeNeedsCorrecting() {
        for offset in [0.0, 0.250, 1.0] {
            let arguments = AudioMuxer().arguments(for: request(plan: copyPlan()),
                                                   videoStartOffset: offset)
            #expect(!arguments.contains("-itsoffset"),
                    "only a picture starting below zero can be rebased")
        }
    }

    @Test("one function decides the correction, for the command and for the report")
    func theRuleHasOneHome() {
        // The command and the report must not be able to disagree. They did once: the
        // harness announced a correction on an MP4 mux that the argument list had skipped.
        for container in [AudioMuxPolicy.Container.mkv, .mp4] {
            for offset in [-0.250, -0.033367, 0.0, 0.250] {
                let applied = AudioMuxer.audioOffset(for: container, videoStartOffset: offset)
                let arguments = AudioMuxer().arguments(
                    for: request(plan: container == .mkv ? copyPlan()
                                                         : transcodePlan(container: .mp4)),
                    videoStartOffset: offset)
                // Whatever the rule says was applied is exactly what the command carries.
                #expect(arguments.contains("-itsoffset") == (applied < 0))
                #expect(arguments.firstIndex(of: "-itsoffset").map { arguments[$0 + 1] }
                            == (applied < 0 ? String(format: "%.6f", applied) : nil))
            }
        }
        #expect(AudioMuxer.audioOffset(for: .mkv, videoStartOffset: -0.250) == -0.250)
        #expect(AudioMuxer.audioOffset(for: .mp4, videoStartOffset: -0.250) == 0)
        #expect(AudioMuxer.audioOffset(for: .mkv, videoStartOffset: 0) == 0)
    }

    @Test("the probe takes the lowest packet time and ignores what it cannot read")
    func parseMinPTSReadsTheLowest() {
        // The real shape: reordered frames, so the first packet is not the earliest.
        let reordered = Data("-0.250000\n-0.042000\n-0.125000\n-0.208000\n".utf8)
        #expect(AudioMuxer.parseMinPTS(reordered) == -0.250)

        // A stream that starts at or after zero means no correction, which is the same
        // answer as "there is nothing here to correct for".
        #expect(AudioMuxer.parseMinPTS(Data("0.000000\n0.042000\n".utf8)) == 0)
        #expect(AudioMuxer.parseMinPTS(Data("".utf8)) == 0)

        // `N/A` must not be read as a zero. A zero is a real, aligned value, and taking
        // one from an unreadable packet would silently disable the correction.
        #expect(AudioMuxer.parseMinPTS(Data("N/A\nN/A\n".utf8)) == 0)
        #expect(AudioMuxer.parseMinPTS(Data("N/A\n-0.100000\n".utf8)) == -0.1)
    }

    // MARK: - Reading the result back

    @Test("a stream with no stated duration is not read as a missing stream")
    func absentDurationIsNotAbsentStream() throws {
        // This is Matroska's real shape: the audio stream is there, its duration is not.
        // Treating the two as the same thing reported "the audio was lost" about a file
        // that had the audio in it — invariant 29's mistake, one layer up.
        let json = """
        {"streams":[
          {"codec_type":"video","start_time":"0.000000"},
          {"codec_type":"audio","start_time":"0.000000"}
        ],"chapters":[],"format":{"duration":"1.215000"}}
        """
        let streams = try AudioMuxer.parseStreams(Data(json.utf8))

        #expect(streams.hasAudio)
        #expect(streams.audioSeconds == nil)
        // The video's duration falls back to the container's, which is the only thing
        // that knows it for this container.
        #expect(streams.videoSeconds == 1.215)
    }

    @Test("ffprobe's numbers are accepted as strings and as numbers")
    func numericFieldsInBothForms() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","start_time":"0.000000","duration":"0.467133"},
          {"codec_type":"audio","start_time":0.748,"duration":0.467}
        ],"chapters":[{"id":1},{"id":2}],"format":{"duration":"0.467133"}}
        """
        let streams = try AudioMuxer.parseStreams(Data(json.utf8))

        #expect(streams.videoSeconds == 0.467133)
        #expect(streams.audioSeconds == 0.467)
        #expect(streams.videoStart == 0)
        #expect(streams.audioStart == 0.748)
        #expect(streams.chapters == 2)
        // And the offset is the difference, which is the number that matters.
        #expect(abs((streams.offset ?? 0) - 0.748) < 1e-9)
    }

    @Test("N/A is treated as unknown rather than as zero")
    func naIsNotZero() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","start_time":"N/A","duration":"N/A"},
          {"codec_type":"audio","start_time":"0.000000","duration":"N/A"}
        ],"format":{"duration":"N/A"}}
        """
        let streams = try AudioMuxer.parseStreams(Data(json.utf8))

        // A zeroed start would read as a perfectly aligned stream, which is the one
        // answer that must not be invented.
        #expect(streams.videoStart == nil)
        #expect(streams.audioStart == 0)
        #expect(streams.offset == nil)
        #expect(streams.hasAudio)
    }

    @Test("a file with no audio stream is distinguishable from one with no duration")
    func missingAudioIsDistinguishable() throws {
        let json = """
        {"streams":[{"codec_type":"video","start_time":"0.000000","duration":"1.0"}],
         "chapters":[],"format":{"duration":"1.0"}}
        """
        let streams = try AudioMuxer.parseStreams(Data(json.utf8))
        #expect(!streams.hasAudio)
    }

    // MARK: - Muxing

    /// A muxer whose ffmpeg is a recorder and whose probe answers a fixed shape.
    ///
    /// `ffmpegPath` has to name something that really exists — `mux` refuses to run
    /// when it does not — but nothing ever executes it, because `runFFmpeg` is the
    /// recorder. `/usr/bin/true` is the cheapest such file; `/bin/true` is not one, on
    /// macOS `/bin` is a symlink into `/usr/bin` and the standalone `true` is not there.
    ///
    /// `videoMinPTS` is stubbed rather than left to its default, because the default
    /// really does run ffprobe: leaving it would make every test here shell out against a
    /// path that does not exist, and pass for the wrong reason.
    private func fakeMuxer(streams: AudioMuxer.Streams,
                           recorded: Recorder,
                           videoStartOffset: Double = 0) -> AudioMuxer {
        AudioMuxer(
            runFFmpeg: { arguments in
                recorded.store(arguments)
                // Stand in for the file ffmpeg would have written.
                let path = arguments.last!
                FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: 128))
                return ""
            },
            probeStreams: { _ in streams },
            videoMinPTS: { _ in videoStartOffset },
            ffmpegPath: { "/usr/bin/true" })
    }

    /// Runs one mux against a fixed read-back, in its own directory.
    private func run(_ name: String,
                     streams: AudioMuxer.Streams,
                     plan: AudioMuxPolicy.Plan? = nil,
                     bound: Bool = false,
                     videoSeconds: Double = 0.467133,
                     sourceChapters: Int = 0) throws -> AudioMuxer.Outcome {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = request(plan: plan ?? copyPlan(),
                            output: directory.appendingPathComponent(name),
                            bound: bound, videoSeconds: videoSeconds,
                            sourceChapters: sourceChapters)
        return try fakeMuxer(streams: streams, recorded: Recorder()).mux(built)
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []

        func store(_ arguments: [String]) {
            lock.lock(); calls.append(arguments); lock.unlock()
        }

        var value: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    @Test("a clean mux reports the command it ran and the file it wrote")
    func cleanMux() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mkv")

        let recorder = Recorder()
        let muxer = fakeMuxer(streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 0.467133, audioSeconds: 0.467,
            videoStart: 0, audioStart: 0, chapters: 20), recorded: recorder)

        let outcome = try muxer.mux(request(plan: copyPlan(), output: output))

        #expect(outcome.isClean)
        #expect(outcome.bytes == 128)
        #expect(outcome.streams?.chapters == 20)
        #expect(recorder.value.count == 1)
        // The executable leads and the output path trails, which is the only thing that
        // makes the argument list runnable as a command.
        #expect(recorder.value[0].first == "/usr/bin/true")
        #expect(recorder.value[0].last == output.path)
        #expect(recorder.value[0].contains("-c:v"))
    }

    @Test("audio that starts away from the picture is a problem, not a pass")
    func offsetIsReported() throws {
        // The measured failure: the picture at 0.748 s against audio at 0.000, which is
        // what a stream copy does when it is asked to cut. Nothing about the file looks
        // wrong — it opens, it plays, it has both streams — it is simply three quarters
        // of a second out, which is the sort of thing only a measurement catches.
        let outcome = try run("offset.mkv", streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 0.467133, audioSeconds: 1.204,
            videoStart: 0.748, audioStart: 0, chapters: 0))

        #expect(!outcome.isClean)
        #expect(outcome.problems.contains { $0.contains("away from the picture") })
        #expect(outcome.offset == -0.748)
    }

    @Test("audio that runs short of the picture is a problem")
    func shortAudioIsReported() throws {
        // A different failure from the offset: the sound is aligned but stops early.
        let outcome = try run("short.mp4", streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 600, audioSeconds: 12,
            videoStart: 0, audioStart: 0, chapters: 0),
            plan: transcodePlan(), videoSeconds: 600)

        #expect(!outcome.isClean)
        #expect(outcome.problems.contains { $0.contains("runs") && $0.contains("short") })
    }

    @Test("audio that outlives its bound is a problem on a partial render")
    func overlongAudioIsReported() throws {
        let overlong = AudioMuxer.Streams(hasAudio: true, videoSeconds: 1,
                                          audioSeconds: 90, videoStart: 0,
                                          audioStart: 0, chapters: 0)

        // A partial render must not produce a file whose soundtrack runs on past the
        // last picture. A full one is allowed to, so the same shape is not a problem
        // when nothing was bounded.
        let bounded = try run("bounded.mp4", streams: overlong,
                              plan: transcodePlan(), bound: true, videoSeconds: 1)
        #expect(bounded.problems.contains { $0.contains("was to stop") })

        let whole = try run("whole.mp4", streams: overlong,
                            plan: transcodePlan(), bound: false, videoSeconds: 1)
        #expect(whole.isClean)
    }

    @Test("audio that never arrived is an error, not a note")
    func missingAudioThrows() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.mkv")

        let muxer = fakeMuxer(streams: AudioMuxer.Streams(
            hasAudio: false, videoSeconds: 0.467133, audioSeconds: nil,
            videoStart: 0, audioStart: nil, chapters: 0), recorded: Recorder())

        // ffmpeg exiting 0 proves the command ran, not that the sound is in the file.
        // The *specific* error is asserted: expecting any throw would also pass if the
        // muxer had failed earlier, for a reason that has nothing to do with audio.
        do {
            _ = try muxer.mux(request(plan: copyPlan(), output: output))
            Issue.record("a file with no audio stream must not be accepted")
        } catch let error as AudioMuxError {
            guard case .audioMissingFromOutput = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    @Test("chapters surviving is checked on a whole film and not on a partial render")
    func chapterCheckOnlyWhenWhole() throws {
        func streams(chapters: Int) -> AudioMuxer.Streams {
            AudioMuxer.Streams(hasAudio: true, videoSeconds: 0.467133,
                               audioSeconds: 0.467, videoStart: 0, audioStart: 0,
                               chapters: chapters)
        }

        // Chapters ride along on ffmpeg's own initiative — nothing maps them, so nothing
        // would notice them going.
        let whole = try run("whole.mkv", streams: streams(chapters: 20),
                            sourceChapters: 20)
        #expect(whole.isClean, "20 in, 20 out, whole film: nothing to report")

        let lost = try run("lost.mkv", streams: streams(chapters: 0),
                           sourceChapters: 20)
        #expect(lost.problems.contains { $0.contains("chapter") })

        // A partial render legitimately keeps only the marks inside its window, so the
        // same drop is not a defect.
        let partial = try run("partial.mkv", streams: streams(chapters: 1),
                              bound: true, sourceChapters: 20)
        #expect(!partial.problems.contains { $0.contains("chapter") })
    }

    @Test("a plan with no audio action is refused rather than silently skipped")
    func emptyPlanIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let silent = AudioMuxPolicy.Plan(container: .mp4, action: .none, reason: "none")
        let muxer = fakeMuxer(streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 1, audioSeconds: 1,
            videoStart: 0, audioStart: 0), recorded: Recorder())

        // The caller is supposed to skip the mux entirely; reaching here means it
        // forgot, and a no-op would hide that.
        do {
            _ = try muxer.mux(request(plan: silent,
                                      output: directory.appendingPathComponent("x.mp4")))
            Issue.record("an empty plan must not be silently accepted")
        } catch let error as AudioMuxError {
            guard case .ffmpegFailed = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    @Test("the mux probes the picture and writes the correction into the command")
    func muxThreadsTheProbedOffset() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("rebased.mkv")

        let recorder = Recorder()
        let muxer = fakeMuxer(streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 0.467133, audioSeconds: 0.467,
            videoStart: 0, audioStart: 0), recorded: recorder, videoStartOffset: -0.250)

        let outcome = try muxer.mux(request(plan: copyPlan(), output: output))

        // A probe whose answer never reaches the command is the same as no probe at all.
        let index = recorder.value[0].firstIndex(of: "-itsoffset")
        #expect(index != nil, "the probe's answer has to reach the command")
        #expect(index.map { recorder.value[0][$0 + 1] } == "-0.250000")
        // And it is reported rather than applied silently, so a run that needed it can
        // say so — and a run that did not need it cannot claim it did.
        #expect(outcome.audioOffset == -0.250)
    }

    @Test("the container decides, so an MP4 reports no offset even when the picture is rebased")
    func mp4ReportsNoOffset() throws {
        // The harness once announced a 250 ms correction on an MP4 mux whose argument list
        // had deliberately skipped it, because the report asked "is the picture below
        // zero?" instead of "was anything offset?". The two questions have different
        // answers, and only one of them describes the file that was written.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("rebased.mp4")

        let recorder = Recorder()
        let muxer = fakeMuxer(streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 0.467133, audioSeconds: 0.467,
            videoStart: 0, audioStart: 0), recorded: recorder, videoStartOffset: -0.250)

        let outcome = try muxer.mux(request(plan: transcodePlan(container: .mp4), output: output))

        #expect(!recorder.value[0].contains("-itsoffset"))
        #expect(outcome.audioOffset == 0)
    }

    @Test("a probe that fails does not stop the mux")
    func failingProbeStillMuxes() throws {
        // The probe is a correction, not a precondition. If it cannot read the picture the
        // mux still runs without it, and the offset check downstream is what catches a
        // real desync. Refusing here would turn an unreadable header into a failed job.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("noprobe.mkv")

        let recorder = Recorder()
        let muxer = AudioMuxer(
            runFFmpeg: { arguments in
                recorder.store(arguments)
                FileManager.default.createFile(atPath: arguments.last!,
                                               contents: Data(repeating: 7, count: 64))
                return ""
            },
            probeStreams: { _ in AudioMuxer.Streams(
                hasAudio: true, videoSeconds: 0.467133, audioSeconds: 0.467,
                videoStart: 0, audioStart: 0) },
            videoMinPTS: { _ in throw AudioMuxError.ffmpegMissing },
            ffmpegPath: { "/usr/bin/true" })

        let outcome = try muxer.mux(request(plan: copyPlan(), output: output))

        #expect(!recorder.value[0].contains("-itsoffset"))
        #expect(outcome.audioOffset == 0)
        #expect(outcome.isClean)
    }

    @Test("a desync that survives the correction says so")
    func problemMentionsTheCorrection() throws {
        // Otherwise the reported number reads as the uncorrected one, and the reader
        // cannot tell a correction that was applied from one that was never tried.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("still-off.mkv")

        let muxer = fakeMuxer(streams: AudioMuxer.Streams(
            hasAudio: true, videoSeconds: 0.467133, audioSeconds: 0.467,
            videoStart: 0, audioStart: 0.253), recorded: Recorder(),
            videoStartOffset: -0.250)

        let outcome = try muxer.mux(request(plan: copyPlan(), output: output))

        #expect(!outcome.isClean)
        #expect(outcome.problems.contains { $0.contains("after offsetting") })
    }
}
