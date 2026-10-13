import CoreVideo
import Foundation
import VideoToolbox

/// Delivers frames at a size other than the one they were interpolated at.
///
/// ## What this is for
///
/// Interpolation cost is a step function of frame width, and it is the reason this project has
/// a width ladder at all. Delivered size is a property of the screen the file is for. Until
/// this sink existed those were the same number, because `ConversionQuality` set both — so a
/// screen-sized file necessarily cost a full-resolution interpolation, and a cheap
/// interpolation necessarily produced a small file.
///
/// With the two separated, a conversion can interpolate at 1920 wide — **31.87 ms** per
/// interval against the film's 41.71 ms budget, where 4K needs ~105 ms — and still deliver a
/// file at 3440×1440. The upscale is `VTPixelTransferSession`'s, measured at **2.71 ms** per
/// frame for 1920×816 → 3440×1440 and **3.48 ms** from 4K. That is 4–5% of the interpolation
/// it sits behind, so it does not change which rung of the ladder fits.
///
/// This is the arrangement SVP ships: it interpolates at 3384×1440 and scales to the screen,
/// and its manual states the rule under *Resizing an Image* — scaling exists to "reduce the
/// CPU load when the frame rate conversion function is active", by reducing the frame size
/// before the intermediate frames are calculated.
///
/// ## Why it is the framework that places the picture
///
/// The two modes map to two documented scaling modes: `kVTScalingMode_Letterbox` ("preserve
/// aspect ratio of the source, and fill remaining areas with black in to fit destination
/// dimensions") and `kVTScalingMode_Trim` ("preserve aspect ratio of the source, and crop
/// picture to fit destination dimensions"). Nothing here scales, letterboxes or composites by
/// hand — one property is set and the framework does the rest.
///
/// Measured on this machine, 1920×816 into 3440×1440, reading back the luma plane:
///
/// | mode | x=25 | x=26 | x=3413 | x=3414 |
/// | --- | --- | --- | --- | --- |
/// | `Letterbox` | **16** | 235 | 235 | **16** |
/// | `Trim` | 235 | 235 | 235 | 235 |
///
/// 26 is exactly the bar width `OutputGeometry` predicts, so the picture is centred on the
/// pixel. And the bars are **written**, not left over: with the destination pre-filled with a
/// sentinel of 77, the bars still read 16. That matters because destination buffers are
/// recycled — a transfer that only wrote the picture would show the previous frame's edge in
/// the bars, which is a defect that would appear only under load and only at the edges.
///
/// ## Threading
///
/// `write` is called from the engine's completion threads, concurrently and out of order
/// (`FrameSink`'s contract). Two pieces of state therefore have to be shared safely:
///
/// - **Destination buffers** come from a `PixelBufferPool`, never from `CVPixelBufferCreate`.
///   Invariant 2: one buffer per frame allocated directly crashes after 65–90 frames. A pooled
///   buffer is recycled only once every reference to it is gone, so a wrapped sink that keeps
///   one is safe rather than corrupting — it just costs a fresh allocation.
/// - **Transfer sessions** are pooled rather than shared, because a `VTPixelTransferSession`
///   is not safe for concurrent use. Creation measured **0.138 ms**, against 2.71 ms for the
///   transfer itself, so a pool keeps that overhead off the hot path without being load
///   bearing: exceeding the pool simply means creating one.
public final class ScalingFrameSink: FrameSink, @unchecked Sendable {

    /// The sink that receives the scaled frames.
    private let inner: FrameSink

    /// The size to deliver.
    private let target: OutputSize

    /// What happens to the parts that do not fit.
    private let mode: FitMode

    private let lock = NSLock()
    private var problemList: [String] = []

    /// Built in ``begin(_:)``, once the format is known.
    private var pool: PixelBufferPool?

    /// Idle transfer sessions, one per concurrent writer in the steady state.
    private var idleSessions: [VTPixelTransferSession] = []

    /// A ceiling on how many idle sessions are kept. Above this they are invalidated instead
    /// of pooled, because an unbounded pool is a leak that only shows up under load.
    private static let maximumIdleSessions = 16

    /// True when the geometry already matches the target and no transfer is needed.
    ///
    /// Set rather than assumed: a sink that silently spends 1.05 ms per frame copying a frame
    /// onto itself is exactly the kind of cost that never appears in a profile because nobody
    /// thinks to look for it.
    private var passthrough = false

    private var closed = false

    public init(wrapping inner: FrameSink, target: OutputSize, mode: FitMode) {
        self.inner = inner
        self.target = target
        self.mode = mode
    }

    // MARK: - FrameSink

    public func begin(_ geometry: SinkGeometry) throws {
        let destination = SinkGeometry(width: target.width,
                                       height: target.height,
                                       format: geometry.format,
                                       sourceRate: geometry.sourceRate,
                                       outputRate: geometry.outputRate,
                                       sourceFrameCount: geometry.sourceFrameCount,
                                       outputFrameCount: geometry.outputFrameCount)

        if geometry.width == target.width && geometry.height == target.height {
            passthrough = true
            try inner.begin(destination)
            return
        }

        pool = try PixelBufferPool(width: target.width,
                                   height: target.height,
                                   format: geometry.format,
                                   capacity: 16)
        try inner.begin(destination)
    }

    public func write(_ buffer: CVPixelBuffer, at outputIndex: Int) {
        if passthrough {
            inner.write(buffer, at: outputIndex)
            return
        }

        guard let pool else {
            // `begin` was never called. Forward rather than drop: a run that produces a
            // wrong-sized file and says so is better than one that produces nothing.
            record("scaled frame \(outputIndex) arrived before begin(); passed through unscaled")
            inner.write(buffer, at: outputIndex)
            return
        }

        let destination: CVPixelBuffer
        do {
            destination = try pool.makeBuffer()
        } catch {
            record("could not get a \(target.label) buffer for frame \(outputIndex): \(error)")
            return
        }

        guard let session = takeSession() else {
            record("could not create a transfer session for frame \(outputIndex)")
            return
        }
        let status = VTPixelTransferSessionTransferImage(session, from: buffer, to: destination)
        giveBack(session)

        guard status == noErr else {
            // A transfer that fails is reported, not thrown: `write` must not throw, because
            // there is no useful place to report an error from inside an engine completion.
            record("scaling frame \(outputIndex) to \(target.label) failed (\(status))")
            return
        }

        inner.write(destination, at: outputIndex)
    }

    public func finish() throws {
        lock.lock()
        closed = true
        let sessions = idleSessions
        idleSessions = []
        lock.unlock()
        for session in sessions { VTPixelTransferSessionInvalidate(session) }

        try inner.finish()
    }

    public var problems: [String] {
        lock.lock()
        let mine = problemList
        lock.unlock()
        return mine + inner.problems
    }

    // MARK: - Session pool

    private func takeSession() -> VTPixelTransferSession? {
        lock.lock()
        if let session = idleSessions.popLast() {
            lock.unlock()
            return session
        }
        lock.unlock()
        return makeSession()
    }

    private func giveBack(_ session: VTPixelTransferSession) {
        lock.lock()
        if !closed && idleSessions.count < Self.maximumIdleSessions {
            idleSessions.append(session)
            lock.unlock()
            return
        }
        lock.unlock()
        VTPixelTransferSessionInvalidate(session)
    }

    private func makeSession() -> VTPixelTransferSession? {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                           pixelTransferSessionOut: &session) == noErr,
              let session else { return nil }
        let status = VTSessionSetProperty(session,
                                          key: kVTPixelTransferPropertyKey_ScalingMode,
                                          value: mode == .fit ? kVTScalingMode_Letterbox
                                                              : kVTScalingMode_Trim)
        guard status == noErr else {
            VTPixelTransferSessionInvalidate(session)
            return nil
        }
        return session
    }

    private func record(_ problem: String) {
        lock.lock()
        problemList.append(problem)
        lock.unlock()
    }
}
