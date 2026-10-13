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

    /// See ``SubmissionOrder``. Not a hint — a statement that has to be true.
    private var submissionMode: SubmissionOrder

    /// The framework's own quality/performance tier for the conversion model.
    ///
    /// **There are exactly two, and this is the *only* knob in the pipeline that changes what
    /// the interpolator does rather than how big a frame it is handed.** `.normal` (1) and
    /// `.quality` (2) — see `VTFrameProcessor_FrameRateConversion.h`. `.normal` is the shipping
    /// setting and has been since the engine was written; the parameter exists so that the
    /// question "would turning the model down be cheaper, and would anyone see it?" can be
    /// answered by measurement instead of by reading the enum. §37.
    ///
    /// It is deliberately *not* wired to a user setting. `.normal` is already the faster tier,
    /// so there is nothing below it to offer a user who wants speed — the honest lever for that
    /// is width, which is ``InterpolationWidth``.
    ///
    /// Public so the shipping default is *checkable* rather than merely written down: §37's
    /// whole conclusion is "we are already on the fast tier", and a default that silently moved
    /// would invalidate it without failing anything.
    public let qualityPrioritization: VTFrameRateConversionConfiguration.QualityPrioritization

    private var processor: VTFrameProcessor?
    private var sessionStarted = false

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inFlight = 0
    private var firstError: Error?

    /// - Parameters:
    ///   - depth: requests kept in flight. **2 is the minimum that works**: depth 1
    ///     fails outright on 23.976 → 60, dropping to 56.7 fps (invariant 3).
    ///   - submissionMode: what this session may assume about the order it is fed. **Defaults
    ///     to `.random`, which is the safe answer and, for anything in this package, the true
    ///     one.** `.sequential` is a claim that the submissions follow presentation order
    ///     *without jump or skip*, and every caller here breaks that claim: a pool is fed a
    ///     stride, and any run that skips a scene cut's all-passthrough interval leaves a gap.
    ///     A session told `.sequential` across such a gap carries an optical flow describing an
    ///     interval it was never given, and the two frames after each cut come back as a plain
    ///     cross-fade. See `InterpolationPipeline` for the measurement. Ask for `.sequential`
    ///     only if you are the thing producing the stream *and* you know it is unbroken.
    ///   - qualityPrioritization: the framework's model tier. **Defaults to `.normal`, the
    ///     shipping setting**, so passing nothing reproduces every measurement in `reports/`.
    ///     `.quality` is the slower tier and exists here only so the difference can be measured.
    public init(source: FrameRate, output: FrameRate, depth: Int = 2,
                submissionMode: SubmissionOrder = .random,
                qualityPrioritization: VTFrameRateConversionConfiguration.QualityPrioritization
                    = .normal) {
        self.sourceRate = source
        self.outputRate = output
        self.depth = max(2, depth)
        self.submissionMode = submissionMode
        self.qualityPrioritization = qualityPrioritization

        // One interval can produce at most ceil(out/src) frames, plus slack for the
        // phase landing just either side of a boundary.
        let ratio = output.doubleValue / source.doubleValue
        self.maximumInterpolationsPerInterval = Int(ratio.rounded(.up)) + 2
    }

    public func setSubmissionOrder(_ order: SubmissionOrder) {
        submissionMode = order
    }

    // MARK: - Session

    /// The configuration this engine would start a session with.
    ///
    /// Split out of ``prepare(width:height:)`` so the one thing §37 depends on — that
    /// ``qualityPrioritization`` actually reaches the framework's own object rather than being
    /// accepted and dropped — can be checked without a GPU, a film, or a stopwatch. A tier that
    /// stopped being passed through would leave every wall-clock measurement in §37 describing a
    /// setting that was not in force, and nothing about the timings would look wrong.
    func makeConfiguration(width: Int, height: Int) -> VTFrameRateConversionConfiguration? {
        // Invariant 6: leave usePrecomputedFlow off. Pre-computed flow measured 14%
        // *slower*, not faster.
        VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: qualityPrioritization,
            revision: VTFrameRateConversionConfiguration.defaultRevision
        )
    }

    public func prepare(width: Int, height: Int) throws {
        guard !sessionStarted else { return }

        guard let configuration = makeConfiguration(width: width, height: height) else {
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
                submissionMode: submissionMode == .sequential
                    ? .sequential : .random,
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
            //
            // Invariant 23: the caller's completion runs *before* this request is
            // retired from the pipeline. `leavePipeline` is what releases the
            // depth semaphore, and `drain()` returns as soon as `inFlight` reaches
            // zero — so retiring first let `drain()` return while the last
            // completion was still running. The caller would then truncate its
            // output file, or hand it to an encoder, before the final frames had
            // been written. That is not theoretical: it cost the last two output
            // frames of every run, silently, as black.
            request.completion(error.map { .failure($0) } ?? .success(()))
            self?.leavePipeline(error: error)
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
