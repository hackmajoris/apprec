import SwiftUI

@main
struct AppRecApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var player = Player()

    var body: some Scene {
        MenuBarExtra {
            MenuView(recorder: recorder, player: player)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
