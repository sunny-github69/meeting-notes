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
            if !model.jobs.isEmpty {
                QueueCard(jobs: model.jobs).transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let meeting = model.lastMeeting, !model.isRecording {
                DoneCard(meeting: meeting).card().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.jobs)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.lastMeeting)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.recordingSince)
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
        if model.isRecording {
            return model.meetingApp.map { "Recording \($0.title) locally" } ?? "Recording locally"
        }
        if let active = model.jobs.first(where: \.isActive) {
            return "Working on your notes · \(Int(active.progress * 100))%"
        }
        if model.jobs.contains(where: { if case .failed = $0.phase { return true } else { return false } }) {
            return "A meeting needs attention"
        }
        if model.lastMeeting != nil { return "Notes saved" }
        return autoDetectZoom ? "Waiting for Zoom, Meet or Teams" : "Ready"
    }

    /// Start, or the live recording. Processing runs separately (see the queue card), so a new meeting can
    /// be recorded while earlier ones are still being transcribed.
    private var statusCard: some View {
        Group {
            if let since = model.recordingSince {
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
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    wideButton("Start recording", icon: "record.circle.fill") { await model.start() }
                    if let error = model.startError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(autoDetectZoom ? "Recording starts by itself when you join a call."
                                            : "Join your meeting, then press Start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            Button { model.dismissLastMeeting() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Hide")
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
                .disabled(model.isProcessing(meeting))
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
                Button { model.regenerateNotes(meeting) } label: {
                    Label(meeting.hasNotes ? "Regenerate" : "Write notes", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(selectedModel.isEmpty || model.isProcessing(meeting))
                .help("Write the notes again with the selected model")
            }
            Text(model.isProcessing(meeting) ? "Regenerating… progress is shown above."
                                             : "Not happy with the notes? Pick another model and regenerate.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

/// Meetings being transcribed and summarised, one at a time, with failed ones offering Retry.
struct QueueCard: View {
    let jobs: [AppModel.Job]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Processing").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                let waiting = jobs.filter { $0.phase == .queued }.count
                if waiting > 0 { Badge(text: "\(waiting) in queue", icon: "clock") }
            }
            ForEach(jobs) { job in
                switch job.phase {
                case .transcribing, .writingNotes: ActiveJobRow(job: job)
                case .queued: QueuedJobRow(job: job)
                case .failed(let message): FailedJobRow(job: job, message: message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private extension AppModel.Job {
    var title: String { date.formatted(date: .abbreviated, time: .shortened) }
}

struct ActiveJobRow: View {
    let job: AppModel.Job

    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(progress: job.progress)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.regenerate ? "Regenerating notes" : job.title)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                step("Transcribing", detail: transcribeDetail, state: transcribeState)
                step(notesLabel, detail: nil, state: notesState)
            }
        }
    }

    private enum StepState { case pending, active, done }

    private var transcribeState: StepState {
        if job.regenerate { return .done }
        if case .transcribing = job.phase { return .active }
        return .done
    }

    private var notesState: StepState {
        if case .writingNotes = job.phase { return .active }
        return .pending
    }

    private var transcribeDetail: String? {
        guard case .transcribing(let part, let parts) = job.phase else { return nil }
        return parts == 0 ? "preparing" : "part \(part) of \(parts)"
    }

    private var notesLabel: String {
        if case .writingNotes(let model) = job.phase { return "Writing notes · \(model)" }
        return "Writing notes"
    }

    private func step(_ title: String, detail: String?, state: StepState) -> some View {
        HStack(spacing: 6) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active: Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            Text(detail.map { "\(title) · \($0)" } ?? title)
                .font(.caption)
                .foregroundStyle(state == .pending ? .secondary : .primary)
                .lineLimit(1)
        }
    }
}

struct QueuedJobRow: View {
    let job: AppModel.Job

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 18)
            Text(job.regenerate ? "Regenerate notes · \(job.title)" : job.title).lineLimit(1)
            Spacer()
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct FailedJobRow: View {
    let job: AppModel.Job
    let message: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 18)
                Text(job.regenerate ? "Couldn't regenerate notes" : "Couldn't finish \(job.title)")
                    .font(.callout.weight(.medium)).lineLimit(1)
            }
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { model.retry(job) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button(job.regenerate ? "Dismiss" : "Discard") { model.discard(job) }
                    .controlSize(.small)
                    .help(job.regenerate ? "Keep the previous notes" : "Move this recording to the Trash")
            }
            .padding(.leading, 26)
        }
    }
}

/// Circular gradient progress with the percentage in the middle.
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(AngularGradient(colors: [.blue, .purple, .pink, .blue], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .purple.opacity(0.35), radius: 4)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
        }
        .frame(width: 58, height: 58)
        .animation(.easeOut(duration: 0.4), value: progress)
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
