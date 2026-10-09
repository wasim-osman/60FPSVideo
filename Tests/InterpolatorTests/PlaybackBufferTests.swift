import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// The handoff between the engine's completion threads and the screen.
///
/// The two properties worth testing are the ones that make it a *bounded* queue rather than
/// a buffer: that both ends block, so a producer faster than the clock is throttled and a
/// consumer faster than the producer waits rather than spins; and that a queue built from
/// out-of-order completions still delivers frames in order.
struct PlaybackBufferTests {

    // MARK: - Scaffolding

    /// A value a background thread can hand back. Locked rather than merely declared
    /// `@unchecked Sendable`, because a test that races is a test that fails on someone
    /// else's machine.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ initial: Value) { storage = initial }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    /// `CVPixelBuffer` is a refcounted CoreFoundation object and is thread-safe, but it is
    /// not `Sendable` as far as the compiler is concerned. Wrapping it says so where the
    /// compiler has to hear it, rather than suppressing the warning at each capture.
    private struct Shared: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private func makeBuffer() -> Shared {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         nil, &buffer)
        precondition(status == kCVReturnSuccess, "test fixture could not make a buffer")
        return Shared(buffer: buffer!)
    }

    /// A real thread, not `DispatchQueue.global()`.
    ///
    /// This matters, and it cost a debugging round to learn. libdispatch caps the global
    /// queue's thread pool, and swift-testing runs tests in parallel — so when several
    /// tests are each blocking a thread on a semaphore, the blocks they are waiting for
    /// never get a thread to run on, and a test that passes alone fails in the suite.
    /// Detaching a thread per blocked call removes the shared resource entirely.
    private func onAThread(_ body: @escaping @Sendable () -> Void) {
        Thread.detachNewThread(body)
    }

    // MARK: - Ordering

    @Test("the queue delivers in index order")
    func sortedDelivery() {
        let queue = PlaybackBuffer(capacity: 8)
        // Completions arrive out of order: interval n+1 can land before interval n.
        for index in [5, 2, 9, 0, 7] {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        var seen: [Int] = []
        for _ in 0..<5 {
            if let entry = queue.pop() { seen.append(entry.index) }
        }
        #expect(seen == [0, 2, 5, 7, 9], "got \(seen)")
    }

    @Test("a duplicate index keeps both, in order")
    func duplicateIndex() {
        let queue = PlaybackBuffer(capacity: 4)
        _ = queue.push(.init(index: 1, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 1, buffer: makeBuffer().buffer))
        #expect(queue.count == 2)
        #expect(queue.pop()?.index == 1)
        #expect(queue.pop()?.index == 1)
    }

    @Test("the newest index is the far end")
    func newestIndex() {
        let queue = PlaybackBuffer(capacity: 4)
        #expect(queue.newestIndex == nil)
        _ = queue.push(.init(index: 3, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 8, buffer: makeBuffer().buffer))
        #expect(queue.newestIndex == 8)
    }

    // MARK: - Blocking

    /// Backpressure, and the reason playback does not render the whole film into memory
    /// before showing a second of it.
    @Test("push blocks while the queue is full, and returns when a slot frees")
    func pushBlocksWhenFull() {
        let queue = PlaybackBuffer(capacity: 2)
        let third = makeBuffer()
        _ = queue.push(.init(index: 0, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 1, buffer: makeBuffer().buffer))

        let returned = DispatchSemaphore(value: 0)
        onAThread {
            _ = queue.push(.init(index: 2, buffer: third.buffer))
            returned.signal()
        }

        #expect(returned.wait(timeout: .now() + 0.3) == .timedOut,
                "push returned while the queue was full — no backpressure")
        #expect(queue.count == 2)
        _ = queue.pop()
        #expect(returned.wait(timeout: .now() + 5) == .success,
                "push never returned after a slot was freed")
        #expect(queue.count == 2)
    }

    @Test("pop blocks while the queue is empty, and returns when a frame arrives")
    func popBlocksWhenEmpty() {
        let queue = PlaybackBuffer(capacity: 4)
        let buffer = makeBuffer()
        let popped = Box<Int?>(nil)
        let returned = DispatchSemaphore(value: 0)
        onAThread {
            popped.value = queue.pop()?.index
            returned.signal()
        }

        #expect(returned.wait(timeout: .now() + 0.3) == .timedOut,
                "pop returned from an empty queue that was still running")
        _ = queue.push(.init(index: 7, buffer: buffer.buffer))
        #expect(returned.wait(timeout: .now() + 5) == .success)
        #expect(popped.value == 7)
    }

    // MARK: - Ending

    @Test("finishing drains what is queued, then pop returns nil")
    func finishDrains() {
        let queue = PlaybackBuffer(capacity: 4)
        _ = queue.push(.init(index: 0, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 1, buffer: makeBuffer().buffer))
        queue.finish()

        #expect(queue.pop()?.index == 0)
        #expect(queue.pop()?.index == 1)
        #expect(queue.pop() == nil, "a drained, finished queue must return nil")
        #expect(queue.isDrained)
        #expect(!queue.wasAbandoned)
    }

    @Test("finishing an empty queue makes pop return nil at once")
    func finishEmpty() {
        let queue = PlaybackBuffer(capacity: 4)
        queue.finish()
        #expect(queue.pop() == nil)
        #expect(queue.isDrained)
    }

    @Test("finishing wakes a blocked pop")
    func finishWakesConsumer() {
        let queue = PlaybackBuffer(capacity: 4)
        let returned = DispatchSemaphore(value: 0)
        onAThread {
            _ = queue.pop()
            returned.signal()
        }
        #expect(returned.wait(timeout: .now() + 0.3) == .timedOut)
        queue.finish()
        #expect(returned.wait(timeout: .now() + 5) == .success,
                "finish() left the consumer waiting forever")
    }

    /// Abandoning is not finishing. A seek throws the queue away, and the consumer has to be
    /// able to tell that from the end of the film — otherwise seeking to the last minute
    /// plays the credits.
    @Test("abandoning throws the queue away and stops both ends")
    func abandonIsNotFinish() {
        let queue = PlaybackBuffer(capacity: 4)
        _ = queue.push(.init(index: 0, buffer: makeBuffer().buffer))
        _ = queue.push(.init(index: 1, buffer: makeBuffer().buffer))
        queue.abandon()

        #expect(queue.count == 0, "abandoning left frames queued")
        #expect(queue.pop() == nil)
        #expect(queue.wasAbandoned)
        #expect(!queue.isFinished)
        #expect(queue.isDrained)
    }

    @Test("abandoning wakes a blocked producer and refuses its frame")
    func abandonWakesProducer() {
        let queue = PlaybackBuffer(capacity: 1)
        let extra = makeBuffer()
        _ = queue.push(.init(index: 0, buffer: makeBuffer().buffer))

        let accepted = Box<Bool?>(nil)
        let returned = DispatchSemaphore(value: 0)
        onAThread {
            accepted.value = queue.push(.init(index: 1, buffer: extra.buffer))
            returned.signal()
        }
        #expect(returned.wait(timeout: .now() + 0.3) == .timedOut)
        queue.abandon()
        #expect(returned.wait(timeout: .now() + 5) == .success,
                "abandon() left the producer blocked")
        #expect(accepted.value == false,
                "a producer was told its frame was accepted after the queue was abandoned")
    }

    @Test("abandoning wakes a blocked consumer")
    func abandonWakesConsumer() {
        let queue = PlaybackBuffer(capacity: 4)
        let returned = DispatchSemaphore(value: 0)
        onAThread {
            _ = queue.pop()
            returned.signal()
        }
        #expect(returned.wait(timeout: .now() + 0.3) == .timedOut)
        queue.abandon()
        #expect(returned.wait(timeout: .now() + 5) == .success,
                "abandon() left the consumer waiting forever")
    }

    @Test("a capacity below one is still a queue")
    func degenerateCapacity() {
        let queue = PlaybackBuffer(capacity: 0)
        #expect(queue.capacity == 1)
        #expect(queue.count == 0)
    }

    @Test("the push count is what was accepted, not what was shown")
    func pushCount() {
        let queue = PlaybackBuffer(capacity: 4)
        for index in 0..<3 {
            _ = queue.push(.init(index: index, buffer: makeBuffer().buffer))
        }
        #expect(queue.pushed == 3)
        _ = queue.pop()
        #expect(queue.pushed == 3, "the pushed count moved when a frame was consumed")
    }
}
