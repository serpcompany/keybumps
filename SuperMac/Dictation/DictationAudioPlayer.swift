import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class DictationAudioPlayer {
    private(set) var activeEntryID: String?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var lastError: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTimer: Timer?

    func toggle(_ entry: DictationHistoryEntry) {
        guard let audioURL = entry.audioURL else { return }
        if activeEntryID == entry.id, let player {
            player.isPlaying ? pause() : resume()
            return
        }

        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            guard player.play() else {
                lastError = "This recording could not be played."
                return
            }
            self.player = player
            activeEntryID = entry.id
            isPlaying = true
            lastError = nil
            startProgressTimer()
        } catch {
            lastError = "This recording could not be played."
        }
    }

    func stop() {
        player?.stop()
        player = nil
        activeEntryID = nil
        isPlaying = false
        progress = 0
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func progress(for entry: DictationHistoryEntry) -> Double {
        activeEntryID == entry.id ? progress : 0
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func resume() {
        guard player?.play() == true else { return }
        isPlaying = true
        startProgressTimer()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }

    private func updateProgress() {
        guard let player else { return }
        progress = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        if isPlaying, !player.isPlaying { stop() }
    }
}
