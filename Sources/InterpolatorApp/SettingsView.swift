import Combine
import Interpolator
import SwiftUI

/// The settings screen, and the recorded decisions it exposes.
///
/// Each one carries the reason it is what it is, because every one of these was a measurement
/// and a choice — and a preference panel that presents a decision as a taste is a panel that
/// invites the user to undo the measurement.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// The screens attached right now.
    ///
    /// Held in `@State` rather than read inline because ``DisplayList/connected`` walks
    /// `NSScreen.screens` and every mode of every display — cheap, but not something to do once
    /// per body evaluation, and not something whose *result* should change silently while the
    /// picker is open. It is refreshed when the window server says the screen arrangement
    /// changed, which is the event that actually invalidates it.
    @State private var displays: [DisplayList.Display] = []

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Output") {
                Picker("Frame rate", selection: $model.settings.policyLabel) {
                    ForEach(OutputRatePolicy.all, id: \.label) { policy in
                        Text(policy.label).tag(policy.label)
                    }
                }
                Text("59.94 is 60000/1001, the exact NTSC-derived rate. A whole 60.000 "
                     + "would drift against the source by a frame every thousand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                Picker("Interpolate at", selection: $model.settings.playbackResolution) {
                    ForEach(PlaybackResolutionPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .onChange(of: model.settings.playbackResolution) {
                    model.reloadForSettingsChange()
                }
                Text(model.settings.playbackResolution.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("At 4K an interval costs 104.7 ms against the 41.7 ms the film spends "
                     + "playing one. Automatic measures the film and picks the widest size that "
                     + "still holds real time — the job SVP's fi_auto does — which on this "
                     + "machine is 1920 wide. Full keeps true 4K and accepts the dropped frames.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Routed through the model rather than written straight to the settings, because
                // the layer has to be told as well — and there are two ways in (here and the
                // player's readout), so there is one method that does both.
                Picker("Fit the picture", selection: Binding(
                    get: { model.settings.playbackFitMode },
                    set: { model.setPlaybackFitMode($0) })) {
                    ForEach(FitMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(model.settings.playbackFitMode.detail
                     + " The same two modes a conversion writes with, so what is on screen here "
                     + "is what a file will look like. Changing it takes effect on the next "
                     + "frame — unlike the size above, which rebuilds the session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Play the soundtrack", isOn: $model.settings.useSound)
                Text("The sound is the clock: a compressed stream cannot be retimed, so the "
                     + "picture follows the sound rather than the other way round.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speed") {
                Stepper("Sessions in parallel: \(model.settings.workerLabel)",
                        value: $model.settings.workers, in: 0...8)
                Text(workerExplanation)
                    .font(.caption)
                    .foregroundStyle(model.settings.workerCount > RenderWorkers.optimum
                                     ? .orange : .secondary)

                Stepper("Requests in flight: \(model.settings.depth)",
                        value: $model.settings.depth, in: 1...8)
                Text(model.settings.depth < 2
                     ? "Depth 1 fails outright on 23.976 → 59.94 — measured, dropping to 56.7 fps."
                     : "Two is the minimum that works, and past it this does nothing at all: "
                       + "at 4K, depths 2, 4 and 8 all give 13.4–13.5 source frames/s. It is "
                       + "not a speed control — the sessions above are.")
                    .font(.caption)
                    .foregroundStyle(model.settings.depth < 2 ? .orange : .secondary)
            }

            Section("Quality") {
                Picker("Conversion", selection: $model.settings.conversionQuality) {
                    ForEach(ConversionQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                Text(model.settings.conversionQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.settings.conversionQuality == .fast {
                    Text("Fast interpolates at 1080p. What the file comes out as is the next "
                         + "setting down, not this one — so Fast plus a 4K delivery is a real "
                         + "combination, and it is the cheap way to get one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Detect scene cuts", isOn: $model.settings.sceneDetection)
                Text("Both engines double-expose across a cut, so the interpolations there are "
                     + "turned into held frames. Off only to see why it is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            outputSizeSection

            folderAccessSection

            Section("Container and audio") {
                Picker("Write", selection: $model.settings.container) {
                    ForEach(AudioMuxPolicy.Container.allCases, id: \.rawValue) { container in
                        Text(container.label).tag(container.rawValue)
                    }
                }
                Text(model.settings.audioPolicy.container == .mkv
                     ? "Matroska, with the disc's own track copied bit for bit. The only route "
                       + "for DTS-HD MA, TrueHD and DTS:X — none of which MP4 can hold, and "
                       + "none of which macOS will open if ffmpeg writes it anyway."
                     : "MP4 with AAC. Universally playable, and a re-encode: the disc's DTS-X "
                       + "master is not what comes out. Choose Matroska to keep it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Long jobs") {
                Toggle("Render in pieces", isOn: Binding(
                    get: { model.settings.segmentSeconds != nil },
                    set: { model.settings.segmentSeconds = $0 ? 600 : nil }))
                if let seconds = model.settings.segmentSeconds {
                    Stepper("About \(Fmt.interval(seconds)) each",
                            value: Binding(get: { seconds },
                                           set: { model.settings.segmentSeconds = $0 }),
                            in: 60...3600, step: 60)
                    Toggle("Keep the pieces after joining", isOn: $model.settings.keepSegments)
                    Text("Not for speed — pieces cost a little. It is so a crash, a power cut "
                         + "or a quit costs one piece rather than four hours, and so a job can "
                         + "be stopped and picked up again. A resumed job skips what the "
                         + "manifest says is finished.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Replace an existing output", isOn: $model.settings.overwrite)
                Text("Off, because silently overwriting a film is not something a converter "
                     + "should do on its own initiative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Preview limit")
                    Spacer()
                    TextField("whole film", value: $model.settings.previewSeconds,
                              format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text("seconds").foregroundStyle(.secondary)
                }
                Text("Convert only the first part of each film, to try a setting without "
                     + "waiting for three hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Where outputs go") {
                HStack {
                    Text(model.settings.outputDirectory.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    } ?? "Beside each film")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        if let url = FileChooser.chooseFolder(
                            message: "Where converted films should go") {
                            model.settings.outputDirectory = url.path
                        }
                    }
                    Button("Beside Each Film") {
                        model.settings.outputDirectory = nil
                    }
                    .disabled(model.settings.outputDirectory == nil)
                }
            }

            Section("Prepared soundtracks") {
                HStack {
                    Text(model.cacheEntries == 0
                         ? "Nothing cached"
                         : "\(model.cacheEntries) file(s), \(Fmt.megabytes(model.cacheBytes))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clearCache() }
                        .disabled(model.cacheEntries == 0)
                    Button("Refresh") { model.refreshCacheSize() }
                }
                Text("A soundtrack has to be copied out of the Matroska before it can be played. "
                     + "It is kept so the next open is instant — the real disc takes 1.7 s and "
                     + "307 MB to prepare, and 0.00 s to reuse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
        // Reports what the app already knows; asks nothing. A probe here would raise a system
        // prompt for every folder macOS has never been answered about — measured, one dialog
        // at a time, Desktop then Documents then Downloads. The row offers to ask instead.
        .task { model.refreshFolderAccess() }
    }

    // MARK: - Output size

    /// The size a converted file comes out at — a different question from the size it was
    /// interpolated at, and the one that decides whether a film is right for a particular screen.
    ///
    /// ## Why the screens are listed by name
    ///
    /// Because "3440 × 1440" is not something a person knows about their own television, and
    /// because getting it wrong is invisible until the file is played somewhere else. The rows
    /// are the connected displays, and the number beside each is the number the app measured for
    /// it — `CGDisplayPixelsWide/High`, which is not the largest mode the display accepts. On
    /// this machine those differ by 38% for the ultrawide. See ``DisplayList``.
    ///
    /// ## Why this is one setting for the queue and not one per film
    ///
    /// A queue is a run of films for one screen. Asking per film would mean answering the same
    /// question once per file, and the answer would be the same every time. The queue's footer
    /// states the current answer, so the choice is visible where the jobs are rather than only
    /// here.
    @ViewBuilder
    private var outputSizeSection: some View {
        // Declared here rather than reached for from `body`: `@Bindable` is a local, and a
        // computed property is a separate scope. Without it `$model.settings…` does not resolve
        // and the picker has no binding.
        @Bindable var model = model
        let choice = OutputTargetChoice.resolve(from: model.settings.batchOutputSize)

        Section("Output size") {
            Picker("Deliver at", selection: targetChoiceBinding(choice)) {
                Text("The film's own size").tag(OutputTargetChoice.source.tag)
                ForEach(displays) { display in
                    Text(display.fileLabel).tag(OutputTargetChoice.display(display.id).tag)
                }
                // A remembered size that matches no connected screen still gets a row, because
                // it is still the setting. A picker whose selection has no matching tag shows a
                // blank row and silently changes the setting when the menu is dismissed, which
                // is a worse answer than an extra line.
                if case .size(let size) = choice {
                    Text("\(size.label) — remembered").tag(OutputTargetChoice.size(size).tag)
                }
            }
            .onChange(of: model.settings.batchOutputSize) {
                model.reloadForSettingsChange()
            }

            HStack {
                Text("Fit")
                Picker("Fit", selection: $model.settings.batchFitMode) {
                    ForEach(FitMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Text(model.settings.batchFitMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(outputSizeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.settings.batchOutputSize == nil {
                Text("Conversions deliver exactly what was interpolated, at the quality chosen "
                     + "above. This is the behaviour every measurement in the reports was taken "
                     + "with, and the cheapest setting here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { displays = DisplayList.connected }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayList.connected
        }
    }

    /// The picker's selection, as a string tag in both directions.
    ///
    /// The stored value is an `OutputSize`; the tags are strings, because a `CGDirectDisplayID`
    /// is only meaningful while the display is attached and a size is meaningful forever. The
    /// conversion is ``OutputTargetChoice``'s job and this is the only place it is wired to a
    /// control, so there is one path in and one path out.
    private func targetChoiceBinding(_ choice: OutputTargetChoice) -> Binding<String> {
        Binding(get: { choice.tag },
                set: { tag in
                    guard let picked = OutputTargetChoice(tag: tag) else { return }
                    model.settings.batchOutputSize = picked.target
                })
    }

    /// What the setting does, in the numbers it was chosen by.
    ///
    /// States the arithmetic for the film that is actually loaded, when there is one, because a
    /// generic sentence about aspect ratios is not what a user needs before starting a four-hour
    /// job — they need to know whether *this* film comes out with bars or with the sides cut off.
    private var outputSizeExplanation: String {
        var text = "Interpolation cost is a step function of frame width, so the size a file is "
            + "interpolated at and the size it is delivered at are two separate questions. "
            + "Delivering 3440 × 1440 from a 1080p interpolation costs 2.7 ms per frame for the "
            + "upscale against 37 ms for the interpolation itself."
        if let film = model.film, let target = model.settings.batchOutputSize {
            let geometry = OutputGeometry.fitting(
                source: OutputSize(width: film.info.width, height: film.info.height),
                target: target,
                mode: model.settings.batchFitMode)
            text += "\n\n\(film.name) is \(film.info.width) × \(film.info.height): "
                + "\(geometry.summary)."
        } else if model.film == nil {
            text += "\n\nNo film is loaded, so the effect on one cannot be shown yet."
        }
        return text
    }

    // MARK: - Speed

    /// Why the session count is what it is, in the numbers it was decided by.
    private var workerExplanation: String {
        let chosen = model.settings.workerCount
        var text = "One session cannot be hurried — `VTFrameProcessor` runs its requests one "
            + "at a time, and asking it for more at once changes nothing. Separate sessions do "
            + "overlap. Measured on real 4K HDR film, whole conversions: "
            + "1 session 13.4 source frames/s, 2 sessions 21.5, 4 sessions 23.8 — a 1.78× "
            + "speed-up, or 2.0 h instead of 3.5 for a two-hour film. "
        if chosen > RenderWorkers.optimum {
            text += "Six sessions measured **17.0** — slower than four. Past the knee the "
                + "sessions fight over the same unit and the losers just queue, so this "
                + "setting is set above what the machine wants."
        } else if model.settings.workers == 0 {
            text += "This machine asks for \(chosen)."
        }
        return text
    }

    // MARK: - Folder access

    /// The status line, and the one thing that can be done about it.
    ///
    /// macOS gates Desktop, Documents, Downloads and removable volumes, and it remembers one
    /// answer per app. A refusal is silent from then on: films do not open, the file chooser
    /// lists nothing, and no error says why. So the row states what macOS has actually said —
    /// which it only knows from work already done — and when there is something to ask or
    /// repair, the row itself is the button.
    @ViewBuilder
    private var folderAccessSection: some View {
        let report = model.folderAccess
        let actionable = report.needsAttention

        Section("Folder access") {
            Button {
                model.fixFolderAccess()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol(for: report))
                        .foregroundStyle(report.isClear ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.headline)
                            .foregroundStyle(actionable ? .primary : .secondary)
                        if !report.detail.isEmpty {
                            Text(report.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    if model.checkingFolderAccess {
                        ProgressView().controlSize(.small)
                    } else if actionable {
                        Text(report.isClear ? "Ask…" : "Allow…").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            // Clickable exactly when clicking would do something, and a plain row otherwise —
            // a settings line that offers to "fix" a working state is a line that teaches the
            // user not to trust the others.
            .buttonStyle(.plain)
            .disabled(!actionable || model.checkingFolderAccess)

            Text(folderExplanation(report))
                .font(.caption)
                .foregroundStyle(report.isClear ? Color.secondary : Color.orange)
        }
    }

    private func symbol(for report: FolderAccess.Report) -> String {
        if !report.isClear { return "exclamationmark.triangle.fill" }
        return report.notAsked.isEmpty ? "checkmark.circle.fill" : "questionmark.circle"
    }

    private func folderExplanation(_ report: FolderAccess.Report) -> String {
        if !report.isClear {
            return "macOS has refused this app access. It will not ask again — a second attempt "
                + "fails immediately and silently, which is why a film that will not open gives "
                + "no error at all. Clicking opens the switch, in System Settings ▸ Privacy & "
                + "Security ▸ Files and Folders."
        }
        if !report.notAsked.isEmpty {
            return "Nothing has needed these folders yet, so macOS has not been asked. Clicking "
                + "asks it — and because there is no way to read the answer without attempting "
                + "the access, that raises one system prompt per folder. macOS remembers the "
                + "answer for the whole app, and a refusal is silent: films simply stop opening."
        }
        return "Every folder the app uses has been read successfully, so nothing is being "
            + "withheld. macOS remembers this per app, and it is not something the app can "
            + "look up — this is the record of what it has actually been able to do."
    }
}

/// The About panel.
///
/// A window of its own rather than the standard panel, because the licences here are the point:
/// this app is a shell over Apple's frame interpolation, and the honest version of "what is
/// this made of" needs more than two lines.
enum AboutWindow {
    @MainActor private static var controller: NSWindowController?

    @MainActor
    static func show() {
        if let controller {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "About 60FPS"
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        let created = NSWindowController(window: window)
        controller = created
        created.showWindow(nil)
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("60FPS").font(.system(size: 26, weight: .semibold))
                    Text("Frame interpolation for macOS, using Apple's own engine.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("What does the interpolating") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("**VTFrameProcessor** — Apple's VideoToolbox frame-rate "
                             + "conversion, on the Neural Engine and GPU.")
                        Text("A CoreML RIFE 4.25 tier was built and measured on real 4K HDR "
                             + "footage, and dropped: statistically indistinguishable from "
                             + "VTFrameProcessor — Δ 0.105 MAE — at **4.06×** the cost.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("What it costs, measured") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("2 h film, 23.976 → 59.94")
                            .font(.caption.weight(.semibold))
                        Text("Quality (source resolution) · 2.1 h     Fast (1080p) · 0.5 h")
                            .font(.system(.caption, design: .monospaced))
                        Text("Playback · **Automatic** interpolates at 1920 wide and holds real "
                             + "time — the engine sustains 75.8 output fps against the 59.94 "
                             + "needed. Full 4K sustains 34.5 fps, so about half the intervals "
                             + "are skipped; that is still one click away.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Licences") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("**60FPS** is MIT licensed.")
                        Text("""
                             Permission is hereby granted, free of charge, to any person \
                             obtaining a copy of this software and associated documentation \
                             files (the "Software"), to deal in the Software without \
                             restriction, including without limitation the rights to use, \
                             copy, modify, merge, publish, distribute, sublicense, and/or sell \
                             copies of the Software, and to permit persons to whom the Software \
                             is furnished to do so, subject to the following conditions:

                             The above copyright notice and this permission notice shall be \
                             included in all copies or substantial portions of the Software.

                             THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, \
                             EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
                             MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
                             NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT \
                             HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, \
                             WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
                             OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
                             DEALINGS IN THE SOFTWARE.
                             """)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Divider()
                        Text("**ffmpeg** does the decoding, the container work and the audio. "
                             + "It is not bundled — 60FPS uses the copy on your system, and "
                             + "says so when it cannot find one.")
                            .font(.caption)
                        Text("FFmpeg is licensed under the LGPL or GPL depending on how it was "
                             + "built. This app invokes it as a separate program.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Before you install") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This build is **ad-hoc signed and not notarised**. macOS will "
                             + "warn you the first time you open it; right-click and choose "
                             + "Open, or allow it in Privacy & Security.")
                            .font(.caption)
                        Text("Requires macOS 15.4 or later — that is where "
                             + "`VTFrameRateConversionConfiguration` landed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}
