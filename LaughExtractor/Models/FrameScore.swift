import Foundation

/// One classifier window, reduced to the three scores the segmenter cares about.
///
/// `startTime` is the start of the analysis window as reported by SoundAnalysis.
/// Each score is the maximum confidence across every label in its group, so a
/// window that lit up `belly_laugh` at 0.6 and `giggle` at 0.2 scores 0.6.
struct FrameScore: Equatable, Sendable {
    let startTime: Double
    let laughScore: Double
    let speechScore: Double
    let applauseScore: Double
    /// RMS level of the window's audio in dBFS (0 is full scale, silence is
    /// deeply negative). What the ambient noise gate compares against the
    /// recording's own noise floor.
    let loudnessDb: Double

    init(startTime: Double,
         laughScore: Double,
         speechScore: Double,
         applauseScore: Double = 0,
         loudnessDb: Double = 0) {
        self.startTime = startTime
        self.laughScore = laughScore
        self.speechScore = speechScore
        self.applauseScore = applauseScore
        self.loudnessDb = loudnessDb
    }
}
