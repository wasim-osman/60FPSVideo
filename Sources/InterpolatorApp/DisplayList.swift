import AppKit
import CoreGraphics
import Foundation
import Interpolator

/// The screens that are connected right now, and the pixel size a file should be for each.
///
/// ## Why the size comes from `CGDisplayPixelsWide`, and not from the mode list
///
/// The obvious way to ask "how big is this screen" is to walk `CGDisplayCopyAllDisplayModes`
/// and take the largest `pixelWidth × pixelHeight`. **That answer is wrong on the machine this
/// was written on, and wrong in the direction that looks right.**
///
/// Measured here, for the LG ULTRAGEAR — the display a 3440×1440 file is actually for:
///
/// ```
/// CGDisplayPixelsWide/High            3440 × 1440     <- the size the file should be
/// current mode pixelWidth/Height      3440 × 1440
/// largest pixel mode in the mode list 3840 × 2160     <- a scaled mode, not native
/// ```
///
/// 3840×2160 is a mode the display accepts over DisplayPort — the panel is driven at that
/// resolution and scales it down itself. It is *larger* than the panel, so a "biggest mode"
/// heuristic picks it every time, and the conversion would deliver a 4K file for a 1440p
/// screen: 38% more pixels than the display has, an interpolation an entire rung of the width
/// ladder more expensive, and a picture the panel then throws away. `CGDisplayPixelsWide/High`
/// reports what the display is *currently driven at*, which is the only number that answers the
/// question being asked.
///
/// This is the same class of mistake as `max()` over a list of things that are not alternatives.
/// The mode list is a list of *offerings*, not a list of *sizes*, and it includes modes the
/// panel cannot natively show.
///
/// ## Scale factor is carried but not applied
///
/// `CGDisplayPixelsWide/High` is already in pixels — on a Retina panel in a scaled mode it
/// reports the framebuffer the window server is actually compositing, e.g. 3024 for a 14-inch
/// MacBook set to "looks like 1512". So the scale factor is *reported* for the readout and is
/// deliberately **not** multiplied in. Applying it a second time would ask for a 6048-wide file
/// for a 3024-wide framebuffer.
@MainActor
enum DisplayList {

    /// One connected screen.
    struct Display: Identifiable, Hashable {

        /// `CGDirectDisplayID`. Stable for as long as the display is attached, which is why it
        /// is what the picker tags rows with rather than the name — two identical monitors on
        /// one desk would otherwise be one row.
        let id: CGDirectDisplayID

        /// `NSScreen.localizedName` — "LG ULTRAGEAR", "Built-in Retina Display".
        let name: String

        /// The pixel size a file should be, from `CGDisplayPixelsWide/High`.
        let size: OutputSize

        /// `NSScreen.backingScaleFactor`. Shown, not applied.
        let scale: Double

        let isMain: Bool
        let isBuiltIn: Bool

        /// The row's second line: everything needed to tell two displays apart, and to see why
        /// the number is the number.
        var detail: String {
            var parts = [size.label]
            if scale != 1 { parts.append(String(format: "%.0f× scale", scale)) }
            if isBuiltIn { parts.append("built in") }
            if isMain { parts.append("main") }
            return parts.joined(separator: " · ")
        }

        /// A name for a file destined for this display.
        var fileLabel: String { "\(name) — \(size.label)" }
    }

    /// Every connected screen, main first, then by name.
    ///
    /// Ordered rather than left in `NSScreen.screens` order because that order is the order
    /// displays were attached, which changes when a monitor is unplugged and plugged back in —
    /// and a picker whose rows move between visits is a picker that gets mis-clicked.
    static var connected: [Display] {
        NSScreen.screens
            .compactMap(display(for:))
            .sorted { first, second in
                if first.isMain != second.isMain { return first.isMain }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    /// The screen a window is on, which is the one a playback setting is about.
    static func display(for screen: NSScreen?) -> Display? {
        guard let screen else { return nil }
        return display(for: screen)
    }

    private static func display(for screen: NSScreen) -> Display? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)

        // Zero means the display is asleep, mirrored away, or otherwise not currently driven.
        // Falling back to the window server's own view of it keeps the row present — a display
        // that vanishes from the picker while it is asleep is a display the user cannot choose.
        var width = CGDisplayPixelsWide(id)
        var height = CGDisplayPixelsHigh(id)
        if width <= 0 || height <= 0 {
            let backing = screen.convertRectToBacking(screen.frame).size
            width = Int(backing.width.rounded())
            height = Int(backing.height.rounded())
        }
        guard width > 0, height > 0 else { return nil }

        return Display(id: id,
                       name: screen.localizedName,
                       size: OutputSize(width: width, height: height),
                       scale: Double(screen.backingScaleFactor),
                       isMain: CGDisplayIsMain(id) != 0,
                       isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }

    /// The display whose native size is exactly this, if one is connected.
    ///
    /// Used to turn a stored size back into a display for the picker's selection, so that
    /// reopening Settings shows the screen that was chosen rather than "Custom". The first
    /// match wins: two displays of the same size are interchangeable for this purpose, which is
    /// the whole reason the setting is stored as a *size*.
    static func display(matching size: OutputSize) -> Display? {
        connected.first { $0.size == size }
    }
}

// MARK: - The picker's value

/// What the output-size picker is set to.
///
/// ## Why this is not just `OutputSize?`
///
/// The setting *is* a size — that is what gets stored and what goes in the job fingerprint. But
/// the picker has to distinguish three states that a bare `OutputSize?` collapses together:
/// "the film's own size", "the screen called LG ULTRAGEAR", and "a size that is not any
/// connected screen" — the last being what a remembered choice becomes when the television is
/// unplugged. Presenting an unplugged TV's size as if it were still a listed display would be
/// the picker lying about the machine.
///
/// So the choice is derived from the stored size and the connected displays, and mapped back on
/// the way out. ``OutputTargetChoice/resolve(from:)`` and ``target`` are the two directions, and
/// they are the only places that conversion happens.
enum OutputTargetChoice: Hashable {

    /// Deliver the film at whatever size it was interpolated at. The default.
    case source

    /// Deliver at a connected screen's native size.
    case display(CGDirectDisplayID)

    /// Deliver at a size that is not currently any connected screen — a remembered choice, or
    /// one typed in by hand.
    case size(OutputSize)

    /// What the stored setting amounts to, given the screens attached now.
    ///
    /// Main-actor isolated because it reads ``DisplayList/connected``, which asks the window
    /// server. Only the two members that touch the display list carry the annotation — ``tag``
    /// and ``init?(tag:)`` are pure string work and stay usable from anywhere, which is what
    /// lets a `Picker` be built from them without the isolation spreading.
    @MainActor
    static func resolve(from stored: OutputSize?) -> OutputTargetChoice {
        guard let stored else { return .source }
        if let display = DisplayList.display(matching: stored) { return .display(display.id) }
        return .size(stored)
    }

    /// The setting this choice writes back.
    ///
    /// `.display` resolves through the live display list, so the size stored is the size
    /// measured now. A display that has gone away in the meantime resolves to `nil` — which is
    /// `.source`, and is the honest answer for "a screen that is not there".
    @MainActor
    var target: OutputSize? {
        switch self {
        case .source: nil
        case .display(let id): DisplayList.connected.first { $0.id == id }?.size
        case .size(let size): size
        }
    }

    /// A stable tag for the picker.
    var tag: String {
        switch self {
        case .source: "source"
        case .display(let id): "display:\(id)"
        case .size(let size): "size:\(size.width)x\(size.height)"
        }
    }

    init?(tag: String) {
        if tag == "source" { self = .source; return }
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        if parts[0] == "display", let id = UInt32(parts[1]) {
            self = .display(CGDirectDisplayID(id))
            return
        }
        if parts[0] == "size" {
            let dimensions = parts[1].split(separator: "x").compactMap { Int($0) }
            guard dimensions.count == 2 else { return nil }
            self = .size(OutputSize(width: dimensions[0], height: dimensions[1]))
            return
        }
        return nil
    }
}
