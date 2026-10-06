import SwiftUI

@main
struct AppRecApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var player = Player()
    @StateObject private var ollama = Ollama()

    var body: some Scene {
        MenuBarExtra {
            MenuView(recorder: recorder, player: player, ollama: ollama)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
