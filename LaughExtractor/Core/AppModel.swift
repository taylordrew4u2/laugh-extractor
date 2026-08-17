import Foundation
import AVFoundation
import AppKit

/// One video in the batch, from drop to exported clips.
struct VideoItem: Identifiable {
    enum Status: Equatable {
        case queued
        case extracting(Double)
        case preparingClassifier
        case classifying(Double)
        case finishingAnalysis
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .queued, .ready, .failed: return false
            case .extracting, .preparingClassifier, .classifying, .finishingAnalysis: return true
            }
        }
    }

    let id = UUID()
    let sourceURL: URL
    var status: Status = .queued
    var audio: ExtractedAudio?
    var analysis: AnalysisResult?
    var segments: [LaughSegment] = []
    var diagnostics: DetectionDiagnostics?
    /// The configured rules found nothing; these bursts came from the fallback ladder.
    var relaxed = false
    var selection: Set<Int> = []

    var fileName: String { sourceURL.lastPathComponent }

    /// Prefix for exported clip files — the video's name without its extension,
    /// with filesystem-hostile characters flattened.
    var exportPrefix: String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let cleaned = base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return String(cleaned).isEmpty ? "laugh" : String(cleaned)
    }
}

/// Owns the batch: a queue of videos processed one at a time, each going
/// drop → extract → classify → segment without further clicks.
///
/// The important invariant survives from the single-file days: frame scores
/// are cached per item, so moving a threshold slider re-runs `Segmenter` over
/// every analyzed item and nothing else. Tuning has to feel instant.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var items: [VideoItem] = []
    @Published var currentID: UUID?
    @Published private(set) var exportProgress: (completed: Int, total: Int)?
    @Published var errorMessage: String?
    @Published var lastExportFolder: URL?

    /// The segmenter config the pipeline uses when an analysis finishes.
    /// Updated by every `resegment` call, so it tracks the sliders.
    private var lastConfig: SegmenterConfig = .default
    private var pipeline: Task<Void, Never>?
    private var exportWork: Task<Void, Never>?

    var current: VideoItem? {
        guard let currentID else { return nil }
        return items.first { $0.id == currentID }
    }

    var isExporting: Bool { exportProgress != nil }

    var completedItems: [VideoItem] { items.filter { $0.analysis != nil } }

    // MARK: - Loading

    /// Queues videos for processing. Adding never clears existing items —
    /// that's what `reset()` is for.
    func add(urls: [URL], config: SegmenterConfig) {
        lastConfig = config
        for url in urls {
            let item = VideoItem(sourceURL: url)
            items.append(item)
            if currentID == nil { currentID = item.id }
        }
        processNextIfIdle()
    }

    /// Puts a failed item back in the queue and restarts the pipeline.
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .failed = items[index].status else { return }
        items[index].status = .queued
        processNextIfIdle()
    }

    // MARK: - Pipeline

    private func processNextIfIdle() {
        guard pipeline == nil else { return }
        guard let next = items.first(where: { $0.status == .queued }) else { return }

        let id = next.id
        pipeline = Task { [weak self] in
            await self?.process(id: id)
            let wasCancelled = Task.isCancelled
            self?.pipeline = nil
            // A cancelled run stops the pump; queued items wait for the next add/retry.
            if !wasCancelled { self?.processNextIfIdle() }
        }
    }

    private func process(id: UUID) async {
        func update(_ change: (inout VideoItem) -> Void) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            change(&items[index])
        }
        guard let item = items.first(where: { $0.id == id }) else { return }

        do {
            var audio = item.audio
            if audio == nil {
                update { $0.status = .extracting(0) }
                let url = item.sourceURL
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                let extracted = try await AudioExtractor.extract(from: url) { fraction in
                    Task { @MainActor [weak self] in
                        self?.mutate(id: id) { $0.status = .extracting(fraction) }
                    }
                }
                guard !Task.isCancelled else {
                    AudioExtractor.cleanUp(extracted)
                    update { $0.status = .failed("Cancelled") }
                    return
                }
                update { $0.audio = extracted }
                audio = extracted
            }

            guard let audio else { return }
            update { $0.status = .preparingClassifier }
            let result = try await LaughDetector.analyze(analysisFileURL: audio.analysisURL) { progress in
                Task { @MainActor [weak self] in
                    self?.mutate(id: id) {
                        switch progress {
                        case .preparingClassifier: $0.status = .preparingClassifier
                        case .classifying(let fraction): $0.status = .classifying(fraction)
                        case .finishing: $0.status = .finishingAnalysis
                        }
                    }
                }
            }
            guard !Task.isCancelled else {
                update { $0.status = .failed("Cancelled") }
                return
            }

            let outcome = Segmenter.segmentsNeverEmpty(from: result.frames,
                                                       windowDuration: result.windowDuration,
                                                       hopDuration: result.hopDuration,
                                                       config: lastConfig)
            update {
                $0.analysis = result
                $0.segments = outcome.segments
                $0.diagnostics = outcome.diagnostics
                $0.relaxed = outcome.relaxed
                $0.selection = Set(outcome.segments.map(\.index))
                $0.status = .ready
            }
        } catch is CancellationError {
            update { $0.status = .failed("Cancelled") }
        } catch {
            update { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func mutate(id: UUID, _ change: (inout VideoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: - Segmentation

    /// Cheap enough to call straight from a slider's `onChange`. Re-runs the
    /// segmenter over every analyzed item so switching videos never shows
    /// results from stale settings.
    func resegment(config: SegmenterConfig) {
        lastConfig = config
        for index in items.indices {
            guard let analysis = items[index].analysis else { continue }
            let previous = items[index].selection
            let outcome = Segmenter.segmentsNeverEmpty(from: analysis.frames,
                                                       windowDuration: analysis.windowDuration,
                                                       hopDuration: analysis.hopDuration,
                                                       config: config)
            items[index].segments = outcome.segments
            items[index].diagnostics = outcome.diagnostics
            items[index].relaxed = outcome.relaxed
            // Segment indices are reassigned on every pass, so re-selecting by
            // index only makes sense for the ones that still exist.
            items[index].selection = previous.intersection(outcome.segments.map(\.index))
        }
    }

    // MARK: - Export

    /// Exports the current video's selected bursts.
    func exportCurrent(format: ExportFormat) {
        guard let current, current.audio != nil, !selectedSegments(of: current).isEmpty else { return }
        export(items: [current], format: format)
    }

    /// Exports every analyzed video's selected bursts, each set prefixed with
    /// its video's name so the files don't collide.
    func exportAll(format: ExportFormat) {
        let exportable = completedItems.filter { !selectedSegments(of: $0).isEmpty }
        guard !exportable.isEmpty else { return }
        export(items: exportable, format: format)
    }

    private func selectedSegments(of item: VideoItem) -> [LaughSegment] {
        item.segments.filter { item.selection.contains($0.index) }
    }

    private func export(items exportItems: [VideoItem], format: ExportFormat) {
        guard exportWork == nil, let folder = chooseOutputFolder() else { return }

        let jobs: [(prefix: String, masterURL: URL, segments: [LaughSegment])] = exportItems.compactMap { item in
            guard let audio = item.audio else { return nil }
            let segments = selectedSegments(of: item)
            guard !segments.isEmpty else { return nil }
            // A single video keeps the classic "laugh_01" names.
            let prefix = exportItems.count == 1 ? "laugh" : item.exportPrefix
            return (prefix, audio.masterURL, segments)
        }
        let totalClips = jobs.reduce(0) { $0 + $1.segments.count }
        guard totalClips > 0 else { return }

        exportProgress = (0, totalClips)
        exportWork = Task { [weak self] in
            defer { folder.stopAccessingSecurityScopedResource() }
            var written: [URL] = []
            var finished = 0
            do {
                for job in jobs {
                    let base = finished
                    let urls = try await Exporter.export(segments: job.segments,
                                                         masterURL: job.masterURL,
                                                         outputDirectory: folder,
                                                         format: format,
                                                         filePrefix: job.prefix) { fraction in
                        let done = base + Int((fraction * Double(job.segments.count)).rounded())
                        Task { @MainActor [weak self] in
                            self?.exportProgress = (done, totalClips)
                        }
                    }
                    written.append(contentsOf: urls)
                    finished += job.segments.count
                }
                await MainActor.run {
                    self?.exportProgress = nil
                    self?.exportWork = nil
                    self?.lastExportFolder = folder
                    NSWorkspace.shared.activateFileViewerSelecting(written)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.exportProgress = nil
                    self?.exportWork = nil
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                    self?.exportProgress = nil
                    self?.exportWork = nil
                }
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
        guard let currentID else { return }
        mutate(id: currentID) {
            if $0.selection.contains(segment.index) {
                $0.selection.remove(segment.index)
            } else {
                $0.selection.insert(segment.index)
            }
        }
    }

    func selectAll() {
        guard let currentID else { return }
        mutate(id: currentID) { $0.selection = Set($0.segments.map(\.index)) }
    }

    func selectNone() {
        guard let currentID else { return }
        mutate(id: currentID) { $0.selection = [] }
    }

    // MARK: - Lifecycle

    /// Stops the pipeline and any export. The in-flight item is marked failed
    /// (retryable); queued items stay queued until something restarts the pump.
    func cancel() {
        pipeline?.cancel()
        exportWork?.cancel()
    }

    func reset() {
        cancel()
        for item in items {
            if let audio = item.audio { AudioExtractor.cleanUp(audio) }
        }
        items = []
        currentID = nil
        errorMessage = nil
        exportProgress = nil
    }
}
