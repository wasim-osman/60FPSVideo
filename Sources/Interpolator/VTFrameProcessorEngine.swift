import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The shipping engine. Single tier — see `reports/ENGINE-EQUIVALENCE.md` for why
/// there is no neural alternative.
///
/// Everything here that looks odd is odd for a measured reason. The invariants it
/// encodes are listed in `BUILD-DECISIONS.md`; the ones that bite are repeated at
/// the call sites below.
///
/// `@unchecked Sendable` is accurate rather than convenient: every piece of mutable
/// state below is guarded by `lock`, and the semaphore is the pipeline-depth
/// backpressure. The only unguarded state is the `VTFrameProcessor` session itself,
/// which is not thread-safe and is only ever touched from `prepare`/`submit`/
/// `shutdown` — all of which the caller drives from one thread.
public final class VTFrameProcessorEngine: InterpolationEngine, @unchecked Sendable {

    public let name = "VTFrameProcessor"
    public let maximumInterpolationsPerInterval: Int

    private let sourceRate: FrameRate
    private let outputRate: FrameRate
    /// Requests kept in flight. Public so the caller can size its buffer ring.
    public let depth: Int

    private var processor: VTFrameProcessor?
    private var sessionStarted = false

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inFlight = 0
    private var firstError: Error?

    /// - Parameters:
    ///   - depth: requests kept in flight. **2 is the minimum that works**: depth 1
    ///     fails outright on 23.976 → 60, dropping to 56.7 fps (invariant 3).
    public init(source: FrameRate, output: FrameRate, depth: Int = 2) {
        self.sourceRate = source
        self.outputRate = output
        self.depth = max(2, depth)

        // One interval can produce at most ceil(out/src) frames, plus slack for the
        // phase landing just either side of a boundary.
        let ratio = output.doubleValue / source.doubleValue
        self.maximumInterpolationsPerInterval = Int(ratio.rounded(.up)) + 2
    }

    // MARK: - Session

    public func prepare(width: Int, height: Int) throws {
        guard !sessionStarted else { return }

        // Invariant 6: leave usePrecomputedFlow off. Pre-computed flow measured 14%
        // *slower*, not faster.
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTFrameRateConversionConfiguration.defaultRevision
        ) else {
            throw InterpolatorError.unsupportedResolution(
                width: width, height: height,
                reason: "VTFrameRateConversionConfiguration returned nil")
        }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: configuration)
        self.processor = processor
        self.sessionStarted = true
    }

    // MARK: - Submission

    public func submit(_ request: InterpolationRequest) {
        guard let processor else {
            request.completion(.failure(
                InterpolatorError.engineRejected("prepare(width:height:) was not called")))
            return
        }

        let interpolations = request.interval.interpolations
        guard !interpolations.isEmpty else {
            request.completion(.success(()))
            return
        }
        guard request.destinations.count >= interpolations.count else {
            request.completion(.failure(InterpolatorError.engineRejected(
                "\(interpolations.count) interpolations but only "
                + "\(request.destinations.count) destination buffers")))
            return
        }

        var destinationFrames: [VTFrameProcessorFrame] = []
        var phases: [Float] = []
        destinationFrames.reserveCapacity(interpolations.count)
        phases.reserveCapacity(interpolations.count)

        for (n, frame) in interpolations.enumerated() {
            guard case .interpolate(_, _, let phase) = frame.kind else { continue }
            let pts = VTFrameProcessorEngine.time(forOutputIndex: frame.index,
                                                  rate: outputRate)
            guard let destination = VTFrameProcessorFrame(
                buffer: request.destinations[n],
                presentationTimeStamp: pts
            ) else {
                request.completion(.failure(InterpolatorError.engineRejected(
                    "could not wrap destination buffer \(n) at output frame \(frame.index)")))
                return
            }
            destinationFrames.append(destination)
            phases.append(Float(phase))
        }

        let sourcePTS = VTFrameProcessorEngine.time(
            forSourceIndex: request.interval.sourceIndex, rate: sourceRate)
        let nextPTS = VTFrameProcessorEngine.time(
            forSourceIndex: request.interval.sourceIndex + 1, rate: sourceRate)

        guard let sourceFrame = VTFrameProcessorFrame(buffer: request.sourceA,
                                                      presentationTimeStamp: sourcePTS),
              let nextFrame = VTFrameProcessorFrame(buffer: request.sourceB,
                                                    presentationTimeStamp: nextPTS),
              let parameters = VTFrameRateConversionParameters(
                sourceFrame: sourceFrame,
                nextFrame: nextFrame,
                opticalFlow: nil,
                interpolationPhase: phases,
                submissionMode: .sequential,
                destinationFrames: destinationFrames
              )
        else {
            request.completion(.failure(InterpolatorError.engineRejected(
                "could not build parameters for interval "
                + "\(request.interval.sourceIndex)")))
            return
        }

        enterPipeline()

        // Invariant 1: the completion-handler form. The `async` form of `process()`
        // returns in 0.08 ms and never writes the destination buffer — it looks like
        // success and produces nothing.
        processor.process(parameters: parameters) { [weak self] _, error in
            // Invariant 5: always check the error. The low-latency path fails
            // *silently* above 1920x1080 — `startSession` still reports success and
            // the completion arrives with no error and no frames.
            self?.leavePipeline(error: error)
            request.completion(error.map { .failure($0) } ?? .success(()))
        }
    }

    public func drain() throws {
        lock.lock()
        while inFlight > 0 {
            lock.unlock()
            semaphore.wait()
            lock.lock()
        }
        let error = firstError
        lock.unlock()
        if let error { throw error }
    }

    public func shutdown() {
        guard sessionStarted, let processor else { return }
        try? drain()
        processor.endSession()
        self.processor = nil
        sessionStarted = false
    }

    // MARK: - Pipeline depth

    private func enterPipeline() {
        lock.lock()
        while inFlight >= depth {
            lock.unlock()
            semaphore.wait()
            lock.lock()
        }
        inFlight += 1
        lock.unlock()
    }

    private func leavePipeline(error: Error?) {
        lock.lock()
        inFlight -= 1
        if let error, firstError == nil { firstError = error }
        lock.unlock()
        semaphore.signal()
    }

    // MARK: - Presentation timestamps
    //
    // Exact integer arithmetic at a 90 kHz timescale, same as the phase plan. A
    // timestamp rounded through a Double is another place a decimal rate can leak in.

    static func time(forOutputIndex index: Int, rate: FrameRate,
                     timescale: CMTimeScale = 90000) -> CMTime {
        let numerator = Int64(index) * Int64(rate.denominator) * Int64(timescale)
        let denominator = Int64(rate.numerator)
        return CMTime(value: CMTimeValue((numerator + denominator / 2) / denominator),
                      timescale: timescale)
    }

    static func time(forSourceIndex index: Int, rate: FrameRate,
                     timescale: CMTimeScale = 90000) -> CMTime {
        time(forOutputIndex: index, rate: rate, timescale: timescale)
    }
}
