import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(Date)
        case processing(Step)
        case done(Meeting)
        case failed(String)
    }

    enum Step: Equatable {
        case transcribing
        case writingNotes(model: String)
    }

    /// A saved meeting: a folder named "yyyy-MM-dd HHmm" or "yyyy-MM-dd HHmm · Title".
    struct Meeting: Identifiable, Equatable {
        let id: URL  // the folder
        let date: Date
        let title: String?
        let file: URL  // notes.md, else transcript.md
        let hasNotes: Bool
        let summary: [String]  // first bullets of the Summary section

        var displayTitle: String { title ?? date.formatted(date: .abbreviated, time: .shortened) }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var speakerStatus: SpeakerDetector.Status?
    @Published private(set) var meetingApp: MeetingApp?
    @Published private(set) var recent: [Meeting] = []
    @Published private(set) var models: [String] = []
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelsError: String?

    private let recorder = Recorder()
    private var session: (dir: URL, recording: Recording?)?
    private var autoStarted = false
    private var ignoreCurrentMeeting = false
    private var missedPolls = 0

    private static let titleSeparator = " · "
    private static let folderFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    var isRecording: Bool { if case .recording = state { return true } else { return false } }
    var canRetry: Bool { if case .failed = state, session?.recording != nil { return true } else { return false } }
    private var isBusy: Bool {
        switch state {
        case .recording, .processing: return true
        default: return false
        }
    }

    init() {
        Prefs.registerDefaults()
        Notifier.shared.setUp()
        refreshRecent()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollMeetings() }
        }
    }

    static var notesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingNotes")
    }

    // MARK: Recording

    /// Starts recording. `app` is the meeting app auto-record detected; a manual start works it out here.
    func start(auto: Bool = false, app: MeetingApp? = nil) async {
        guard !isBusy else { return }
        let dir = Self.notesRoot.appendingPathComponent(Self.folderFormat.string(from: Date()))
        do {
            let app = await Self.detected(app) { MeetingDetector.currentApp() }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await recorder.start(into: dir, app: app, detectSpeakers: Prefs.detectSpeakers) { [weak self] status in
                self?.speakerStatus = status
            }
            session = (dir, nil)
            meetingApp = app
            autoStarted = auto
            missedPolls = 0
            state = .recording(Date())
            if auto {
                Notifier.shared.post("Recording \(app?.title ?? "meeting")", "Notes will be written when the meeting ends.")
            }
        } catch {
            ignoreCurrentMeeting = true
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard let dir = session?.dir, isRecording else { return }
        ignoreCurrentMeeting = true
        session = (dir, await recorder.stop())
        speakerStatus = nil
        meetingApp = nil
        await process()
    }

    func retry() async { await process() }

    private func process() async {
        guard let session, let recording = session.recording else { return }
        do {
            state = .processing(.transcribing)
            let segments = try await Transcriber.transcribe(tracks: recording.tracks, engine: Prefs.sttEngine,
                                                              language: Prefs.transcriptionLanguage)
                .map { name($0, using: recording.speakers) }
            guard !segments.isEmpty else { throw AppError("No speech was detected.") }
            let transcript = Transcriber.format(segments)
            try transcript.write(to: session.dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            var title: String?

            if Prefs.aiNotesEnabled {
                let provider = Prefs.provider
                let model = Prefs.model(for: provider)
                state = .processing(.writingNotes(model: model))
                var seen = Set<String>()
                let speakers = segments.map(\.speaker).filter { seen.insert($0).inserted }
                let notes = try await LLM.complete(
                    provider: provider, model: model,
                    user: LLM.userMessage(transcript: transcript, app: recording.app, recordedBy: Prefs.yourName,
                                          speakers: speakers, namesOnScreen: recording.participants))
                try notes.write(to: session.dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
                title = LLM.title(fromNotes: notes)
            }

            // Raw audio is only kept when something failed, so it can be retried.
            recording.tracks.flatMap(\.chunks).forEach { try? FileManager.default.removeItem(at: $0.url) }
            self.session = nil
            // Saved already under the date; the AI's title is applied on top and can be changed later.
            let saved = Self.meeting(at: session.dir)
            let meeting = title.flatMap { title in saved.flatMap { try? move($0, to: title) } } ?? saved
            guard let meeting else { throw AppError("Couldn't read the saved meeting.") }
            state = .done(meeting)
            refreshRecent()
            Notifier.shared.post("Meeting notes ready", "\(meeting.displayTitle): click to open.", open: meeting.file)
        } catch {
            state = .failed("\(error.localizedDescription) Audio kept in \(session.dir.lastPathComponent).")
            Notifier.shared.post("Meeting notes failed", error.localizedDescription)
        }
    }

    /// Replaces the track label with your name, or with whoever the meeting app highlighted.
    /// Lines spoken while the meeting window was hidden (or with no highlight) have no sample and stay unrecognised.
    private func name(_ segment: Segment, using speakers: [SpeakerDetector.Sample]) -> Segment {
        var segment = segment
        segment.speaker = segment.speaker == Track.you
            ? Prefs.yourName
            : SpeakerDetector.dominantSpeaker(in: speakers, from: segment.start, to: segment.end) ?? SpeakerDetector.unknownSpeaker
        return segment
    }

    // MARK: Meeting auto-detection

    /// Starts when Zoom, Meet or Teams enters a call and stops once the call has ended for two polls.
    private func pollMeetings() async {
        guard Prefs.autoDetectZoom else { return }
        let recordingApp = isRecording ? meetingApp : nil
        let newCall = await Self.detected(nil) { recordingApp == nil ? MeetingDetector.newCall() : nil }
        let inCall = await Self.detected(nil) { recordingApp.map(MeetingDetector.isInCall) } ?? (newCall != nil)

        if !inCall { ignoreCurrentMeeting = false }
        if isRecording {
            guard autoStarted else { return }
            missedPolls = inCall ? 0 : missedPolls + 1
            if missedPolls >= 2 { await stop() }
        } else if let newCall, !ignoreCurrentMeeting {
            await start(auto: true, app: newCall)
        }
    }

    /// Returns `known` if set, else runs the (process-launching, CoreAudio) detection off the main thread.
    private static func detected<T>(_ known: T?, _ detect: @escaping @Sendable () -> T?) async -> T? {
        if let known { return known }
        return await Task.detached(operation: detect).value
    }

    // MARK: Menu & settings helpers

    func refreshRecent() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Self.notesRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        recent = dirs.compactMap(Self.meeting(at:)).sorted { $0.date > $1.date }.prefix(5).map { $0 }
    }

    /// Renames a saved meeting. An empty title goes back to the plain date name.
    func rename(_ meeting: Meeting, to title: String) {
        guard let renamed = try? move(meeting, to: title) else { return }
        if case .done(let current) = state, current.id == meeting.id { state = .done(renamed) }
        refreshRecent()
    }

    func moveToTrash(_ meeting: Meeting) {
        try? FileManager.default.trashItem(at: meeting.id, resultingItemURL: nil)
        if case .done(let current) = state, current.id == meeting.id { state = .idle }
        refreshRecent()
    }

    func copyNotes(_ meeting: Meeting) {
        guard let text = try? String(contentsOf: meeting.file, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func move(_ meeting: Meeting, to title: String) throws -> Meeting? {
        // Finder-safe: no slashes or colons, single line, sensible length.
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let name = Self.folderFormat.string(from: meeting.date)
            + (clean.isEmpty ? "" : Self.titleSeparator + String(clean.prefix(80)))
        let target = meeting.id.deletingLastPathComponent().appendingPathComponent(name)
        if target.path != meeting.id.path {
            try FileManager.default.moveItem(at: meeting.id, to: target)
        }
        return Self.meeting(at: target)
    }

    private static func meeting(at dir: URL) -> Meeting? {
        let name = dir.lastPathComponent
        guard let date = folderFormat.date(from: String(name.prefix(15))) else { return nil }
        let title = name.count > 15
            ? String(name.dropFirst(15)).replacingOccurrences(of: titleSeparator, with: "", options: .anchored)
            : nil
        let fm = FileManager.default
        let notes = dir.appendingPathComponent("notes.md")
        let transcript = dir.appendingPathComponent("transcript.md")
        guard let file = [notes, transcript].first(where: { fm.fileExists(atPath: $0.path) }) else { return nil }
        let summary = file == notes ? summaryBullets(of: notes) : []
        return Meeting(id: dir, date: date, title: title?.isEmpty == false ? title : nil,
                       file: file, hasNotes: file == notes, summary: summary)
    }

    /// The first bullets under "## Summary" in notes.md, for a preview in the menu.
    private static func summaryBullets(of notes: URL, limit: Int = 3) -> [String] {
        guard let text = try? String(contentsOf: notes, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Summary") }) else { return [] }
        return lines[(start + 1)...]
            .prefix { !$0.hasPrefix("## ") }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .prefix(limit)
            .map { String($0.dropFirst(2)) }
    }

    func refreshModels(for provider: Provider) async {
        modelsLoading = true
        defer { modelsLoading = false }
        do {
            models = try await LLM.models(for: provider)
            modelsError = nil
        } catch {
            models = []
            modelsError = error.localizedDescription
        }
    }
}
