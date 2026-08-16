import Foundation
import AVFoundation
// SoundAnalysis predates Sendable annotation; the analyzer and observer are
// confined to one queue here, so the warnings it emits are noise.
@preconcurrency import SoundAnalysis
import os

/// Frame scores plus the window geometry the segmenter needs to turn them back
/// into timestamps.
struct AnalysisResult: Sendable {
    let frames: [FrameScore]
    let windowDuration: Double
    let hopDuration: Double
}

enum LaughDetectionError: LocalizedError {
    case classifierUnavailable(String)
    case noLabelsResolved(String)

    var errorDescription: String? {
        switch self {
        case .classifierUnavailable(let detail):
            return "The system sound classifier isn't available: \(detail)"
        case .noLabelsResolved(let group):
            return "The system sound classifier has no '\(group)' labels on this version of macOS."
        }
    }
}

/// Groups of classifier labels, resolved at runtime.
///
/// Apple has renamed classes between OS releases, so nothing here is hardcoded
/// as an exact string — we substring-match against whatever the installed
/// classifier actually reports.
struct LabelGroups {
    let laugh: Set<String>
    let speech: Set<String>
    let applause: Set<String>

    private static let laughNeedles = ["laughter", "giggl", "belly_laugh", "chuckle", "snicker"]
    private static let speechNeedles = ["speech", "conversation", "narration", "monologue"]
    private static let applauseNeedles = ["applause", "cheering", "clapping"]
    /// `baby_laughter` false-fires on high crowd noise, so it's excluded.
    private static let laughExclusions = ["baby"]

    init(knownClassifications: [String]) {
        func match(_ needles: [String], excluding exclusions: [String] = []) -> Set<String> {
            Set(knownClassifications.filter { label in
                let lowered = label.lowercased()
                guard exclusions.allSatisfy({ !lowered.contains($0) }) else { return false }
                return needles.contains { lowered.contains($0) }
            })
        }
        laugh = match(Self.laughNeedles, excluding: Self.laughExclusions)
        speech = match(Self.speechNeedles)
        applause = match(Self.applauseNeedles)
    }
}

enum LaughDetector {

    private static let logger = Logger(subsystem: "com.laughextractor.LaughExtractor", category: "detector")

    /// The shortest window the classifier will accept, so that a 500 ms clip is
    /// several frames wide rather than barely half of one.
    private static let preferredWindowDuration = CMTime(seconds: 0.975, preferredTimescale: 48_000)
    /// 0.9 overlap on a 0.975 s window gives an effective hop of ~97 ms.
    private static let overlapFactor = 0.9

    static func analyze(analysisFileURL: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> AnalysisResult {

        let request: SNClassifySoundRequest
        do {
            request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        } catch {
            throw LaughDetectionError.classifierUnavailable(error.localizedDescription)
        }

        let groups = LabelGroups(knownClassifications: request.knownClassifications)
        // A group resolving to nothing means Apple renamed a class and detection
        // would otherwise fail silently — which is far worse than failing loudly.
        if groups.laugh.isEmpty { throw LaughDetectionError.noLabelsResolved("laughter") }
        if groups.speech.isEmpty { throw LaughDetectionError.noLabelsResolved("speech") }
        if groups.applause.isEmpty {
            logger.warning("No applause labels resolved; applause rejection will have no effect.")
        }
        logger.info("""
            Resolved classifier labels — laugh: \(groups.laugh.sorted().joined(separator: ", "), privacy: .public); \
            speech: \(groups.speech.sorted().joined(separator: ", "), privacy: .public); \
            applause: \(groups.applause.sorted().joined(separator: ", "), privacy: .public)
            """)

        let file = try AVAudioFile(forReading: analysisFileURL)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0 else {
            return AnalysisResult(frames: [], windowDuration: 0, hopDuration: 0)
        }

        // Don't assume 0.975 s is legal on every OS version — clamp to whatever
        // the installed classifier declares.
        let windowDuration = resolvedWindowDuration(for: request)
        request.windowDuration = windowDuration
        request.overlapFactor = overlapFactor

        let windowSeconds = windowDuration.seconds
        let hopSeconds = windowSeconds * (1 - overlapFactor)

        let observer = ClassificationObserver(groups: groups)
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: observer)

        let chunkFrames: AVAudioFrameCount = 16_384

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var position: AVAudioFramePosition = 0
                    while position < totalFrames {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                            break
                        }
                        try file.read(into: buffer, frameCount: chunkFrames)
                        if buffer.frameLength == 0 { break }

                        analyzer.analyze(buffer, atAudioFramePosition: position)
                        position += AVAudioFramePosition(buffer.frameLength)
                        progress(min(1.0, Double(position) / Double(totalFrames)))
                    }
                    analyzer.completeAnalysis()
                    observer.waitForCompletion()
                    continuation.resume()
                } catch {
                    analyzer.completeAnalysis()
                    continuation.resume(throwing: error)
                }
            }
        }

        if let failure = observer.failure { throw failure }
        progress(1.0)

        return AnalysisResult(frames: observer.frames(),
                              windowDuration: windowSeconds,
                              hopDuration: hopSeconds)
    }

    /// 0.975 s is the shortest window the classifier has historically accepted,
    /// but that isn't promised across OS versions — so ask, don't assume.
    private static func resolvedWindowDuration(for request: SNClassifySoundRequest) -> CMTime {
        switch request.windowDurationConstraint {
        case .enumeratedDurations(let durations):
            // Shortest offered duration that still meets our preference; if
            // every option is shorter, take the longest of those — it's the
            // closest to what we asked for.
            let sorted = durations.sorted { $0.seconds < $1.seconds }
            return sorted.first { $0.seconds >= preferredWindowDuration.seconds }
                ?? sorted.last
                ?? preferredWindowDuration
        case .durationRange(let range):
            if preferredWindowDuration < range.start { return range.start }
            if preferredWindowDuration > range.end { return range.end }
            return preferredWindowDuration
        @unknown default:
            return preferredWindowDuration
        }
    }
}

/// Collects classification results off the analysis queue.
private final class ClassificationObserver: NSObject, SNResultsObserving {

    private let groups: LabelGroups
    private let lock = NSLock()
    private var collected: [FrameScore] = []
    private let completion = DispatchSemaphore(value: 0)
    private var _failure: Error?

    init(groups: LabelGroups) {
        self.groups = groups
    }

    var failure: Error? {
        lock.lock(); defer { lock.unlock() }
        return _failure
    }

    func frames() -> [FrameScore] {
        lock.lock(); defer { lock.unlock() }
        return collected.sorted { $0.startTime < $1.startTime }
    }

    /// Results may be delivered asynchronously, so give the analyzer a moment to
    /// finish after `completeAnalysis()` rather than snapshotting immediately.
    func waitForCompletion() {
        _ = completion.wait(timeout: .now() + 10)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }

        var laugh = 0.0
        var speech = 0.0
        var applause = 0.0
        for classification in result.classifications {
            let confidence = classification.confidence
            if groups.laugh.contains(classification.identifier) { laugh = max(laugh, confidence) }
            if groups.speech.contains(classification.identifier) { speech = max(speech, confidence) }
            if groups.applause.contains(classification.identifier) { applause = max(applause, confidence) }
        }

        let frame = FrameScore(startTime: result.timeRange.start.seconds,
                               laughScore: laugh,
                               speechScore: speech,
                               applauseScore: applause)
        lock.lock()
        collected.append(frame)
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        _failure = error
        lock.unlock()
        completion.signal()
    }

    func requestDidComplete(_ request: SNRequest) {
        completion.signal()
    }
}
