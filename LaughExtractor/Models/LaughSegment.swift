import Foundation

/// A single burst of audience laughter, ready to be sliced out of the master audio.
struct LaughSegment: Identifiable, Equatable, Sendable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    let meanLaugh: Double
    let meanSpeech: Double
    let meanApplause: Double
    let peakLaugh: Double

    var id: Int { index }

    var duration: Double { endSeconds - startSeconds }

    /// `mm:ss.mmm`, the format the results list shows.
    var startTimecode: String { Self.timecode(startSeconds) }

    var durationLabel: String { String(format: "%.2fs", duration) }

    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let secs = Int(clamped) % 60
        let millis = Int((clamped - clamped.rounded(.down)) * 1000)
        return String(format: "%02d:%02d.%03d", minutes, secs, millis)
    }
}
