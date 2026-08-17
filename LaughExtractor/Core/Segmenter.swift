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
    /// A burst whose *average* speech score is above this is rejected — the
    /// no-talking rule. Judged on the burst mean, not per frame: the classifier
    /// reports speech almost continuously in live comedy (including during the
    /// laugh break), so a per-frame veto rejects nearly everything real.
    var speechCeiling: Double = 0.60
    /// …and the burst's average laugh score must be at least this multiple of
    /// its average speech score. 0 turns the check off.
    var dominanceRatio: Double = 0.5
    /// A frame must be at least this many dB louder than the recording's own
    /// noise floor, so ambient rumble the classifier half-hears as laughter
    /// doesn't qualify. 0 disables the gate.
    ///
    /// Off by default: it only helps when laughter is genuinely louder than
    /// the rest of the recording. On compressed, close-mic'd sets the loudest
    /// thing is the comedian's voice and the gate rejects the real laughs.
    var ambientMarginDb: Double = 0
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

/// What happened at each stage of detection, so "no laughter detected" can say
/// which rule did the rejecting instead of leaving the user to bisect sliders.
///
/// Frames are gated on laugh confidence and loudness; candidate bursts are then
/// judged on their averages — the counters mirror that split.
struct DetectionDiagnostics: Equatable, Sendable {
    var frameCount = 0
    var peakLaugh = 0.0
    var peakSpeech = 0.0
    /// `nil` when the ambient gate isn't active (margin 0, or the recording
    /// has no dynamic range to gate on).
    var noiseFloorDb: Double?
    var passedLaugh = 0
    var passedAmbient = 0
    /// Frames passing both gates — the raw material bursts are built from.
    var laughPositive = 0
    /// Bursts formed after bridging, before any burst-level rejection.
    var candidateBursts = 0
    var rejectedShort = 0
    var rejectedTalky = 0
    var rejectedDominance = 0
    var rejectedApplause = 0
    var kept = 0
}

/// What `segmentsNeverEmpty` produced: the segments, the diagnostics for the
/// *configured* rules, and whether the fallback ladder had to loosen them.
struct SegmentationOutcome: Equatable, Sendable {
    var segments: [LaughSegment]
    var diagnostics: DetectionDiagnostics
    var relaxed: Bool
}

/// Turns a flat array of window scores into filtered laughter bursts.
///
/// Pure logic, no framework imports, no actor isolation — that is deliberate.
/// It makes the whole detection policy unit-testable without audio fixtures,
/// and it means re-running it on a slider change costs a single array pass.
///
/// Detection is two-level by design. Frames are gated only on what is reliable
/// per window: laugh confidence and loudness. The no-talking rules compare a
/// burst's *averages*, where the classifier's frame-to-frame jitter washes out.
/// Requiring every individual frame to be simultaneously laugh-high and
/// speech-low multiplies the rules' failure rates and rejects nearly every
/// real laugh in continuous-performance audio.
enum Segmenter {

    /// Frame times are derived by accumulating a fractional hop, so a gap that
    /// should be exactly 100 ms arrives as 0.10000000000000009. Comparisons
    /// against the millisecond thresholds are tolerant by a hair to match.
    private static let epsilon = 1e-9

    static func segments(from frames: [FrameScore],
                         windowDuration: Double,
                         hopDuration: Double,
                         config: SegmenterConfig = .default) -> [LaughSegment] {
        segmentsWithDiagnostics(from: frames,
                                windowDuration: windowDuration,
                                hopDuration: hopDuration,
                                config: config).segments
    }

    /// - Parameters:
    ///   - frames: window scores in ascending time order.
    ///   - windowDuration: length of one classifier window, in seconds.
    ///   - hopDuration: spacing between consecutive window starts, in seconds.
    ///
    /// A window starting at `t` covers audio `[t, t + windowDuration]`, so the
    /// point in time it actually describes is its *centre*. Each frame is
    /// therefore treated as owning the cell `[centre - hop/2, centre + hop/2]`.
    /// Anchoring on the start instead would shift every burst half a window early.
    static func segmentsWithDiagnostics(from frames: [FrameScore],
                                        windowDuration: Double,
                                        hopDuration: Double,
                                        config: SegmenterConfig = .default)
        -> (segments: [LaughSegment], diagnostics: DetectionDiagnostics) {

        var d = DetectionDiagnostics()
        d.frameCount = frames.count
        d.noiseFloorDb = activeNoiseFloor(for: frames, config: config)
        for frame in frames {
            d.peakLaugh = max(d.peakLaugh, frame.laughScore)
            d.peakSpeech = max(d.peakSpeech, frame.speechScore)
            if frame.laughScore >= config.laughThreshold { d.passedLaugh += 1 }
            if passesAmbientGate(frame, config: config, noiseFloorDb: d.noiseFloorDb) {
                d.passedAmbient += 1
            }
        }

        guard !frames.isEmpty, hopDuration > 0 else { return ([], d) }

        let halfHop = hopDuration / 2
        let halfWindow = windowDuration / 2

        func cellStart(_ frame: FrameScore) -> Double { frame.startTime + halfWindow - halfHop }
        func cellEnd(_ frame: FrameScore) -> Double { frame.startTime + halfWindow + halfHop }

        // 1. Group contiguous runs of laugh-positive frames.
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for (i, frame) in frames.enumerated() {
            if isLaughPositive(frame, config: config, noiseFloorDb: d.noiseFloorDb) {
                d.laughPositive += 1
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                runs.append(start...(i - 1))
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start...(frames.count - 1)) }
        guard !runs.isEmpty else { return ([], d) }

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
        d.candidateBursts = merged.count

        // 3–6. Trim inward, then judge each burst on duration and its averages.
        let trim = config.edgeTrimMs / 1000
        let minDuration = config.minDurationMs / 1000
        var results: [LaughSegment] = []

        for range in merged {
            let rawStart = max(0, cellStart(frames[range.lowerBound]))
            let rawEnd = cellEnd(frames[range.upperBound])

            let start = rawStart + trim
            let end = rawEnd - trim
            // An over-aggressive trim can invert a short burst. Drop it, don't crash.
            guard end > start, end - start >= minDuration - Self.epsilon else {
                d.rejectedShort += 1
                continue
            }

            let window = frames[range]
            let count = Double(window.count)
            let meanLaugh = window.reduce(0) { $0 + $1.laughScore } / count
            let meanSpeech = window.reduce(0) { $0 + $1.speechScore } / count
            let meanApplause = window.reduce(0) { $0 + $1.applauseScore } / count
            let peakLaugh = window.reduce(0) { max($0, $1.laughScore) }

            // The no-talking rule, on burst averages: mostly-talk bursts go,
            // laughter with a little voice bleed stays (the edge trim exists
            // for exactly that bleed).
            if meanSpeech > config.speechCeiling {
                d.rejectedTalky += 1
                continue
            }
            if config.dominanceRatio > 0, meanLaugh < meanSpeech * config.dominanceRatio {
                d.rejectedDominance += 1
                continue
            }
            if config.rejectApplause && meanApplause > config.applauseCeiling {
                d.rejectedApplause += 1
                continue
            }

            results.append(LaughSegment(index: results.count + 1,
                                        startSeconds: start,
                                        endSeconds: end,
                                        meanLaugh: meanLaugh,
                                        meanSpeech: meanSpeech,
                                        meanApplause: meanApplause,
                                        peakLaugh: peakLaugh))
        }
        d.kept = results.count

        return (results, d)
    }

    /// `segmentsWithDiagnostics`, plus a promise: if the configured rules
    /// reject everything, a ladder of progressively looser configs runs until
    /// something survives, ending with the single most laugh-like stretch in
    /// the file. `relaxed` tells the UI to say so. The only way to get zero
    /// segments is audio with nothing laugh-like in it at all.
    ///
    /// Diagnostics always describe the *configured* rules, so the readout
    /// matches the sliders even when the results came from the ladder.
    static func segmentsNeverEmpty(from frames: [FrameScore],
                                   windowDuration: Double,
                                   hopDuration: Double,
                                   config: SegmenterConfig = .default) -> SegmentationOutcome {
        let strict = segmentsWithDiagnostics(from: frames,
                                             windowDuration: windowDuration,
                                             hopDuration: hopDuration,
                                             config: config)
        if !strict.segments.isEmpty {
            return SegmentationOutcome(segments: strict.segments,
                                       diagnostics: strict.diagnostics,
                                       relaxed: false)
        }

        for looser in relaxationLadder(from: config) {
            let attempt = segmentsWithDiagnostics(from: frames,
                                                  windowDuration: windowDuration,
                                                  hopDuration: hopDuration,
                                                  config: looser)
            if !attempt.segments.isEmpty {
                return SegmentationOutcome(segments: attempt.segments,
                                           diagnostics: strict.diagnostics,
                                           relaxed: true)
            }
        }

        if let rescue = mostLaughLikeStretch(in: frames,
                                             windowDuration: windowDuration,
                                             hopDuration: hopDuration) {
            return SegmentationOutcome(segments: [rescue],
                                       diagnostics: strict.diagnostics,
                                       relaxed: true)
        }
        return SegmentationOutcome(segments: [],
                                   diagnostics: strict.diagnostics,
                                   relaxed: false)
    }

    /// Two rungs: "noticeably looser than anything a user would set", then
    /// "accept nearly any laugh evidence at all".
    private static func relaxationLadder(from config: SegmenterConfig) -> [SegmenterConfig] {
        var first = config
        first.laughThreshold = min(config.laughThreshold, 0.15)
        first.speechCeiling = max(config.speechCeiling, 0.80)
        first.dominanceRatio = 0
        first.ambientMarginDb = 0
        first.minDurationMs = min(config.minDurationMs, 400)

        var second = first
        second.laughThreshold = 0.05
        second.speechCeiling = 1.0
        second.minDurationMs = min(config.minDurationMs, 300)
        second.edgeTrimMs = min(config.edgeTrimMs, 50)
        second.bridgeGapMs = max(config.bridgeGapMs, 200)

        return [first, second]
    }

    /// ~1.5 s centred on the strongest laugh moment in the file. Returns `nil`
    /// only when nothing resembles laughter at all (e.g. silence) — inventing
    /// a clip out of noise would be worse than an honest empty result.
    private static func mostLaughLikeStretch(in frames: [FrameScore],
                                             windowDuration: Double,
                                             hopDuration: Double) -> LaughSegment? {
        guard hopDuration > 0,
              let best = frames.indices.max(by: { frames[$0].laughScore < frames[$1].laughScore }),
              frames[best].laughScore >= 0.02 else { return nil }

        let halfSpan = 0.75
        let centre = frames[best].startTime + windowDuration / 2
        let start = max(0, centre - halfSpan)
        let end = centre + halfSpan

        let covered = frames.filter {
            let frameCentre = $0.startTime + windowDuration / 2
            return frameCentre >= start && frameCentre <= end
        }
        let count = Double(max(covered.count, 1))
        return LaughSegment(index: 1,
                            startSeconds: start,
                            endSeconds: end,
                            meanLaugh: covered.reduce(0) { $0 + $1.laughScore } / count,
                            meanSpeech: covered.reduce(0) { $0 + $1.speechScore } / count,
                            meanApplause: covered.reduce(0) { $0 + $1.applauseScore } / count,
                            peakLaugh: frames[best].laughScore)
    }

    /// The per-frame gate: laugh confidence plus the ambient loudness check.
    /// Speech is deliberately not tested here — see the type-level comment.
    static func isLaughPositive(_ frame: FrameScore,
                                config: SegmenterConfig,
                                noiseFloorDb: Double? = nil) -> Bool {
        frame.laughScore >= config.laughThreshold
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
}
