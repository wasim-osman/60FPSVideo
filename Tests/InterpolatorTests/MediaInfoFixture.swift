import Foundation
@testable import Interpolator

/// A `MediaInfo` for tests that only need a size.
///
/// ## Why this is shared rather than copied per suite
///
/// `MediaInfo`'s memberwise initialiser takes sixteen arguments, so every suite that needs "a
/// 1920×816 film" writes the same block of `nil`s — and two copies of a fixture drift. One gets
/// a `frameRate` changed, the other does not, and then two suites are measuring two different
/// things while both claiming to describe the same film.
///
/// Built through the real initialiser rather than a stub: a change to what `MediaInfo` requires
/// then shows up as a compile error here, in one place, instead of as a test that silently
/// measures nothing.
extension MediaInfo {

    /// A film of a given pixel size.
    ///
    /// `format` follows from the bit depth in the way the real probe does — `p010` for 10-bit —
    /// so a test that cares about 10-bit handling does not have to remember to set both.
    static func film(_ width: Int, _ height: Int, format: FrameFormat = .nv12) -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/dev/null"),
                  width: width, height: height,
                  frameRate: .twentyFourNTSC, frameCount: nil, duration: 60,
                  pixelFormat: format == .p010 ? "yuv420p10le" : "nv12", format: format,
                  colorPrimaries: nil, transferFunction: nil, colorSpace: nil,
                  colorRange: nil, masteringDisplay: nil, contentLightLevel: nil,
                  audioTracks: [], chapterCount: 0)
    }
}
