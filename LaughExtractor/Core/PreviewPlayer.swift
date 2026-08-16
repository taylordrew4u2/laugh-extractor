import Foundation
import AVFoundation

/// Plays a single burst out of the master audio, stopping at the segment end.
@MainActor
final class PreviewPlayer: ObservableObject {

    @Published private(set) var playingIndex: Int?
    @Published private(set) var playhead: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stopAt: Double = 0

    func toggle(_ segment: LaughSegment, in masterURL: URL) {
        if playingIndex == segment.index {
            stop()
        } else {
            play(segment, in: masterURL)
        }
    }

    func play(_ segment: LaughSegment, in masterURL: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: masterURL)
            player.prepareToPlay()
            player.currentTime = segment.startSeconds
            player.play()
            self.player = player
            playingIndex = segment.index
            playhead = segment.startSeconds
            stopAt = segment.endSeconds

            // AVAudioPlayer has no "play this range", so the tail is clipped here.
            timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingIndex = nil
    }

    private func tick() {
        guard let player else { return }
        playhead = player.currentTime
        if !player.isPlaying || player.currentTime >= stopAt {
            stop()
        }
    }
}
