import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let fileName: String?
    let durationLabel: String
    let onPick: ([URL]) -> Void

    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: fileName == nil ? [8, 6] : []))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            if let fileName {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(durationLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose File…") { isImporting = true }
                }
                .padding(.horizontal, 20)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Drop stand-up videos here")
                        .font(.headline)
                    Text("MP4, MOV, M4A, MP3 or WAV — several at once is fine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose File…") { isImporting = true }
                        .padding(.top, 4)
                }
            }
        }
        .frame(height: fileName == nil ? 160 : 76)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // Providers resolve independently, so each URL is handed
                    // over as it arrives; the model appends to its queue.
                    Task { @MainActor in onPick([url]) }
                }
            }
            return true
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: AudioExtractor.supportedContentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onPick(urls)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}
