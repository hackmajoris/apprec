import Foundation

enum TranscriberError: LocalizedError {
    case invalidEndpoint
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Transcription endpoint is not a valid URL."
        case let .server(status, body): "Server returned \(status): \(body)"
        }
    }
}

enum Transcriber {
    static let endpointKey = "transcriptionEndpoint"
    static let tokenKey = "transcriptionToken"
    static let modelKey = "transcriptionModel"
    static let defaultModel = "whisper-1"

    private struct Response: Decodable {
        let text: String
    }

    static func transcribe(_ file: URL, defaults: UserDefaults = .standard) async throws -> String {
        guard let endpoint = URL(string: defaults.string(forKey: endpointKey) ?? ""), endpoint.scheme != nil else {
            throw TranscriberError.invalidEndpoint
        }
        let model = defaults.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        let boundary = UUID().uuidString

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = defaults.string(forKey: tokenKey), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TranscriberError.server(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data).text
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
