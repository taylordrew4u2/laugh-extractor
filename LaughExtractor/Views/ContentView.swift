import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = AppModel()
    @StateObject private var player = PreviewPlayer()
    @State private var showSettings = true

    var body: some View {
        HSplitView {
            main
                .frame(minWidth: 600)
            if showSettings {
                SettingsView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .help("Show or hide detection settings")
            }
        }
        // The whole point of caching frame scores: a slider change re-runs the
        // segmenter only — no re-extraction, no re-inference.
        .onChange(of: settings.segmenterConfig) { _, newConfig in
            model.resegment(config: newConfig)
        }
        .onChange(of: model.currentID) { _, _ in
            player.stop()
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            DropZoneView(fileName: model.current?.fileName,
                         durationLabel: durationLabel) { urls in
                player.stop()
                model.add(urls: urls, config: settings.segmenterConfig)
            }

            if model.items.count > 1 {
                fileStrip
            }

            if let current = model.current {
                content(for: current)
            } else {
                Spacer()
            }
        }
        .padding(16)
    }

    private var durationLabel: String {
        guard let audio = model.current?.audio else { return "" }
        return LaughSegment.timecode(audio.duration)
    }

    // MARK: - Batch strip

    /// One chip per queued video: status at a glance, click to switch.
    private var fileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.items) { item in
                    chip(for: item)
                }
                Button("Clear All") {
                    player.stop()
                    model.reset()
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(for item: VideoItem) -> some View {
        let isCurrent = item.id == model.currentID
        return HStack(spacing: 6) {
            chipGlyph(for: item)
            Text(item.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule().strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture { model.currentID = item.id }
        .help(chipHelp(for: item))
    }

    @ViewBuilder
    private func chipGlyph(for item: VideoItem) -> some View {
        switch item.status {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .extracting, .preparingClassifier, .classifying, .finishingAnalysis:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            Text("\(item.segments.count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(item.relaxed ? Color.orange : Color.accentColor))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
    }

    private func chipHelp(for item: VideoItem) -> String {
        switch item.status {
        case .queued: return "Waiting to be processed"
        case .extracting: return "Decoding audio…"
        case .preparingClassifier, .classifying, .finishingAnalysis: return "Listening for laughter…"
        case .ready: return item.relaxed
            ? "\(item.segments.count) bursts (found with relaxed rules)"
            : "\(item.segments.count) bursts"
        case .failed(let message): return message
        }
    }

    // MARK: - Current item

    @ViewBuilder
    private func content(for item: VideoItem) -> some View {
        switch item.status {
        case .queued:
            centred {
                busyRow("Waiting for its turn…", fraction: nil)
            }
        case .extracting(let fraction):
            centred {
                busyRow("Decoding audio…", fraction: fraction)
                Button("Cancel") { model.cancel() }
            }
        case .preparingClassifier:
            centred {
                busyRow("Loading the sound classifier…", fraction: nil)
                Button("Cancel") { model.cancel() }
            }
        case .classifying(let fraction):
            centred {
                busyRow("Listening for laughter…", fraction: fraction)
                Button("Cancel") { model.cancel() }
            }
        case .finishingAnalysis:
            centred {
                busyRow("Finishing analysis…", fraction: nil)
                Button("Cancel") { model.cancel() }
            }
        case .failed(let message):
            centred {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Retry") { model.retry(item.id) }
            }
        case .ready:
            waveform(for: item)
            controls(for: item)
            Divider()
            results(for: item)
        }
    }

    private func centred<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func waveform(for item: VideoItem) -> some View {
        if let audio = item.audio {
            WaveformView(peaks: audio.waveformPeaks,
                         hopSeconds: audio.waveformHopSeconds,
                         duration: audio.duration,
                         segments: item.segments,
                         playhead: player.playingIndex == nil ? nil : player.playhead) { seconds in
                guard let segment = item.segments.first(where: {
                    seconds >= $0.startSeconds && seconds <= $0.endSeconds
                }) else { return }
                player.toggle(segment, in: audio.masterURL)
            }
            .frame(height: 84)
        }
    }

    @ViewBuilder
    private func controls(for item: VideoItem) -> some View {
        HStack(spacing: 12) {
            if let progress = model.exportProgress {
                busyRow("Exporting clip \(min(progress.completed + 1, progress.total)) of \(progress.total)…",
                        fraction: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil)
                Button("Cancel") { model.cancel() }
            } else {
                Text("\(item.segments.count) burst\(item.segments.count == 1 ? "" : "s") · \(item.selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Export Selected…") {
                    player.stop()
                    model.exportCurrent(format: settings.exportFormat)
                }
                .disabled(item.selection.isEmpty)
                .keyboardShortcut("e", modifiers: .command)

                if model.completedItems.count > 1 {
                    Button("Export All…") {
                        player.stop()
                        model.exportAll(format: settings.exportFormat)
                    }
                    .disabled(model.completedItems.allSatisfy(\.selection.isEmpty))
                    .help("Exports every video's selected bursts, prefixed with each video's name.")
                }
            }
        }
    }

    /// Status row for any busy phase: an always-animating spinner (so the app
    /// visibly isn't frozen even when the fraction stalls), the stage label,
    /// and — when the stage has a measurable fraction — a bar with a percentage.
    private func busyRow(_ label: String, fraction: Double?) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            if let fraction {
                ProgressView(value: fraction) { Text(label) }
                    .frame(maxWidth: 320)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(label)
                    .font(.callout)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(for item: VideoItem) -> some View {
        if item.segments.isEmpty {
            emptyState(for: item)
        } else {
            if item.relaxed {
                Label("Nothing passed the current settings — showing the most laugh-like bursts found with relaxed rules.",
                      systemImage: "wand.and.rays")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Bursts").font(.headline)
                Spacer()
                Button("Select All") { model.selectAll() }
                    .controlSize(.small)
                Button("None") { model.selectNone() }
                    .controlSize(.small)
            }

            List(item.segments) { segment in
                SegmentRowView(segment: segment,
                               isSelected: item.selection.contains(segment.index),
                               isPlaying: player.playingIndex == segment.index,
                               onToggleSelection: { model.toggle(segment) },
                               onTogglePlayback: {
                                   guard let audio = item.audio else { return }
                                   player.toggle(segment, in: audio.masterURL)
                               })
            }
            .listStyle(.inset)
        }
    }

    private func emptyState(for item: VideoItem) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No laughter detected")
                .font(.headline)
            Text("Even the relaxed fallback found nothing laugh-like in this audio. Check that the recording contains audible audience laughter.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let diagnostics = item.diagnostics {
                diagnosticsView(diagnostics)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Which detection stage is doing the rejecting, updated live as the
    /// sliders move. A stage whose count sits at zero is the culprit.
    private func diagnosticsView(_ d: DetectionDiagnostics) -> some View {
        VStack(spacing: 3) {
            if let floor = d.noiseFloorDb {
                Text("Classifier peaks — laugh \(score(d.peakLaugh)) · speech \(score(d.peakSpeech))"
                     + " · noise floor \(String(format: "%.0f", floor)) dB")
            } else {
                Text("Classifier peaks — laugh \(score(d.peakLaugh)) · speech \(score(d.peakSpeech))"
                     + " · ambient gate off")
            }
            Text("Windows (of \(d.frameCount)) — laugh ≥ threshold: \(d.passedLaugh) · "
                 + "above noise floor: \(d.passedAmbient) · both: \(d.laughPositive)")
            Text("Bursts — candidates: \(d.candidateBursts) · too short: \(d.rejectedShort) · "
                 + "too talky: \(d.rejectedTalky) · weak dominance: \(d.rejectedDominance) · "
                 + "applause: \(d.rejectedApplause) · kept: \(d.kept)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
