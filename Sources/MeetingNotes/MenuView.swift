import SwiftUI

// MARK: - Menu bar popover

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoDetectZoom") private var autoDetectZoom = false
    @AppStorage("detectSpeakers") private var detectSpeakers = true
    @AppStorage("aiNotesEnabled") private var aiNotesEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusCard
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.state)
            VStack(spacing: 10) {
                SwitchRow(title: "Auto-record meetings", icon: "video.fill", tint: .blue, isOn: $autoDetectZoom)
                SwitchRow(title: "Identify speakers", icon: "person.2.wave.2.fill", tint: .teal, isOn: $detectSpeakers)
                SwitchRow(title: "Write AI notes", icon: "sparkles", tint: .purple, isOn: $aiNotesEnabled)
            }
            .card()
            if !model.recent.isEmpty { recentMeetings }
            HStack {
                Button {
                    try? FileManager.default.createDirectory(at: AppModel.notesRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppModel.notesRoot)
                } label: {
                    Label("All notes", systemImage: "folder")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.refreshRecent() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        case .idle: return autoDetectZoom ? "Waiting for Zoom, Meet or Teams" : "Ready"
        case .recording: return model.meetingApp.map { "Recording \($0.title) locally" } ?? "Recording locally"
        case .processing: return "Working on your notes…"
        case .done: return "Notes saved"
        case .failed: return "Something went wrong"
        }
    }

    @ViewBuilder private var statusCard: some View {
        Group {
            switch model.state {
            case .idle:
                VStack(alignment: .leading, spacing: 8) {
                    wideButton("Start recording", icon: "record.circle.fill") { await model.start() }
                    Text(autoDetectZoom ? "Recording starts by itself when you join a call."
                                        : "Join your meeting, then press Start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .recording(let since):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        PulsingDot()
                        Text(since, style: .timer)
                            .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        Spacer()
                        if let app = model.meetingApp { Badge(text: app.title, icon: "video.fill") }
                    }
                    if detectSpeakers { speakerLine.font(.callout) }
                    wideButton("Stop & write notes", icon: "stop.fill", tint: .red) { await model.stop() }
                }
            case .processing(let step):
                ProcessingSteps(step: step, writesNotes: aiNotesEnabled || step != .transcribing)
            case .done(let meeting):
                DoneCard(meeting: meeting)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.canRetry {
                            Button { Task { await model.retry() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("New recording") { Task { await model.start() } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder private var speakerLine: some View {
        switch model.speakerStatus {
        case .speaking(let name):
            Label("\(name) is speaking", systemImage: "person.wave.2.fill").foregroundStyle(.primary)
        case .noHighlight:
            Label("Looking for the active speaker (use grid/gallery view)", systemImage: "person.crop.rectangle")
                .foregroundStyle(.secondary)
        case .appHidden:
            Label("\(model.meetingApp?.title ?? "Meeting") not visible – notes from audio only", systemImage: "eye.slash")
                .foregroundStyle(.orange)
        case nil:
            Label("Listening…", systemImage: "waveform").foregroundStyle(.secondary)
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
            ForEach(model.recent) { MeetingRow(meeting: $0) }
        }
    }

    private func wideButton(_ title: String, icon: String, tint: Color = .accentColor,
                            action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }
}

// MARK: - Done: name, preview, actions and regenerate

/// Shown once notes are saved. The meeting is already stored under the AI's title (or the date);
/// editing the name renames it and Cancel keeps what is saved. "Regenerate" rewrites the notes of this
/// latest meeting with another model, from the saved transcript.
struct DoneCard: View {
    let meeting: AppModel.Meeting
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("llmProvider") private var providerRaw = Provider.anthropic.rawValue
    @State private var draft = ""
    @State private var copied = false
    @State private var selectedModel = ""
    @FocusState private var nameFocused: Bool

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .anthropic }
    private var edited: Bool { draft.trimmingCharacters(in: .whitespaces) != (meeting.title ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            nameField
            details
            actions
            Divider()
            regenerateRow
        }
        .onAppear {
            draft = meeting.title ?? ""
            selectedModel = Prefs.model(for: provider)
        }
        .onChange(of: meeting) { draft = $0.title ?? "" }
        .task(id: providerRaw) {
            selectedModel = Prefs.model(for: provider)
            await model.refreshModels(for: provider)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text(meeting.hasNotes ? "Notes ready" : "Transcript ready").font(.subheadline.weight(.semibold))
            Spacer()
            if let app = meeting.app { Badge(text: app.title, icon: "video.fill") }
        }
    }

    /// The meeting name, edited in place. ✓ / Return saves, ✕ / Esc keeps the saved name.
    private var nameField: some View {
        HStack(spacing: 6) {
            TextField("Name this meeting", text: $draft)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($nameFocused)
                .onSubmit(save)
                .onExitCommand(perform: cancel)
            if edited {
                Button(action: save) { Image(systemName: "checkmark.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.green).help("Save name (Return)")
                Button(action: cancel) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Keep the saved name (Esc)")
            } else {
                Image(systemName: "pencil").foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(nameFocused ? 0.09 : 0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(nameFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: edited)
        .animation(.easeOut(duration: 0.15), value: nameFocused)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                if let notesModel = meeting.notesModel {
                    Text("·")
                    Image(systemName: "sparkles")
                    // "gemini-3.8-flash (Gemini (Google))" → just the model, so the line fits.
                    Text(notesModel.components(separatedBy: " (").first ?? notesModel).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !meeting.summary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(meeting.summary, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: -2)
                            Text(bullet).lineLimit(2)
                        }
                    }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.open(meeting.file) } label: {
                Label(meeting.hasNotes ? "Open notes" : "Open transcript", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            IconButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard") {
                model.copyNotes(meeting)
                copied = true
                Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            }
            IconButton(icon: "folder", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.file])
            }
            IconButton(icon: "plus", help: "Start a new recording") { Task { await model.start() } }
        }
    }

    /// Pick another model of the current provider and rewrite the notes from the saved transcript.
    private var regenerateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Section(provider.title) {
                        ForEach(model.models, id: \.self) { name in
                            Button {
                                selectedModel = name
                                UserDefaults.standard.set(name, forKey: "model.\(providerRaw)")
                            } label: {
                                if name == selectedModel { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    }
                    Divider()
                    Button("Other provider…") {
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } label: {
                    Label(selectedModel.isEmpty ? "Choose model" : selectedModel, systemImage: "cpu")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { Task { await model.regenerateNotes(meeting) } } label: {
                    Label(meeting.hasNotes ? "Regenerate" : "Write notes", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(selectedModel.isEmpty)
                .help("Write the notes again with the selected model")
            }
            Text(model.notesError.map { "Couldn't regenerate: \($0)" }
                 ?? "Not happy with the notes? Pick another model and regenerate.")
                .font(.caption)
                .foregroundStyle(model.notesError == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        guard edited else { nameFocused = false; return }
        model.rename(meeting, to: draft)
        nameFocused = false
    }

    private func cancel() {
        draft = meeting.title ?? ""
        nameFocused = false
    }
}

struct Badge: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(help)
    }
}

// MARK: - Recent meeting row

struct MeetingRow: View {
    let meeting: AppModel.Meeting
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: meeting.hasNotes ? "doc.text.fill" : "text.alignleft")
                .foregroundStyle(meeting.hasNotes ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            if editing {
                TextField("Meeting name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(save)
                    .onExitCommand { editing = false }
                Button(action: save) { Image(systemName: "checkmark") }.buttonStyle(.borderless).help("Save")
                Button { editing = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Cancel")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.displayTitle).lineLimit(1)
                    if meeting.title != nil {
                        Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if hovering {
                    Button(action: startEditing) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Rename")
                    Button { model.moveToTrash(meeting) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Move to Trash")
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(hovering && !editing ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !editing { NSWorkspace.shared.open(meeting.file) } }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(meeting.file) }
            Button("Rename…", action: startEditing)
            Button("Copy to Clipboard") { model.copyNotes(meeting) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.file]) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.moveToTrash(meeting) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func startEditing() {
        draft = meeting.title ?? ""
        editing = true
        nameFocused = true
    }

    private func save() {
        model.rename(meeting, to: draft)
        editing = false
    }
}

// MARK: - Small pieces

struct ProcessingSteps: View {
    let step: AppModel.Step
    let writesNotes: Bool

    private enum Phase { case pending, active, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Transcribing audio", step == .transcribing ? .active : .done)
            if writesNotes { row(notesTitle, step == .transcribing ? .pending : .active) }
        }
    }

    private var notesTitle: String {
        if case .writingNotes(let model) = step { return "Writing notes with \(model)" }
        return "Writing notes"
    }

    private func row(_ title: String, _ phase: Phase) -> some View {
        HStack(spacing: 8) {
            Group {
                switch phase {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active: ProgressView().controlSize(.small)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)
            Text(title).lineLimit(1).foregroundStyle(phase == .pending ? .secondary : .primary)
        }
        .font(.callout)
    }
}

struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .overlay(
                Circle().stroke(Color.red.opacity(0.6), lineWidth: 2)
                    .scaleEffect(pulsing ? 2.4 : 1)
                    .opacity(pulsing ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulsing = true }
            }
    }
}

struct SwitchRow: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

private extension View {
    /// Rounded, softly filled container used for each section of the popover.
    func card() -> some View {
        padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
