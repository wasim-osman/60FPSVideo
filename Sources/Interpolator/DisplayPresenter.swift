import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// What the presenter needs from a display.
///
/// Narrow on purpose. `AVSampleBufferDisplayLayer` is the shipping implementation, but a
/// presenter that could only be tested by opening a window could not be tested at all — and
/// the pacing arithmetic is exactly the kind that is wrong in a way nobody notices until
/// someone watches a film.
///
/// Not `Sendable`: a display is a layer and layers belong to a thread. The presenter is the
/// one that touches it, from one thread, which is why the presenter is the thing marked
/// `@unchecked Sendable` rather than the protocol.
public protocol VideoDisplay: AnyObject {
    /// Whether the display will take another sample without unbounded queueing.
    var isReadyForMoreMediaData: Bool { get }
    /// Set when the display has hit a decode failure it cannot recover from on its own.
    var requiresFlushToResumeDecoding: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    /// Drop everything queued. Used by a seek, where the queued frames belong to a position
    /// the film is no longer at.
    func flush()
}

/// The shipping display.
///
/// `@preconcurrency` because the SDK marks `AVSampleBufferDisplayLayer` main-actor-isolated,
/// and this presenter deliberately does not run on the main actor: it blocks on the queue,
/// and a player that blocks the main thread is a player with a frozen window.
///
/// The annotation is a statement that the isolation does not apply here, and it is only true
/// because of how the presenter is built rather than because of anything the compiler can
/// see: **the presenter is the layer's only owner and calls it from exactly one thread**.
/// There is no second accessor to race with, which is what the main-actor rule exists to
/// prevent. A window controller that also drew into this layer would make the annotation a
/// lie, so it must not.
extension AVSampleBufferDisplayLayer: @preconcurrency VideoDisplay {}

/// Turns queued output frames into timed samples, and paces them.
///
/// ## Who owns the clock
///
/// The `PlaybackClock` does, and the display is a slave to it. The alternative — attaching a
/// `CMTimebase` to the layer and letting *it* schedule — is what AVPlayer does, and it means
/// two clocks that have to agree: the timebase for the picture and the media clock for
/// everything else. Keeping them in step through play, pause, rate changes and seeks is a
/// source of drift with no compensating benefit here, because this presenter has nothing
/// else to do but wait for the right moment.
///
/// So a frame is enqueued **when its time has come**, and the layer shows what it is given as
/// it is given. The pacing accuracy is therefore the presenter's scheduling accuracy, which
/// is a few milliseconds — against a frame interval of 16.7 ms.
///
/// ## The two ways a frame is thrown away
///
/// A frame that has been *superseded* is dropped: its moment has passed and a newer frame is
/// already waiting, so showing it would show the wrong picture and push everything after it
/// later still. The guard is "and a newer frame is waiting" — without it a machine that
/// cannot keep up would drop everything and show nothing, which is a black screen rather than
/// a stutter.
///
/// A frame the presenter has *already passed* is dropped too, which is what makes a seek
/// backwards or a reordered completion harmless rather than a visible rewind.
public final class DisplayPresenter: @unchecked Sendable {

    public struct Report: Sendable {
        /// Frames handed to the display.
        public let shown: Int
        /// Frames thrown away because their moment had passed.
        public let dropped: Int
        /// Total time spent waiting for frames' moments. The measure of how much of
        /// playback was the clock's doing rather than the renderer's.
        public let pacedSeconds: Double
        /// True when the run ended because the queue was abandoned — a seek or a stop —
        /// rather than because the film ended.
        public let endedByAbandon: Bool
        public let problems: [String]

        public var droppedFraction: Double {
            let total = shown + dropped
            return total == 0 ? 0 : Double(dropped) / Double(total)
        }
    }

    private let queue: PlaybackBuffer
    private let display: VideoDisplay
    private let clock: PlaybackClock
    private let pacer: PlaybackPacer
    private let outputRate: FrameRate

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var problemList: [String] = []

    public init(queue: PlaybackBuffer,
                display: VideoDisplay,
                clock: PlaybackClock,
                pacer: PlaybackPacer,
                outputRate: FrameRate) {
        self.queue = queue
        self.display = display
        self.clock = clock
        self.pacer = pacer
        self.outputRate = outputRate
    }

    /// Present until the queue is drained or abandoned. **Blocks**, so it belongs on its own
    /// thread.
    public func run() -> Report {
        var shown = 0
        var dropped = 0
        var paced = 0.0
        var lastShown = -1

        while true {
            guard let entry = queue.pop() else { break }
            if queue.wasAbandoned { break }

            // Superseded, and there is something newer to show instead.
            if queue.count > 0, pacer.isSuperseded(entry.index, at: clock.mediaTime) {
                dropped += 1
                continue
            }
            // Behind what has already been shown: a seek backwards, or a completion that
            // arrived out of order.
            if entry.index <= lastShown {
                dropped += 1
                continue
            }

            paced += waitForMoment(of: entry.index)
            if queue.wasAbandoned { break }

            // A pause can land during the wait, and so can a seek. Re-check the frame
            // against the clock rather than showing one the pause made stale.
            if queue.count > 0, pacer.isSuperseded(entry.index, at: clock.mediaTime) {
                dropped += 1
                continue
            }

            waitUntilReady()
            if queue.wasAbandoned { break }

            do {
                let description = try formatDescription(for: entry.buffer)
                let sample = try Self.sampleBuffer(imageBuffer: entry.buffer,
                                                   format: description,
                                                   index: entry.index,
                                                   rate: outputRate)
                display.enqueue(sample)
                shown += 1
                lastShown = entry.index
            } catch {
                record("could not present output frame \(entry.index): \(error)")
            }
        }

        lock.lock()
        let problems = problemList
        lock.unlock()
        return Report(shown: shown, dropped: dropped, pacedSeconds: paced,
                      endedByAbandon: queue.wasAbandoned, problems: problems)
    }

    // MARK: - Pacing

    /// Hold a frame until its own time, and report how long that took.
    ///
    /// The wait is served in short slices rather than one long sleep, so a pause or a seek
    /// is noticed within a few milliseconds instead of after a whole frame interval. The
    /// cost is a handful of wakeups per frame; the alternative is a pause that takes effect
    /// up to 16.7 ms late and a seek that feels sluggish.
    private func waitForMoment(of index: Int) -> Double {
        var waited = 0.0
        // While paused there is no moment to wait for: the playhead is not moving, so the
        // frame's time will never arrive. Wait for the clock instead.
        while !clock.isPlaying && !queue.wasAbandoned {
            usleep(2000)
        }
        while !queue.wasAbandoned, clock.isPlaying {
            let remaining = pacer.presentationTime(of: index) - clock.mediaTime
            if remaining <= 0 { break }
            let slice = min(remaining, 0.005)
            usleep(UInt32(slice * 1_000_000))
            waited += slice
        }
        return waited
    }

    /// Block until the display will take a sample.
    ///
    /// A poll rather than `requestMediaDataWhenReady(on:using:)`, because that API assumes a
    /// single serial producer and this presenter's frames come from the engine's completion
    /// threads via the queue. One millisecond is far below a frame interval, so the poll
    /// costs nothing measurable and cannot be the thing that decides when a frame appears.
    private func waitUntilReady() {
        while !display.isReadyForMoreMediaData && !queue.wasAbandoned {
            usleep(1000)
        }
        // A display that has failed to decode will refuse samples forever until it is
        // flushed. Nothing here produces a decode failure — the frames are uncompressed —
        // but a window that was closed and reopened, or a display that lost its connection
        // to a screen, arrives in this state.
        if display.requiresFlushToResumeDecoding {
            display.flush()
        }
    }

    // MARK: - Sample buffers

    private func formatDescription(for buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
        lock.lock()
        if let format = self.format { lock.unlock(); return format }
        lock.unlock()

        var created: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &created)
        guard status == noErr, let created else {
            throw InterpolatorError.writerFailed(
                "no format description for the display (\(status))")
        }
        lock.lock()
        format = created
        lock.unlock()
        return created
    }

    /// Wrap one frame for the display.
    ///
    /// The timestamp is exact rational arithmetic, like everything else in this pipeline:
    /// output frame `n` presents at `n x denominator / numerator` seconds, computed in
    /// integers. A `Double` here would be the same mistake as a decimal frame rate
    /// (invariant 14) — small, plausible, and cumulative over a feature film.
    static func sampleBuffer(imageBuffer: CVPixelBuffer,
                             format: CMVideoFormatDescription,
                             index: Int,
                             rate: FrameRate) throws -> CMSampleBuffer {
        let timescale = Int32(rate.numerator)
        let presentation = CMTime(value: Int64(index) * Int64(rate.denominator),
                                  timescale: timescale)
        let duration = CMTime(value: Int64(rate.denominator), timescale: timescale)
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: presentation,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw InterpolatorError.writerFailed("could not wrap frame \(index) (\(status))")
        }
        return sample
    }

    private func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }
}
