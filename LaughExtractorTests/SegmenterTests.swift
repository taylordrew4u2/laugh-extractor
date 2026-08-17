import XCTest
@testable import LaughExtractor

/// Pure logic tests — synthetic `FrameScore` arrays, no audio fixtures.
final class SegmenterTests: XCTestCase {

    /// Matches the real classifier geometry closely enough: ~97 ms hop.
    private let hop = 0.1
    /// Tests use a zero-length window so frame `startTime` *is* the frame centre,
    /// which keeps the expected timestamps readable.
    private let window = 0.0

    private var config = SegmenterConfig.default

    override func setUp() {
        super.setUp()
        config = SegmenterConfig.default
    }

    // MARK: - Helpers

    /// `pattern` is one character per frame: `L` laugh, `T` talking over laughter,
    /// `.` silence. Frames are spaced `hop` apart starting at `start`.
    private func frames(_ pattern: String, start: Double = 1.0, applause: Double = 0) -> [FrameScore] {
        pattern.enumerated().map { offset, symbol in
            let time = start + Double(offset) * hop
            switch symbol {
            case "L": return FrameScore(startTime: time, laughScore: 0.85, speechScore: 0.02, applauseScore: applause)
            case "T": return FrameScore(startTime: time, laughScore: 0.85, speechScore: 0.70, applauseScore: applause)
            default:  return FrameScore(startTime: time, laughScore: 0.05, speechScore: 0.60, applauseScore: applause)
            }
        }
    }

    private func segment(_ pattern: String, applause: Double = 0) -> [LaughSegment] {
        Segmenter.segments(from: frames(pattern, applause: applause),
                           windowDuration: window,
                           hopDuration: hop,
                           config: config)
    }

    // MARK: - Duration

    func testRunLongerThanMinimumSurvives() {
        // 10 frames spans 1.0 s; 0.15 s off each end leaves 0.7 s.
        let results = segment("LLLLLLLLLL")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].duration, 0.7, accuracy: 0.0001)
        XCTAssertEqual(results[0].startSeconds, 1.10, accuracy: 0.0001)
        XCTAssertEqual(results[0].endSeconds, 1.80, accuracy: 0.0001)
    }

    func testRunShorterThanMinimumAfterEdgeTrimIsDropped() {
        // 7 frames spans 0.7 s; trimming 0.3 s total leaves 0.4 s, under the 0.5 s floor.
        XCTAssertTrue(segment("LLLLLLL").isEmpty)
    }

    func testMinimumIsMeasuredAfterTrimmingNotBefore() {
        // 8 frames spans 0.8 s — comfortably over 0.5 s before trimming, and
        // exactly 0.5 s after. It should survive, but only just.
        let results = segment("LLLLLLLL")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].duration, 0.5, accuracy: 0.0001)

        // One frame less and the same burst falls below the floor.
        XCTAssertTrue(segment("LLLLLLL").isEmpty)
    }

    // MARK: - The no-talking rule (judged on burst averages)

    func testBurstThatIsMostlyTalkIsRejected() {
        // Every frame is laughter *and* talking — the burst's average speech
        // is far over the ceiling, so nothing survives.
        XCTAssertTrue(segment("TTTTTTTTTTTT").isEmpty)
    }

    func testBrieflyTalkedOverLaughterStaysOneBurst() {
        // A short talked-over stretch inside a long laugh doesn't split it:
        // the burst is judged on its average, which stays laugh-dominated.
        let results = segment("LLLLLLLLLLTTTTTLLLLLLLLLL")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].duration, 2.2, accuracy: 0.0001)
        XCTAssertEqual(results[0].meanSpeech, (20 * 0.02 + 5 * 0.70) / 25, accuracy: 0.0001)
    }

    func testDominanceRatioRejectsLaughterThatBarelyBeatsSpeech() {
        // Average speech is under the ceiling, but average laughter only
        // doubles it — a 3× dominance requirement isn't met. Pinned explicitly
        // because the test exercises the mechanism, not the shipping default.
        let borderline = (0..<12).map {
            FrameScore(startTime: 1.0 + Double($0) * hop,
                       laughScore: 0.20,
                       speechScore: 0.10,
                       applauseScore: 0)
        }
        config.laughThreshold = 0.15
        config.dominanceRatio = 3.0
        XCTAssertTrue(Segmenter.segments(from: borderline,
                                         windowDuration: window,
                                         hopDuration: hop,
                                         config: config).isEmpty)
    }

    // MARK: - Bridging

    func test100msGapBridgesIntoOneBurst() {
        let results = segment("LLLLL.LLLLL")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].duration, 0.8, accuracy: 0.0001)
    }

    func test300msGapSplitsIntoTwoBursts() {
        let results = segment("LLLLLLLLLL...LLLLLLLLLL")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].index, 1)
        XCTAssertEqual(results[1].index, 2)
        XCTAssertLessThan(results[0].endSeconds, results[1].startSeconds)
    }

    // MARK: - Degenerate input

    func testEdgeTrimThatInvertsASegmentDropsItRatherThanCrashing() {
        config.edgeTrimMs = 5_000 // Far wider than the burst itself.
        config.minDurationMs = 0
        XCTAssertTrue(segment("LLLLLLLLLLLL").isEmpty)
    }

    func testEmptyInputReturnsEmptyOutput() {
        XCTAssertTrue(Segmenter.segments(from: [],
                                         windowDuration: window,
                                         hopDuration: hop,
                                         config: config).isEmpty)
    }

    func testZeroHopReturnsEmptyRatherThanDividingByIt() {
        XCTAssertTrue(Segmenter.segments(from: frames("LLLLLLLLLL"),
                                         windowDuration: window,
                                         hopDuration: 0,
                                         config: config).isEmpty)
    }

    func testSegmentStartIsNeverNegative() {
        let results = Segmenter.segments(from: frames("LLLLLLLLLL", start: 0),
                                         windowDuration: window,
                                         hopDuration: hop,
                                         config: config)
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThanOrEqual(results[0].startSeconds, 0)
    }

    // MARK: - Applause

    func testApplauseHeavyBurstIsRejectedOnlyWhenTheToggleIsOn() {
        XCTAssertEqual(segment("LLLLLLLLLL", applause: 0.9).count, 1)

        config.rejectApplause = true
        config.applauseCeiling = 0.5
        XCTAssertTrue(segment("LLLLLLLLLL", applause: 0.9).isEmpty)

        // Below the ceiling it survives even with rejection on.
        XCTAssertEqual(segment("LLLLLLLLLL", applause: 0.2).count, 1)
    }

    // MARK: - Ambient noise gate

    /// A quiet room at −60 dB, laughter that barely rises above it, and loud
    /// non-laugh crowd noise that gives the recording real dynamic range.
    private func roomFrames(laughLoudnessDb: Double) -> [FrameScore] {
        var scores: [FrameScore] = []
        func add(_ count: Int, laugh: Double, dbfs: Double) {
            for _ in 0..<count {
                scores.append(FrameScore(startTime: 1.0 + Double(scores.count) * hop,
                                         laughScore: laugh,
                                         speechScore: 0.02,
                                         applauseScore: 0,
                                         loudnessDb: dbfs))
            }
        }
        add(20, laugh: 0.05, dbfs: -60)              // room tone
        add(10, laugh: 0.85, dbfs: laughLoudnessDb)  // the laugh under test
        add(10, laugh: 0.05, dbfs: -20)              // loud crowd noise
        return scores
    }

    func testAmbientGateRejectsLaughterThatSitsAtTheNoiseFloor() {
        // Laughter only 3 dB above a −60 dB floor doesn't clear the 6 dB margin.
        XCTAssertTrue(Segmenter.segments(from: roomFrames(laughLoudnessDb: -57),
                                         windowDuration: window,
                                         hopDuration: hop,
                                         config: config).isEmpty)

        // The same laughter, loud enough to stand out, survives.
        XCTAssertEqual(Segmenter.segments(from: roomFrames(laughLoudnessDb: -20),
                                          windowDuration: window,
                                          hopDuration: hop,
                                          config: config).count, 1)
    }

    func testAmbientGateDisablesItselfWithoutDynamicRange() {
        // Every frame at the same level: nothing can ever stand out, so the
        // gate must step aside rather than reject the whole recording.
        let uniform = (0..<10).map {
            FrameScore(startTime: 1.0 + Double($0) * hop,
                       laughScore: 0.85,
                       speechScore: 0.02,
                       applauseScore: 0,
                       loudnessDb: -30)
        }
        XCTAssertEqual(Segmenter.segments(from: uniform,
                                          windowDuration: window,
                                          hopDuration: hop,
                                          config: config).count, 1)
    }

    // MARK: - Reported statistics

    func testSegmentCarriesMeanAndPeakScores() {
        let results = segment("LLLLLLLLLL")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].meanLaugh, 0.85, accuracy: 0.0001)
        XCTAssertEqual(results[0].peakLaugh, 0.85, accuracy: 0.0001)
        XCTAssertEqual(results[0].meanSpeech, 0.02, accuracy: 0.0001)
    }

    func testIndicesAreSequentialFromOne() {
        let results = segment("LLLLLLLLLL...LLLLLLLLLL...LLLLLLLLLL")
        XCTAssertEqual(results.map(\.index), [1, 2, 3])
    }

    // MARK: - Window centring

    func testWindowDurationShiftsSegmentsToTheWindowCentre() {
        // With a real 0.975 s window, a burst detected at t=1.0 describes audio
        // centred on 1.4875 s — anchoring on the window start would place every
        // clip roughly half a window early.
        let results = Segmenter.segments(from: frames("LLLLLLLLLL"),
                                         windowDuration: 0.975,
                                         hopDuration: hop,
                                         config: config)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].startSeconds, 1.10 + 0.4875, accuracy: 0.0001)
        XCTAssertEqual(results[0].duration, 0.7, accuracy: 0.0001)
    }
}
