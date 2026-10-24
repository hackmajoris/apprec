import AppKit
import CryptoKit
import Security

@MainActor
final class Updater: ObservableObject {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var zip: Asset? { assets.first { $0.name == "AppRec.zip" } }
    }

    nonisolated static let releasesURL = URL(string: "https://github.com/hackmajoris/apprec/releases")!
    private static let latestURL = URL(string: "https://api.github.com/repos/hackmajoris/apprec/releases/latest")!
    private static let bundleID = "com.hackmajoris.AppRec"
    private static let checkInterval: TimeInterval = 60 * 60

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    @Published private(set) var latest: Release?
    @Published private(set) var isInstalling = false
    @Published private(set) var error: String?
    private var lastChecked: Date?

    var canUpdate: Bool { Bundle.main.bundleIdentifier == Self.bundleID }

    var updateAvailable: Bool {
        guard let latest, latest.zip != nil else { return false }
        return latest.version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    func checkIfStale() async {
        if let lastChecked, Date.now.timeIntervalSince(lastChecked) < Self.checkInterval { return }
        lastChecked = .now
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else {
            lastChecked = nil
            return
        }
        latest = release
    }

    func install() async {
        guard let latest, let zip = latest.zip, !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        error = nil
        do {
            let app = Bundle.main.bundleURL
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let (download, _) = try await URLSession.shared.download(from: zip.browser_download_url)
            let archive = staging.appending(path: zip.name)
            try FileManager.default.moveItem(at: download, to: archive)
            try Self.verifyDigest(of: archive, expected: zip.digest)

            let expanded = staging.appending(path: "expanded")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
            let staged = expanded.appending(path: "AppRec.app")
            try Self.verifyBundle(staged, version: latest.version)

            _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
            relaunch(app)
        } catch {
            self.error = "Update failed: \(error.localizedDescription)"
        }
    }

    private func relaunch(_ app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    private static func verifyDigest(of archive: URL, expected: String?) throws {
        guard let expected, expected.hasPrefix("sha256:") else { throw UpdateError("release has no checksum") }
        let actual = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + actual == expected else { throw UpdateError("checksum mismatch") }
    }

    private static func verifyBundle(_ app: URL, version: String) throws {
        let plist = app.appending(components: "Contents", "Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { throw UpdateError("archive has no AppRec.app") }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError("unexpected bundle id") }
        guard info["CFBundleShortVersionString"] as? String == version else { throw UpdateError("unexpected version") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { throw UpdateError("invalid code signature") }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                process.terminationStatus == 0
                    ? continuation.resume()
                    : continuation.resume(throwing: UpdateError("\(tool) exited with \(process.terminationStatus)"))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
