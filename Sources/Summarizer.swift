import Foundation
import FoundationModels

enum SummarizerError: LocalizedError {
    case unavailable
    case timedOut
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "No summary model available. Install Ollama or enable Apple Intelligence."
        case .timedOut: "Apple Intelligence took too long. Open Ollama to summarize long recordings."
        case let .server(status, body): "Server returned \(status): \(body)"
        }
    }
}

enum Summarizer {
    static var isAppleAvailable: Bool {
        if #available(macOS 26, *) { return AppleSummarizer.isAvailable }
        return false
    }

    static func isAvailable() async -> Bool {
        if isAppleAvailable { return true }
        return await Ollama.isReady()
    }

    static func summarize(_ transcript: String) async throws -> String {
        if await Ollama.isReady() { return try await Ollama.summarize(transcript) }
        if #available(macOS 26, *), AppleSummarizer.isAvailable { return try await AppleSummarizer.summarize(transcript) }
        throw SummarizerError.unavailable
    }
}

@available(macOS 26, *)
private enum AppleSummarizer {
    private static let chunkSize = 6_000
    private static let timeout = Duration.seconds(900)

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct Summary {
        @Guide(description: "Short descriptive title, 3 to 6 words")
        let title: String
        @Guide(description: "One or two sentences with the gist")
        let tldr: String
        @Guide(description: "Facts, decisions and numbers discussed, each starting with the [mm:ss] time from the transcript line where it was said")
        let keyPoints: [String]
        @Guide(description: "Tasks only, each as 'Name: task'. Empty if there are none")
        let actionItems: [String]
    }

    static func summarize(_ transcript: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await summarizeNow(transcript) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SummarizerError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func summarizeNow(_ transcript: String) async throws -> String {
        let notes = try await condense(transcript)
        let session = LanguageModelSession(instructions: """
            You summarize recording transcripts, which may be in any language. Always write in English. \
            Never repeat the same point in two fields. Do not invent details.
            """)
        let summary = try await session.respond(to: notes, generating: Summary.self).content

        let bullets = { (items: [String]) in items.isEmpty ? "None" : items.map { "- \($0)" }.joined(separator: "\n") }
        return """
            # \(summary.title)

            ## TL;DR
            \(summary.tldr)

            ## Key points
            \(bullets(summary.keyPoints))

            ## Action items
            \(bullets(summary.actionItems))

            """
    }

    private static func condense(_ text: String) async throws -> String {
        guard text.count > chunkSize else { return text }
        var notes: [String] = []
        for chunk in chunks(text) {
            try Task.checkCancellation()
            notes.append(try await respond(
                instructions: "Condense this part of a recording transcript into short factual notes in English. Keep names, numbers, decisions and tasks, each with its [mm:ss] time.",
                prompt: chunk
            ))
        }
        return try await condense(notes.joined(separator: "\n\n"))
    }

    private static func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    private static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !current.isEmpty, current.count + word.count + 1 > chunkSize {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " \(word)"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
