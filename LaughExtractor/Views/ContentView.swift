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
            DropZoneView(fileName: model.fileName,
                         durationLabel: model.durationLabel) { url in
                player.stop()
                model.load(url: url)
            }

            if model.audio != nil {
                waveform
                controls
                Divider()
                results
            } else if case .extracting(let fraction) = model.phase {
                importing(fraction)
            } else {
                Spacer()
            }
        }
        .padding(16)
    }

    // MARK: - Sections

    @ViewBuilder
    private var waveform: some View {
        if let audio = model.audio {
            WaveformView(peaks: audio.waveformPeaks,
                         hopSeconds: audio.waveformHopSeconds,
                         duration: audio.duration,
                         segments: model.segments,
                         playhead: player.playingIndex == nil ? nil : player.playhead) { seconds in
                guard let segment = model.segments.first(where: {
                    seconds >= $0.startSeconds && seconds <= $0.endSeconds
                }) else { return }
                player.toggle(segment, in: audio.masterURL)
            }
            .frame(height: 84)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .extracting(let fraction):
                busyRow("Decoding audio…", fraction: fraction)
                Button("Cancel") { model.cancel() }
            case .preparingClassifier:
                busyRow("Loading the sound classifier…", fraction: nil)
                Button("Cancel") { model.cancel() }
            case .classifying(let fraction):
                busyRow("Listening for laughter…", fraction: fraction)
                Button("Cancel") { model.cancel() }
            case .finishingAnalysis:
                busyRow("Finishing analysis…", fraction: nil)
                Button("Cancel") { model.cancel() }
            case .exporting(let completed, let total):
                busyRow("Exporting clip \(min(completed + 1, total)) of \(total)…",
                        fraction: total > 0 ? Double(completed) / Double(total) : nil)
                Button("Cancel") { model.cancel() }
            case .idle, .ready:
                Button(model.hasAnalyzed ? "Re-analyze" : "Analyze") {
                    player.stop()
                    model.analyze(config: settings.segmenterConfig)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)

                if model.hasAnalyzed {
                    Text("\(model.segments.count) burst\(model.segments.count == 1 ? "" : "s") · \(model.selection.count) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Export Selected…") {
                    player.stop()
                    model.export(format: settings.exportFormat)
                }
                .disabled(model.selectedSegments.isEmpty)
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    /// Import feedback. Before extraction finishes there is no waveform, no
    /// controls row, nothing — without this the drop of a long video looks
    /// like the app ignored it.
    private func importing(_ fraction: Double) -> some View {
        VStack(spacing: 14) {
            Spacer()
            busyRow("Decoding audio…", fraction: fraction)
            Button("Cancel") { model.cancel() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

    @ViewBuilder
    private var results: some View {
        if model.hasAnalyzed && model.segments.isEmpty {
            emptyState
        } else if !model.segments.isEmpty {
            HStack {
                Text("Bursts").font(.headline)
                Spacer()
                Button("Select All") { model.selectAll() }
                    .controlSize(.small)
                Button("None") { model.selectNone() }
                    .controlSize(.small)
            }

            List(model.segments) { segment in
                SegmentRowView(segment: segment,
                               isSelected: model.selection.contains(segment.index),
                               isPlaying: player.playingIndex == segment.index,
                               onToggleSelection: { model.toggle(segment) },
                               onTogglePlayback: {
                                   guard let audio = model.audio else { return }
                                   player.toggle(segment, in: audio.masterURL)
                               })
            }
            .listStyle(.inset)
        } else {
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No laughter detected")
                .font(.headline)
            Text("Try lowering the laugh threshold or the ambient noise margin, or shortening the minimum duration. Bursts whose average is more talk than laugh are discarded on purpose.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let diagnostics = model.diagnostics {
                diagnosticsView(diagnostics)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Which of the three detection rules is doing the rejecting, updated live
    /// as the sliders move. A rule whose pass count is near zero is the culprit.
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
