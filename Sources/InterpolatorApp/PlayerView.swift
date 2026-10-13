import Interpolator
import SwiftUI

/// The player.
///
/// The video surface is a bare `NSView` hosting the display layer the presenter writes into;
/// everything around it is transport and — the part §13 asks for — an honest readout of what
/// the machine is actually managing, rather than a spinner that implies everything is fine.
///
/// ## Two layouts, and how they are switched
///
/// Windowed, the transport is a strip under the picture. In full screen it **floats over** the
/// picture and hides itself after a few still seconds, which is the difference between a video
/// window and a video *viewer*. Floating is not decoration: a viewer's chrome comes and goes
/// several times a minute, and a transport that occupied space would resize the picture on every
/// appearance — the film would visibly reflow under a moving pointer.
///
/// The two are switched with **`AnyLayout`, not an `if`**, and that is load-bearing.
///
/// The obvious way to write this is a branch — `if isFullScreen { floating } else { strip }` —
/// and it **destroys the picture**. Measured on the real 4K film: windowed, 28.2% of the picture
/// area lit; press ⌃⌘F, and it is 0.0% — pure black, for the rest of the session, with the
/// player's own readout still reporting 59.9 fps of 59.94 presented and three dropped frames in
/// three minutes. The session was healthy and nothing was on screen.
///
/// The mechanism is the shared view. `VideoSurface` hands SwiftUI the *same* `NSView` every time —
/// it has to, because the presenter holds a reference to the layer inside it — so a branch that
/// contains a `VideoSurface` on both sides gives SwiftUI two representables wrapping one view.
/// When the condition flips, SwiftUI builds the new branch (which adopts that view) and *then*
/// dismantles the old one, and the old one's teardown removes the very view the new branch is
/// using. The picture is gone from the window while the layer keeps being fed.
///
/// This is why switching Convert ⇄ Player does *not* break it, in either build: `BatchView` has no
/// video surface, so there is never a second representable to tear down. The bug needed a branch
/// whose two sides both contain the picture, and full screen was the first such branch.
///
/// `AnyLayout` keeps one child list — the same views, in the same order — and changes only how
/// they are arranged, so `surface` never changes identity and is never torn down. See
/// `RootView.body`, which had the same bug one level up.
struct PlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let layout = model.isFullScreen
            ? AnyLayout(ZStackLayout(alignment: .bottom))
            : AnyLayout(VStackLayout(spacing: 0))

        layout {
            surface
            transportArea
        }
        .background(Color.black)
    }

    // MARK: - The picture

    private var surface: some View {
        ZStack {
            // Double click is the gesture a viewer reaches for, so it is wired to the same action
            // the menu item and ⌃⌘F are. It has to be handled inside the `NSView`: see
            // `VideoLayerView`.
            VideoSurface(host: model.displayHost,
                         onDoubleClick: { model.toggleFullScreen() })

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

    /// The transport, in whichever of its two presentations the current layout calls for.
    ///
    /// **Faded, never removed**, and that is a correctness requirement rather than a style: taking
    /// it out of the tree would change the number of children the layout has, which re-identifies
    /// the picture beside it — and re-identifying the picture costs the picture. It also means the
    /// transport never reflows the surface, so the film does not resize every time the chrome
    /// appears.
    ///
    /// A strip in the window, a floating panel over the picture in full screen: the background is
    /// the one thing that differs, and it follows the layout rather than the visibility.
    private var transportArea: some View {
        transport
            .background(model.isFullScreen ? AnyShapeStyle(.ultraThinMaterial)
                                           : AnyShapeStyle(.bar))
            .overlay(alignment: .top) {
                if !model.isFullScreen { Divider() }
            }
            .opacity(model.chromeHidden ? 0 : 1)
            .allowsHitTesting(!model.chromeHidden)
            .animation(.easeInOut(duration: 0.18), value: model.chromeHidden)
    }

    private var transport: some View {
        VStack(spacing: 6) {
            scrubber
            controls
            readout
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                model.nudge(by: -AppModel.backSeconds)
            } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.borderless)
            .disabled(model.film == nil)
            .help("Back \(Int(AppModel.backSeconds)) seconds — ←")

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
                model.nudge(by: AppModel.forwardSeconds)
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(.borderless)
            .disabled(model.film == nil)
            .help("Forward \(Int(AppModel.forwardSeconds)) seconds — →")

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

            Button {
                model.toggleFullScreen()
            } label: {
                Image(systemName: model.isFullScreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Full screen — ⌃⌘F, or double-click the picture. Escape leaves it.")

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

                // Which resolution the trade was made at. Without it the readout says the film is
                // keeping up but not what it cost to keep up, and the cost here is the picture.
                //
                // **The number is also the control.** This is the one setting a viewer changes
                // *while watching*, because "is the drops-free 1080p worth more than native size
                // with half the intervals skipped?" is a question you can only answer by looking
                // at both. Burying it in Settings made it a decision to go and make; here it is a
                // decision you make where the answer is reported.
                if let size = model.interpolationSize {
                    Text("·").foregroundStyle(.tertiary)
                    Picker(selection: resolutionChoice) {
                        ForEach(PlaybackResolutionPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    } label: {
                        Text(interpolationLine(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .help("The size the interpolator runs at. **Full** is the film's own "
                          + "resolution — the best picture, and on a 4K film this machine cannot "
                          + "hold the rate, so intervals get skipped. **Automatic** measures the "
                          + "film and takes the widest size that does hold it.")
                }

                Text("·").foregroundStyle(.tertiary)

                // How those pixels are fitted to the window. This is the second half of the
                // same question the size above answers: the size is how many pixels the engine
                // produces, this is what is done with them when the window is a different shape.
                //
                // **Live, unlike the picker beside it.** `videoGravity` is read by the layer as
                // it composites, so this applies on the next frame with no rebuild — which is
                // why it can be a control a viewer works while watching, and the resolution
                // cannot.
                Picker(selection: fitChoice) {
                    ForEach(FitMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text(presentationLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .help(model.settings.playbackFitMode.detail
                      + "\n\nApplied to the window as it plays — no interruption, unlike the "
                      + "size picker, which rebuilds the session.")

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

                if short, model.settings.playbackResolution == .source {
                    Button("Hold real time instead") {
                        model.settings.playbackResolution = .automatic
                        model.reloadForSettingsChange()
                    }
                    .controlSize(.small)
                    .help("Measure the film and interpolate at the widest size that holds the "
                          + "rate, instead of keeping the resolution and dropping frames.")
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

    /// The readout's resolution picker, wired to the rebuild.
    ///
    /// Changing this changes the size the decoder is told to scale to, the size of every buffer,
    /// and the size the encoder writes — so it cannot be applied to a running session. It is the
    /// same route the Settings picker takes, deliberately: one setting, one way of applying it,
    /// so the two cannot drift apart.
    private var resolutionChoice: Binding<PlaybackResolutionPolicy> {
        Binding(
            get: { model.settings.playbackResolution },
            set: { policy in
                guard policy != model.settings.playbackResolution else { return }
                model.settings.playbackResolution = policy
                model.reloadForSettingsChange()
            })
    }

    /// The size the interpolator runs at, and whether that was measured or asked for.
    ///
    /// "measured" and not "chosen", because the difference matters to a user deciding whether to
    /// override it: `Automatic` arrived at this number by running the pipeline, and a manual
    /// policy arrived at it because someone said so.
    private func interpolationLine(_ size: (width: Int, height: Int,
                                            policy: PlaybackResolutionPolicy,
                                            calibrated: Bool)) -> String {
        let how = size.calibrated ? "measured" : size.policy.label.lowercased()
        return "\(size.width)×\(size.height) · \(how)"
    }

    /// The fit mode, and what it is doing to this picture in this window.
    ///
    /// The mode alone would be a word the user has to interpret. The geometry is what makes it
    /// concrete — "26 px bars each side" or "146 px cropped top and bottom" — and it is computed
    /// from the layer's actual bounds, so it is right after a resize and right in full screen
    /// without the app having to know which of the two it is in.
    private var presentationLine: String {
        let mode = model.settings.playbackFitMode.label.lowercased()
        guard let geometry = model.presentationGeometry,
              geometry.scaledWidth != geometry.targetWidth
                || geometry.scaledHeight != geometry.targetHeight else {
            return mode
        }
        return "\(mode) · \(geometry.summary)"
    }

    /// The readout's Fit/Fill control, wired to the live property.
    private var fitChoice: Binding<FitMode> {
        Binding(get: { model.settings.playbackFitMode },
                set: { model.setPlaybackFitMode($0) })
    }
}
