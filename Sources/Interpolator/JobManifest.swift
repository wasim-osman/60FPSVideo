import CryptoKit
import Foundation

/// The on-disk record of a segmented job: which pieces are finished, and what they were
/// rendered from.
///
/// ## Why there is a file at all
///
/// Segments exist so a crash costs one segment rather than a whole film. That only works if
/// the next run can tell what survived — and it cannot tell from the files alone. A segment
/// file that exists might be complete, or might be the first half of an `AVAssetWriter`
/// output that was interrupted. Those two are indistinguishable from the outside: a
/// truncated MP4 opens, reports fewer frames, and looks like a short film.
///
/// So the rule is **discard, not trust**. A segment counts as done only when this file says
/// so, and the entry is written *after* the segment has been finished and checked. A
/// half-written segment has no entry, is ignored, and is overwritten next run. There is no
/// "mostly done" state to get wrong.
///
/// ## The fingerprint
///
/// Resuming is only safe if the job is the same job. Without a fingerprint this would
/// happily join the first half of one conversion to the second half of another — a
/// different bit rate, a different resolution, a different rate, a different *film* — and
/// the result would play perfectly, looking like two films spliced together. The
/// fingerprint is cheap to compute and the failure it prevents is silent.
public struct JobManifest: Codable, Sendable, Equatable {

    // MARK: - What the segments were rendered from

    /// The inputs a job's segments were rendered from, recorded so a resume can refuse to
    /// mix two different jobs.
    public struct Fingerprint: Codable, Sendable, Equatable {
        public let sourcePath: String
        public let sourceBytes: Int64
        public let sourceModified: Double?
        /// SHA-256 of the source's first 64 KB.
        ///
        /// Size and modification time are what a build system uses and they are nearly
        /// always enough. This makes it certain rather than nearly: two different films of
        /// the same length, one of them copied, are not distinguishable from their
        /// metadata. Reading 64 KB of a file that is about to be decoded in full costs
        /// nothing measurable.
        public let sourceHead: String
        public let sourceRate: String
        public let outputRate: String
        public let width: Int
        public let height: Int
        public let format: String
        public let bitRate: Int?
        public let depth: Int
        public let sceneDetection: Bool
        /// How many intervals a segment renders. Part of the job, not a detail of it: a
        /// different length produces a different set of boundaries, and the segments from
        /// one are not the segments of the other.
        public let intervalsPerSegment: Int

        public init(sourcePath: String, sourceBytes: Int64, sourceModified: Double?,
                    sourceHead: String, sourceRate: String, outputRate: String,
                    width: Int, height: Int, format: String, bitRate: Int?,
                    depth: Int, sceneDetection: Bool, intervalsPerSegment: Int) {
            self.sourcePath = sourcePath
            self.sourceBytes = sourceBytes
            self.sourceModified = sourceModified
            self.sourceHead = sourceHead
            self.sourceRate = sourceRate
            self.outputRate = outputRate
            self.width = width
            self.height = height
            self.format = format
            self.bitRate = bitRate
            self.depth = depth
            self.sceneDetection = sceneDetection
            self.intervalsPerSegment = intervalsPerSegment
        }

        /// The first way this fingerprint differs from `other`, in words, or `nil` when
        /// they agree.
        ///
        /// One difference rather than all of them, because the caller is deciding whether
        /// to resume: the first disagreement is already decisive, and a list of eleven
        /// fields that all changed because the film changed helps nobody.
        public func difference(from other: Fingerprint) -> String? {
            if sourcePath != other.sourcePath {
                return "a different source file (\(sourcePath) against \(other.sourcePath))"
            }
            if sourceBytes != other.sourceBytes {
                return "the source is \(other.sourceBytes) bytes, not \(sourceBytes)"
            }
            if sourceHead != other.sourceHead {
                return "the source's first 64 KB have changed"
            }
            if sourceModified != other.sourceModified {
                return "the source's modification time has changed"
            }
            if sourceRate != other.sourceRate || outputRate != other.outputRate {
                return "a different rate pair (\(other.sourceRate) -> \(other.outputRate) "
                    + "against \(sourceRate) -> \(outputRate))"
            }
            if width != other.width || height != other.height {
                return "a different resolution (\(other.width)x\(other.height) against "
                    + "\(width)x\(height))"
            }
            if format != other.format {
                return "a different pixel format (\(other.format) against \(format))"
            }
            if bitRate != other.bitRate {
                return "a different bit rate (\(other.bitRate.map(String.init) ?? "default") "
                    + "against \(bitRate.map(String.init) ?? "default"))"
            }
            if depth != other.depth {
                return "a different depth (\(other.depth) against \(depth))"
            }
            if sceneDetection != other.sceneDetection {
                return "scene detection is \(other.sceneDetection ? "on" : "off") in the "
                    + "finished segments and \(sceneDetection ? "on" : "off") here"
            }
            if intervalsPerSegment != other.intervalsPerSegment {
                return "a different segment length (\(other.intervalsPerSegment) intervals "
                    + "against \(intervalsPerSegment))"
            }
            return nil
        }
    }

    // MARK: - One finished segment

    /// What a segment claims, as written down after it was finished and checked.
    public struct Entry: Codable, Sendable, Equatable {
        public let index: Int
        /// File name inside the job directory, not a path.
        public let file: String
        public let bytes: Int64
        /// Frames the sink wrote, and the number the finished container reports.
        public let frames: Int
        public let sourceStart: Int
        public let sourceCount: Int
        public let outputStart: Int
        public let outputCount: Int
        public let wallSeconds: Double

        public init(index: Int, file: String, bytes: Int64, frames: Int,
                    sourceStart: Int, sourceCount: Int,
                    outputStart: Int, outputCount: Int, wallSeconds: Double) {
            self.index = index
            self.file = file
            self.bytes = bytes
            self.frames = frames
            self.sourceStart = sourceStart
            self.sourceCount = sourceCount
            self.outputStart = outputStart
            self.outputCount = outputCount
            self.wallSeconds = wallSeconds
        }

        /// Whether this entry describes the segment `plan` has at this position.
        public func matches(_ segment: SegmentPlan.Segment) -> Bool {
            index == segment.index
                && sourceStart == segment.sourceStart
                && sourceCount == segment.sourceCount
                && outputStart == segment.outputStart
                && outputCount == segment.outputCount
        }
    }

    // MARK: - The file

    public static let currentVersion = 1
    public static let fileName = "manifest.json"
    /// How much of the source is hashed into the fingerprint.
    static let headProbeBytes = 64 * 1024

    public var version: Int
    public var fingerprint: Fingerprint
    /// Finished segments, in the order they were recorded. Not necessarily contiguous —
    /// that is the point.
    public var segments: [Entry]

    public init(fingerprint: Fingerprint) {
        self.version = Self.currentVersion
        self.fingerprint = fingerprint
        self.segments = []
    }

    // MARK: - Reading and writing

    /// The directory a job's segments and manifest live in, beside the output.
    ///
    /// Beside rather than in a cache directory, so a crashed job leaves something obviously
    /// unfinished next to the file the user asked for, and so the join is a rename inside
    /// one volume.
    public static func directory(beside output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(output.lastPathComponent + ".segments")
    }

    /// The name of a segment's file.
    ///
    /// Zero-padded to a width that makes lexical order the same as numeric order, because
    /// the concat list is read in the order it is written and `10` sorts before `9`
    /// otherwise.
    public static func segmentFileName(index: Int, of count: Int) -> String {
        let digits = max(3, String(max(1, count)).count)
        return String(format: "%0\(digits)d.mp4", index)
    }

    /// Read a manifest. `nil` when there is not one.
    ///
    /// Throws rather than returning `nil` for a manifest that is *there but unusable*. The
    /// two are different answers — "no job to resume" and "the record of the job is
    /// damaged" — and collapsing them would make a corrupt manifest look like a fresh
    /// start, silently discarding hours of finished work without saying so.
    public static func load(from directory: URL) throws -> JobManifest? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestError.unreadable("\(error)")
        }
        let decoded: JobManifest
        do {
            decoded = try JSONDecoder().decode(JobManifest.self, from: data)
        } catch {
            throw ManifestError.unreadable("\(error)")
        }
        guard decoded.version <= currentVersion else {
            throw ManifestError.futureVersion(found: decoded.version,
                                              supported: currentVersion)
        }
        return decoded
    }

    /// Write the manifest, atomically.
    ///
    /// `Data.write(options: .atomic)` writes a temporary file in the same directory and
    /// renames it over the target, so an interrupted write leaves the previous manifest
    /// intact rather than a half-written one. That matters more here than anywhere else in
    /// the job: this file is the only record of what survived, and a corrupt one costs
    /// everything it was keeping.
    public func write(to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    // MARK: - Recording and resuming

    /// Add or replace the entry for a segment.
    ///
    /// Replace rather than append, so a segment that was re-rendered after its file went
    /// missing cannot end up recorded twice with two different sizes.
    public mutating func record(_ entry: Entry) {
        segments.removeAll { $0.index == entry.index }
        segments.append(entry)
        segments.sort { $0.index < $1.index }
    }

    public func entry(for index: Int) -> Entry? {
        segments.first { $0.index == index }
    }

    /// The segments that are already rendered and may be skipped.
    ///
    /// An entry counts only when all four of these hold, and each rules out a different
    /// way of being wrong:
    ///
    /// - the plan has a segment at that index, and the entry describes *it* — so a changed
    ///   segment length does not resume onto geometry that no longer exists;
    /// - the file the entry names is present;
    /// - it is exactly the size that was recorded, which catches a truncated or replaced
    ///   file;
    /// - and the entry says it produced the output frames the plan expects.
    ///
    /// Nothing here trusts the file's contents. That is deliberate: the entry is written
    /// only after the segment has been finished and read back, so the entry *is* the claim
    /// of completeness, and the checks above are what stop a claim outliving its file.
    public func completed(in directory: URL, plan: SegmentPlan) -> Set<Int> {
        var done: Set<Int> = []
        let manager = FileManager.default
        for segment in plan.segments {
            guard let entry = entry(for: segment.index), entry.matches(segment) else { continue }
            guard entry.frames == segment.outputCount else { continue }
            let url = directory.appendingPathComponent(entry.file)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size == entry.bytes else { continue }
            done.insert(segment.index)
        }
        return done
    }

    /// A one-line account of what the manifest holds, for a report.
    public var summary: String {
        let frames = segments.reduce(0) { $0 + $1.outputCount }
        let seconds = segments.reduce(0.0) { $0 + $1.wallSeconds }
        return "\(segments.count) finished segment\(segments.count == 1 ? "" : "s"), "
            + "\(frames) output frames, \(String(format: "%.1f", seconds)) s of work kept"
    }
}

extension JobManifest.Fingerprint {

    /// Fingerprint a source, reading only the head of it for the content hash.
    public static func of(source: URL,
                          info: MediaInfo,
                          outputRate: FrameRate,
                          bitRate: Int?,
                          depth: Int,
                          sceneDetection: Bool,
                          intervalsPerSegment: Int) -> JobManifest.Fingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        return JobManifest.Fingerprint(
            sourcePath: source.path,
            sourceBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            sourceModified: (attributes?[.modificationDate] as? Date)?
                .timeIntervalSince1970,
            sourceHead: headHash(of: source),
            sourceRate: "\(info.frameRate)",
            outputRate: "\(outputRate)",
            width: info.width,
            height: info.height,
            format: info.pixelFormat,
            bitRate: bitRate,
            depth: depth,
            sceneDetection: sceneDetection,
            intervalsPerSegment: intervalsPerSegment)
    }

    /// SHA-256 of the source's first 64 KB, or an empty string when it cannot be read.
    ///
    /// An unreadable file produces the *same* answer every time rather than a different
    /// one, so it refuses to resume instead of appearing to match. This is a resume guard,
    /// not a security boundary: nothing here is defending against an attacker who controls
    /// the file, only against a person who has pointed the job at a different film.
    static func headHash(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: JobManifest.headProbeBytes),
              !data.isEmpty else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a manifest could not be used.
public enum ManifestError: Error, CustomStringConvertible {
    case unreadable(String)
    case futureVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unreadable(let detail):
            return "the segment manifest could not be read: \(detail)"
        case .futureVersion(let found, let supported):
            return "the segment manifest is version \(found) but this build understands "
                + "\(supported); a newer version of the app wrote it"
        }
    }
}
