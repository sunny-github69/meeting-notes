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

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI notes", systemImage: "sparkles") }
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 520, height: 480)
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
                Toggle("Auto-record when a Zoom, Meet or Teams call starts", isOn: $autoDetectZoom)
            } footer: {
                Text("Recording starts when you join a meeting and notes are written when it ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Your name", text: $yourName)
                Toggle("Identify who is speaking from the meeting window", isOn: $detectSpeakers)
            } footer: {
                Text("Use a grid/gallery layout and keep the meeting window (for Meet: its browser tab) on screen. Frames are analysed in memory about once a second and never saved. If the window is hidden, notes come from audio alone (\"Not recognised\") and detection resumes when it is back.")
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
            Section {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if provider.needsKey {
                    SecureField("API key", text: $apiKey, prompt: Text(provider.keyHint))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(model.models, id: \.self) { Text($0).tag($0) }
                    }
                    Button { Task { await reloadModels() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Reload models")
                }
                keyStatus
            } header: {
                Text("Provider")
            } footer: {
                if !provider.needsKey {
                    Text("Runs on this Mac: free, offline, nothing leaves your machine. Larger models write better notes but take longer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)
            FallbackSection().disabled(!enabled)
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
            HStack {
                ProgressView().controlSize(.small)
                Text(provider.needsKey ? "Checking key…" : "Connecting to Ollama…")
            }
            .font(.caption)
        } else if let error = model.modelsError {
            Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        } else if !model.models.isEmpty {
            Label(provider.needsKey ? "Key works · \(model.models.count) models available"
                                    : "Ollama is running · \(model.models.count) local models",
                  systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else if !provider.needsKey {
            HStack {
                Text("No models installed. In Terminal run: ollama pull llama3.1").textSelection(.enabled)
                Link("Browse models", destination: provider.keyURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Paste your API key to load the latest models.")
                Link("Get a key", destination: provider.keyURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

/// A second model that writes the notes when the main one still fails after its automatic retries.
struct FallbackSection: View {
    @AppStorage("fallbackEnabled") private var enabled = false
    @AppStorage("fallbackProvider") private var providerRaw = Provider.ollama.rawValue
    @AppStorage("fallbackModel") private var modelName = ""
    @State private var models: [String] = []
    @State private var loadError: String?

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .ollama }

    var body: some View {
        Section {
            Toggle("Use a fallback model if notes fail", isOn: $enabled)
            if enabled {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Model", selection: $modelName) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                if let loadError {
                    Label(loadError, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                } else if models.isEmpty {
                    Text(provider.needsKey
                         ? "No key saved for \(provider.title): pick it as the main provider once to add its key."
                         : "Start Ollama and pull a model, e.g. ollama pull llama3.1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Fallback")
        } footer: {
            Text("Tried when the main model keeps failing, e.g. a cloud model as main and a local Ollama model as fallback. The notes show which model wrote them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: "\(enabled)|\(providerRaw)") {
            guard enabled else { return }
            do {
                models = try await LLM.models(for: provider)
                loadError = nil
            } catch {
                models = []
                loadError = error.localizedDescription
            }
            if !models.contains(modelName), let first = models.first { modelName = first }
        }
    }
}

struct TranscriptionSettings: View {
    @AppStorage("sttEngine") private var sttRaw = STTEngine.local.rawValue
    @AppStorage("transcriptionLanguage") private var languageRaw = TranscriptionLanguage.english.rawValue
    @AppStorage("whisperModelPath") private var whisperPath = Prefs.defaultWhisperModel

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $sttRaw) {
                    ForEach(STTEngine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Language", selection: $languageRaw) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text(languageRaw == TranscriptionLanguage.english.rawValue
                     ? "Best for English meetings: accented English is never mistaken for another language."
                     : "For meetings in other languages. Detected per 10-minute part, so a meeting that switches language mid-way may be transcribed in the first one. Notes are written in the meeting's main language.")
                    .font(.caption).foregroundStyle(.secondary)
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
