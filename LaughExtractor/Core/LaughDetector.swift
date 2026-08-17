import Foundation
import AVFoundation
import Accelerate
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

/// Progress through analysis, including the stages that have no meaningful
/// fraction — loading the classifier model and waiting for the analyzer to
/// flush its last results. Both can take seconds, and the UI needs to show
/// *something* during them or the app looks hung.
enum AnalysisProgress: Sendable, Equatable {
    case preparingClassifier
    case classifying(Double)
    case finishing
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
                        progress: @escaping @Sendable (AnalysisProgress) -> Void) async throws -> AnalysisResult {

        // Creating the request loads a CoreML model, which can take seconds on
        // first use — report it so the UI isn't sitting on a dead 0%.
        progress(.preparingClassifier)

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

        // Measured from the same stream the classifier hears, so the ambient
        // noise gate judges exactly what was classified.
        let envelope = RMSEnvelope(sampleRate: format.sampleRate)

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
                        envelope.accumulate(buffer, startingAt: position)
                        position += AVAudioFramePosition(buffer.frameLength)
                        progress(.classifying(min(1.0, Double(position) / Double(totalFrames))))
                    }
                    // Results can trail the last buffer by several seconds, so
                    // switch to an explicit "finishing" state instead of leaving
                    // the bar frozen at 100%.
                    progress(.finishing)
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

        let frames = observer.frames().map { frame in
            FrameScore(startTime: frame.startTime,
                       laughScore: frame.laughScore,
                       speechScore: frame.speechScore,
                       applauseScore: frame.applauseScore,
                       loudnessDb: envelope.loudnessDb(from: frame.startTime,
                                                       to: frame.startTime + windowSeconds))
        }

        return AnalysisResult(frames: frames,
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
///
/// All mutable state is guarded by `lock`, so the instance is safe to hand to
/// the `@Sendable` analysis closure — hence `@unchecked Sendable`.
private final class ClassificationObserver: NSObject, SNResultsObserving, @unchecked Sendable {

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

/// Mean-square energy of the analysis stream in coarse cells, queryable per
/// classifier window once streaming finishes.
///
/// Touched only from the analysis queue while streaming and read only after
/// the continuation resumes, so there is no concurrent access — hence
/// `@unchecked Sendable`, same justification as the observer above.
private final class RMSEnvelope: @unchecked Sendable {

    /// 25 ms cells: fine enough that a ~1 s window averages ~40 of them,
    /// coarse enough that an hour of audio is a ~144k-element array.
    private static let cellDuration = 0.025
    /// dBFS reported for digital silence, and the lowest value ever returned.
    private static let silenceDb = -100.0

    private let cellFrames: Int
    private let sampleRate: Double
    private var sumSquares: [Double] = []
    private var counts: [Int] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.cellFrames = max(1, Int(sampleRate * Self.cellDuration))
    }

    func accumulate(_ buffer: AVAudioPCMBuffer, startingAt position: AVAudioFramePosition) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let total = Int(buffer.frameLength)
        var offset = 0
        while offset < total {
            let cell = (Int(position) + offset) / cellFrames
            let cellEnd = (cell + 1) * cellFrames - Int(position)
            let take = min(cellEnd, total) - offset
            while sumSquares.count <= cell {
                sumSquares.append(0)
                counts.append(0)
            }
            var sum: Float = 0
            vDSP_svesq(samples + offset, 1, &sum, vDSP_Length(take))
            sumSquares[cell] += Double(sum)
            counts[cell] += take
            offset += take
        }
    }

    /// Mean RMS level over `[from, to]` seconds, in dBFS.
    func loudnessDb(from: Double, to: Double) -> Double {
        guard !sumSquares.isEmpty, to > from else { return Self.silenceDb }
        let first = max(0, Int(from * sampleRate) / cellFrames)
        let last = min(sumSquares.count - 1, Int(to * sampleRate) / cellFrames)
        guard first <= last else { return Self.silenceDb }

        var sum = 0.0
        var count = 0
        for cell in first...last {
            sum += sumSquares[cell]
            count += counts[cell]
        }
        guard count > 0 else { return Self.silenceDb }
        let meanSquare = sum / Double(count)
        return max(Self.silenceDb, 10 * log10(max(meanSquare, 1e-10)))
    }
}
