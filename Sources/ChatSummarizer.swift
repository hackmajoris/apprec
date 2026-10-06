import Foundation
import NaturalLanguage

enum ChatSummarizer {
    private static func instructions(language: String) -> String {
        """
        You summarize recording transcripts. Write everything in \(language), including the section headings. \
        Reply in Markdown with exactly these sections:
        ## TL;DR
        One or two sentences, no list.
        ## Key points
        Bullets with the facts, decisions and numbers discussed.
        ## Action items
        Bullets of tasks only, as "Name: task". Write "None" if there are none.
        Never repeat the same point in two sections. Do not invent details. Reply with the summary only.
        """
    }

    private static func language(of text: String) -> String {
        NLLanguageRecognizer.dominantLanguage(for: text)
            .flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.rawValue) }
            ?? "the same language as the transcript"
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            let message: Message
        }
        let choices: [Choice]
    }

    static func summarize(_ transcript: String, defaults: UserDefaults = .standard) async throws -> String {
        guard let endpoint = URL(string: defaults.string(forKey: Summarizer.endpointKey) ?? ""), endpoint.scheme != nil else {
            throw SummarizerError.invalidEndpoint
        }
        guard let model = defaults.string(forKey: Summarizer.modelKey), !model.isEmpty else {
            throw SummarizerError.missingModel
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = defaults.string(forKey: Summarizer.tokenKey), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: [
            Message(role: "system", content: instructions(language: language(of: transcript))),
            Message(role: "user", content: transcript),
        ]))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SummarizerError.server(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else {
            throw SummarizerError.server(status, "Empty response")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
