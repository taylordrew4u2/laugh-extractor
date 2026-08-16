import Foundation

/// Everything the segmenter needs to turn frame scores into bursts.
///
/// Deliberately a plain value type with no framework dependencies — it is what
/// the settings sliders write into and what the unit tests construct by hand.
struct SegmenterConfig: Equatable, Sendable {
    /// A frame must score at least this to count as laughter.
    var laughThreshold: Double = 0.45
    /// …and at most this for speech. This is what enforces the no-talking rule.
    var speechCeiling: Double = 0.12
    /// …and laughter must beat speech by at least this factor.
    var dominanceRatio: Double = 3.0
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

        let halfHop = hopDuration / 2
        let halfWindow = windowDuration / 2

        func cellStart(_ frame: FrameScore) -> Double { frame.startTime + halfWindow - halfHop }
        func cellEnd(_ frame: FrameScore) -> Double { frame.startTime + halfWindow + halfHop }

        // 1. Group contiguous runs of laugh-positive frames.
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for (i, frame) in frames.enumerated() {
            if isLaughPositive(frame, config: config) {
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

    /// All three conditions must hold. The speech ceiling is the important one:
    /// laughter over the comedian's voice is discarded, never trimmed around.
    static func isLaughPositive(_ frame: FrameScore, config: SegmenterConfig) -> Bool {
        frame.laughScore >= config.laughThreshold
            && frame.speechScore <= config.speechCeiling
            && frame.laughScore >= frame.speechScore * config.dominanceRatio
    }
}
