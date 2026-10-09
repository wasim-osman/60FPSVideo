import CoreVideo
import Foundation

/// A bounded queue of finished output frames, between the engine and the screen.
///
/// ## Why a queue exists at all
///
/// The engine's completions arrive on its own threads, out of order, and the display has to
/// be fed from one place. Something has to sit between them, and it has to be **bounded**:
/// interpolation produces frames as fast as it can, which at 1080p is faster than real time,
/// and an unbounded queue would mean the whole film rendered into memory before a second of
/// it was shown. The bound is what makes the producer wait, which is the only reason
/// playback uses bounded memory.
///
/// ## Both ends block
///
/// `push` blocks while the queue is full and `pop` blocks while it is empty, and both are
/// woken by the other. That is deliberate, and it is the whole synchronisation design:
///
/// - the producer blocking on a full queue is backpressure — it stops reading the source,
///   which is what keeps decode and interpolation from running away;
/// - the consumer blocking on an empty queue is a starvation wait, which is what a player
///   does when the machine cannot keep up;
/// - neither end polls, so a player that is keeping up does no work at all between frames.
///
/// ## Ordering
///
/// Entries are held in index order, because the producer's own order is not the output's —
/// a completion for interval `n + 1` can land before interval `n`'s. Insertion is a binary
/// search rather than an append, since a queue that assumed arrival order would deliver
/// frames out of order and the picture would show it as a stutter on exactly the fast
/// motion the interpolation was bought for.
///
/// `@unchecked Sendable` is accurate: everything mutable is behind `condition`.
public final class PlaybackBuffer: @unchecked Sendable {

    public struct Entry: @unchecked Sendable {
        /// The frame's position in the output sequence.
        public let index: Int
        /// The pixels. Owned by the queue until it is popped — the producer has already
        /// copied them out of the engine's buffer (invariant 25).
        public let buffer: CVPixelBuffer

        public init(index: Int, buffer: CVPixelBuffer) {
            self.index = index
            self.buffer = buffer
        }
    }

    /// Frames the queue will hold before `push` blocks.
    public let capacity: Int

    private let condition = NSCondition()
    private var entries: [Entry] = []
    /// No more entries will arrive. `pop` drains what is left and then returns `nil`.
    private var finished = false
    /// Abandoned. `pop` returns `nil` immediately and `push` refuses, whatever is queued.
    private var abandoned = false
    private var pushedCount = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    // MARK: - Producing

    /// Add a frame, blocking while the queue is full.
    ///
    /// Returns `false` when the queue has been abandoned, which is how a seek or a stop
    /// tells a producer that its work is no longer wanted. Callers must check it: a sink
    /// that ignores this keeps interpolating into a queue nobody is reading.
    @discardableResult
    public func push(_ entry: Entry) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while entries.count >= capacity && !finished && !abandoned {
            condition.wait()
        }
        guard !abandoned else { return false }
        // Binary search rather than append: completions arrive out of order, and a queue
        // that delivered them in arrival order would show a stutter on fast motion.
        let position = insertionPoint(for: entry.index)
        entries.insert(entry, at: position)
        pushedCount += 1
        condition.broadcast()
        return true
    }

    private func insertionPoint(for index: Int) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].index < index { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// No more frames are coming. The consumer drains what is queued and then stops.
    public func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Throw everything away and stop. Used by a seek, where the queued frames belong to a
    /// position the film is no longer at.
    public func abandon() {
        condition.lock()
        abandoned = true
        entries.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Consuming

    /// The oldest queued frame, blocking while the queue is empty.
    ///
    /// `nil` only when the queue is finished *and* drained, or abandoned. A caller that
    /// treats `nil` as "end of film" must therefore also check ``wasAbandoned``, or a seek
    /// will look like the credits.
    public func pop() -> Entry? {
        condition.lock()
        defer { condition.unlock() }
        while entries.isEmpty && !finished && !abandoned {
            condition.wait()
        }
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        condition.broadcast()
        return entry
    }

    /// The oldest queued frame, or `nil` if there is nothing yet. Never blocks.
    public func peek() -> Entry? {
        condition.lock()
        defer { condition.unlock() }
        return entries.first
    }

    // MARK: - State

    public var count: Int {
        condition.lock(); defer { condition.unlock() }
        return entries.count
    }

    public var isEmpty: Bool { count == 0 }

    public var isFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    public var wasAbandoned: Bool {
        condition.lock(); defer { condition.unlock() }
        return abandoned
    }

    /// True when `pop` has nothing more to give and never will.
    public var isDrained: Bool {
        condition.lock(); defer { condition.unlock() }
        return (finished || abandoned) && entries.isEmpty
    }

    /// Frames accepted. Not the same as frames shown: the consumer discards superseded ones.
    public var pushed: Int {
        condition.lock(); defer { condition.unlock() }
        return pushedCount
    }

    /// The highest index queued, or `nil`. Used to decide whether a frame is superseded —
    /// a stale frame is only dropped when something newer is actually waiting.
    public var newestIndex: Int? {
        condition.lock(); defer { condition.unlock() }
        return entries.last?.index
    }
}
