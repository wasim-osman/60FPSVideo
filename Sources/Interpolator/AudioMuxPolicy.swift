import Foundation

/// What to do with the audio, as a value rather than as a flag.
///
/// ## Why this is a type and not two booleans
///
/// The same reason ``OutputRatePolicy`` is one. A container and a codec are not
/// independent knobs — which codec is even *possible* depends on the container, and
/// whether the result is bit-perfect depends on both. Passing `container: .mp4` and
/// `copy: true` separately lets a caller ask for something that cannot exist, and the
/// failure arrives as a file that opens and has no sound. A policy is a value that
/// already knows which combinations are real.
///
/// ## What was measured, and what it changed
///
/// The disc's main track is **DTS-HD MA + DTS:X 7.1** (stream 1) and it also carries
/// an **AC-3 5.1** compatibility track (stream 2). Three facts were established by
/// running ffmpeg rather than by reasoning:
///
/// 1. **`-c:a copy` of DTS into MP4 succeeds.** ffmpeg writes it, reports only
///    `codec frame size is not set`, and produces a 1.7 MB file. The original
///    justification for this project's codec list — "DTS cannot be copied into MP4 at
///    all" — was **wrong**. The real problem is worse: **macOS cannot open the
///    result** (`AudioFileOpenURL failed`). The container's codec registry, not
///    ffmpeg, is what refuses, and it refuses silently.
/// 2. **AC-3 5.1 copies into MP4 and macOS opens it.** Bit-perfect, no re-encode.
/// 3. **AAC 7.1 is real.** ffmpeg's native `aac` encoder produces a genuine
///    8-channel 7.1 track from the DTS source at ~636 kbps delivered for a 640 kbps
///    request, and macOS opens that too.
///
/// So the default is *not* "copy when possible", which would have quietly downgraded
/// a 7.1 master to a 5.1 compatibility track on every conversion. It is **keep the
/// best track, then copy it if the container takes it and transcode it if not** —
/// which on this disc means AAC 7.1 in MP4 and the untouched DTS-HD MA in MKV.
public struct AudioMuxPolicy: Sendable, Hashable, CustomStringConvertible {

    /// The container the muxed file goes into.
    public enum Container: String, Sendable, Hashable, CaseIterable {
        case mp4
        case mkv

        public var fileExtension: String {
            switch self {
            case .mp4: "mp4"
            case .mkv: "mkv"
            }
        }

        /// Audio codecs this container can carry *and* a player can read back.
        ///
        /// The list is stated here rather than delegated to ffmpeg, because ffmpeg
        /// will write a codec the container does not define and the resulting file is
        /// then unopenable rather than refused. See ``MediaInfo/audioPassThroughCodecs``.
        public var audioCodecs: Set<String> {
            switch self {
            case .mp4: MediaInfo.audioPassThroughCodecs
            case .mkv: MediaInfo.matroskaAudioCodecs
            }
        }

        public var label: String {
            switch self {
            case .mp4: "MP4"
            case .mkv: "Matroska"
            }
        }
    }

    /// What may happen to the chosen track.
    public enum Handling: String, Sendable, Hashable, CaseIterable {
        /// Keep the best track; copy it if the container takes it, transcode if not.
        case automatic
        /// Never re-encode. Refuse — loudly, before the job starts — if the container
        /// cannot carry the track. This is the "I want the master, byte for byte" mode.
        case copy
        /// Always re-encode. For a uniform output, or to change the channel count.
        case transcode
        /// Leave the audio out, and say so in the report.
        ///
        /// It exists because the alternative is a caller who *forgets* to mux and gets
        /// silence without being told. Asking for silence is fine; getting it by
        /// accident is not.
        case drop
    }

    public var container: Container
    public var handling: Handling

    /// Transcode target codec. Only consulted for ``Handling/transcode`` and for the
    /// transcode half of ``Handling/automatic``.
    public var codec: String
    /// Transcode target channel count. `nil` keeps the source's.
    public var channels: Int?
    /// Transcode target bit rate. `nil` derives one from the channel count.
    public var bitRate: Int?

    public init(container: Container,
                handling: Handling = .automatic,
                codec: String = "aac",
                channels: Int? = nil,
                bitRate: Int? = nil) {
        self.container = container
        self.handling = handling
        self.codec = codec
        self.channels = channels
        self.bitRate = bitRate
    }

    // MARK: - Presets

    /// MP4, keeping the best track: transcode to AAC when the container cannot carry it.
    public static let mp4 = AudioMuxPolicy(container: .mp4)
    /// Matroska, keeping the best track: on a BluRay source this is a bit-perfect copy.
    public static let mkv = AudioMuxPolicy(container: .mkv)
    public static let `default` = AudioMuxPolicy.mp4
    public static let all: [AudioMuxPolicy] = [.mp4, .mkv]

    /// `mp4`, `mkv`, or `mp4-copy` / `mkv-transcode` / `mp4-drop`.
    ///
    /// Never indexes an empty split: `"".split(separator:)` is `[]`, and this is fed
    /// straight from a command line, so `parts[0]` is a crash waiting for someone to
    /// type `--container ""`.
    public static func named(_ name: String) -> AudioMuxPolicy? {
        let parts = name.lowercased().split(separator: "-", maxSplits: 1)
        guard let first = parts.first,
              let container = Container(rawValue: String(first)) else { return nil }
        guard parts.count == 2 else { return AudioMuxPolicy(container: container) }
        guard let handling = Handling(rawValue: String(parts[1])) else { return nil }
        return AudioMuxPolicy(container: container, handling: handling)
    }

    /// The policy an output path implies, when the caller did not name one.
    ///
    /// `out.mkv` asks for Matroska by writing it, and Matroska is the container that
    /// can hold the disc's own audio — so honouring the extension means
    /// `--convert film.mkv film.mkv` is a bit-perfect audio copy rather than a
    /// transcode the user never asked for.
    public static func forOutput(_ url: URL) -> AudioMuxPolicy {
        url.pathExtension.lowercased() == "mkv" ? .mkv : .mp4
    }

    public var label: String {
        let base = "\(container.fileExtension) \(handling.rawValue)"
        return handling == .automatic ? "\(container.fileExtension) (auto)" : base
    }

    public var description: String {
        "\(container.label), audio \(handling.rawValue)"
            + (handling == .drop ? "" : " (\(codec))")
    }

    /// A sensible bit rate for a channel count.
    ///
    /// Derived rather than a constant: 640 kbps on a stereo track is waste and 192 on
    /// 7.1 is audibly lossy. Unlike the *video* encoder — which undershoots by up to
    /// 28% on dark content — ffmpeg's AAC encoder lands close to its target: a
    /// 640 kbps request on the reference disc's 7.1 track delivered 636 kbps.
    public static func defaultBitRate(channels: Int) -> Int {
        switch channels {
        case ...1: 96_000
        case 2: 192_000
        case 3...4: 320_000
        case 5...6: 448_000
        default: 640_000
        }
    }

    // MARK: - The decision

    /// What will happen to the audio of `source`, decided before the job starts.
    ///
    /// Throws rather than returning an empty plan when the request cannot be honoured,
    /// because "I could not do what you asked" and "there was nothing to do" are
    /// different answers and only one of them is fine.
    ///
    /// - Parameter cutting: whether this job needs the audio cut at a point that is not
    ///   the start of the stream — a partial render, or a segment.
    ///
    ///   **A compressed stream cannot be cut anywhere but a packet boundary**, and the
    ///   boundaries are not where anyone wants them: measured on the reference disc, an
    ///   `-ss` seek that landed the picture exactly on its frame left the copied DTS
    ///   audio **0.748 s early**, because the demuxer can only seek to a keyframe and a
    ///   stream copy cannot discard the packets in between. ffmpeg then shifts the whole
    ///   output to avoid negative timestamps, so the picture ends up at 0.748 s against
    ///   audio at 0.000 — a file that begins with three quarters of a second of sound
    ///   and no picture, and whose `-t` bound is ignored too (the audio ran 1.204 s
    ///   against a 0.467 s request).
    ///
    ///   So a cut is a re-encode. That is not a limitation to work around: it is what
    ///   "cut here exactly" means. A whole-film conversion needs no cut at all, which
    ///   is why the shipping path — full length, no seek — stays bit-perfect.
    public func plan(for source: MediaInfo, cutting: Bool = false) throws -> Plan {
        let tracks = source.audioTracks

        guard !tracks.isEmpty else {
            return Plan(container: container, action: .none,
                        reason: "the source has no audio stream")
        }

        let ranked = Self.ranked(tracks)
        let best = ranked[0]

        switch handling {
        case .drop:
            return Plan(container: container, action: .none,
                        reason: "audio was deliberately left out")

        case .transcode:
            return transcodePlan(best, tracks: tracks, container: container,
                                 cutting: cutting)

        case .copy:
            guard container.audioCodecs.contains(best.codec) else {
                throw AudioMuxError.containerCannotCarry(
                    container: container.label,
                    codec: best.codec,
                    available: tracks.map(\.codec))
            }
            // Refused rather than quietly upgraded: `copy` is how a caller asks for the
            // master untouched, and re-encoding it while reporting success would be the
            // worst of both.
            guard !cutting else {
                throw AudioMuxError.cannotCutWithoutReEncoding(codec: best.codec)
            }
            return copyPlan(best, container: container)

        case .automatic:
            if container.audioCodecs.contains(best.codec) && !cutting {
                return copyPlan(best, container: container)
            }
            return transcodePlan(best, tracks: tracks, container: container,
                                 cutting: cutting)
        }
    }

    /// Best track first: most channels, then lossless over lossy, then the highest
    /// stated bit rate, then the container's own default, then source order.
    ///
    /// Channel count leads deliberately. Ranking a lossless 5.1 above a lossy 7.1
    /// would trade away a whole surround pair for fidelity the transcode is going to
    /// cost anyway, and on the reference disc it is exactly the choice on offer.
    static func ranked(_ tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.sorted { a, b in
            if a.channels != b.channels { return (a.channels ?? 0) > (b.channels ?? 0) }
            if a.isLossless != b.isLossless { return a.isLossless }
            if a.bitRate != b.bitRate { return (a.bitRate ?? 0) > (b.bitRate ?? 0) }
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.index < b.index
        }
    }

    private func copyPlan(_ track: AudioTrack, container: Container) -> Plan {
        Plan(container: container,
             action: .copy(track: track.index, codec: track.codec, channels: track.channels),
             reason: "\(track) can go into \(container.label) unchanged")
    }

    private func transcodePlan(_ track: AudioTrack,
                               tracks: [AudioTrack],
                               container: Container,
                               cutting: Bool) -> Plan {
        let channels = self.channels ?? track.channels ?? 2
        let bitRate = self.bitRate ?? AudioMuxPolicy.defaultBitRate(channels: channels)

        // Say what was passed over. Silently transcoding a 7.1 master while a 5.1
        // compatibility track sat there copyable is a decision the user should be able
        // to see and disagree with.
        var reason: String
        if cutting && container.audioCodecs.contains(track.codec) {
            reason = "\(track) could be copied whole, but this render cuts it, and a "
                + "compressed stream can only be cut at a packet boundary — so it is "
                + "re-encoded to cut it exactly"
        } else {
            reason = "\(track) cannot go into \(container.label), so it is transcoded"
        }
        if !cutting, let alternative = tracks.first(where: {
            $0.index != track.index && container.audioCodecs.contains($0.codec)
        }) {
            reason += "; the copyable \(alternative.codec.uppercased()) track was not used "
                + "because it carries fewer channels"
        }

        return Plan(container: container,
                    action: .transcode(track: track.index,
                                       from: track.codec,
                                       to: codec,
                                       channels: channels,
                                       bitRate: bitRate),
                    reason: reason)
    }
}

// MARK: - Plan

extension AudioMuxPolicy {

    /// The decision, in a form the muxer can execute and a report can print.
    public struct Plan: Sendable, Equatable, CustomStringConvertible {

        public enum Action: Sendable, Equatable {
            /// Nothing to mux — either the source is silent or silence was asked for.
            case none
            /// Stream copy. Bit-perfect, no generation loss.
            case copy(track: Int, codec: String, channels: Int?)
            /// Re-encode. Lossy, and reported as such.
            case transcode(track: Int, from: String, to: String,
                           channels: Int, bitRate: Int)

            /// The ffmpeg stream index inside the source file.
            public var trackIndex: Int? {
                switch self {
                case .none: nil
                case .copy(let track, _, _): track
                case .transcode(let track, _, _, _, _): track
                }
            }

            public var isCopy: Bool {
                if case .copy = self { return true }
                return false
            }
        }

        public let container: Container
        public let action: Action
        /// Why this action, in words — including what was passed over.
        public let reason: String

        public init(container: Container, action: Action, reason: String) {
            self.container = container
            self.action = action
            self.reason = reason
        }

        public var isSilent: Bool { action == .none }

        /// One line for a report. Never says "ok" without saying *what* happened.
        public var summary: String {
            switch action {
            case .none:
                return "none — \(reason)"
            case .copy(_, let codec, let channels):
                let layout = channels.map { "\($0) ch" } ?? "unknown channels"
                return "copied bit-perfect (\(codec.uppercased()) \(layout)) — \(reason)"
            case .transcode(_, let from, let to, let channels, let bitRate):
                return "transcoded \(from.uppercased()) -> \(to.uppercased()) "
                    + "\(channels) ch @ \(bitRate / 1000) kbps — \(reason)"
            }
        }

        public var description: String { "\(container.label): \(summary)" }
    }
}

// MARK: - Errors

public enum AudioMuxError: Error, CustomStringConvertible {
    /// `copy` was asked for and the container cannot carry the track.
    case containerCannotCarry(container: String, codec: String, available: [String])
    /// `copy` was asked for, but the job needs the audio cut.
    case cannotCutWithoutReEncoding(codec: String)
    case ffmpegMissing
    case ffmpegFailed(status: Int32, message: String)
    /// The mux reported success but the container has no audio stream.
    case audioMissingFromOutput(String)

    public var description: String {
        switch self {
        case .containerCannotCarry(let container, let codec, let available):
            return "\(container) cannot carry \(codec.uppercased()) audio; "
                + "the source has \(available.map { $0.uppercased() }.joined(separator: ", ")). "
                + "Use the automatic or transcode policy, or write Matroska."
        case .cannotCutWithoutReEncoding(let codec):
            return "copy-only was asked for, but this render cuts the audio and "
                + "\(codec.uppercased()) can only be cut at a packet boundary, which is "
                + "not where the picture starts. Use the automatic or transcode policy "
                + "for a partial render."
        case .ffmpegMissing:
            return "ffmpeg is not on PATH. The batch converter needs it to mux audio."
        case .ffmpegFailed(let status, let message):
            return "ffmpeg exited \(status) while muxing: \(message)"
        case .audioMissingFromOutput(let path):
            return "the muxed file \(path) has no audio stream, so the audio was lost"
        }
    }
}
