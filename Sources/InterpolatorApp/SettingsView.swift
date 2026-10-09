import Interpolator
import SwiftUI

/// The settings screen, and the recorded decisions it exposes.
///
/// Each one carries the reason it is what it is, because every one of these was a measurement
/// and a choice — and a preference panel that presents a decision as a taste is a panel that
/// invites the user to undo the measurement.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

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
                Picker("Interpolate at", selection: $model.settings.interpolateAtFullResolution) {
                    Text("The film's own resolution").tag(true)
                    Text("1080p").tag(false)
                }
                .onChange(of: model.settings.interpolateAtFullResolution) {
                    model.reloadForSettingsChange()
                }
                Text("At 4K an interval costs 104.7 ms against the 41.7 ms the film spends on "
                     + "one, so about half the intervals are skipped and the picture judders. "
                     + "1080p is a quarter of the work and plays smoothly. Batch conversion is "
                     + "unaffected — it always writes at the source's resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Play the soundtrack", isOn: $model.settings.useSound)
                Text("The sound is the clock: a compressed stream cannot be retimed, so the "
                     + "picture follows the sound rather than the other way round.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quality") {
                Stepper("Requests in flight: \(model.settings.depth)",
                        value: $model.settings.depth, in: 1...8)
                Text(model.settings.depth < 2
                     ? "Depth 1 fails outright on 23.976 → 59.94 — measured, dropping to 56.7 fps."
                     : "Two is the minimum that works and the point where more stops helping.")
                    .font(.caption)
                    .foregroundStyle(model.settings.depth < 2 ? .orange : .secondary)

                Toggle("Detect scene cuts", isOn: $model.settings.sceneDetection)
                Text("Both engines double-expose across a cut, so the interpolations there are "
                     + "turned into held frames. Off only to see why it is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                        Text("1080p batch · 1.6 h     4K batch · 3.8 h")
                            .font(.system(.caption, design: .monospaced))
                        Text("4K playback · ~half the intervals skipped, ~19 fps presented, "
                             + "a fifth of a second of picture behind the sound, permanently "
                             + "and without growth.")
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
