import CoreVideo
import Foundation

/// What a sink is told about the job before the first frame arrives.
///
/// Passed as a struct rather than as separate arguments because the batch converter
/// needs all of it to build an `AVAssetWriter` — the colour tags, the frame rates and
/// the HDR metadata all have to be set before the first sample is appended, and they
/// all come from here.
public struct SinkGeometry: Sendable {
    public let width: Int
    public let height: Int
    public let format: FrameFormat
    public let sourceRate: FrameRate
    public let outputRate: FrameRate
    /// What the source said it was, when it said anything. `nil` for a Matroska
    /// file, which is the normal case.
    public let sourceFrameCount: Int?
    /// `nil` whenever the count is not known up front, which is always for a
    /// stream. The pipeline does not know it either — that is the point of
    /// ``IntervalPlanner``.
    public let outputFrameCount: Int?

    public init(width: Int, height: Int, format: FrameFormat,
                sourceRate: FrameRate, outputRate: FrameRate,
                sourceFrameCount: Int?, outputFrameCount: Int?) {
        self.width = width
        self.height = height
        self.format = format
        self.sourceRate = sourceRate
        self.outputRate = outputRate
        self.sourceFrameCount = sourceFrameCount
        self.outputFrameCount = outputFrameCount
    }
}

/// Where the pipeline's output frames go.
///
/// ## Threading, and why it is stated this way
///
/// `write` is called from the engine's completion threads. Completions arrive **out
/// of order** and, with `depth > 1`, concurrently. Every implementation therefore
/// has to place a frame by its own index rather than by arrival order — which is why
/// `outputIndex` is a parameter and not something the sink counts for itself.
///
/// The packed-file sink does that with `pwrite` at an explicit offset. The batch
/// converter will have to do it with an `AVAssetWriterInput` and a reorder buffer,
/// because a writer takes samples in order. Stating the contract here is what keeps
/// the second implementation from being written as if it were sequential.
public protocol FrameSink: AnyObject, Sendable {

    /// Called once, before any frame. Throwing here fails the whole run.
    func begin(_ geometry: SinkGeometry) throws

    /// Deliver one output frame at its position in the output sequence.
    ///
    /// Called concurrently and out of order. Must not throw: a sink that fails
    /// records the problem and is asked for it at the end, because there is no
    /// useful place to report an error from inside an engine completion.
    func write(_ buffer: CVPixelBuffer, at outputIndex: Int)

    /// Called once, after the last frame has been delivered. Throwing here fails
    /// the run — which is what a partially written file should do.
    func finish() throws

    /// Anything that went wrong while writing. Read after ``finish()``.
    var problems: [String] { get }
}

/// Writes packed frames at their own file offsets.
///
/// The measurement sink, and the one the harness has always used. `pwrite` at an
/// explicit offset means completions may land in any order without corrupting the
/// stream, which is exactly the contract ``FrameSink`` states.
///
/// `@unchecked Sendable` is accurate: everything mutable is behind `lock`.
public final class PackedFileSink: FrameCountingSink, @unchecked Sendable {

    private let descriptor: Int32
    private let width: Int
    private let height: Int
    private let format: FrameFormat
    private let frameSize: Int
    private let lock = NSLock()
    private var writtenCount = 0
    private var problemList: [String] = []
    /// Which indices actually landed. A hole in the output is invisible otherwise:
    /// `pwrite` past the end of a file leaves the gap as zeros and reports success,
    /// so a frame that was never written looks exactly like a frame that was written
    /// black. That is not a hypothetical — it is how the first `--pipeline` run
    /// produced two silent black frames at the tail.
    private var writtenIndices: Set<Int> = []
    /// What the pipeline said it would deliver, when it knew. Used as the authority
    /// for the output length: deriving the length from the number of writes means a
    /// single late write silently truncates a frame off the end.
    private var expectedFrames: Int?

    /// Takes an already-open descriptor. **Does not close it** — call
    /// ``closeFile()`` when the result is no longer needed.
    ///
    /// Opening is left to the caller because the harness needs the descriptor to size
    /// the file and to verify the result afterwards, which means the file has to stay
    /// open past `finish()`. `finish()` therefore flushes and truncates, and closing
    /// is a separate, later decision.
    public init(descriptor: Int32, width: Int, height: Int, format: FrameFormat = .nv12) {
        self.descriptor = descriptor
        self.width = width
        self.height = height
        self.format = format
        self.frameSize = format.packedByteSize(width: width, height: height)
    }

    public func begin(_ geometry: SinkGeometry) throws {
        lock.lock()
        expectedFrames = geometry.outputFrameCount
        lock.unlock()
    }

    public func write(_ buffer: CVPixelBuffer, at index: Int) {
        // Own staging buffer: completions run concurrently, so this must not be
        // shared between them.
        var packed = [UInt8](repeating: 0, count: frameSize)
        packed.withUnsafeMutableBytes { raw in
            format.store(buffer: buffer, into: raw.baseAddress!,
                         width: width, height: height)
        }
        let wrote = packed.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress, frameSize, off_t(index * frameSize))
        }
        lock.lock()
        if wrote == frameSize {
            writtenCount += 1
            if !writtenIndices.insert(index).inserted {
                problemList.append("output frame \(index) written twice")
            }
        } else {
            problemList.append("short write at output frame \(index): \(wrote)")
        }
        lock.unlock()
    }

    /// Set the output length, flush, and check for holes.
    ///
    /// The length comes from what the pipeline said it would deliver. Falling back
    /// to the number of writes is wrong when a write lands late: the file gets
    /// truncated one frame short and the frame that was just written is thrown away.
    /// The fallback here spans the indices actually seen instead, which can only
    /// ever be too long — and a too-long file is a reported problem, not silent data
    /// loss.
    public func finish() throws {
        lock.lock()
        let count = writtenCount
        let indices = writtenIndices
        let expected = expectedFrames ?? max(count, (indices.max() ?? -1) + 1)
        lock.unlock()

        // Every index in 0..<expected must be present, and nothing may land beyond
        // it. A gap means a frame was never delivered — and because `pwrite` leaves
        // the gap as zeros and returns success, the output looks like a black frame
        // rather than a failure. An index at or past `expected` is worse: it is a
        // frame written past the end of the plan, which the truncate below discards.
        // Both are silent without this check.
        let missing = (0..<expected).filter { !indices.contains($0) }
        let beyond = indices.filter { $0 >= expected }.sorted()
        if !missing.isEmpty || !beyond.isEmpty {
            lock.lock()
            if !missing.isEmpty {
                let preview = missing.prefix(8).map(String.init).joined(separator: ", ")
                problemList.append("output frames never written: \(preview)"
                                   + (missing.count > 8 ? " (+\(missing.count - 8) more)" : ""))
            }
            if !beyond.isEmpty {
                let preview = beyond.prefix(8).map(String.init).joined(separator: ", ")
                problemList.append("output frames written past the end of the plan: "
                                   + "\(preview)"
                                   + (beyond.count > 8 ? " (+\(beyond.count - 8) more)" : ""))
            }
            lock.unlock()
        }

        ftruncate(descriptor, off_t(expected * frameSize))
        fsync(descriptor)
    }

    public func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }

    public var written: Int {
        lock.lock(); defer { lock.unlock() }
        return writtenCount
    }

    public var problems: [String] {
        lock.lock(); defer { lock.unlock() }
        return problemList
    }

    /// Close the underlying descriptor. Separate from `finish()` because the
    /// harness still wants to read the file back to verify it.
    ///
    /// Named `closeFile` rather than `close` because an instance method of that name
    /// shadows the POSIX `close` inside the class body, which is a confusing thing
    /// to leave in a file that calls it.
    public func closeFile() {
        close(descriptor)
    }
}

/// Collects frames in memory, for tests.
///
/// Ordered by index on the way out, so a test can compare against a plan without
/// caring about completion order.
public final class MemoryFrameSink: FrameSink, @unchecked Sendable {

    private let lock = NSLock()
    private var frames: [Int: [UInt8]] = [:]
    private var problemList: [String] = []
    private var geometry: SinkGeometry?
    private let width: Int
    private let height: Int
    private let format: FrameFormat

    public init(width: Int, height: Int, format: FrameFormat) {
        self.width = width
        self.height = height
        self.format = format
    }

    public func begin(_ geometry: SinkGeometry) throws {
        lock.lock(); self.geometry = geometry; lock.unlock()
    }

    public func write(_ buffer: CVPixelBuffer, at index: Int) {
        var packed = [UInt8](repeating: 0, count: format.packedByteSize(width: width,
                                                                       height: height))
        packed.withUnsafeMutableBytes { raw in
            format.store(buffer: buffer, into: raw.baseAddress!, width: width, height: height)
        }
        lock.lock()
        if frames[index] != nil {
            problemList.append("output frame \(index) written twice")
        }
        frames[index] = packed
        lock.unlock()
    }

    public func finish() throws {}

    public var problems: [String] {
        lock.lock(); defer { lock.unlock() }
        return problemList
    }

    /// Every frame, in output order.
    public var ordered: [(index: Int, bytes: [UInt8])] {
        lock.lock(); defer { lock.unlock() }
        return frames.keys.sorted().map { ($0, frames[$0]!) }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    public func frame(at index: Int) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return frames[index]
    }

    public var receivedGeometry: SinkGeometry? {
        lock.lock(); defer { lock.unlock() }
        return geometry
    }
}
