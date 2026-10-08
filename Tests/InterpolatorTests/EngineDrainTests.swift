import CoreVideo
import Foundation
import Testing
@testable import Interpolator

/// Destination buffers travelling into a completion. `CVPixelBuffer` is not
/// `Sendable`; this states the borrow the same way `InterpolationRequest` does.
private struct BorrowedBuffers: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
    init(_ buffers: [CVPixelBuffer]) { self.buffers = buffers }
}

/// `drain()` is a promise: when it returns, every submitted request has finished —
/// including the caller's own completion closure.
///
/// ## Why this is worth its own suite
///
/// The engine retires a request from its depth accounting and *then* runs the
/// caller's completion. `drain()` waits on the depth semaphore, so it woke up in
/// that gap and returned while the last completion was still running.
///
/// Nothing in the engine was wrong on its own terms — the frames were produced, the
/// completion did eventually run. What broke was everything downstream that treats
/// `drain()` as a barrier. The batch converter truncates or finalises its output
/// file there, and the packed sink sets the file length from what it has written. A
/// completion arriving after that point is a frame written past the end of the file,
/// which the truncate then discards.
///
/// It cost exactly the last frames of every run, silently, as black — and it was
/// invisible for as long as it was, because the harness sized its output from the
/// plan rather than from what had been written, and only sampled one passthrough
/// frame in thirty-seven.
@Suite("Engine drain")
struct EngineDrainTests {

    /// Counts completions. A class because the completion is `@Sendable` and cannot
    /// capture a mutable local.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func fill(_ buffer: CVPixelBuffer, seed: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            let bytes = luma.assumingMemoryBound(to: UInt8.self) + row * stride
            for x in 0..<width {
                bytes[x] = UInt8((x + row + seed * 7) % 200 + 20)
            }
        }
        guard let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) {
            memset(chroma + row * chromaStride, 128, width)
        }
    }

    @Test("drain returns only after every completion has run")
    func drainWaitsForCompletions() throws {
        let width = 128
        let height = 128
        let sourceRate = FrameRate.parse("24")!
        let outputRate = FrameRate.parse("60")!
        let requests = 12

        let engine = VTFrameProcessorEngine(source: sourceRate, output: outputRate, depth: 2)
        try engine.prepare(width: width, height: height)
        defer { engine.shutdown() }

        let pool = try PixelBufferPool(width: width, height: height, format: .nv12,
                                       capacity: 4 + requests * 4)
        let counter = Counter()

        // A slot per request, so the test does not itself break invariant 17.
        var slots: [(a: CVPixelBuffer, b: CVPixelBuffer, destinations: [CVPixelBuffer])] = []
        for i in 0..<requests {
            let a = try pool.makeBuffer()
            let b = try pool.makeBuffer()
            fill(a, seed: i, width: width, height: height)
            fill(b, seed: i + 1, width: width, height: height)
            let destinations = try (0..<2).map { _ in try pool.makeBuffer() }
            slots.append((a, b, destinations))
        }

        for i in 0..<requests {
            let slot = slots[i]
            let interval = SourceInterval(sourceIndex: i, output: [
                OutputFrame(index: i * 2, kind: .interpolate(before: i, after: i + 1,
                                                              phase: 0.4)),
                OutputFrame(index: i * 2 + 1, kind: .interpolate(before: i, after: i + 1,
                                                                  phase: 0.8)),
            ])
            let request = InterpolationRequest(interval: interval,
                                               sourceA: slot.a, sourceB: slot.b,
                                               destinations: slot.destinations) { _ in
                // Widen the window between the engine retiring this request and the
                // completion running. Without the fix, drain() returns inside it.
                usleep(20_000)
                counter.increment()
            }
            engine.submit(request)
        }

        try engine.drain()

        let seen = counter.count
        #expect(seen == requests,
                "drain() returned with \(requests - seen) completion(s) still running")
    }

    @Test("a completion that arrives late cannot be lost by the caller's bookkeeping")
    func completionsPrecedeDrainReturning() throws {
        // The same property stated the way the pipeline depends on it: everything a
        // completion does has happened by the time drain() returns. The sink is
        // finalised immediately afterwards, which is what makes the ordering matter.
        let width = 128
        let height = 128
        let sourceRate = FrameRate.parse("24")!
        let outputRate = FrameRate.parse("60")!

        let engine = VTFrameProcessorEngine(source: sourceRate, output: outputRate, depth: 2)
        try engine.prepare(width: width, height: height)
        defer { engine.shutdown() }

        let pool = try PixelBufferPool(width: width, height: height, format: .nv12,
                                       capacity: 32)
        let sink = MemoryFrameSink(width: width, height: height, format: .nv12)
        let slots = try (0..<6).map { i -> (CVPixelBuffer, CVPixelBuffer, [CVPixelBuffer]) in
            let a = try pool.makeBuffer()
            let b = try pool.makeBuffer()
            fill(a, seed: i, width: width, height: height)
            fill(b, seed: i + 1, width: width, height: height)
            return (a, b, try (0..<2).map { _ in try pool.makeBuffer() })
        }

        var expected = 0
        for i in 0..<6 {
            let (a, b, buffers) = slots[i]
            let frames = [
                OutputFrame(index: i * 2, kind: .interpolate(before: i, after: i + 1,
                                                              phase: 0.4)),
                OutputFrame(index: i * 2 + 1, kind: .interpolate(before: i, after: i + 1,
                                                                  phase: 0.8)),
            ]
            expected += frames.count
            let borrowed = BorrowedBuffers(buffers)
            engine.submit(InterpolationRequest(
                interval: SourceInterval(sourceIndex: i, output: frames),
                sourceA: a, sourceB: b, destinations: buffers
            ) { result in
                guard case .success = result else { return }
                for (n, frame) in frames.enumerated() {
                    sink.write(borrowed.buffers[n], at: frame.index)
                }
            })
        }

        try engine.drain()

        // No sleep and no tolerance: after drain, the sink must already hold them
        // all. The count is read once into a local, because reading it twice — once
        // for the check and once for the message — can report the two sides as equal
        // while the check itself fails, which is a confusing thing to look at.
        let delivered = sink.count
        #expect(delivered == expected,
                "the sink holds \(delivered) frames after drain(), expected \(expected)")
    }
}
