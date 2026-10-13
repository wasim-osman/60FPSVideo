import Interpolator
import SwiftUI

/// The batch converter.
///
/// A queue of films, one at a time, with the progress the pipeline reports per interval and a
/// projection that only appears once there is enough of a run for it to mean anything. The
/// reason it exists at all: a 4K job on a feature film runs for **3.8 hours** measured, and
/// four hours of "nothing is happening" is indistinguishable from a hang.
struct BatchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.jobs.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.addFilms()
            } label: {
                Label("Add Films", systemImage: "plus")
            }

            Spacer()

            if model.queueRunning {
                Button("Stop After This Piece") { model.stopQueue() }
            } else {
                Button("Start") { model.startQueue() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.jobs.allSatisfy { $0.state != .waiting })
            }

            Button("Clear Finished") { model.clearFinished() }
                .disabled(!model.jobs.contains { $0.state == .finished || $0.state == .failed })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 38, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Nothing queued")
                .font(.title3)
            Text("Add films to convert them to \(model.settings.policy.label) fps.\n"
                 + "One at a time — interpolation saturates the GPU, so four at once "
                 + "is four jobs at a quarter speed.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The queue

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.jobs) { job in
                    BatchRow(job: job)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            if let seconds = model.settings.segmentSeconds {
                Label("In \(Fmt.interval(seconds)) pieces, resumable",
                      systemImage: "square.split.2x1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("One render, no resume point", systemImage: "square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("·").foregroundStyle(.tertiary)

            Label("\(model.settings.audioPolicy.label)", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("·").foregroundStyle(.tertiary)

            Label(model.settings.conversionQuality == .fast
                  ? "Interpolating at 1080p"
                  : "Interpolating at the source's resolution",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Text("·").foregroundStyle(.tertiary)

            // The *delivered* size, which is a separate setting from the interpolation size
            // beside it. Both are shown because the pair is the point: "interpolating at 1080p,
            // delivering 3440 × 1440" is the whole arrangement, and either half alone is
            // ambiguous about what a four-hour job is going to produce.
            Label(model.settings.batchOutputLabel, systemImage: "rectangle.inset.filled")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// One row, and the only place the four hours are visible.
struct BatchRow: View {
    @Environment(AppModel.self) private var model
    let job: BatchJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let info = job.info {
                        Text("\(Fmt.format(info)) · \(info.frameRate) → \(model.settings.policy.label)"
                             + (info.duration > 0 ? " · \(Fmt.time(info.duration))" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                statusLabel

                Menu {
                    Button("Reveal Output") { model.reveal(job) }
                        .disabled(job.state != .finished)
                    Button("Copy the Report") { copyReport() }
                        .disabled(job.result == nil)
                    Divider()
                    Toggle("Render Again From Scratch", isOn: Binding(
                        get: { job.restart }, set: { job.restart = $0 }))
                    Button("Remove") { model.remove(job) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            if job.state == .running, let progress = job.progress {
                progressBar(progress)
            }

            if let result = job.result, job.state == .finished {
                summary(result)
            }

            if let failure = job.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !(job.result?.isClean ?? true), let result = job.result {
                ForEach(result.problems.prefix(3), id: \.self) { problem in
                    Text("· \(problem)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch job.state {
        case .waiting: "clock"
        case .running: "gearshape.2"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "pause.circle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .waiting: .secondary
        case .running: .accentColor
        case .finished: .green
        case .failed: .red
        case .stopped: .orange
        }
    }

    private var statusLabel: some View {
        Group {
            if job.state == .running, let elapsed = job.elapsed {
                Text(Fmt.time(elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 62, alignment: .trailing)
    }

    /// The bar, what the bar is measuring, and how much longer it has to go.
    ///
    /// The fraction comes from the pipeline once per interval, and the total is an **estimate**
    /// — Matroska reports `nb_frames=N/A`, so a film's length comes from its duration. So the
    /// bar is honest about reaching 100% slightly before the film ends rather than pretending
    /// to be exact.
    ///
    /// The time remaining is measured from the job's **rate**, not from `elapsed / fraction`.
    /// Those two differ by hours on a real film: the old formula started its clock at the probe,
    /// so every second spent extracting the audio counted as a second of rendering. See
    /// ``ProgressEstimator``.
    private func progressBar(_ progress: BatchConverter.Progress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack(spacing: 8) {
                Text(progress.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let piece = progress.piece, let pieces = progress.pieces, pieces > 1 {
                    Text("piece \(piece) of \(pieces)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                projection(progress)
            }
        }
    }

    /// What the job has left, or an honest admission that it does not know yet.
    @ViewBuilder
    private func projection(_ progress: BatchConverter.Progress) -> some View {
        if progress.stage == .rendering {
            if let remaining = job.remaining {
                Label("about \(Fmt.interval(remaining)) left", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if job.isEstimating {
                // Not a placeholder for a number that is on its way — the estimator genuinely
                // has no rate yet, and saying so beats guessing for the first few seconds.
                Text("estimating…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            // The render is behind us. The tail — restoring the audio, joining the pieces —
            // reports no fraction of its own, and carrying the render's last projection through
            // it would read "about 0 seconds left" for as long as the mux takes.
            Text(progress.stage.description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// What was actually delivered, in the units the reports use.
    private func summary(_ result: BatchConverter.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("\(result.outputFrames) frames")
                Text(Fmt.rate(result.megabitsPerSecond))
                Text(String(format: "%.4f bpp", result.bitsPerPixelPerFrame))
                Text(Fmt.megabytes(result.bytes))
                Text(Fmt.time(result.outputSeconds))
                if let segments = result.segments, !segments.resumed.isEmpty {
                    Text("\(segments.resumed.count) pieces resumed")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("\(result.cutCount) cuts")
                Text(String(format: "%.0f%% passthrough",
                            result.passthroughFraction * 100))
                // Only when it differs from the source. A conversion with no output target
                // delivered the source's size, and printing it twice would be noise.
                if result.delivered.width != result.source.width
                    || result.delivered.height != result.source.height {
                    Text("delivered \(result.delivered.label)")
                        .foregroundStyle(.secondary)
                }
                if let audio = result.audio {
                    Text(audio.summary)
                } else {
                    Text(result.audioPolicy.label)
                }
                if let offset = result.audio?.offset {
                    Text(String(format: "A/V %.1f ms", offset * 1000))
                }
                Spacer()
                Button("Reveal") { model.reveal(job) }
                    .controlSize(.mini)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    /// The report as text, because the numbers are the point and a screenshot is not a report.
    private func copyReport() {
        guard let result = job.result else { return }
        var lines: [String] = []
        lines.append("input   : \(job.input.path)")
        lines.append("output  : \(result.output.path)")
        lines.append("source  : \(Fmt.format(result.source))  \(result.source.frameRate)")
        lines.append("deliver : \(result.delivered.label)"
                     + "  fit \(result.fitMode.label.lowercased())")
        lines.append("rate    : policy \(model.settings.policy.label) -> \(result.resolution.output)"
                     + "  ratio \(result.resolution.ratio.numerator)"
                     + "/\(result.resolution.ratio.denominator)"
                     + (result.resolution.isPassthrough ? "  (already at target)" : ""))
        if let note = result.resolution.note { lines.append("note    : \(note)") }
        if let segments = result.segments {
            lines.append("pieces  : \(segments.summary)")
            if let joined = segments.joined { lines.append("          \(joined.summary)") }
        }
        lines.append("frames  : \(result.report.sourceFrames) source -> \(result.outputFrames) output"
                     + "  (\(result.report.interpolatedFrames) interpolated,"
                     + " \(result.report.passthroughFrames) passthrough)")
        lines.append("cuts    : \(result.cutCount) across \(result.report.decisions.count) intervals,"
                     + " \(result.report.engineCalls) engine calls")
        lines.append(String(format: "encode  : %.1f MB  %.1f Mbps  %.4f bpp  %.1f s of video",
                            Double(result.bytes) / 1e6, result.megabitsPerSecond,
                            result.bitsPerPixelPerFrame, result.outputSeconds))
        lines.append("audio   : \(result.audioPolicy.label)")
        if let audio = result.audio {
            lines.append("          \(audio.summary)")
            if let offset = audio.offset {
                lines.append(String(format: "          A/V offset %.1f ms", offset * 1000))
            }
        }
        lines.append(String(format: "time    : %.1f s wall", result.wallSeconds))
        for problem in result.problems { lines.append("problem : \(problem)") }
        if let segments = result.segments {
            for problem in segments.problems { lines.append("problem : \(problem)") }
        }
        if !result.isClean { lines.append("RESULT  : \(result.problems.count) problem(s)") }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
