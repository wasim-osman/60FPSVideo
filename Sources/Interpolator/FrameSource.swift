import CoreVideo
import Foundation

/// A source of packed frames, in pipeline order.
///
/// Packed rather than `CVPixelBuffer` on purpose: the pipeline's own staging
/// buffer is packed, `FrameFormat.load` turns packed into a pixel buffer, and the
/// harness already works this way. Handing back pixel buffers would mean either
/// allocating one per frame — which crashes after 65–90 frames, invariant 2 — or
/// making the source manage a pool that the pipeline already manages.
///
/// ## Threading
///
/// `read` and `close` are called from one thread. That contract is stated by each
/// implementation's `@unchecked Sendable` rather than left implicit, in the same
/// way ``InterpolationRequest`` does.
public protocol FrameSource: AnyObject, Sendable {
    var info: MediaInfo { get }
    /// Bytes in one packed frame, from `FrameFormat.packedByteSize`.
    var frameByteSize: Int { get }
    /// Read the next frame into `destination`, which must hold `frameByteSize`
    /// bytes. Returns `false` at end of stream, which is not an error.
    func read(into destination: UnsafeMutableRawPointer) throws -> Bool
    /// Stop early and release the source. Safe to call more than once.
    func close()
}

public enum FrameSourceError: Error, CustomStringConvertible {
    case ffmpegMissing
    case couldNotLaunch(String)
    case shortRead(frame: Int, expected: Int, got: Int)
    case decoderFailed(status: Int32, message: String)

    public var description: String {
        switch self {
        case .ffmpegMissing:
            "ffmpeg is not on PATH. The pipeline needs it to decode media files."
        case .couldNotLaunch(let detail):
            "could not start ffmpeg: \(detail)"
        case .shortRead(let frame, let expected, let got):
            "short read at frame \(frame): wanted \(expected) bytes, got \(got)"
        case .decoderFailed(let status, let message):
            "ffmpeg exited \(status): \(message)"
        }
    }
}

/// Reads frames from a file ffmpeg can open, decoded to packed frames on a pipe.
///
/// This is the shipping input path. See ``MediaProbe`` for why ffmpeg rather than
/// AVFoundation — the short version is that AVFoundation cannot open Matroska, and
/// half of a film library is Matroska.
///
/// ## Why the pipe is not a bottleneck
///
/// Measured on the reference disc: 4K HEVC to raw P010 through a pipe runs at
/// **37 source frames per second**. The interpolator consumes about 14.6 — two
/// source frames per interval at ~137 ms. So decoding runs at roughly 2.5× what
/// the rest of the pipeline can absorb, and the pipe is never the constraint.
public final class FFmpegFrameSource: FrameSource, @unchecked Sendable {

    public let info: MediaInfo
    public let frameByteSize: Int

    private let process = Process()
    private let stdout: Pipe
    private let stderr: Pipe
    private var readHandle: FileHandle
    private var errorHandle: FileHandle
    private var errorText = ""
    private let errorLock = NSLock()

    private var framesRead = 0
    private var reachedEnd = false
    private var closed = false

    /// - Parameters:
    ///   - url: the media file.
    ///   - info: its probe result. Passed in rather than re-probed, so the caller
    ///     decides the format once and this cannot disagree with it.
    ///   - startSeconds: seek here first. Input seeking, so it lands on a keyframe
    ///     and is fast; the frames before the requested time are skipped.
    ///   - frameLimit: stop after this many frames. `nil` for the whole file.
    public init(url: URL, info: MediaInfo,
                startSeconds: Double? = nil,
                frameLimit: Int? = nil) throws {
        let executable = MediaProbe.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw FrameSourceError.ffmpegMissing
        }

        self.info = info
        self.frameByteSize = info.format.packedByteSize(width: info.width,
                                                        height: info.height)

        var arguments: [String] = ["-hide_banner", "-v", "error", "-nostdin"]
        if let startSeconds, startSeconds > 0 {
            arguments += ["-ss", String(format: "%.6f", startSeconds)]
        }
        arguments += ["-i", url.path, "-map", "0:v:0"]
        if let frameLimit { arguments += ["-frames:v", String(frameLimit)] }
        // The pixel format is chosen by the probe, not by ffmpeg. Asking for the
        // format the source already is means no colour conversion happens here at
        // all — invariant 16. If the caller wants a different depth than the source
        // has, that is a deliberate conversion and it happens in this one place.
        arguments += ["-pix_fmt", info.format == .p010 ? "p010le" : "nv12"]
        arguments += ["-f", "rawvideo", "-"]

        stdout = Pipe()
        stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        readHandle = stdout.fileHandleForReading
        errorHandle = stderr.fileHandleForReading

        do {
            try process.run()
        } catch {
            throw FrameSourceError.couldNotLaunch("\(error)")
        }

        // Drain stderr on its own thread. An undrained pipe fills at 64 KB and
        // blocks the writer — which would deadlock ffmpeg, and through it the whole
        // pipeline, with no visible reason.
        let handle = errorHandle
        let lock = errorLock
        Thread.detachNewThread { [weak self] in
            let data = handle.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            lock.lock()
            self?.errorText = text
            lock.unlock()
        }
    }

    /// Read the next frame. Returns `false` at end of stream.
    public func read(into destination: UnsafeMutableRawPointer) throws -> Bool {
        if reachedEnd { return false }
        var filled = 0
        while filled < frameByteSize {
            // A pipe returns what is available, not what was asked for, so a single
            // read of frameByteSize bytes is wrong in a way that only shows up on
            // large frames — exactly the 4K case.
            let chunk = try readHandle.read(upToCount: frameByteSize - filled)
            guard let chunk, !chunk.isEmpty else {
                // End of stream. A partial frame here means the file is truncated or
                // ffmpeg died mid-frame; both are worth reporting rather than
                // silently ending.
                if filled == 0 {
                    reachedEnd = true
                    try finish()
                    return false
                }
                throw FrameSourceError.shortRead(frame: framesRead,
                                                 expected: frameByteSize, got: filled)
            }
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(destination + filled, base, chunk.count)
            }
            filled += chunk.count
        }
        framesRead += 1
        return true
    }

    /// Frames handed out so far.
    public var count: Int { framesRead }

    public func close() {
        guard !closed else { return }
        closed = true
        if process.isRunning { process.terminate() }
        try? readHandle.close()
        try? errorHandle.close()
        process.waitUntilExit()
    }

    /// Reap the process at end of stream and report a decoder failure, if any.
    private func finish() throws {
        process.waitUntilExit()
        try? readHandle.close()
        guard process.terminationStatus == 0 else {
            errorLock.lock()
            let text = errorText
            errorLock.unlock()
            throw FrameSourceError.decoderFailed(status: process.terminationStatus,
                                                 message: text.isEmpty
                                                    ? "no message" : text)
        }
    }
}

/// Reads packed frames straight out of a raw file.
///
/// Used by the harness and the tests, where the frames have already been extracted
/// and re-extracting them per run would be wasteful — and where a test should not
/// depend on a decoder being installed.
public final class PackedFileFrameSource: FrameSource, @unchecked Sendable {

    public let info: MediaInfo
    public let frameByteSize: Int

    private let handle: FileHandle
    private var framesRead = 0
    private let totalFrames: Int
    private var closed = false

    /// - Parameter format: the sample width of the packed file, which the file
    ///   itself cannot state.
    public init(url: URL, width: Int, height: Int, format: FrameFormat,
                frameRate: FrameRate) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? Int) ?? 0
        self.frameByteSize = format.packedByteSize(width: width, height: height)
        self.totalFrames = (size ?? 0) / frameByteSize
        self.info = MediaInfo(
            url: url, width: width, height: height, frameRate: frameRate,
            frameCount: totalFrames, duration: Double(totalFrames) / frameRate.doubleValue,
            pixelFormat: format == .p010 ? "p010le" : "nv12", format: format,
            colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
            colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
            audioCodec: nil, audioChannels: nil)
    }

    public func read(into destination: UnsafeMutableRawPointer) throws -> Bool {
        if closed || framesRead >= totalFrames { return false }
        var filled = 0
        while filled < frameByteSize {
            guard let chunk = try handle.read(upToCount: frameByteSize - filled),
                  !chunk.isEmpty else {
                if filled == 0 { return false }
                throw FrameSourceError.shortRead(frame: framesRead,
                                                 expected: frameByteSize, got: filled)
            }
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(destination + filled, base, chunk.count)
            }
            filled += chunk.count
        }
        framesRead += 1
        return true
    }

    public var count: Int { framesRead }

    public func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
