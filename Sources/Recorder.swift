import AppKit
import AVFoundation
import ScreenCaptureKit

struct Recording: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    let hasTranscript: Bool
    let hasSummary: Bool
    var id: URL { url }
    var transcriptURL: URL { url.deletingPathExtension().appendingPathExtension("txt") }
    var summaryURL: URL { url.deletingPathExtension().appendingPathExtension("summary.md") }
}

struct RecordableApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage
}

enum RecorderError: LocalizedError {
    case appNotRunning
    case noDisplay
    case noAudio
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .appNotRunning: "Selected app is not running."
        case .noDisplay: "No display available for capture."
        case .noAudio: "No audio was captured."
        case .exportFailed: "Could not create the export session."
        }
    }
}

@MainActor
final class Recorder: NSObject, ObservableObject, SCStreamDelegate {
    @Published var apps: [RecordableApp] = []
    @Published var selectedBundleID: String?
    @Published var includeMicrophone = true
    @Published private(set) var startedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var error: String?
    @Published private(set) var transcribing: Set<URL> = []
    @Published private(set) var modelStatus: String?
    @Published private(set) var summarizing: Set<URL> = []

    var isRecording: Bool { stream != nil }

    private var stream: SCStream?
    private var writer: TrackWriter?
    private var appName = ""
    private let localTranscriber = LocalTranscriber()

    let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Recordings", isDirectory: true)

    override init() {
        super.init()
        refreshRecordings()
    }

    func refreshApps() {
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap { app in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return RecordableApp(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start() async {
        guard let bundleID = selectedBundleID, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let targets = content.applications.filter {
                $0.bundleIdentifier == bundleID || $0.bundleIdentifier.hasPrefix(bundleID + ".")
            }
            guard !targets.isEmpty else { throw RecorderError.appNotRunning }
            guard let display = content.displays.first else { throw RecorderError.noDisplay }

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = includeMicrophone
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            let writer = try TrackWriter(url: tempURL, includeMicrophone: includeMicrophone)

            let filter = SCContentFilter(display: display, including: targets, exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            if includeMicrophone {
                try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            try await stream.startCapture()

            self.stream = stream
            self.writer = writer
            appName = targets.first?.applicationName ?? bundleID
            startedAt = .now
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() async {
        guard let stream, let writer else { return }
        isBusy = true
        defer { isBusy = false }

        try? await stream.stopCapture()
        self.stream = nil
        self.writer = nil
        startedAt = nil

        do {
            let tempURL = try await writer.finish()
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let outputURL = try makeOutputURL()
            try await Self.mixdown(tempURL, to: outputURL)
            refreshRecordings()
            Task { await transcribe(outputURL) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.error = error.localizedDescription
            await self.stop()
        }
    }

    func refreshRecordings() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        } catch CocoaError.fileReadNoSuchFile {
            urls = []
        } catch {
            self.error = error.localizedDescription
            urls = []
        }
        recordings = urls
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let base = url.deletingPathExtension()
                return Recording(
                    url: url,
                    date: values?.creationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0),
                    hasTranscript: FileManager.default.fileExists(atPath: base.appendingPathExtension("txt").path),
                    hasSummary: FileManager.default.fileExists(atPath: base.appendingPathExtension("summary.md").path)
                )
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ recording: Recording) {
        do {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            if recording.hasTranscript {
                try FileManager.default.trashItem(at: recording.transcriptURL, resultingItemURL: nil)
            }
            if recording.hasSummary {
                try FileManager.default.trashItem(at: recording.summaryURL, resultingItemURL: nil)
            }
        } catch {
            self.error = error.localizedDescription
        }
        refreshRecordings()
    }

    func transcribe(_ url: URL) async {
        guard transcribing.insert(url).inserted else { return }
        defer { transcribing.remove(url) }
        do {
            let text = try await localTranscriber.transcribe(url) { [weak self] in self?.modelStatus = $0 }
            try text.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            refreshRecordings()
        } catch {
            self.error = "Transcription failed: \(error.localizedDescription)"
            return
        }
        if Summarizer.isAvailable {
            await summarize(url)
        }
    }

    func summarize(_ url: URL) async {
        guard summarizing.insert(url).inserted else { return }
        defer { summarizing.remove(url) }
        let base = url.deletingPathExtension()
        do {
            let transcript = try String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8)
            let summary = try await Summarizer.summarize(transcript)
            try summary.write(to: base.appendingPathExtension("summary.md"), atomically: true, encoding: .utf8)
            refreshRecordings()
        } catch {
            self.error = "Summary failed: \(error.localizedDescription)"
        }
    }

    private func makeOutputURL() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folder.appendingPathComponent("\(appName) \(formatter.string(from: .now)).m4a")
    }

    private static func mixdown(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed
        }
        try await export.export(to: destination, as: .m4a)
    }
}

final class TrackWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "AppRec.writer")
    private let writer: AVAssetWriter
    private let appInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput?
    private var started = false

    init(url: URL, includeMicrophone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        appInput = Self.makeInput(channels: 2)
        writer.add(appInput)
        if includeMicrophone {
            let mic = Self.makeInput(channels: 1)
            writer.add(mic)
            micInput = mic
        } else {
            micInput = nil
        }
    }

    private static func makeInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000 * channels,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let input: AVAssetWriterInput?
        switch type {
        case .audio: input = appInput
        case .microphone: input = micInput
        default: input = nil
        }
        guard let input else { return }

        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard started else {
                    continuation.resume(throwing: RecorderError.noAudio)
                    return
                }
                appInput.markAsFinished()
                micInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: writer.outputURL)
                    }
                }
            }
        }
    }
}
