import CoreVideo
import Foundation

/// A frame-pair interpolation engine.
///
/// The protocol is deliberately shaped around *intervals*, not individual frames,
/// because that is where the speed is. `VTFrameProcessor` takes one source pair and
/// a list of phases, and returns all of those frames from a single call: on
/// 23.976 → 59.94 it produces two output frames for 80 ms. An engine API that
/// submitted one phase per call would throw that away.
///
/// ## Buffer contract
///
/// `sourceA`, `sourceB` and every element of `destinations` are borrowed for the
/// duration of the request. The engine may hold them until `completion` fires, so
/// the caller must not reuse or mutate them before then. Buffers come from a
/// ``PixelBufferPool`` and are recycled on release.
public protocol InterpolationEngine: AnyObject, Sendable {

    /// For logs and reports.
    var name: String { get }

    /// Upper bound on how many interpolated frames one interval can produce. The
    /// caller sizes its destination list from this.
    var maximumInterpolationsPerInterval: Int { get }

    /// Requests the engine keeps in flight. The caller sizes its buffer ring from
    /// this, and it is the number of slots that have to be independently guarded
    /// (invariant 17) — so it is part of the contract, not an implementation detail.
    var depth: Int { get }

    /// Prepare for a given frame size. Must be called once before any `submit`.
    func prepare(width: Int, height: Int) throws

    /// Submit one interval. Returns immediately; the work continues in the
    /// background and `completion` is called on an arbitrary thread.
    func submit(_ request: InterpolationRequest)

    /// Block until every submitted request has completed. Throws the first error
    /// any request reported.
    func drain() throws

    /// Release the session. Safe to call more than once.
    func shutdown()
}

/// `CVPixelBuffer` is a Core Foundation type and carries no `Sendable` conformance,
/// but the engine's contract is precisely that a submitted buffer is not touched by
/// anyone else until its completion fires. This struct states that contract to the
/// compiler rather than leaving it implicit. It is not a licence to pass buffers
/// around freely — it is a promise that the borrow is respected.
public struct InterpolationRequest: @unchecked Sendable {
    public let interval: SourceInterval
    public let sourceA: CVPixelBuffer
    public let sourceB: CVPixelBuffer
    /// One destination per interpolated frame, in the same order as
    /// `interval.interpolations`.
    public let destinations: [CVPixelBuffer]
    public let completion: @Sendable (Result<Void, Error>) -> Void

    public init(interval: SourceInterval,
                sourceA: CVPixelBuffer,
                sourceB: CVPixelBuffer,
                destinations: [CVPixelBuffer],
                completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.interval = interval
        self.sourceA = sourceA
        self.sourceB = sourceB
        self.destinations = destinations
        self.completion = completion
    }
}
