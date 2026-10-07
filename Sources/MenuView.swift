import SwiftUI

struct MenuView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var player: Player
    @ObservedObject var ollama: Ollama
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AppPicker(apps: recorder.apps, selection: $recorder.selectedBundleID)
                Button {
                    recorder.refreshApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(recorder.isRecording)

            HStack {
                Toggle("Include microphone", isOn: $recorder.includeMicrophone)
                    .disabled(recorder.isRecording)

                Spacer()

                if let startedAt = recorder.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let end = recorder.pausedAt ?? context.date
                        Text(Duration.seconds(end.timeIntervalSince(startedAt) - recorder.pausedDuration).formatted(.time(pattern: .hourMinuteSecond)))
                            .monospacedDigit()
                            .foregroundStyle(recorder.isPaused ? .orange : .red)
                    }
                }

                if recorder.isRecording {
                    Button {
                        recorder.isPaused ? recorder.resume() : recorder.pause()
                    } label: {
                        Label(
                            recorder.isPaused ? "Resume" : "Pause",
                            systemImage: recorder.isPaused ? "record.circle" : "pause.fill"
                        )
                    }
                    .disabled(recorder.isBusy)

                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.isBusy)
                } else {
                    Button {
                        Task { await recorder.start() }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.selectedBundleID == nil || recorder.isBusy)
                }
            }

            if let status = recorder.modelStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = recorder.error ?? player.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.open(recorder.folder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open Recordings folder")
            }

            if recorder.recordings.isEmpty {
                Text("No recordings yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(recorder.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                player: player,
                                isTranscribing: recorder.transcribing.contains(recording.url),
                                onTranscribe: { Task { await recorder.transcribe(recording.url) } },
                                isSummarizing: recorder.summarizing.contains(recording.url),
                                onSummarize: summarizeAction(for: recording)
                            ) {
                                if player.current == recording.url { player.stop() }
                                recorder.delete(recording)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, 320))
            }

            Divider()

            SummarySettings(ollama: ollama)

            Divider()

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .foregroundStyle(.secondary)
                Link("Changelog", destination: URL(string: "https://github.com/hackmajoris/apprec/releases")!)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            recorder.refreshApps()
            recorder.refreshRecordings()
            Task { await ollama.refresh() }
        }
    }
}

extension MenuView {
    private func summarizeAction(for recording: Recording) -> (() -> Void)? {
        guard recording.hasTranscript, ollama.state == .ready || Summarizer.isAppleAvailable else { return nil }
        return { Task { await recorder.summarize(recording.url) } }
    }
}

private struct SummarySettings: View {
    @ObservedObject var ollama: Ollama
    @AppStorage(Ollama.modelKey) private var model = Ollama.defaultModel

    var body: some View {
        DisclosureGroup("Summary configs") {
            VStack(alignment: .leading, spacing: 6) {
                switch ollama.state {
                case .unknown:
                    ProgressView().controlSize(.small)
                case .notInstalled:
                    Text(fallbackText + " Install Ollama for better, multilingual summaries.")
                    Link("Download Ollama", destination: Ollama.downloadURL)
                case .notRunning:
                    Text(fallbackText + " Ollama is installed but not running.")
                    Button("Open Ollama") { Task { await ollama.open() } }
                case .missingModel, .ready:
                    modelPicker
                    if let progress = ollama.pullProgress {
                        ProgressView(value: progress) {
                            Text("Downloading \(model)… \(Int(progress * 100))%")
                        }
                    } else if ollama.state == .missingModel {
                        Button("Download \(model)") { Task { await ollama.pull() } }
                    }
                }
                if let error = ollama.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .padding(.top, 6)
        }
    }

    private var fallbackText: String {
        Summarizer.isAppleAvailable ? "Using Apple Intelligence (English only)." : "Summaries are off."
    }

    private var modelPicker: some View {
        Picker("Model", selection: $model) {
            ForEach(Array(Set(ollama.models + [Ollama.defaultModel, model])).sorted(), id: \.self) { name in
                Text(label(for: name)).tag(name)
            }
        }
        .disabled(ollama.pullProgress != nil)
        .onChange(of: model) { Task { await ollama.refresh() } }
    }

    private func label(for name: String) -> String {
        var label = name
        if name == Ollama.defaultModel { label += " (recommended)" }
        if !ollama.models.contains(name) { label += " – not downloaded" }
        return label
    }
}

private struct AppPicker: View {
    let apps: [RecordableApp]
    @Binding var selection: String?
    @State private var isExpanded = false
    @State private var query = ""
    @State private var listHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [RecordableApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            if isExpanded {
                Group {
                    if filtered.isEmpty {
                        Text("No matching apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(filtered) { app in
                                    AppListRow(app: app, isSelected: app.id == selection) {
                                        select(app)
                                    }
                                }
                            }
                            .padding(4)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                        }
                        .frame(height: min(listHeight, 260))
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
        }
    }

    private var selectedApp: RecordableApp? {
        apps.first { $0.id == selection }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Group {
                if !isExpanded, let app = selectedApp {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }
            }
            .onTapGesture { searchFocused = true }

            ZStack(alignment: .leading) {
                TextField("", text: $query, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filtered.first { select(first) }
                    }
                    .onExitCommand { collapse() }
                if !isExpanded, let app = selectedApp {
                    Text(app.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                if isExpanded { collapse() } else { searchFocused = true }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 22)
        .padding(6)
        .onChange(of: searchFocused) { _, focused in
            if focused { isExpanded = true }
        }
    }

    private var prompt: String {
        if isExpanded { return "Search apps" }
        return selectedApp == nil ? "Choose app…" : ""
    }

    private func collapse() {
        isExpanded = false
        searchFocused = false
        query = ""
    }

    private func select(_ app: RecordableApp) {
        selection = app.id
        collapse()
    }
}

private struct AppListRow: View {
    let app: RecordableApp
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                AppRow(app: app)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct AppRow: View {
    let app: RecordableApp

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 22, height: 22)
            Text(app.name)
                .font(.system(size: 14))
                .lineLimit(1)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var player: Player
    let isTranscribing: Bool
    let onTranscribe: () -> Void
    let isSummarizing: Bool
    let onSummarize: (() -> Void)?
    let onDelete: () -> Void

    private var isCurrent: Bool { player.current == recording.url }

    var body: some View {
        VStack(spacing: 4) {
            header
            if isCurrent {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack {
                        Slider(
                            value: Binding(get: { player.currentTime }, set: { player.currentTime = $0 }),
                            in: 0...max(player.duration, 0.1)
                        )
                        .controlSize(.small)
                        Text("\(Self.format(player.currentTime)) / \(Self.format(player.duration))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private var title: String {
        let name = recording.name
        guard let prefix = name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2} "#, options: .regularExpression) else { return name }
        return String(name[prefix.upperBound...])
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(2)
                    .help(recording.name)
                Text("\(recording.date.formatted(date: .abbreviated, time: .shortened)) · \(recording.size.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if recording.hasTranscript {
                Button {
                    NSWorkspace.shared.open(recording.transcriptURL)
                } label: {
                    Image(systemName: "doc.text")
                }
                .modifier(FilePreview(file: recording.transcriptURL) { player.play(recording.url, at: $0) })
            } else if isTranscribing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: onTranscribe) {
                    Image(systemName: "text.bubble")
                }
                .help("Transcribe")
            }
            if recording.hasSummary {
                Button {
                    NSWorkspace.shared.open(recording.summaryURL)
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .modifier(FilePreview(file: recording.summaryURL) { player.play(recording.url, at: $0) })
            } else if isSummarizing {
                ProgressView()
                    .controlSize(.small)
            } else if let onSummarize {
                Button(action: onSummarize) {
                    Image(systemName: "sparkles")
                }
                .help("Summarize")
            }
            Button {
                player.toggle(recording.url)
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.circle" : "play.circle")
            }
            .help(isCurrent && player.isPlaying ? "Pause" : "Play")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Move to Trash")
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
            }
        }
    }
}

private struct FilePreview: ViewModifier {
    let file: URL
    let onSeek: (TimeInterval) -> Void
    @State private var overAnchor = false
    @State private var overPopover = false
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .onHover { overAnchor = $0; update() }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                FileText(file: file, onSeek: onSeek)
                    .onHover { overPopover = $0; update() }
            }
    }

    private func update() {
        let hovering = overAnchor || overPopover
        guard hovering != isShown else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(hovering ? 400 : 300))
            if (overAnchor || overPopover) == hovering { isShown = hovering }
        }
    }
}

private struct FileText: View {
    private static let seekScheme = "apprec-seek"

    let file: URL
    let onSeek: (TimeInterval) -> Void
    @State private var lines: [String] = []
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(lines.indices, id: \.self) { line(lines[$0]) }
            }
            .padding(12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(width: 380, height: min(height, 420))
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.seekScheme, let seconds = TimeInterval(url.absoluteString.dropFirst(Self.seekScheme.count + 1)) else {
                return .systemAction
            }
            onSeek(seconds)
            return .handled
        })
        .task { lines = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: .newlines) ?? [] }
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        if text.hasPrefix("#") {
            Text(Self.linked(text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                .font(.headline)
                .padding(.top, 4)
        } else if text.hasPrefix("- ") {
            Text(Self.linked("• " + text.dropFirst(2)))
        } else {
            Text(Self.linked(text))
        }
    }

    static func linked(_ line: String) -> AttributedString {
        let markdown = line.replacing(#/\[(?:(\d+):)?(\d{1,2}):(\d{2})\]/#) { match in
            let (stamp, h, m, s) = match.output
            let seconds = (h.flatMap { Int($0) } ?? 0) * 3600 + Int(m)! * 60 + Int(s)!
            return "[\\[\(stamp.dropFirst().dropLast())\\]](\(seekScheme):\(seconds))"
        }
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}
