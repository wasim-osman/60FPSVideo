import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Interpolator

// MARK: - Choosing a track

/// The real disc, as the probe reports it.
///
/// Copied from `ffprobe -show_streams` on
/// `The.Fast.and.the.Furious.2001.2160p.UHD.BluRay.x265.10bit.HDR.DTS-X.7.1-LAMA.mkv`, with
/// the two audio streams exactly as they appear: DTS-HD MA + DTS:X 7.1 as the default, and an
/// AC-3 5.1 compatibility track that is **not** the default. That second track is what makes
/// the player's audio path fast, and it is the whole subject of the first test below.
private func realDiscTracks() -> [AudioTrack] {
    [AudioTrack(index: 1, codec: "dts", profile: "DTS-HD MA + DTS:X",
                channels: 8, channelLayout: "7.1", sampleRate: 48000,
                bitRate: nil, isDefault: true),
     AudioTrack(index: 2, codec: "ac3", profile: nil,
                channels: 6, channelLayout: "5.1(side)", sampleRate: 48000,
                bitRate: 384_000, isDefault: false)]
}

private func info(tracks: [AudioTrack],
                  duration: Double = 6411.456) -> MediaInfo {
    MediaInfo(url: URL(fileURLWithPath: "/films/a.mkv"),
              width: 3840, height: 1632, frameRate: .twentyFourNTSC,
              frameCount: nil, duration: duration,
              pixelFormat: "yuv420p10le", format: .p010,
              colorPrimaries: "bt2020", transferFunction: "smpte2084",
              colorSpace: "bt2020nc", colorRange: "tv",
              masteringDisplay: nil, contentLightLevel: nil,
              audioTracks: tracks, chapterCount: 19)
}

@Suite("Audio playback plan")
struct AudioPlaybackPlanTests {

    /// **The finding.** The disc's default track is DTS-HD MA, which macOS cannot decode at
    /// all. The disc also carries an AC-3 5.1 compatibility mix — the studio's own, put there
    /// for players that cannot do DTS — and `ac3` *is* in the codec set macOS opens in MP4.
    ///
    /// So the sound the user hears is a real track off the disc, copied bit for bit, prepared
    /// in **1.94 s**. The alternative was a re-encode of the 7.1 master at 4.5 s per 120 s,
    /// which is 3.6 minutes of waiting for something lossier. Choosing the non-default track
    /// is not a liberty: it is the track the disc provides for exactly this.
    @Test("the disc's compatibility track beats re-encoding the master")
    func compatibilityTrackWins() {
        let plan = AudioPlaybackPlan.choose(for: info(tracks: realDiscTracks()),
                                           containerIsPlayable: false)
        #expect(plan == .remux(track: 2, codec: "ac3"), "\(plan)")
        #expect(plan.isLossless, "a copy of a track on the disc is not a re-encode")
        // And it is the *global* stream index, not the audio-relative one.
        #expect(plan.track == 2)
    }

    /// When the disc marks a decodable track as default, that one wins — the compatibility
    /// track is a fallback, not a preference.
    @Test("a default track macOS can decode is preferred over a compatibility track")
    func defaultDecodableTrackWins() {
        let tracks = [AudioTrack(index: 1, codec: "ac3", channels: 6, isDefault: false),
                      AudioTrack(index: 2, codec: "aac", channels: 2, isDefault: true)]
        let plan = AudioPlaybackPlan.choose(for: info(tracks: tracks),
                                           containerIsPlayable: false)
        #expect(plan == .remux(track: 2, codec: "aac"), "\(plan)")
    }

    /// An MP4 that AVFoundation can already open is opened where it is. No temp file, no
    /// ffmpeg, no cache directory created for a film nobody needed to touch.
    @Test("a container AVFoundation reads is opened in place")
    func playableContainerIsOpenedDirectly() {
        let tracks = [AudioTrack(index: 1, codec: "aac", channels: 2, isDefault: true)]
        let plan = AudioPlaybackPlan.choose(for: info(tracks: tracks),
                                           containerIsPlayable: true)
        #expect(plan == .direct(track: 1, codec: "aac"), "\(plan)")
        #expect(plan.needsPreparation == false)
        #expect(plan.arguments(input: URL(fileURLWithPath: "/a.mp4"),
                               output: URL(fileURLWithPath: "/b.mp4")).isEmpty,
                "a direct plan must run nothing at all")
    }

    /// The same file in a Matroska has to be copied out first. `AVURLAsset` refuses MKV —
    /// that is the entire reason this type exists.
    @Test("the same track in Matroska has to be copied out")
    func playableCodecInMatroskaIsRemuxed() {
        let tracks = [AudioTrack(index: 1, codec: "aac", channels: 2, isDefault: true)]
        let plan = AudioPlaybackPlan.choose(for: info(tracks: tracks),
                                           containerIsPlayable: false)
        #expect(plan == .remux(track: 1, codec: "aac"), "\(plan)")
    }

    /// A DTS-only disc still plays. It is slower and lossy, and it is the difference between
    /// a player that works and a player that is silent on half the discs in existence.
    @Test("a disc with nothing macOS can decode is re-encoded rather than left silent")
    func dtsOnlyDiscIsReencoded() {
        let tracks = [AudioTrack(index: 1, codec: "dts", profile: "DTS-HD MA",
                                 channels: 6, channelLayout: "5.1", sampleRate: 48000,
                                 isDefault: true)]
        let plan = AudioPlaybackPlan.choose(for: info(tracks: tracks),
                                           containerIsPlayable: false)
        #expect(plan == .transcode(track: 1, codec: "dts", bitRate: 448_000, channels: 6),
                "\(plan)")
        #expect(plan.isLossless == false)
        #expect(plan.description.contains("re-encoded"))
    }

    /// AAC tops out at 7.1. An object-audio bed reported as twelve channels has to be brought
    /// down, and the failure of not doing it arrives as a silently truncated track rather than
    /// as an error — the encoder is handed a layout it cannot describe.
    @Test("a layout wider than AAC can carry is brought down to eight channels")
    func wideLayoutsAreNarrowed() {
        let tracks = [AudioTrack(index: 1, codec: "truehd", profile: "Dolby Atmos",
                                 channels: 12, channelLayout: "7.1.4", isDefault: true)]
        let plan = AudioPlaybackPlan.choose(for: info(tracks: tracks),
                                           containerIsPlayable: false)
        #expect(plan == .transcode(track: 1, codec: "truehd", bitRate: 640_000, channels: 8),
                "\(plan)")
    }

    @Test("a film with no audio plans nothing")
    func silentFilm() {
        let plan = AudioPlaybackPlan.choose(for: info(tracks: []), containerIsPlayable: false)
        #expect(plan == .none)
        #expect(plan.needsPreparation == false)
        #expect(plan.isLossless == false, "silence is not a copy of anything")
    }

    /// **`-map_chapters -1` is not optional.** ffmpeg carries a Matroska's chapters into MP4
    /// as a `bin_data` track, and that track is as long as the whole film — measured: a 120 s
    /// extraction from the real disc reported a duration of **5811.447 s** and `AVAsset`
    /// believed it. Every seek and every end-of-track test would have been computed against
    /// the wrong length.
    @Test("chapters are dropped, or the duration is the film's rather than the clip's")
    func chaptersAreDropped() {
        let plan = AudioPlaybackPlan.remux(track: 2, codec: "ac3")
        let arguments = plan.arguments(input: URL(fileURLWithPath: "/in.mkv"),
                                      output: URL(fileURLWithPath: "/out.mp4"))
        let chapters = arguments.firstIndex(of: "-map_chapters")
        #expect(chapters != nil, "\(arguments)")
        #expect(chapters.map { arguments[$0 + 1] } == "-1", "\(arguments)")
        // `-progress pipe:1` is what makes a transcode's bar possible at all.
        #expect(arguments.contains("-progress"), "\(arguments)")
        #expect(arguments.contains("pipe:1"), "\(arguments)")
    }

    @Test("a remux copies the stream and a transcode re-encodes it")
    func remuxCopiesAndTranscodeDoesNot() {
        let input = URL(fileURLWithPath: "/in.mkv")
        let output = URL(fileURLWithPath: "/out.mp4")
        let remux = AudioPlaybackPlan.remux(track: 2, codec: "ac3")
            .arguments(input: input, output: output)
        #expect(remux.contains("copy"), "\(remux)")
        #expect(!remux.contains("aac"), "a remux must not name an encoder: \(remux)")

        let transcode = AudioPlaybackPlan.transcode(track: 1, codec: "dts",
                                                    bitRate: 448_000, channels: 6)
            .arguments(input: input, output: output)
        #expect(transcode.contains("aac"), "\(transcode)")
        #expect(transcode.contains("448000"), "\(transcode)")
        // The stream is named by its global index, so nothing has to be counted.
        #expect(transcode.contains("0:1"), "\(transcode)")
        #expect(!transcode.contains("0:a:0"), "an audio-relative index is one more off-by-one")
    }
}

// MARK: - The cache

@Suite("Audio cache")
struct AudioCacheTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `Hasher` is seeded per process, so a cache keyed on `hashValue` would give every launch
    /// a different file name — never hitting, while filling the disk with copies of the same
    /// soundtrack. The digest is pinned to a literal so that a change to the algorithm is
    /// caught here rather than by a cache that quietly stopped working.
    @Test("the digest is the same in every process")
    func digestIsStable() {
        // The SHA-256 of the empty string, which is a published constant.
        #expect(AudioCache.digest("") == "e3b0c44298fc1c14")
        #expect(AudioCache.digest("a").count == 16)
        #expect(AudioCache.digest("a") != AudioCache.digest("b"))
        #expect(AudioCache.digest("a") == AudioCache.digest("a"))
    }

    /// A file replaced by a different cut of the same name is a different film. A cache that
    /// matched on name alone would play the old one's sound against the new one's picture —
    /// in sync for the first reel and drifting after that, which is the worst possible way for
    /// it to be wrong.
    @Test("the key covers size and modification date, not just the path")
    func keyCoversIdentity() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 100).write(to: source)

        let first = AudioCache.Key(source: source, track: 2, codec: "ac3")
        #expect(first.bytes == 100)

        try Data(repeating: 1, count: 200).write(to: source)
        let second = AudioCache.Key(source: source, track: 2, codec: "ac3")
        #expect(second.bytes == 200)
        #expect(first.fileName != second.fileName,
                "a replaced file must not reuse the old soundtrack")

        // A different track of the same file is a different entry too.
        let other = AudioCache.Key(source: source, track: 1, codec: "dts")
        #expect(other.fileName != second.fileName)
    }

    /// A process killed mid-write leaves a zero-length file. A cache that trusted the name
    /// would hand `AVPlayer` a file with no sound in it and report the film as silent.
    @Test("a zero-length cache entry is not a cache hit")
    func emptyFileIsNotAHit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 10).write(to: source)
        let cache = AudioCache(directory: directory.appendingPathComponent("audio"),
                               limit: 1_000_000)
        let key = AudioCache.Key(source: source, track: 2, codec: "ac3")

        #expect(cache.existing(for: key) == nil, "nothing has been written yet")
        try cache.store(Data(), for: key)
        #expect(cache.existing(for: key) == nil, "an empty file is not a soundtrack")
        try cache.store(Data(repeating: 7, count: 64), for: key)
        #expect(cache.existing(for: key) != nil)
    }

    /// Run *after* a successful preparation, so the file just written is never the one
    /// evicted — a cache that spent two seconds preparing something and then immediately
    /// deleted it is worse than no cache.
    @Test("trimming drops the oldest and keeps the one just written")
    func trimKeepsWhatWasJustWritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AudioCache(directory: directory, limit: 300)

        let oldest = directory.appendingPathComponent("oldest.mp4")
        let middle = directory.appendingPathComponent("middle.mp4")
        let newest = directory.appendingPathComponent("newest.mp4")
        try Data(repeating: 0, count: 200).write(to: oldest)
        try Data(repeating: 0, count: 200).write(to: middle)
        try Data(repeating: 0, count: 200).write(to: newest)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: oldest.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-200)], ofItemAtPath: middle.path)

        let removed = cache.trim(keeping: newest)
        #expect(removed >= 1)
        #expect(!FileManager.default.fileExists(atPath: oldest.path), "the oldest should go first")
        #expect(FileManager.default.fileExists(atPath: newest.path),
                "the file that was just written must survive its own trim")
    }

    @Test("clearing takes everything")
    func clear() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AudioCache(directory: directory, limit: 1_000_000)
        for name in ["a.mp4", "b.mp4"] {
            try Data(repeating: 1, count: 10)
                .write(to: directory.appendingPathComponent(name))
        }
        #expect(cache.clear() == 2)
        #expect(cache.contents().isEmpty)
    }
}

// MARK: - Extraction

@Suite("Audio extraction")
struct AudioExtractorTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a plausible output file, the way ffmpeg would.
    private func spawnWriting(_ bytes: Int = 128,
                              lines: [String] = []) -> @Sendable (AudioSpawn) throws -> String {
        { request in
            for line in lines { request.onLine(line) }
            guard let output = request.arguments.last else { return "" }
            try Data(repeating: 3, count: bytes).write(to: URL(fileURLWithPath: output))
            return ""
        }
    }

    /// The fast path, and the reason the cache exists: opening the same film twice must not
    /// prepare the sound twice.
    @Test("a cached soundtrack is reused without running anything")
    func cacheHitRunsNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 500).write(to: source)
        let cache = AudioCache(directory: directory.appendingPathComponent("audio"),
                               limit: 10_000_000)

        let counter = CallCounter()
        let extractor = AudioExtractor(spawn: { request in
            counter.bump()
            for line in ["out_time_us=1000000", "progress=continue"] { request.onLine(line) }
            try Data(repeating: 3, count: 64)
                .write(to: URL(fileURLWithPath: request.arguments.last!))
            return ""
        })

        let first = try extractor.prepare(from: source, info: info(tracks: realDiscTracks()),
                                          cache: cache)
        #expect(first.fromCache == false)
        #expect(counter.count == 1)

        let second = try extractor.prepare(from: source, info: info(tracks: realDiscTracks()),
                                           cache: cache)
        #expect(second.fromCache, "the second open must hit the cache")
        #expect(counter.count == 1, "ffmpeg must not have run again")
        #expect(second.url == first.url)
        #expect(second.bytes > 0)
    }

    /// A film AVFoundation can open needs nothing written, and in particular must not create
    /// a cache directory — a side effect on the user's disk from merely opening a file.
    @Test("a direct plan writes nothing and creates no cache directory")
    func directPlanTouchesNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mp4")
        try Data(repeating: 0, count: 500).write(to: source)
        let cacheDirectory = directory.appendingPathComponent("audio")
        let cache = AudioCache(directory: cacheDirectory, limit: 10_000_000)

        let tracks = [AudioTrack(index: 1, codec: "aac", channels: 2, isDefault: true)]
        let extractor = AudioExtractor(spawn: { _ in
            Issue.record("nothing should be run for a direct plan")
            return ""
        })
        let outcome = try extractor.prepare(from: source, info: info(tracks: tracks),
                                            cache: cache)
        #expect(outcome.plan == .direct(track: 1, codec: "aac"))
        #expect(outcome.url == source)
        #expect(outcome.fromCache)
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    @Test("a film with no audio is refused rather than played silently")
    func noAudioIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 10).write(to: source)
        let extractor = AudioExtractor(spawn: { _ in "" })
        #expect(throws: AudioExtractor.Failure.self) {
            try extractor.prepare(from: source, info: info(tracks: []))
        }
    }

    /// Progress is a fraction of the **film's** length, and the film's length comes from the
    /// probe rather than from `AVAsset` — because the file being prepared is the source, which
    /// AVFoundation cannot open. That is the entire reason this type exists.
    @Test("progress is a fraction of the film's length")
    func progressIsAFractionOfTheFilm() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 500).write(to: source)

        let seen = DoubleBox()
        let extractor = AudioExtractor(spawn: spawnWriting(
            lines: ["out_time_us=1602789000",   // a quarter of 6411.456 s
                    "frame=12",
                    "progress=continue",
                    "out_time=01:46:51.456000", // the whole film
                    "progress=end"]))
        let outcome = try extractor.prepare(
            from: source, info: info(tracks: realDiscTracks()),
            cache: AudioCache(directory: directory.appendingPathComponent("audio"),
                              limit: 10_000_000),
            progress: { seen.append($0) })

        let values = seen.values
        #expect(values.count == 2, "only the two time lines carry a position: \(values)")
        #expect(abs(values[0] - 0.25) < 0.001, "\(values)")
        #expect(abs(values[1] - 1.0) < 0.001, "\(values)")
        #expect(outcome.plan == .remux(track: 2, codec: "ac3"))
    }

    /// `out_time_ms` also exists and is **not** milliseconds — it is microseconds, despite the
    /// name. Reading it as milliseconds makes the bar finish a thousand times too early, which
    /// is why it is not read at all. Lines that are not a time must not reset the bar either:
    /// the report is interleaved with `frame=`, `bitrate=`, `speed=` and `progress=`, several
    /// times a second.
    @Test("only the time lines are read, and only in microseconds")
    func progressParsing() {
        #expect(AudioExtractor.progressSeconds(from: "out_time_us=1500000") == 1.5)
        #expect(AudioExtractor.progressSeconds(from: "out_time=00:01:02.500000") == 62.5)
        #expect(AudioExtractor.progressSeconds(from: "out_time=01:46:51.456000")
                .map { abs($0 - 6411.456) < 0.001 } == true)
        // Not read, on purpose.
        #expect(AudioExtractor.progressSeconds(from: "out_time_ms=1500000") == nil)
        // Not times.
        for line in ["frame=12", "fps=0", "bitrate=N/A", "speed=1.02x",
                     "progress=continue", "progress=end", "", "=5", "out_time_us="] {
            #expect(AudioExtractor.progressSeconds(from: line) == nil, "\(line)")
        }
    }

    /// A partial file from a failed or cancelled run must not be mistaken for a finished one.
    /// This is the same discipline the batch converter's staging file exists for.
    @Test("a failed conversion leaves nothing behind")
    func failureLeavesNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 500).write(to: source)
        let cacheDirectory = directory.appendingPathComponent("audio")

        let extractor = AudioExtractor(spawn: { request in
            // A child that dies halfway: it writes something, then fails.
            try? Data(repeating: 3, count: 64)
                .write(to: URL(fileURLWithPath: request.arguments.last!))
            throw AudioExtractor.Failure.conversionFailed("ffmpeg exited 1")
        })
        #expect(throws: AudioExtractor.Failure.self) {
            try extractor.prepare(from: source, info: info(tracks: realDiscTracks()),
                                  cache: AudioCache(directory: cacheDirectory,
                                                    limit: 10_000_000))
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirectory.path)) ?? []
        #expect(leftovers.isEmpty, "a half-written soundtrack was left behind: \(leftovers)")
    }

    @Test("a cancelled conversion throws and leaves nothing behind")
    func cancellationLeavesNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 500).write(to: source)
        let cacheDirectory = directory.appendingPathComponent("audio")

        let cancelled = Flag()
        let extractor = AudioExtractor(spawn: { request in
            try? Data(repeating: 3, count: 64)
                .write(to: URL(fileURLWithPath: request.arguments.last!))
            cancelled.set()
            return ""
        })
        #expect(throws: AudioExtractor.Failure.self) {
            try extractor.prepare(from: source, info: info(tracks: realDiscTracks()),
                                  cache: AudioCache(directory: cacheDirectory,
                                                    limit: 10_000_000),
                                  isCancelled: { cancelled.value })
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirectory.path)) ?? []
        #expect(leftovers.isEmpty, "a cancelled run left \(leftovers)")
    }

    /// A child that exits cleanly having written nothing is the failure mode that a
    /// `terminationStatus == 0` check alone would pass: `AVPlayer` would be handed an empty
    /// file and the film would play silent, with nothing anywhere reporting a problem.
    @Test("a clean exit with an empty file is refused")
    func emptyOutputIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 500).write(to: source)

        let extractor = AudioExtractor(spawn: { request in
            FileManager.default.createFile(atPath: request.arguments.last!, contents: Data())
            return ""
        })
        #expect(throws: AudioExtractor.Failure.self) {
            try extractor.prepare(from: source, info: info(tracks: realDiscTracks()),
                                  cache: AudioCache(
                                    directory: directory.appendingPathComponent("audio"),
                                    limit: 10_000_000))
        }
    }

    /// The child writes to a sibling and it is renamed only once it has exited cleanly, so a
    /// crash mid-run cannot leave something at the name the cache trusts.
    @Test("the partial file is renamed into place and not left behind")
    func partialIsRenamed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("film.mkv")
        try Data(repeating: 0, count: 500).write(to: source)
        let cacheDirectory = directory.appendingPathComponent("audio")

        let written = TextBox()
        let extractor = AudioExtractor(spawn: { request in
            written.store(request.arguments.last ?? "")
            try Data(repeating: 3, count: 64)
                .write(to: URL(fileURLWithPath: request.arguments.last!))
            return ""
        })
        let outcome = try extractor.prepare(from: source, info: info(tracks: realDiscTracks()),
                                            cache: AudioCache(directory: cacheDirectory,
                                                              limit: 10_000_000))
        #expect(written.value.hasSuffix(".partial"),
                "the child must write to a sibling: \(written.value)")
        #expect(outcome.url.lastPathComponent.hasSuffix(".partial") == false)
        #expect(FileManager.default.fileExists(atPath: outcome.url.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirectory.path))?.filter { $0.hasSuffix(".partial") } ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
    }
}

// MARK: - The sound as the clock

/// A sound that the test moves by hand.
///
/// The point of the seam: a clock driven by real audio cannot be tested, because the test
/// cannot make the hardware play faster. Everything that can be wrong about the arithmetic —
/// a pause that loses the fraction in flight, a seek that adds the distance seeked to the
/// playhead — is reachable here, deterministically.
final class FakeSound: AudioTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var position = 0.0
    private var playing = false
    private var speedValue = 1.0
    private var seekList: [Double] = []

    var mediaTime: Double { lock.lock(); defer { lock.unlock() }; return position }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }

    func play() { lock.lock(); playing = true; lock.unlock() }
    func pause() { lock.lock(); playing = false; lock.unlock() }
    func seek(to seconds: Double) {
        lock.lock(); position = seconds; seekList.append(seconds); lock.unlock()
    }
    func setSpeed(_ speed: Double) { lock.lock(); speedValue = speed; lock.unlock() }

    /// The audio hardware moving the sound on.
    func advance(_ seconds: Double) { lock.lock(); position += seconds; lock.unlock() }
    var seeks: [Double] { lock.lock(); defer { lock.unlock() }; return seekList }
    var speed: Double { lock.lock(); defer { lock.unlock() }; return speedValue }
}

@Suite("The sound is the clock")
struct SoundClockTests {

    /// A compressed stream cannot be retimed, so the sound plays at its own rate and the
    /// picture follows it. That makes the sound's position the *definition* of where the film
    /// is — not a convenience reading of it.
    @Test("media time is the sound's position, not the wall clock's")
    func clockFollowsTheSound() {
        let sound = FakeSound()
        let clock = PlaybackClock(timeSource: { sound.mediaTime })
        sound.play()
        clock.play()

        sound.advance(10)
        #expect(clock.mediaTime == 10)
        sound.advance(2.5)
        #expect(clock.mediaTime == 12.5)

        // Paused, the hardware stops and the picture stops with it.
        clock.pause()
        sound.pause()
        sound.advance(100)
        #expect(clock.mediaTime == 12.5,
                "a paused clock must hold its position whatever the sound does")
    }

    /// The trap this order exists for. The sound has to be moved **before** the clock is
    /// re-anchored, because the anchor records the sound's position: anchoring first and
    /// moving the sound afterwards makes the playhead gain the whole distance seeked, and the
    /// picture then races through the gap to catch up — which looks like a stutter and is
    /// really arithmetic.
    @Test("a seek re-anchors against the sound's new position")
    func seekReanchorsAgainstTheSound() {
        let sound = FakeSound()
        let clock = PlaybackClock(timeSource: { sound.mediaTime })
        sound.play()
        clock.play()
        sound.advance(10)
        #expect(clock.mediaTime == 10)

        // The order `PlaybackController.seek` uses: the sound first, then the clock.
        sound.seek(to: 500)
        clock.seek(to: 500)
        sound.advance(1)
        #expect(clock.mediaTime == 501,
                "a seek must not add the distance seeked to the playhead")
    }

    @Test("anchoring before the sound moves is what the order avoids")
    func theWrongOrderIsWrong() {
        let sound = FakeSound()
        let clock = PlaybackClock(timeSource: { sound.mediaTime })
        sound.play()
        clock.play()
        sound.advance(10)

        // Deliberately the wrong way round: the anchor is taken while the sound is still at
        // 10, and only then is the sound moved to 500.
        clock.seek(to: 500)
        sound.seek(to: 500)
        sound.advance(1)
        // 500 + (501 - 10) — the playhead has gained the distance seeked.
        #expect(clock.mediaTime == 991,
                "this is the bug the other order exists to prevent: \(clock.mediaTime)")
    }

    /// The speed lives in the sound, not in the clock. The clock multiplies the elapsed host
    /// time by its own rate, and its host time here is *already* media time — so a 2x sound
    /// with a 2x clock would advance the film at 4x.
    @Test("the clock's rate stays 1 because the sound carries the speed")
    func speedLivesInTheSound() {
        let sound = FakeSound()
        let clock = PlaybackClock(timeSource: { sound.mediaTime })
        sound.play()
        clock.play()
        sound.setSpeed(2)

        // Two seconds of real time, so four seconds of film, and the sound reports four.
        sound.advance(4)
        #expect(clock.mediaTime == 4)
        #expect(clock.rate == 1)
        #expect(sound.speed == 2)
    }

    /// Pressing play at the end restarts the film. With the sound as the clock that means
    /// moving the sound to the beginning **first** — the clock's play anchors media time
    /// against the sound's position, so restarting the clock while the sound was still at the
    /// end would put the playhead a whole film's length out. The test was written the other way
    /// round first and failed at `0` rather than `3`, which is the failure the ordering exists
    /// to prevent.
    @Test("restarting an ended film moves the sound back to the start")
    func restartMovesTheSound() {
        let sound = FakeSound()
        let clock = PlaybackClock(timeSource: { sound.mediaTime })
        sound.play()
        clock.play()
        sound.advance(100)
        clock.end(at: 100)
        #expect(clock.state == .ended)

        // The order `PlaybackController.restart` uses.
        sound.seek(to: 0)
        clock.play()
        #expect(clock.mediaTime == 0, "play at the end restarts")
        sound.advance(3)
        #expect(clock.mediaTime == 3)
    }
}

// MARK: - Small shared helpers

/// Counts calls, so "ffmpeg must not run again" is a testable claim.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Collects the numbers a progress callback was given.
final class DoubleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func append(_ value: Double) { lock.lock(); list.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return list }
}

/// Holds one string out of a concurrently-executing closure.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func store(_ value: String) { lock.lock(); text = value; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
