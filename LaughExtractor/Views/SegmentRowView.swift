import SwiftUI

struct SegmentRowView: View {
    let segment: LaughSegment
    let isSelected: Bool
    let isPlaying: Bool
    let onToggleSelection: () -> Void
    let onTogglePlayback: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggleSelection() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include laugh \(segment.index)")

            Text(String(format: "%02d", segment.index))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            Text(segment.startTimecode)
                .font(.system(.body, design: .monospaced))
                .frame(width: 92, alignment: .leading)

            Text(segment.durationLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            ConfidenceBar(value: segment.meanLaugh)
                .frame(width: 90, height: 6)
                .help(String(format: "mean laugh %.2f · peak %.2f · mean speech %.2f",
                             segment.meanLaugh, segment.peakLaugh, segment.meanSpeech))

            Spacer(minLength: 8)

            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
    }
}
