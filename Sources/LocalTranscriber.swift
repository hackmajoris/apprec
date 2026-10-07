import Foundation
import WhisperKit

@MainActor
final class LocalTranscriber {
    private static let model = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private static let folderKey = "localTranscriberModelFolder"

    private var kit: WhisperKit?
    private var loading: Task<Void, Error>?
    private var isDownloading = false

    func transcribe(_ file: URL, onStatus: @escaping @MainActor (String?) -> Void) async throws -> String {
        let kit = try await load(onStatus: onStatus)
        let options = DecodingOptions(
            language: nil,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        let results = try await kit.transcribe(audioPath: file.path, decodeOptions: options)
        return results.flatMap(\.segments)
            .map { ($0.start, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .map { "[\(Self.timestamp($0.0))] \($0.1)" }
            .joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Float) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func load(onStatus: @escaping @MainActor (String?) -> Void) async throws -> WhisperKit {
        if let kit { return kit }
        let task = loading ?? Task { @MainActor in
            defer { onStatus(nil) }
            let folder = try await modelFolder(onStatus: onStatus)
            onStatus("Preparing speech model… (first time can take a few minutes)")
            kit = try await WhisperKit(WhisperKitConfig(model: Self.model, modelFolder: folder.path, download: false))
        }
        loading = task
        do {
            try await task.value
        } catch {
            loading = nil
            throw error
        }
        guard let kit else { throw CancellationError() }
        return kit
    }

    private func modelFolder(onStatus: @escaping @MainActor (String?) -> Void) async throws -> URL {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AppRec", isDirectory: true)
        onStatus("Downloading speech model… 0%")
        isDownloading = true
        defer { isDownloading = false }
        let folder = try await WhisperKit.download(variant: Self.model, downloadBase: base) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor in
                if self.isDownloading { onStatus("Downloading speech model… \(percent)%") }
            }
        }
        UserDefaults.standard.set(folder.path, forKey: Self.folderKey)
        return folder
    }
}
