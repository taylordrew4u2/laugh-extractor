import SwiftUI

/// Threshold controls. Everything here re-runs only the segmenter, so dragging
/// a slider updates the burst list immediately.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Detection") {
                    slider("Laugh threshold",
                           value: $settings.laughThreshold,
                           range: 0.05...0.95,
                           step: 0.01,
                           format: "%.2f",
                           help: "How confident the classifier has to be before a window counts as laughter.")

                    slider("Speech ceiling",
                           value: $settings.speechCeiling,
                           range: 0.01...0.60,
                           step: 0.01,
                           format: "%.2f",
                           help: "The no-talking rule. Windows scoring above this for speech are rejected outright.")

                    slider("Laugh/speech dominance",
                           value: $settings.dominanceRatio,
                           range: 1.0...8.0,
                           step: 0.1,
                           format: "%.1f×",
                           help: "Laughter must beat speech by at least this factor.")
                }

                section("Boundaries") {
                    slider("Minimum duration",
                           value: $settings.minDurationMs,
                           range: 200...3000,
                           step: 50,
                           format: "%.0f ms",
                           help: "Measured after edge trimming.")

                    slider("Edge trim",
                           value: $settings.edgeTrimMs,
                           range: 0...500,
                           step: 10,
                           format: "%.0f ms",
                           help: "Cut inward at both ends, where the comedian's voice is most likely to bleed in.")

                    slider("Bridge gap",
                           value: $settings.bridgeGapMs,
                           range: 0...500,
                           step: 10,
                           format: "%.0f ms",
                           help: "Dropouts up to this long won't split one laugh into two clips.")
                }

                section("Applause") {
                    Toggle("Reject applause-heavy bursts", isOn: $settings.rejectApplause)
                    slider("Applause ceiling",
                           value: $settings.applauseCeiling,
                           range: 0.05...0.95,
                           step: 0.01,
                           format: "%.2f",
                           help: "Mean applause score above this drops the burst.")
                        .disabled(!settings.rejectApplause)
                        .opacity(settings.rejectApplause ? 1 : 0.4)
                }

                section("Export") {
                    Picker("Format", selection: $settings.exportFormat) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text(settings.exportFormat.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("MP3 isn't offered: macOS decodes it but ships no encoder.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                Button("Reset to Defaults") { settings.resetToDefaults() }
                    .controlSize(.small)

                Text("Defaults are tuned for a close-mic'd comic in a small room. Bigger rooms want a higher laugh threshold and a slightly looser speech ceiling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        format: String,
                        help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
        .help(help)
    }
}
