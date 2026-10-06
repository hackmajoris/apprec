import Foundation
import FoundationModels

enum SummarizerError: LocalizedError {
    case unavailable
    case invalidEndpoint
    case missingModel
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "No summary model available."
        case .invalidEndpoint: "Summary endpoint is not a valid URL."
        case .missingModel: "Summary model is not set."
        case let .server(status, body): "Server returned \(status): \(body)"
        }
    }
}

enum Summarizer {
    static let endpointKey = "summaryEndpoint"
    static let tokenKey = "summaryToken"
    static let modelKey = "summaryModel"

    private static var hasEndpoint: Bool {
        !(UserDefaults.standard.string(forKey: endpointKey) ?? "").isEmpty
    }

    static var isAvailable: Bool {
        if hasEndpoint { return true }
        if #available(macOS 26, *) { return AppleSummarizer.isAvailable }
        return false
    }

    static func summarize(_ transcript: String) async throws -> String {
        if hasEndpoint { return try await ChatSummarizer.summarize(transcript) }
        if #available(macOS 26, *), AppleSummarizer.isAvailable { return try await AppleSummarizer.summarize(transcript) }
        throw SummarizerError.unavailable
    }
}

@available(macOS 26, *)
private enum AppleSummarizer {
    private static let chunkSize = 6_000

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct Summary {
        @Guide(description: "One or two sentences with the gist")
        let tldr: String
        @Guide(description: "Facts, decisions and numbers discussed")
        let keyPoints: [String]
        @Guide(description: "Tasks only, each as 'Name: task'. Empty if there are none")
        let actionItems: [String]
    }

    static func summarize(_ transcript: String) async throws -> String {
        let notes = try await condense(transcript)
        let session = LanguageModelSession(instructions: """
            You summarize recording transcripts, which may be in any language. Always write in English. \
            Never repeat the same point in two fields. Do not invent details.
            """)
        let summary = try await session.respond(to: notes, generating: Summary.self).content

        let bullets = { (items: [String]) in items.isEmpty ? "None" : items.map { "- \($0)" }.joined(separator: "\n") }
        return """
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
            notes.append(try await respond(
                instructions: "Condense this part of a recording transcript into short factual notes in English. Keep names, numbers, decisions and tasks.",
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
