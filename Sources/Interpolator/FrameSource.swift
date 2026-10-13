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
/// Measured on the reference disc, decoding 600 frames of 4K HEVC 10-bit to raw P010 with
/// nothing consuming them: **4.40 s in software at 939% CPU** against **1.53 s through
/// VideoToolbox at 98% CPU**. Either figure is far above the ~14 source frames per second the
/// interpolator consumes — two source frames per interval at ~137 ms — so the decoder is never
/// the constraint and the pipe has room to spare.
///
/// The hardware path is the one used, and it is free: the decoded bytes are identical, MD5 for
/// MD5. See the argument list below.
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
    ///   - scale: ask ffmpeg to resize. `info` must already describe the *scaled* size —
    ///     see ``MediaInfo/scaled(toWidth:height:)`` — because the pipeline sizes every
    ///     buffer from it. Playback's downscale toggle, and the one thing that makes 4K
    ///     source material playable in real time on a machine that cannot interpolate it:
    ///     the interpolation cost is per-pixel, so a 1080p frame is a quarter of the work.
    public init(url: URL, info: MediaInfo,
                startSeconds: Double? = nil,
                frameLimit: Int? = nil,
                scale: Bool = false) throws {
        let executable = MediaProbe.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw FrameSourceError.ffmpegMissing
        }

        self.info = info
        self.frameByteSize = info.format.packedByteSize(width: info.width,
                                                        height: info.height)

        var arguments: [String] = ["-hide_banner", "-v", "error", "-nostdin"]
        // Decode in hardware. Measured on the reference disc, 600 frames of 4K HEVC 10-bit to
        // raw P010: **4.40 s using 939% CPU** without this and **1.53 s using 98% CPU** with
        // it — 2.9× faster and nine cores given back. The output is **bit-identical**
        // (MD5 `f9429dee…` both ways), so this costs nothing at all in quality; VideoToolbox's
        // decoder is exact for this stream.
        //
        // It is unconditional because ffmpeg degrades on its own: given a codec VideoToolbox
        // cannot decode it warns (`Failed setup for format videotoolbox_vld`) and decodes in
        // software anyway, exiting 0 with the full output. Measured on an MPEG-4 part 2 file,
        // which has no VideoToolbox decoder at all. So there is no fallback to write here.
        arguments += ["-hwaccel", "videotoolbox"]
        if let startSeconds, startSeconds > 0 {
            arguments += ["-ss", String(format: "%.6f", startSeconds)]
        }
        arguments += ["-i", url.path, "-map", "0:v:0"]
        // Scaling goes through ffmpeg's own filter, which is a *decode-side* conversion and
        // therefore free of the pipeline's colour-range rule (invariant 16) only because it
        // happens before the pipeline sees anything: what arrives is already the format the
        // probe says it is.
        if scale {
            arguments += ["-vf", "scale=\(info.width):\(info.height):flags=bicubic"]
        }
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
        //
        // This thread closes the handle it read, and only now. See `close()`: closing a pipe
        // from any other thread, while this one is blocked in the read, raises an Objective-C
        // exception that no `try` can catch and that kills the process.
        let handle = errorHandle
        let lock = errorLock
        Thread.detachNewThread { [weak self] in
            let data = handle.readDataToEndOfFile()
            try? handle.close()
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
                // silently ending — *unless* we are the ones who ended it. `close()`
                // stops the process wherever it happens to be, and by the arithmetic
                // above that is always mid-frame, so a short frame after a
                // deliberate stop is the stop rather than a fault in the film.
                if filled == 0 || closed {
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

    /// Stop the decoder, and let the readers finish on their own.
    ///
    /// ## The crash this no longer does
    ///
    /// This used to terminate ffmpeg and then close both pipes. Closing a pipe **while another
    /// thread is blocked reading it** does not fail that read, it *raises*: `readDataOfLength:`
    /// and `read(upToCount:)` both go through `-[NSConcreteFileHandle readDataUpToLength:error:]`,
    /// and an errno it does not recognise — `EBADF`, because the descriptor was closed under it —
    /// comes back as an `NSFileHandleOperationException`, which is an Objective-C exception and
    /// therefore not something `try` can catch. Uncaught, it takes the process with it.
    ///
    /// Measured on the real film, changing the player's resolution while paused:
    ///
    /// ```
    /// *** Terminating app due to uncaught exception 'NSFileHandleOperationException',
    ///     reason: '*** -[NSConcreteFileHandle readDataOfLength:]: unknown error'
    ///   3  Foundation  -[NSConcreteFileHandle readDataOfLength:]
    ///   4  60FPS       FFmpegFrameSource.init(url:info:startSeconds:frameLimit:scale:) closure
    /// ```
    ///
    /// Frame 4 is the **stderr drain thread** — the one started in `init` so ffmpeg's error pipe
    /// cannot fill and deadlock the decoder — sitting in `readDataToEndOfFile()` at the moment
    /// this method closed that very handle. The frame pipe has the same race against the producer
    /// thread, one stack frame away.
    ///
    /// ## The rule
    ///
    /// **A pipe is closed by the thread that reads it, and only once that reader has seen end of
    /// stream.** So this method closes nothing. It ends the process and *waits* for it: ffmpeg
    /// exiting closes both write ends, both readers see EOF, and each then closes its own handle —
    /// `finish()` for the frame pipe, the drain thread for the error pipe. Nothing is ever closed
    /// while a read is in flight, so nothing can raise.
    ///
    /// `waitUntilExit()` is what makes that a wait rather than a hope: when this returns the pipes
    /// are already at EOF, so the producer's blocked read is about to return, not about to fail.
    ///
    /// It is also why a rebuild cannot be made cheaper by skipping the wait. The alternative —
    /// close the pipes to unblock the readers — is the crash above.
    ///
    /// ## The signal, which was wrong
    ///
    /// This used to call `Process.terminate()` — SIGTERM — and then wait. **SIGTERM does not end
    /// this process, and the wait was therefore forever.** The app hung with a live ffmpeg and no
    /// way out, reproducibly, whenever a reader stopped early: changing the player's resolution
    /// wedged it, because the calibration probe reads a few frames and stops.
    ///
    /// The reason is arithmetic. A 3840×1632 P010 frame is 12,582,912 bytes and a pipe holds
    /// 64 KB, so ffmpeg is **always** part-way through a write when a reader stops — it is not an
    /// edge case, it is every case. Blocked in `write()`, it cannot reach the point in its main
    /// loop that notices the signal, and its handler has already run and set the flag it will
    /// never read.
    ///
    /// Measured against the real film, reader stopped, 0.8 s for the write to stall:
    ///
    /// ```
    ///   Process.terminate()              *** ALIVE after 3 s
    ///   raw kill(SIGTERM)                *** ALIVE after 3 s
    ///   raw kill(SIGTERM) + drain hard   *** ALIVE after 3 s   (764 MB drained past it)
    ///   raw kill(SIGKILL)                exited in 21 ms
    /// ```
    ///
    /// Draining is the interesting one: it is the obvious theory — unblock the write and the loop
    /// gets to its check — and 764 MB of frames went by without it making any difference. Sending
    /// SIGTERM twice, which in ffmpeg is documented to `exit()` straight from the handler, did not
    /// help either.
    ///
    /// The handler itself is fine. Pointed at an ffmpeg with no output pipe at all (`-f null -`,
    /// so it can never block) the same signal ends it in **43 ms, exit 255**. It is the blocked
    /// write, and only that.
    ///
    /// So the stop is SIGKILL. It is not a preference — a grace period would be paid in full every
    /// time, because every close of a live decoder is a close of a *blocked* decoder. The wait is
    /// ~20 ms and the readers still see a clean end of stream: measured, the blocked frame reader
    /// returns rather than raising, and the stderr drain returns 0 bytes and closes its own handle.
    public func close() {
        guard !closed else { return }
        closed = true
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    /// Reap the process at end of stream and report a decoder failure, if any.
    private func finish() throws {
        process.waitUntilExit()
        try? readHandle.close()
        // A stop we asked for is not a decoder failure. `close()` ends the process with a signal,
        // so the status is that signal number — and a cancelled run, or a seek taking the source
        // away, would report `ffmpeg exited 9` as though the film were broken. That is how a real
        // fault gets ignored.
        guard !closed else { return }
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
        // `try?` flattens, so this is already an `Int`: a missing or non-numeric size
        // becomes 0 rather than an optional the caller has to think about.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? Int) ?? 0
        self.frameByteSize = format.packedByteSize(width: width, height: height)
        self.totalFrames = size / frameByteSize
        self.info = MediaInfo(
            url: url, width: width, height: height, frameRate: frameRate,
            frameCount: totalFrames, duration: Double(totalFrames) / frameRate.doubleValue,
            pixelFormat: format == .p010 ? "p010le" : "nv12", format: format,
            colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
            colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
            audioTracks: [], chapterCount: 0)
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
