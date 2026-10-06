import AppKit
import NaturalLanguage

@MainActor
final class Ollama: ObservableObject {
    enum State {
        case unknown, notInstalled, notRunning, missingModel, ready
    }

    private static let bundleID = "com.electron.ollama"

    nonisolated static let baseURL = URL(string: "http://localhost:11434")!
    nonisolated static let downloadURL = URL(string: "https://ollama.com/download")!
    nonisolated static let modelKey = "summaryModel"

    nonisolated static var defaultModel: String {
        ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? "gemma3:12b" : "gemma3:4b"
    }

    nonisolated static var model: String {
        UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
    }

    @Published private(set) var state = State.unknown
    @Published private(set) var models: [String] = []
    @Published private(set) var pullProgress: Double?
    @Published private(set) var error: String?

    func refresh() async {
        guard let models = await Self.installedModels() else {
            models = []
            state = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) == nil ? .notInstalled : .notRunning
            return
        }
        self.models = models
        state = models.contains(Self.model) ? .ready : .missingModel
    }

    func open() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<20 where state == .notRunning {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    func pull() async {
        guard pullProgress == nil else { return }
        pullProgress = 0
        defer { pullProgress = nil }
        error = nil
        do {
            var request = URLRequest(url: Self.baseURL.appending(path: "api/pull"))
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(["model": Self.model])
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                let update = try JSONDecoder().decode(PullUpdate.self, from: Data(line.utf8))
                if let message = update.error { throw SummarizerError.server(0, message) }
                if let total = update.total, let completed = update.completed, total > 0 {
                    pullProgress = Double(completed) / Double(total)
                }
            }
        } catch {
            self.error = "Model download failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    nonisolated static func isReady() async -> Bool {
        await installedModels()?.contains(model) ?? false
    }

    private nonisolated static func installedModels() async -> [String]? {
        guard let (data, _) = try? await URLSession.shared.data(from: baseURL.appending(path: "api/tags")),
              let tags = try? JSONDecoder().decode(Tags.self, from: data)
        else { return nil }
        return tags.models.map(\.name).sorted()
    }

    nonisolated static func summarize(_ transcript: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: instructions(language: language(of: transcript))),
                Message(role: "user", content: transcript),
            ],
            stream: false,
            options: .init(num_ctx: min(max(transcript.count / 3 + 2_048, 4_096), 32_768))
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SummarizerError.server(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        let content = try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        return content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private nonisolated static func instructions(language: String) -> String {
        """
        You summarize recording transcripts. Write everything in \(language), including the section headings. \
        Reply in Markdown. Start with a title line "# <short descriptive title, 3 to 6 words>", then exactly these sections:
        ## TL;DR
        One or two sentences, no list.
        ## Key points
        Bullets with the facts, decisions and numbers discussed.
        ## Action items
        Bullets of tasks only, as "Name: task". Write "None" if there are none.
        Never repeat the same point in two sections. Do not invent details. Reply with the summary only.
        """
    }

    private nonisolated static func language(of text: String) -> String {
        NLLanguageRecognizer.dominantLanguage(for: text)
            .flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.rawValue) }
            ?? "the same language as the transcript"
    }

    private struct Tags: Decodable {
        struct Model: Decodable {
            let name: String
        }
        let models: [Model]
    }

    private struct PullUpdate: Decodable {
        let total: Int64?
        let completed: Int64?
        let error: String?
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        struct Options: Encodable {
            let num_ctx: Int
        }
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
    }

    private struct ChatResponse: Decodable {
        let message: Message
    }
}
