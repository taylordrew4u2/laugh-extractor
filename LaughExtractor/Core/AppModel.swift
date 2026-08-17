import Foundation
import AVFoundation
import AppKit

/// Owns the pipeline state for the single window.
///
/// The important invariant lives here: frame scores are cached after analysis,
/// so moving a threshold slider re-runs `Segmenter` and nothing else. Tuning the
/// speech ceiling is the core workflow and it has to feel instant.
@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case extracting(Double)
        /// Loading the CoreML classifier — no fraction to report, just "working".
        case preparingClassifier
        case classifying(Double)
        /// Waiting for the analyzer to deliver its trailing results.
        case finishingAnalysis
        case ready
        case exporting(completed: Int, total: Int)

        var isBusy: Bool {
            switch self {
            case .idle, .ready: return false
            case .extracting, .preparingClassifier, .classifying, .finishingAnalysis, .exporting: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var audio: ExtractedAudio?
    @Published private(set) var segments: [LaughSegment] = []
    @Published private(set) var diagnostics: DetectionDiagnostics?
    @Published private(set) var hasAnalyzed = false
    @Published var selection: Set<Int> = []
    @Published var errorMessage: String?
    @Published var lastExportFolder: URL?

    /// Cached inference output. Never recomputed for a threshold change.
    private var analysis: AnalysisResult?
    private var work: Task<Void, Never>?

    var fileName: String? { audio?.sourceURL.lastPathComponent }
    var duration: Double { audio?.duration ?? 0 }

    var durationLabel: String {
        guard let audio else { return "" }
        return LaughSegment.timecode(audio.duration)
    }

    var selectedSegments: [LaughSegment] {
        segments.filter { selection.contains($0.index) }
    }

    // MARK: - Loading

    func load(url: URL) {
        work?.cancel()
        reset()

        work = Task { [weak self] in
            guard let self else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                await self.setPhase(.extracting(0))
                let extracted = try await AudioExtractor.extract(from: url) { fraction in
                    Task { @MainActor [weak self] in self?.phase = .extracting(fraction) }
                }
                guard !Task.isCancelled else {
                    AudioExtractor.cleanUp(extracted)
                    return
                }
                await MainActor.run {
                    self.audio = extracted
                    self.phase = .idle
                }
            } catch is CancellationError {
                await self.setPhase(.idle)
            } catch {
                await self.fail(error)
            }
        }
    }

    // MARK: - Analysis

    func analyze(config: SegmenterConfig) {
        guard let audio, !phase.isBusy else { return }
        work?.cancel()

        work = Task { [weak self] in
            guard let self else { return }
            do {
                await self.setPhase(.preparingClassifier)
                let result = try await LaughDetector.analyze(analysisFileURL: audio.analysisURL) { update in
                    Task { @MainActor [weak self] in
                        switch update {
                        case .preparingClassifier: self?.phase = .preparingClassifier
                        case .classifying(let fraction): self?.phase = .classifying(fraction)
                        case .finishing: self?.phase = .finishingAnalysis
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.analysis = result
                    self.hasAnalyzed = true
                    self.phase = .ready
                    self.resegment(config: config, selectAll: true)
                }
            } catch is CancellationError {
                await self.setPhase(.idle)
            } catch {
                await self.fail(error)
            }
        }
    }

    /// Cheap enough to call straight from a slider's `onChange`.
    func resegment(config: SegmenterConfig, selectAll: Bool = false) {
        guard let analysis else { return }
        let previous = selection
        let result = Segmenter.segmentsWithDiagnostics(from: analysis.frames,
                                                       windowDuration: analysis.windowDuration,
                                                       hopDuration: analysis.hopDuration,
                                                       config: config)
        segments = result.segments
        diagnostics = result.diagnostics
        // Segment indices are reassigned on every pass, so re-selecting by index
        // only makes sense for the ones that still exist.
        selection = selectAll
            ? Set(segments.map(\.index))
            : previous.intersection(segments.map(\.index))
    }

    // MARK: - Export

    func export(format: ExportFormat) {
        guard let audio, !selectedSegments.isEmpty, !phase.isBusy else { return }
        guard let folder = chooseOutputFolder() else { return }

        let chosen = selectedSegments
        work = Task { [weak self] in
            guard let self else { return }
            defer { folder.stopAccessingSecurityScopedResource() }
            do {
                let total = chosen.count
                await self.setPhase(.exporting(completed: 0, total: total))
                let urls = try await Exporter.export(segments: chosen,
                                                     masterURL: audio.masterURL,
                                                     outputDirectory: folder,
                                                     format: format) { fraction in
                    // The exporter reports (finished ÷ total), so this recovers
                    // the exact clip count for the "clip N of M" label.
                    let completed = Int((fraction * Double(total)).rounded())
                    Task { @MainActor [weak self] in
                        self?.phase = .exporting(completed: completed, total: total)
                    }
                }
                await MainActor.run {
                    self.phase = .ready
                    self.lastExportFolder = folder
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            } catch is CancellationError {
                await self.setPhase(.ready)
            } catch {
                await self.fail(error)
            }
        }
    }

    /// Reuses the remembered folder if there is one, otherwise asks.
    /// Returned with security-scoped access already started.
    private func chooseOutputFolder() -> URL? {
        if let remembered = OutputFolderStore.resolve() { return remembered }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported laugh clips."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        OutputFolderStore.save(url)
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    func forgetOutputFolder() {
        OutputFolderStore.clear()
        lastExportFolder = nil
    }

    // MARK: - Selection

    func toggle(_ segment: LaughSegment) {
        if selection.contains(segment.index) {
            selection.remove(segment.index)
        } else {
            selection.insert(segment.index)
        }
    }

    func selectAll() { selection = Set(segments.map(\.index)) }
    func selectNone() { selection = [] }

    // MARK: - Lifecycle

    func cancel() {
        work?.cancel()
        phase = hasAnalyzed ? .ready : .idle
    }

    func reset() {
        if let audio { AudioExtractor.cleanUp(audio) }
        audio = nil
        analysis = nil
        segments = []
        diagnostics = nil
        selection = []
        hasAnalyzed = false
        errorMessage = nil
        phase = .idle
    }

    private func setPhase(_ newPhase: Phase) async {
        await MainActor.run { self.phase = newPhase }
    }

    private func fail(_ error: Error) async {
        await MainActor.run {
            self.errorMessage = error.localizedDescription
            self.phase = self.hasAnalyzed ? .ready : .idle
        }
    }
}
