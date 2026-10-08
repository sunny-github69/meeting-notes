import SwiftUI

@main
struct MeetingNotesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Window("MeetingNotes Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu bar popover

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoDetectZoom") private var autoDetectZoom = false
    @AppStorage("detectSpeakers") private var detectSpeakers = true
    @AppStorage("aiNotesEnabled") private var aiNotesEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard
            VStack(spacing: 8) {
                SwitchRow(title: "Auto-record Zoom meetings", icon: "video", isOn: $autoDetectZoom)
                SwitchRow(title: "Identify speakers", icon: "person.2.wave.2", isOn: $detectSpeakers)
                SwitchRow(title: "Write AI notes", icon: "sparkles", isOn: $aiNotesEnabled)
            }
            if !model.recent.isEmpty {
                Divider()
                recentMeetings
            }
            Divider()
            HStack {
                Button("Open notes folder") {
                    try? FileManager.default.createDirectory(at: AppModel.notesRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppModel.notesRoot)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshRecent() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill").font(.title).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("MeetingNotes").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var subtitle: String {
        switch model.state {
        case .idle: return autoDetectZoom ? "Waiting for a Zoom meeting" : "Ready"
        case .recording: return "Recording locally"
        case .processing: return "Working…"
        case .done: return "Notes ready"
        case .failed: return "Something went wrong"
        }
    }

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .idle:
                wideButton("Start recording", icon: "record.circle") { await model.start() }
            case .recording(let since):
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(since, style: .timer).font(.title3.monospacedDigit())
                    Spacer()
                }
                if detectSpeakers { speakerLine.font(.callout) }
                wideButton("Stop & write notes", icon: "stop.fill") { await model.stop() }
            case .processing(let message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.callout)
                }
            case .done(let file):
                Label("Saved \(file.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Button("Open") { NSWorkspace.shared.open(file) }.buttonStyle(.borderedProminent)
                    Button("New recording") { Task { await model.start() } }
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.canRetry { Button("Retry") { Task { await model.retry() } }.buttonStyle(.borderedProminent) }
                    Button("New recording") { Task { await model.start() } }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var speakerLine: some View {
        switch model.speakerStatus {
        case .speaking(let name):
            Label("\(name) is speaking", systemImage: "person.wave.2").foregroundStyle(.secondary)
        case .noHighlight:
            Label("Looking for the active speaker (use Gallery view)", systemImage: "person.crop.rectangle")
                .foregroundStyle(.secondary)
        case .zoomHidden:
            Label("Zoom not visible – notes from audio only", systemImage: "eye.slash").foregroundStyle(.orange)
        case nil:
            Label("Listening…", systemImage: "waveform").foregroundStyle(.secondary)
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            ForEach(model.recent) { meeting in
                Button {
                    NSWorkspace.shared.open(meeting.file)
                } label: {
                    HStack {
                        Image(systemName: meeting.hasNotes ? "doc.text" : "text.alignleft").frame(width: 16)
                        Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
    }

    private func wideButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

struct SwitchRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI notes", systemImage: "sparkles") }
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 500, height: 380)
    }
}

struct GeneralSettings: View {
    @AppStorage("autoDetectZoom") private var autoDetectZoom = false
    @AppStorage("detectSpeakers") private var detectSpeakers = true
    @AppStorage("yourName") private var yourName = Prefs.defaultName
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Auto-record when a Zoom meeting starts", isOn: $autoDetectZoom)
            } footer: {
                Text("Recording starts when you join a meeting and notes are written when it ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Your name", text: $yourName)
                Toggle("Identify who is speaking from the Zoom window", isOn: $detectSpeakers)
            } footer: {
                Text("Use Zoom's Gallery view and keep the Zoom window on screen. Frames are analysed in memory about once a second and never saved. If Zoom is minimised, notes come from audio alone (\"Not recognised\") and detection resumes when it is back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: launchAtLogin) { enabled in
            guard enabled != LoginItem.isEnabled else { return }
            do {
                try LoginItem.set(enabled)
                loginError = nil
            } catch {
                loginError = "Couldn't change login item: \(error.localizedDescription) Move the app to /Applications and try again."
                launchAtLogin = LoginItem.isEnabled
            }
        }
    }
}

struct AISettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("aiNotesEnabled") private var enabled = true
    @AppStorage("llmProvider") private var providerRaw = Provider.anthropic.rawValue
    @State private var apiKey = ""
    @State private var selectedModel = ""

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        Form {
            Section {
                Toggle("Write AI notes after each meeting", isOn: $enabled)
            } footer: {
                Text("When off, only the transcript is saved.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                SecureField("API key", text: $apiKey)
                HStack {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(model.models, id: \.self) { Text($0).tag($0) }
                    }
                    Button { Task { await reloadModels() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Reload models")
                }
                keyStatus
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: providerRaw) { _ in load() }
        .onChange(of: apiKey) { Keychain.set($0, for: providerRaw) }
        .onChange(of: selectedModel) { UserDefaults.standard.set($0, forKey: "model.\(providerRaw)") }
        // Debounced: check the key and load its models shortly after typing stops.
        .task(id: "\(providerRaw)|\(apiKey)") {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await reloadModels()
        }
    }

    @ViewBuilder private var keyStatus: some View {
        if model.modelsLoading {
            HStack { ProgressView().controlSize(.small); Text("Checking key…") }.font(.caption)
        } else if let error = model.modelsError {
            Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        } else if !model.models.isEmpty {
            Label("Key works · \(model.models.count) models available", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Text("Paste your API key to load the latest models.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        apiKey = Keychain.get(providerRaw) ?? ""
        selectedModel = Prefs.model(for: provider)
    }

    private func reloadModels() async {
        await model.refreshModels(for: provider)
        if !model.models.contains(selectedModel), let first = model.models.first { selectedModel = first }
    }
}

struct TranscriptionSettings: View {
    @AppStorage("sttEngine") private var sttRaw = STTEngine.local.rawValue
    @AppStorage("whisperModelPath") private var whisperPath = Prefs.defaultWhisperModel

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $sttRaw) {
                    ForEach(STTEngine.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            if sttRaw == STTEngine.local.rawValue {
                Section {
                    TextField("Whisper model file", text: $whisperPath)
                    if FileManager.default.fileExists(atPath: whisperPath) {
                        Label("Model found", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Model file not found", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Free and offline. Install with `brew install whisper-cpp` and download a model (see README).")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Section {
                    Text("Uses the OpenAI key from the AI notes tab. Audio is uploaded to OpenAI for transcription.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
