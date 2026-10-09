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
    ///
    /// Named for what it does rather than `flush`, because `AVSampleBufferDisplayLayer.flush()`
    /// was deprecated in macOS 15 in favour of `sampleBufferRenderer.flush()` — and a protocol
    /// requirement called `flush` would be satisfied by the deprecated method, silently, with a
    /// warning the only sign of it.
    func discardQueuedFrames()
}

/// The shipping display.
///
/// ## Why this conforms to the renderer and not to the layer
///
/// The obvious target is `AVSampleBufferDisplayLayer`, and it is the wrong one twice over.
///
/// **It is main-actor isolated.** The SDK marks the class `NS_SWIFT_UI_ACTOR`, so
/// `isReadyForMoreMediaData`, `enqueue` and `flush` are all main-actor members. This presenter
/// deliberately does not run on the main actor — it blocks on the queue, and a player that
/// blocks the main thread is a player with a frozen window — so a conformance to the layer
/// needs `@preconcurrency` to compile. `@preconcurrency` silences the *compiler*, and nothing
/// else: the witness thunk Swift generates for an isolated member still asserts the executor at
/// run time. Measured, on the real film, the first time the shell ran:
///
/// ```
/// EXC_BREAKPOINT (SIGTRAP) — dispatch_assert_queue_fail
///   _checkExpectedExecutor(_filenameStart:…:executor:)
///   protocol witness for VideoDisplay.isReadyForMoreMediaData.getter
///     in conformance AVSampleBufferDisplayLayer
///   DisplayPresenter.waitUntilReady() → DisplayPresenter.run()
/// ```
///
/// A crash the compiler was told to keep quiet about is the worst kind: it compiles clean, it
/// passes every test that uses a double, and it fires on the first frame of the first real film.
///
/// **And every member of the layer is deprecated anyway.** In macOS 15 `enqueueSampleBuffer:`,
/// `flush`, `status`, `error`, `requiresFlushToResumeDecoding` and `readyForMoreMediaData` on
/// the layer are all deprecated with the same message — *use `sampleBufferRenderer`'s instead*.
/// The annotation and the deprecation are one instruction, not two: the layer is the UI object,
/// and the renderer is the part that does the work.
///
/// `AVSampleBufferVideoRenderer` is a plain `NSObject` with no actor annotation, so conforming
/// to it needs no `@preconcurrency` and no runtime assertion. The presenter holds the renderer
/// and the view holds the layer, which is exactly the split Apple's deprecation describes.
///
/// The isolation the annotation existed to protect is still the presenter's job: **it is the
/// renderer's only owner and calls it from exactly one thread.** Nothing else in this app
/// touches the renderer — not the view, not the model — which is what the main-actor rule
/// exists to guarantee, achieved by construction instead.
extension AVSampleBufferVideoRenderer: VideoDisplay {
    public func discardQueuedFrames() {
        flush()
    }
}

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
    private var shownCount = 0
    private var droppedCount = 0
    private var signalledReady = false

    /// Called once, as soon as the presenter has its first frame in hand.
    ///
    /// This is what a player waits for before starting its clock. Without it, pressing play
    /// starts the clock immediately and the film's first second passes while the decoder is
    /// still opening the file, the engine is still preparing its session and the buffer pool
    /// is still being created — measured at **1.3 s** on the real 4K film, which is a second
    /// and a third of the film lost before the first frame appears.
    ///
    /// It fires on the first frame *popped*, not the first frame shown: the first frame
    /// cannot be shown until the clock is running, so waiting for that would deadlock.
    public var onReady: (@Sendable () -> Void)?

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
        var paced = 0.0
        var lastShown = -1

        while true {
            guard let entry = queue.pop() else { break }
            if queue.wasAbandoned { break }

            // The first frame is in hand. Nothing before this point was the film's fault —
            // it was a decoder opening a file and an engine starting a session.
            if !signalledReady {
                signalledReady = true
                onReady?()
            }

            // Superseded, and there is something newer to show instead.
            if queue.count > 0, pacer.isSuperseded(entry.index, at: clock.mediaTime) {
                countDropped()
                continue
            }
            // Behind what has already been shown: a seek backwards, or a completion that
            // arrived out of order.
            if entry.index <= lastShown {
                countDropped()
                continue
            }

            paced += waitForMoment(of: entry.index)
            if queue.wasAbandoned { break }

            // A pause can land during the wait, and so can a seek. Re-check the frame
            // against the clock rather than showing one the pause made stale.
            if queue.count > 0, pacer.isSuperseded(entry.index, at: clock.mediaTime) {
                countDropped()
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
                lock.lock()
                shownCount += 1
                lock.unlock()
                lastShown = entry.index
            } catch {
                record("could not present output frame \(entry.index): \(error)")
            }
        }

        lock.lock()
        let problems = problemList
        let shown = shownCount
        let dropped = droppedCount
        lock.unlock()
        return Report(shown: shown, dropped: dropped, pacedSeconds: paced,
                      endedByAbandon: queue.wasAbandoned, problems: problems)
    }

    /// Frames handed to the display so far. Readable *during* a run, which is the only way a
    /// player can show a live drop rate — and the only way a measurement harness can report
    /// one, since it stops the player rather than waiting for the film to end.
    public var shown: Int {
        lock.lock(); defer { lock.unlock() }
        return shownCount
    }

    /// Frames thrown away so far. See ``shown``.
    public var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }

    private func countDropped() {
        lock.lock()
        droppedCount += 1
        lock.unlock()
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
            display.discardQueuedFrames()
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
