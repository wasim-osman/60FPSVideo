import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// The presenter: which frames reach the screen, when, and which are thrown away.
///
/// The display is a fake, so none of this opens a window — but the clock is the real one and
/// the pacing is real, because the pacing is the thing under test. A presenter checked
/// against a stopped clock would pass whether or not it paced anything.
struct DisplayPresenterTests {

    // MARK: - Scaffolding

    private final class FakeDisplay: VideoDisplay, @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [CMSampleBuffer] = []
        private var flushCount = 0
        private var polls = 0
        /// Polls that must elapse before the display will take a sample. Models a layer that
        /// is momentarily full, which is the state the presenter must wait through rather
        /// than drop a frame over.
        var readyAfterPolls = 0

        var isReadyForMoreMediaData: Bool {
            lock.lock(); defer { lock.unlock() }
            polls += 1
            return polls > readyAfterPolls
        }

        var requiresFlushToResumeDecoding: Bool { false }

        func enqueue(_ sampleBuffer: CMSampleBuffer) {
            lock.lock(); samples.append(sampleBuffer); lock.unlock()
        }

        func discardQueuedFrames() {
            lock.lock(); flushCount += 1; lock.unlock()
        }

        var enqueued: [CMSampleBuffer] {
            lock.lock(); defer { lock.unlock() }
            return samples
        }

        var flushes: Int {
            lock.lock(); defer { lock.unlock() }
            return flushCount
        }
    }

    private struct Shared: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private func makeBuffer() -> Shared {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         nil, &buffer)
        precondition(status == kCVReturnSuccess, "test fixture could not make a buffer")
        return Shared(buffer: buffer!)
    }

    private var rate: FrameRate { FrameRate.parse("60000/1001")! }

    private func run(_ body: @escaping @Sendable () -> DisplayPresenter.Report)
        -> DisplayPresenter.Report {
        let done = DispatchSemaphore(value: 0)
        let box = ReportBox()
        Thread.detachNewThread {
            box.value = body()
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 20) == .success,
                     "the presenter never returned")
        return box.value!
    }

    private final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: DisplayPresenter.Report?
        var value: DisplayPresenter.Report? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    /// The output frame a sample belongs to, recovered from its own timestamp.
    private func index(of sample: CMSampleBuffer) -> Int {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        return Int((seconds * rate.doubleValue).rounded())
    }

    // MARK: - Timestamps

    @Test("a frame's timestamp is exact rational arithmetic, not a decimal")
    func timestampsAreExact() throws {
        let buffer = makeBuffer()
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer.buffer,
            formatDescriptionOut: &format)
        #expect(status == noErr)
        let description = try #require(format)

        for frame in [0, 1, 59, 60, 154_000] {
            let sample = try DisplayPresenter.sampleBuffer(imageBuffer: buffer.buffer,
                                                           format: description,
                                                           index: frame, rate: rate)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            // 1001/60000 s per frame, in integers. A Double would round 59.94 to 59.94 and
            // be wrong by a millisecond an hour.
            #expect(pts.value == Int64(frame) * 1001, "frame \(frame)")
            #expect(pts.timescale == 60000)
            let duration = CMSampleBufferGetDuration(sample)
            #expect(duration.value == 1001 && duration.timescale == 60000)
        }
    }

    @Test("a whole-number rate carries a whole-number timescale")
    func wholeNumberRate() throws {
        let buffer = makeBuffer()
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer.buffer,
                                                     formatDescriptionOut: &format)
        let description = try #require(format)
        let sixty = FrameRate.parse("60")!
        let sample = try DisplayPresenter.sampleBuffer(imageBuffer: buffer.buffer,
                                                       format: description,
                                                       index: 120, rate: sixty)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        #expect(pts.value == 120 && pts.timescale == 60)
    }

    // MARK: - What reaches the screen

    @Test("every frame is presented, in order, when the machine keeps up")
    func presentsEverythingWhenAhead() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        let count = 6

        for index in 0..<count {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        queue.finish()
        clock.play()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }

        #expect(report.shown == count, "\(report)")
        #expect(report.dropped == 0)
        #expect(display.enqueued.map(index) == Array(0..<count),
                "got \(display.enqueued.map(index))")
        #expect(report.problems.isEmpty, "\(report.problems)")
    }

    @Test("timestamps advance by exactly one frame each")
    func timestampsAdvance() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        for index in 0..<5 {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        queue.finish()
        clock.play()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        _ = run { presenter.run() }

        let times = display.enqueued.map {
            CMSampleBufferGetPresentationTimeStamp($0).value
        }
        #expect(times == [0, 1001, 2002, 3003, 4004], "got \(times)")
    }

    // MARK: - What is thrown away

    /// The signature of a machine that cannot keep up: the playhead has moved past frames
    /// that are still queued. Showing them would show the wrong picture and push everything
    /// after them later still, so they go.
    @Test("superseded frames are dropped, but the newest is always shown")
    func dropsSuperseded() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)

        // The playhead is a long way in, and the frames queued are from the start.
        clock.seek(to: 5.0)
        clock.play()
        for index in 0..<3 {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        queue.finish()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }

        #expect(report.shown == 1, "only the newest frame is worth showing: \(report)")
        #expect(report.dropped == 2)
        #expect(display.enqueued.map(index) == [2],
                "the frame shown must be the newest, not the oldest")
    }

    /// The guard that keeps "drop what is late" from becoming "show nothing". A machine that
    /// cannot keep up would otherwise display a black screen rather than a stutter.
    @Test("a late frame is still shown when it is the only one")
    func neverDropsTheLastFrame() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)

        clock.seek(to: 60.0)
        clock.play()
        _ = queue.push(.init(index: 3, buffer: makeBuffer().buffer))
        queue.finish()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }

        #expect(report.shown == 1, "the only frame available was dropped: \(report)")
        #expect(report.dropped == 0)
    }

    @Test("a frame older than one already shown is discarded")
    func outOfOrderArrivals() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        clock.play()

        // Frame 5 arrives, then frame 3 — a completion that landed out of order.
        _ = queue.push(.init(index: 5, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 3, buffer: makeBuffer().buffer))
        queue.finish()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }

        // The queue sorts by index, so frame 3 comes out first and is shown; frame 5 follows.
        // What must not happen is a *rewind*: the indices enqueued never decrease.
        let enqueued = display.enqueued.map(index)
        #expect(enqueued == enqueued.sorted(), "the display was sent a rewind: \(enqueued)")
        #expect(report.shown + report.dropped == 2)
    }

    // MARK: - Readiness

    @Test("the presenter waits for the display rather than dropping a frame")
    func waitsForReadyDisplay() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        display.readyAfterPolls = 3
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        for index in 0..<3 {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        queue.finish()
        clock.play()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }

        #expect(report.shown == 3, "a frame was dropped waiting for the display: \(report)")
        #expect(report.dropped == 0)
    }

    // MARK: - Ending

    @Test("an abandoned queue ends the run and is reported as such")
    func abandonEndsTheRun() {
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        _ = queue.push(.init(index: 0, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 1, buffer: makeBuffer().buffer))
        clock.play()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        // Abandon after the first frame is shown, from another thread.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            queue.abandon()
        }
        let report = run { presenter.run() }

        #expect(report.endedByAbandon, "a seek must be distinguishable from the end of a film")
        #expect(report.shown >= 1)
    }

    @Test("an empty finished queue ends the run with nothing shown")
    func emptyQueueEnds() {
        let queue = PlaybackBuffer(capacity: 4)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        queue.finish()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }

        #expect(report.shown == 0)
        #expect(report.dropped == 0)
        #expect(!report.endedByAbandon)
    }

    @Test("the dropped fraction is the share of frames thrown away")
    func droppedFraction() {
        let none = DisplayPresenter.Report(shown: 10, dropped: 0, pacedSeconds: 0,
                                           endedByAbandon: false, problems: [])
        #expect(none.droppedFraction == 0)
        let half = DisplayPresenter.Report(shown: 5, dropped: 5, pacedSeconds: 0,
                                           endedByAbandon: false, problems: [])
        #expect(abs(half.droppedFraction - 0.5) < 1e-12)
        let nothing = DisplayPresenter.Report(shown: 0, dropped: 0, pacedSeconds: 0,
                                              endedByAbandon: false, problems: [])
        #expect(nothing.droppedFraction == 0, "an empty run has no fraction, not a divide by zero")
    }

    // MARK: - Where a run sits in the film

    /// **The sink's index is the film's, not the run's.**
    ///
    /// A run that begins anywhere but the start of the film numbers its output from zero —
    /// right for a file, wrong for a display, whose index becomes a presentation timestamp
    /// and is what the pacer compares against a clock that is in film time.
    ///
    /// Measured on the real 4K film: a player started at 60 s presented its first frame at
    /// film time **0.00 s**, sixty seconds behind the sound. Nothing else in the trace looked
    /// wrong — from the picture's own point of view it was playing perfectly — and the only
    /// symptom was a lag of 60210 ms that read like a rendering problem.
    @Test("a run that starts part way through presents the film's timestamps")
    func sinkCarriesTheFilmsNumbering() {
        // A run whose first output frame is the film's frame 3595, which is what 60 s at
        // 59.94 comes to.
        let outputStart = 3595
        let queue = PlaybackBuffer(capacity: 8)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 10)
        let sink = DisplayFrameSink(queue: queue, width: 16, height: 16, format: .nv12,
                                    outputOffset: outputStart)
        try? sink.begin(SinkGeometry(width: 16, height: 16, format: .nv12,
                                     sourceRate: FrameRate.parse("24000/1001")!,
                                     outputRate: rate, sourceFrameCount: nil,
                                     outputFrameCount: nil))
        // The pipeline writes run-relative indices: 0, 1, 2.
        for index in 0..<3 {
            sink.write(makeBuffer().buffer, at: index)
        }
        try? sink.finish()

        clock.play()
        clock.seek(to: Double(outputStart) / rate.doubleValue)
        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        let report = run { presenter.run() }
        #expect(report.shown == 3, "\(report.problems)")

        let presented = display.enqueued.map(index(of:))
        #expect(presented == [outputStart, outputStart + 1, outputStart + 2],
                "the display was handed run-relative frames: \(presented)")

        // And the timestamp itself, so this is checked against the arithmetic rather than
        // against another copy of the offset.
        //
        // `if let` rather than `try? #require`: `#require` on an expression the compiler can
        // already see is non-optional is a redundant unwrap, and the count is asserted two
        // lines above, so the binding here is a guard rather than the check.
        if let first = display.enqueued.first {
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            #expect(pts.value == Int64(outputStart) * 1001, "\(pts)")
            #expect(pts.timescale == 60000)
            #expect(abs(CMTimeGetSeconds(pts) - 59.976) < 0.001,
                    "\(CMTimeGetSeconds(pts)) should be about 60 s, not 0")
        }
    }

    /// The default is zero, so every existing caller — and the file-writing sink's twin — is
    /// unchanged.
    @Test("with no offset a run numbers its frames from zero")
    func defaultOffsetIsZero() throws {
        let queue = PlaybackBuffer(capacity: 4)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 10)
        let sink = DisplayFrameSink(queue: queue, width: 16, height: 16, format: .nv12)
        try sink.begin(SinkGeometry(width: 16, height: 16, format: .nv12,
                                    sourceRate: FrameRate.parse("24000/1001")!,
                                    outputRate: rate, sourceFrameCount: nil,
                                    outputFrameCount: nil))
        sink.write(makeBuffer().buffer, at: 0)
        try sink.finish()

        clock.play()
        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)
        _ = run { presenter.run() }
        #expect(display.enqueued.map(index(of:)) == [0])
    }

    // MARK: - The counters, while the film is still playing

    /// `shown` has to be readable **during** a run, because that is the only moment a player
    /// has anything to report.
    ///
    /// `PlaybackController.status` reads its counters from here — see `counters(live:report:)`
    /// — and it read them from the end-of-run report instead for a while, which made the app's
    /// rate readout structurally zero for the whole of a film. The fix depends entirely on this
    /// property, so it is asserted rather than assumed: the run is observed *in progress*, and
    /// the count is required to have advanced strictly between zero and the total while it was
    /// still going.
    @Test("the shown count advances while the run is still going")
    func shownIsReadableDuringARun() {
        let queue = PlaybackBuffer(capacity: 16)
        let display = FakeDisplay()
        let clock = PlaybackClock()
        // A tenth of a second of lead per frame, so a six-frame run takes long enough to be
        // observed in the middle of rather than only after.
        let pacer = PlaybackPacer(outputRate: rate, leadSeconds: 0.1)
        let count = 6
        for index in 0..<count {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        queue.finish()

        let presenter = DisplayPresenter(queue: queue, display: display, clock: clock,
                                         pacer: pacer, outputRate: rate)

        let box = ReportBox()
        let done = Flag()
        Thread.detachNewThread {
            box.value = presenter.run()
            done.raise()
        }
        clock.play()

        // Sample while it runs. `shown` must be a live reading: it has to be observed strictly
        // between zero and the total, and it must never go backwards.
        var seenMidRun = false
        var previous = 0
        var wentBackwards = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !done.isSet {
            let now = presenter.shown
            if now < previous { wentBackwards = true }
            if now > 0, now < count { seenMidRun = true }
            previous = now
            usleep(1_000)
        }

        // The run's own report is the final answer; the last sample in the loop is taken
        // whenever the loop happened to notice, which is one frame early as often as not.
        #expect(!wentBackwards, "the count went backwards")
        #expect(box.value?.shown == count, "the run reported \(box.value?.shown as Any)")
        #expect(presenter.shown == count, "the live count ended at \(presenter.shown)")
        #expect(seenMidRun,
                "the count was never observed part-way through the run, so it is not live")
        #expect(previous > 0, "the count was still zero at the last sample")
    }

    /// A one-way flag, because a semaphore's signal is consumed by whoever waits for it and
    /// a poll that eats the signal leaves the next wait to time out — which is how a test
    /// that should take a tenth of a second takes twenty.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func raise() { lock.lock(); value = true; lock.unlock() }
    }
}
