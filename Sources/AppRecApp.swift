import SwiftUI

@main
struct AppRecApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var player = Player()
    @StateObject private var ollama = Ollama()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuView(recorder: recorder, player: player, ollama: ollama, updater: updater)
        } label: {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : recorder.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
