import Foundation
import Combine

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a
    case wav

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .wav: return "WAV (lossless)"
        }
    }

    var blurb: String {
        switch self {
        case .m4a: return "Compressed. Small files, opens everywhere."
        case .wav: return "Bit-for-bit copy of the decoded source. No re-encode."
        }
    }
}

/// Persisted configuration, hoisted into an observable object so the core —
/// which knows nothing about SwiftUI — can be handed a plain value type.
///
/// Backed by `UserDefaults` rather than `@AppStorage` because `@AppStorage`
/// only publishes changes when it lives inside a `View`.
@MainActor
final class AppSettings: ObservableObject {

    private enum Key {
        static let laughThreshold = "laughThreshold"
        static let speechCeiling = "speechCeiling"
        static let dominanceRatio = "dominanceRatio"
        static let bridgeGapMs = "bridgeGapMs"
        static let edgeTrimMs = "edgeTrimMs"
        static let minDurationMs = "minDurationMs"
        static let rejectApplause = "rejectApplause"
        static let applauseCeiling = "applauseCeiling"
        static let exportFormat = "exportFormat"
    }

    private let store: UserDefaults

    @Published var laughThreshold: Double { didSet { store.set(laughThreshold, forKey: Key.laughThreshold) } }
    @Published var speechCeiling: Double { didSet { store.set(speechCeiling, forKey: Key.speechCeiling) } }
    @Published var dominanceRatio: Double { didSet { store.set(dominanceRatio, forKey: Key.dominanceRatio) } }
    @Published var bridgeGapMs: Double { didSet { store.set(bridgeGapMs, forKey: Key.bridgeGapMs) } }
    @Published var edgeTrimMs: Double { didSet { store.set(edgeTrimMs, forKey: Key.edgeTrimMs) } }
    @Published var minDurationMs: Double { didSet { store.set(minDurationMs, forKey: Key.minDurationMs) } }
    @Published var rejectApplause: Bool { didSet { store.set(rejectApplause, forKey: Key.rejectApplause) } }
    @Published var applauseCeiling: Double { didSet { store.set(applauseCeiling, forKey: Key.applauseCeiling) } }
    @Published var exportFormat: ExportFormat { didSet { store.set(exportFormat.rawValue, forKey: Key.exportFormat) } }

    init(store: UserDefaults = .standard) {
        let defaults = SegmenterConfig.default
        store.register(defaults: [
            Key.laughThreshold: defaults.laughThreshold,
            Key.speechCeiling: defaults.speechCeiling,
            Key.dominanceRatio: defaults.dominanceRatio,
            Key.bridgeGapMs: defaults.bridgeGapMs,
            Key.edgeTrimMs: defaults.edgeTrimMs,
            Key.minDurationMs: defaults.minDurationMs,
            Key.rejectApplause: defaults.rejectApplause,
            Key.applauseCeiling: defaults.applauseCeiling,
            Key.exportFormat: ExportFormat.m4a.rawValue,
        ])
        self.store = store
        self.laughThreshold = store.double(forKey: Key.laughThreshold)
        self.speechCeiling = store.double(forKey: Key.speechCeiling)
        self.dominanceRatio = store.double(forKey: Key.dominanceRatio)
        self.bridgeGapMs = store.double(forKey: Key.bridgeGapMs)
        self.edgeTrimMs = store.double(forKey: Key.edgeTrimMs)
        self.minDurationMs = store.double(forKey: Key.minDurationMs)
        self.rejectApplause = store.bool(forKey: Key.rejectApplause)
        self.applauseCeiling = store.double(forKey: Key.applauseCeiling)
        self.exportFormat = ExportFormat(rawValue: store.string(forKey: Key.exportFormat) ?? "") ?? .m4a
    }

    /// The pure value the segmenter actually consumes.
    var segmenterConfig: SegmenterConfig {
        SegmenterConfig(laughThreshold: laughThreshold,
                        speechCeiling: speechCeiling,
                        dominanceRatio: dominanceRatio,
                        bridgeGapMs: bridgeGapMs,
                        edgeTrimMs: edgeTrimMs,
                        minDurationMs: minDurationMs,
                        rejectApplause: rejectApplause,
                        applauseCeiling: applauseCeiling)
    }

    func resetToDefaults() {
        let defaults = SegmenterConfig.default
        laughThreshold = defaults.laughThreshold
        speechCeiling = defaults.speechCeiling
        dominanceRatio = defaults.dominanceRatio
        bridgeGapMs = defaults.bridgeGapMs
        edgeTrimMs = defaults.edgeTrimMs
        minDurationMs = defaults.minDurationMs
        rejectApplause = defaults.rejectApplause
        applauseCeiling = defaults.applauseCeiling
    }
}
