import Foundation

/// Everything the segmenter needs to turn frame scores into bursts.
///
/// Deliberately a plain value type with no framework dependencies — it is what
/// the settings sliders write into and what the unit tests construct by hand.
struct SegmenterConfig: Equatable, Sendable {
    /// A frame must score at least this to count as laughter.
    ///
    /// Defaults are deliberately forgiving: the classifier's laughter confidence
    /// on real room recordings rarely gets near its ceiling, and a first run
    /// that finds too much is tunable while one that finds nothing is a dead end.
    var laughThreshold: Double = 0.25
    /// …and at most this for speech. This is what enforces the no-talking rule.
    var speechCeiling: Double = 0.30
    /// …and laughter must beat speech by at least this factor.
    var dominanceRatio: Double = 1.5
    /// …and the window must be at least this many dB louder than the
    /// recording's own noise floor, so ambient rumble the classifier half-hears
    /// as laughter doesn't qualify. 0 disables the gate.
    var ambientMarginDb: Double = 6
    /// Dropouts up to this long are bridged rather than splitting a burst in two.
    var bridgeGapMs: Double = 100
    /// Cut this much off both ends, where the comedian's voice is most likely to bleed in.
    var edgeTrimMs: Double = 150
    /// Bursts shorter than this *after* trimming are discarded.
    var minDurationMs: Double = 500
    var rejectApplause: Bool = false
    var applauseCeiling: Double = 0.5

    static let `default` = SegmenterConfig()
}

/// Per-rule pass counts for the current analysis + config, so "no laughter
/// detected" can say which rule did the rejecting instead of leaving the user
/// to bisect three sliders.
struct DetectionDiagnostics: Equatable, Sendable {
    var frameCount = 0
    var peakLaugh = 0.0
    var peakSpeech = 0.0
    /// `nil` when the ambient gate isn't active (margin 0, or the recording
    /// has no dynamic range to gate on).
    var noiseFloorDb: Double?
    var passedLaugh = 0
    var passedSpeech = 0
    var passedDominance = 0
    var passedAmbient = 0
    var passedAll = 0
}

/// Turns a flat array of window scores into filtered laughter bursts.
///
/// Pure logic, no framework imports, no actor isolation — that is deliberate.
/// It makes the whole detection policy unit-testable without audio fixtures,
/// and it means re-running it on a slider change costs a single array pass.
enum Segmenter {

    /// Frame times are derived by accumulating a fractional hop, so a gap that
    /// should be exactly 100 ms arrives as 0.10000000000000009. Comparisons
    /// against the millisecond thresholds are tolerant by a hair to match.
    private static let epsilon = 1e-9

    /// - Parameters:
    ///   - frames: window scores in ascending time order.
    ///   - windowDuration: length of one classifier window, in seconds.
    ///   - hopDuration: spacing between consecutive window starts, in seconds.
    ///
    /// A window starting at `t` covers audio `[t, t + windowDuration]`, so the
    /// point in time it actually describes is its *centre*. Each frame is
    /// therefore treated as owning the cell `[centre - hop/2, centre + hop/2]`.
    /// Anchoring on the start instead would shift every burst half a window early.
    static func segments(from frames: [FrameScore],
                         windowDuration: Double,
                         hopDuration: Double,
                         config: SegmenterConfig = .default) -> [LaughSegment] {
        guard !frames.isEmpty, hopDuration > 0 else { return [] }

        let noiseFloor = activeNoiseFloor(for: frames, config: config)
        let halfHop = hopDuration / 2
        let halfWindow = windowDuration / 2

        func cellStart(_ frame: FrameScore) -> Double { frame.startTime + halfWindow - halfHop }
        func cellEnd(_ frame: FrameScore) -> Double { frame.startTime + halfWindow + halfHop }

        // 1. Group contiguous runs of laugh-positive frames.
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for (i, frame) in frames.enumerated() {
            if isLaughPositive(frame, config: config, noiseFloorDb: noiseFloor) {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                runs.append(start...(i - 1))
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start...(frames.count - 1)) }
        guard !runs.isEmpty else { return [] }

        // 2. Bridge short dropouts. Laughter is naturally bursty and a single
        //    quiet frame shouldn't split one laugh into two clips.
        let bridgeGap = config.bridgeGapMs / 1000
        var merged: [ClosedRange<Int>] = [runs[0]]
        for run in runs.dropFirst() {
            let previous = merged[merged.count - 1]
            let gap = cellStart(frames[run.lowerBound]) - cellEnd(frames[previous.upperBound])
            if gap <= bridgeGap + Self.epsilon {
                merged[merged.count - 1] = previous.lowerBound...run.upperBound
            } else {
                merged.append(run)
            }
        }

        // 3–5. Trim inward, then reject on duration and (optionally) applause.
        let trim = config.edgeTrimMs / 1000
        let minDuration = config.minDurationMs / 1000
        var results: [LaughSegment] = []

        for range in merged {
            let rawStart = max(0, cellStart(frames[range.lowerBound]))
            let rawEnd = cellEnd(frames[range.upperBound])

            let start = rawStart + trim
            let end = rawEnd - trim
            // An over-aggressive trim can invert a short burst. Drop it, don't crash.
            guard end > start, end - start >= minDuration - Self.epsilon else { continue }

            let window = frames[range]
            let count = Double(window.count)
            let meanLaugh = window.reduce(0) { $0 + $1.laughScore } / count
            let meanSpeech = window.reduce(0) { $0 + $1.speechScore } / count
            let meanApplause = window.reduce(0) { $0 + $1.applauseScore } / count
            let peakLaugh = window.reduce(0) { max($0, $1.laughScore) }

            if config.rejectApplause && meanApplause > config.applauseCeiling { continue }

            results.append(LaughSegment(index: results.count + 1,
                                        startSeconds: start,
                                        endSeconds: end,
                                        meanLaugh: meanLaugh,
                                        meanSpeech: meanSpeech,
                                        meanApplause: meanApplause,
                                        peakLaugh: peakLaugh))
        }

        return results
    }

    /// All conditions must hold. The speech ceiling is the important one:
    /// laughter over the comedian's voice is discarded, never trimmed around.
    /// Pass a `noiseFloorDb` to also require the frame to stand out above the
    /// room by the configured ambient margin.
    static func isLaughPositive(_ frame: FrameScore,
                                config: SegmenterConfig,
                                noiseFloorDb: Double? = nil) -> Bool {
        frame.laughScore >= config.laughThreshold
            && frame.speechScore <= config.speechCeiling
            && frame.laughScore >= frame.speechScore * config.dominanceRatio
            && passesAmbientGate(frame, config: config, noiseFloorDb: noiseFloorDb)
    }

    /// The recording's own noise floor — the 20th percentile of frame loudness,
    /// i.e. the level "the room" sits at — or `nil` when gating is off or can't
    /// work: if the whole recording never rises above its floor by the margin
    /// (heavily limited audio, synthetic fixtures), gating on loudness would
    /// reject everything while distinguishing nothing.
    static func activeNoiseFloor(for frames: [FrameScore], config: SegmenterConfig) -> Double? {
        guard config.ambientMarginDb > 0, !frames.isEmpty else { return nil }
        let sorted = frames.map(\.loudnessDb).sorted()
        let floor = sorted[sorted.count / 5]
        let loud = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        guard loud - floor >= config.ambientMarginDb else { return nil }
        return floor
    }

    private static func passesAmbientGate(_ frame: FrameScore,
                                          config: SegmenterConfig,
                                          noiseFloorDb: Double?) -> Bool {
        guard let noiseFloorDb else { return true }
        return frame.loudnessDb >= noiseFloorDb + config.ambientMarginDb
    }

    /// Scores every frame against each rule independently, so the UI can show
    /// which one is rejecting everything. Same single-pass cost as segmenting.
    static func diagnostics(from frames: [FrameScore],
                            config: SegmenterConfig) -> DetectionDiagnostics {
        var d = DetectionDiagnostics()
        d.frameCount = frames.count
        d.noiseFloorDb = activeNoiseFloor(for: frames, config: config)
        for frame in frames {
            d.peakLaugh = max(d.peakLaugh, frame.laughScore)
            d.peakSpeech = max(d.peakSpeech, frame.speechScore)
            let laugh = frame.laughScore >= config.laughThreshold
            let speech = frame.speechScore <= config.speechCeiling
            let dominance = frame.laughScore >= frame.speechScore * config.dominanceRatio
            let ambient = passesAmbientGate(frame, config: config, noiseFloorDb: d.noiseFloorDb)
            if laugh { d.passedLaugh += 1 }
            if speech { d.passedSpeech += 1 }
            if dominance { d.passedDominance += 1 }
            if ambient { d.passedAmbient += 1 }
            if laugh && speech && dominance && ambient { d.passedAll += 1 }
        }
        return d
    }
}
