import Interpolator
import SwiftUI

/// The player.
///
/// The video surface is a bare `NSView` hosting the display layer the presenter writes into;
/// everything around it is transport and — the part §13 asks for — an honest readout of what
/// the machine is actually managing, rather than a spinner that implies everything is fine.
struct PlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            surface
            Divider()
            transport
        }
        .background(Color.black)
    }

    // MARK: - The picture

    private var surface: some View {
        ZStack {
            VideoSurface(host: model.displayHost)

            if model.film == nil {
                emptyState
            }

            if let preparing = model.preparing {
                busyState(preparing)
            }

            if let error = model.loadError {
                errorState(error)
            }

            if !model.problems.isEmpty {
                problemBadge
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 42, weight: .thin))
            Text("No film open")
                .font(.title3)
            Text("Open a film to watch it at 59.94 fps.\n"
                 + "The conversion runs as it plays, so 4K drops frames — the readout below says how many.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Film…") { model.chooseAndOpen() }
                .keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    private func busyState(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Could not open the film")
                .font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var problemBadge: some View {
        VStack {
            HStack {
                Spacer()
                Label("\(model.problems.count) problem(s)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(10)
                    .help(model.problems.prefix(8).joined(separator: "\n"))
            }
            Spacer()
        }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 6) {
            scrubber
            controls
            readout
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(Fmt.timecode(model.isScrubbing ? model.scrubPosition
                                                : (model.status?.position ?? 0)))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 82, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { model.isScrubbing ? model.scrubPosition
                                             : (model.status?.position ?? 0) },
                    set: { model.scrubPosition = $0 }),
                in: 0...max(1, model.film?.info.duration ?? 1),
                onEditingChanged: { editing in
                    model.isScrubbing = editing
                    // A seek rebuilds the session, so it happens when the drag *ends*: a
                    // slider that seeked on every pixel would spend the whole drag tearing
                    // down and rebuilding, and show the user nothing but the first frame.
                    if !editing { model.seek(to: model.scrubPosition) }
                })
            .disabled(model.film == nil)

            Text(Fmt.time(model.film?.info.duration ?? 0))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 62, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                model.seek(to: (model.status?.position ?? 0) - 10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(.borderless)

            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.status?.state == .playing
                      ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 30)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.film == nil)

            Button {
                model.seek(to: (model.status?.position ?? 0) + 10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 18)

            Picker("", selection: Binding(
                get: { model.settings.playbackSpeed },
                set: { model.setSpeed($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Text(speed == 1 ? "1×" : String(format: "%g×", speed)).tag(speed)
                }
            }
            .labelsHidden()
            .frame(width: 76)

            Button {
                model.setSoundEnabled(!model.settings.useSound)
            } label: {
                Image(systemName: model.settings.useSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(.borderless)
            .help(model.soundLine ?? "No soundtrack")
            .disabled(model.film == nil)

            Slider(value: Binding(get: { model.settings.volume },
                                  set: { model.setVolume($0) }), in: 0...1)
                .frame(width: 90)
                .disabled(model.film == nil || !model.settings.useSound)

            Spacer()

            if let film = model.film {
                Text(Fmt.format(film.info))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open…") { model.chooseAndOpen() }
                .controlSize(.small)
        }
    }

    // MARK: - The honest readout

    /// §13, made concrete: **no silent degradation.**
    ///
    /// The recorded decision is true 4K with the drops accepted. That is a legitimate choice
    /// and it must not look like a working 60 fps player — so when the source is above 1080p
    /// and the measured presented rate is short of the target, the app says so, gives the
    /// number, and offers the one-click way out that the same decision required.
    @ViewBuilder
    private var readout: some View {
        if let film = model.film, let status = model.status {
            HStack(spacing: 14) {
                let target = model.settings.policy.resolve(source: film.info.frameRate).output
                let targetRate = target.doubleValue
                let short = model.presentedRate > 0 && model.presentedRate < targetRate * 0.9

                Label(String(format: "%.1f fps of %.2f presented", model.presentedRate, targetRate),
                      systemImage: short ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(short ? .orange : .secondary)

                Text("·").foregroundStyle(.tertiary)

                Text(skippedLine(status, total: film.info.duration * film.info.frameRate.doubleValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if status.dropped > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(status.dropped) late frames discarded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if short, film.is4K {
                    Button("Interpolate at 1080p") {
                        model.settings.interpolateAtFullResolution = false
                        model.reloadForSettingsChange()
                    }
                    .controlSize(.small)
                    .help("A quarter of the interpolation work, at the cost of resolution. "
                          + "The 4K decision's one-click way out.")
                }

                Spacer()

                if let line = model.soundLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// How much of the film is being computed, stated as a count and a share.
    ///
    /// The two numbers mean different things and both are worth showing: a **skipped interval**
    /// is work the player refused to do because the clock had passed it, and a **discarded
    /// frame** is a finished frame whose moment had passed. Only the first one costs smoothness
    /// at 4K; the second is the presenter doing its job.
    private func skippedLine(_ status: PlaybackController.Status, total: Double) -> String {
        guard total > 0 else { return "—" }
        let share = Double(status.skippedIntervals) / total
        return String(format: "%d of %.0f intervals skipped (%.0f%%)",
                      status.skippedIntervals, total, share * 100)
    }
}
