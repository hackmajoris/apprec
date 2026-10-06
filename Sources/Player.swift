import AVFoundation

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?

    private var player: AVAudioPlayer?

    var duration: TimeInterval { player?.duration ?? 0 }

    var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }

    func toggle(_ url: URL) {
        if url == current, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            isPlaying = player.isPlaying
            return
        }

        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            current = url
            isPlaying = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
