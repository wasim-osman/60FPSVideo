import CoreVideo
import Foundation

/// The pipeline's output, copied into the playback queue.
///
/// ## Why it copies
///
/// Invariant 25: the pipeline releases a slot's buffers as soon as the completion returns,
/// and a display layer reads a sample **asynchronously** — it may hold a frame for a whole
/// frame interval after it was handed over. So a sink that passed the engine's buffer
/// straight through would be showing memory the pipeline is entitled to refill, and the
/// damage has a signature: a slow shot comes out almost right, a fast one badly wrong, and
/// the final interval is perfect because nothing follows it to clobber the buffers.
///
/// `AssetWriterSink` copies for the same reason, and the two now share one implementation
/// (`PixelBufferCopy`), because the interesting part is the strides rather than the copy.
///
/// ## Why it blocks
///
/// `write` is called from the engine's completion threads, and `PlaybackBuffer.push` blocks
/// while the queue is full. That is not an accident of the design — it is the mechanism.
/// Blocking here stops the completion thread, which stops the engine's depth accounting,
/// which stops the pipeline reading more source frames. That is what keeps a player's memory
/// bounded instead of rendering the film as fast as the GPU allows and queueing all of it.
///
/// A sink that must not block the engine would need an unbounded queue, and an unbounded
/// queue in a player is a memory leak with a film's runtime.
public final class DisplayFrameSink: FrameSink, @unchecked Sendable {

    private let queue: PlaybackBuffer
    private let width: Int
    private let height: Int
    private let format: FrameFormat
    private let lock = NSLock()
    private var pool: PixelBufferPool?
    private var problemList: [String] = []

    public init(queue: PlaybackBuffer, width: Int, height: Int, format: FrameFormat) {
        self.queue = queue
        self.width = width
        self.height = height
        self.format = format
    }

    /// Creates the copy pool.
    ///
    /// Sized to the queue plus a margin: a buffer is held by the queue until the presenter
    /// takes it, and by the layer until it has been shown. A pool smaller than the frames
    /// in flight would allocate rather than recycle, which is invariant 2's territory —
    /// `CVPixelBufferPoolCreatePixelBuffer` will still satisfy the request, so the symptom
    /// is not a crash but a pool that has quietly stopped being a pool.
    public func begin(_ geometry: SinkGeometry) throws {
        let created = try PixelBufferPool(width: geometry.width, height: geometry.height,
                                          format: geometry.format,
                                          capacity: queue.capacity + 8)
        lock.lock()
        pool = created
        lock.unlock()
    }

    public func write(_ buffer: CVPixelBuffer, at outputIndex: Int) {
        lock.lock()
        let pool = self.pool
        lock.unlock()

        guard let pool else {
            record("output frame \(outputIndex) arrived before the sink was started")
            return
        }

        do {
            let owned = try pool.makeBuffer()
            PixelBufferCopy.planes(from: buffer, into: owned)
            // `false` means the queue was abandoned — a seek or a stop. The frame is
            // simply not wanted, which is not a problem to report: the pipeline is about
            // to be torn down anyway.
            _ = queue.push(PlaybackBuffer.Entry(index: outputIndex, buffer: owned))
        } catch {
            record("could not copy output frame \(outputIndex): \(error)")
        }
    }

    /// No more frames are coming. The presenter drains the queue and then stops.
    public func finish() throws {
        queue.finish()
    }

    public var problems: [String] {
        lock.lock(); defer { lock.unlock() }
        return problemList
    }

    private func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }
}
