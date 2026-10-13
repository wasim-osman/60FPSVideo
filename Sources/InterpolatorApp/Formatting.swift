import Foundation
import Interpolator
import SwiftUI

/// Number formatting, in one place.
///
/// Every one of these is a number the reports quote, and a number shown two different ways in
/// two places is a number the user has to reconcile. The bit rate in particular: the target is
/// not the delivered rate — the encoder undershoots on dark content by nearly a third — so the
/// only rate worth showing is the one derived from the bytes actually written, which is what
/// `BatchConverter.Result` does and what these format.
enum Fmt {

    /// `HH:MM:SS`, or `MM:SS` for anything under an hour.
    ///
    /// Deliberately not `DateComponentsFormatter`: a film is 6411.456 s and the tenths matter
    /// when you are looking for a frame, while a duration of "1:46:51" is easier to read than
    /// "1:46:51.456" when you are not.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// `HH:MM:SS` with the fraction, for a playhead.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00:00.0" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = seconds - Double(hours * 3600 + minutes * 60)
        return String(format: "%d:%02d:%04.1f", hours, minutes, secs)
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1e6
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
        return String(format: "%.1f MB", mb)
    }

    static func rate(_ megabits: Double) -> String {
        String(format: "%.1f Mbps", megabits)
    }

    /// A duration as a rough human interval, for a projection.
    ///
    /// Deliberately coarse, and the coarseness is the point: the rate behind it moves with how
    /// much of the picture is moving, so "3.8 hours" is a claim the measurement supports and
    /// "3:47:12" is not — the seconds would be invented. The boundaries are where the wording
    /// stops being useful: below a minute a projection has nothing to say, and past ninety
    /// minutes "1.6 hours" is read faster than "96 minutes".
    static func interval(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "less than a minute" }
        if seconds < 90 { return "under two minutes" }
        let minutes = seconds / 60
        if minutes < 90 { return String(format: "%.0f minutes", minutes) }
        return String(format: "%.1f hours", minutes / 60)
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    /// The bit depth and colour of a source, as one phrase.
    static func format(_ info: Interpolator.MediaInfo) -> String {
        var parts = ["\(info.width)×\(info.height)", "\(info.format.bitDepth)-bit"]
        if info.isHDR {
            parts.append("HDR")
            if let primaries = info.colorPrimaries { parts.append(primaries) }
        }
        return parts.joined(separator: " · ")
    }
}
