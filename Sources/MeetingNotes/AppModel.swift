import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    /// A saved meeting: a folder named "yyyy-MM-dd HHmm" or "yyyy-MM-dd HHmm · Title".
    struct Meeting: Identifiable, Equatable {
        let id: URL  // the folder
        let date: Date
        let title: String?
        let file: URL  // notes.md, else transcript.md
        let hasNotes: Bool
        let summary: [String]  // first bullets of the Summary section
        let notesModel: String?  // which AI model wrote notes.md
        let app: MeetingApp?

        var displayTitle: String { title ?? date.formatted(date: .abbreviated, time: .shortened) }
    }

    /// A meeting waiting for, or going through, transcription and notes.
    struct Job: Identifiable, Equatable {
        enum Phase: Equatable {
            case queued
            case transcribing(part: Int, of: Int)
            case writingNotes(model: String)
            case failed(String)
        }

        let id: URL  // the meeting folder
        let date: Date
        var regenerate = false  // only rewrite notes.md of an existing meeting
        var phase: Phase = .queued
        var progress = 0.0  // 0…1

        var isActive: Bool {
            switch phase {
            case .transcribing, .writingNotes: return true
            case .queued, .failed: return false
            }
        }
    }

    @Published private(set) var recordingSince: Date?
    @Published private(set) var startError: String?
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var lastMeeting: Meeting?  // shown in the "Notes ready" card
    @Published private(set) var speakerStatus: SpeakerDetector.Status?
    @Published private(set) var meetingApp: MeetingApp?
    @Published private(set) var recent: [Meeting] = []
    @Published private(set) var models: [String] = []
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelsError: String?

    private let recorder = Recorder()
    private var recordingDir: URL?
    private var worker: Task<Void, Never>?
    private var autoStarted = false
    private var ignoreCurrentMeeting = false
    private var missedPolls = 0

    private static let titleSeparator = " · "
    private static let folderFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    var isRecording: Bool { recordingSince != nil }
    func isProcessing(_ meeting: Meeting) -> Bool { jobs.contains { $0.id == meeting.id } }

    init() {
        Prefs.registerDefaults()
        Notifier.shared.setUp()
        refreshRecent()
        resumePendingJobs()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollMeetings() }
        }
    }

    static var notesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingNotes")
    }

    // MARK: Recording

    /// Starts recording. `app` is the meeting app auto-record detected; a manual start works it out here.
    /// Earlier meetings may still be processing in the background; that doesn't block a new recording.
    func start(auto: Bool = false, app: MeetingApp? = nil) async {
        guard recordingDir == nil else { return }
        let dir = Self.notesRoot.appendingPathComponent(Self.folderFormat.string(from: Date()))
        do {
            let app = await Self.detected(app) { MeetingDetector.currentApp() }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await recorder.start(into: dir, app: app, detectSpeakers: Prefs.detectSpeakers) { [weak self] status in
                self?.speakerStatus = status
            }
            recordingDir = dir
            recordingSince = Date()
            startError = nil
            meetingApp = app
            autoStarted = auto
            missedPolls = 0
            if auto {
                Notifier.shared.post("Recording \(app?.title ?? "meeting")", "Notes will be written when the meeting ends.")
            }
        } catch {
            ignoreCurrentMeeting = true
            startError = error.localizedDescription
        }
    }

    /// Stops recording and hands the meeting to the processing queue.
    func stop() async {
        guard let dir = recordingDir else { return }
        ignoreCurrentMeeting = true
        let recording = await recorder.stop()
        recordingDir = nil
        recordingSince = nil
        speakerStatus = nil
        meetingApp = nil
        do {
            try recording.save(in: dir)
            enqueue(dir)
        } catch {
            Notifier.shared.post("Couldn't save the recording", error.localizedDescription)
        }
    }

    // MARK: Processing queue

    /// Writes notes.md again from the saved transcript with the currently selected model, e.g. when a small
    /// local model gave a weak result. A name the user chose is kept; on failure the old notes stay.
    func regenerateNotes(_ meeting: Meeting) {
        enqueue(meeting.id, regenerate: true)
    }

    func retry(_ job: Job) {
        update(job.id) { $0.phase = .queued; $0.progress = 0 }
        runQueue()
    }

    /// Removes a failed job. A new recording is moved to the Trash with its audio; a failed regeneration
    /// just goes away and the meeting keeps its previous notes.
    func discard(_ job: Job) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
        if !job.regenerate { try? FileManager.default.trashItem(at: job.id, resultingItemURL: nil) }
        refreshRecent()
    }

    private func enqueue(_ dir: URL, regenerate: Bool = false) {
        guard !jobs.contains(where: { $0.id == dir }),
              let date = Self.folderFormat.date(from: String(dir.lastPathComponent.prefix(15))) else { return }
        jobs.append(Job(id: dir, date: date, regenerate: regenerate))
        runQueue()
    }

    /// Meetings recorded before the app quit (or crashed) are picked up again on launch.
    private func resumePendingJobs() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Self.notesRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        dirs.filter(Recording.isPending(in:)).sorted { $0.lastPathComponent < $1.lastPathComponent }.forEach { enqueue($0) }
    }

    /// Processes queued meetings one at a time: transcription keeps the CPU/GPU busy, so running two at
    /// once would only slow both down. Recording is light and carries on alongside.
    private func runQueue() {
        guard worker == nil else { return }
        worker = Task { [self] in
            while let job = jobs.first(where: { $0.phase == .queued }) {
                await process(job)
            }
            worker = nil
        }
    }

    private func process(_ job: Job) async {
        update(job.id) { $0.phase = .transcribing(part: 0, of: 0); $0.progress = 0 }
        do {
            let meeting = try await run(job)
            jobs.removeAll { $0.id == job.id }
            lastMeeting = meeting
            refreshRecent()
            Notifier.shared.post("Meeting notes ready", "\(meeting.displayTitle): click to open.", open: meeting.file)
        } catch {
            update(job.id) { $0.phase = .failed(error.localizedDescription) }
            Notifier.shared.post("Meeting notes failed", error.localizedDescription)
        }
    }

    /// Transcribes (unless a finished transcript is already saved), writes notes, cleans up the audio and
    /// applies the AI's title. Every step leaves its result on disk, so a retry resumes where it failed.
    private func run(_ job: Job) async throws -> Meeting {
        let dir = job.id
        let transcriptFile = dir.appendingPathComponent("transcript.md")
        let writesNotes = job.regenerate || Prefs.aiNotesEnabled
        let transcriptShare = job.regenerate ? 0 : writesNotes ? 0.8 : 1.0  // of the progress bar

        let transcript: String
        if let saved = try? String(contentsOf: transcriptFile, encoding: .utf8) {
            transcript = saved
        } else {
            guard let recording = Recording.load(from: dir) else {
                throw AppError("The recording for this meeting is missing.")
            }
            let segments = try await Transcriber.transcribe(
                tracks: recording.tracks, engine: Prefs.sttEngine, language: Prefs.transcriptionLanguage
            ) { [weak self] part, parts, fraction in
                Task { @MainActor in
                    self?.update(dir) { $0.phase = .transcribing(part: part, of: parts); $0.progress = fraction * transcriptShare }
                }
            }
            .map { name($0, using: recording.speakers) }
            guard !segments.isEmpty else { throw AppError("No speech was detected.") }
            transcript = Transcriber.format(segments)
            try transcript.write(to: transcriptFile, atomically: true, encoding: .utf8)
            let context = NotesContext(app: recording.app?.rawValue, participants: recording.participants)
            try? JSONEncoder().encode(context).write(to: dir.appendingPathComponent(NotesContext.fileName))
        }

        var title: String?
        if writesNotes {
            let notes = try await writeNotes(transcript: transcript, in: dir, progressFrom: transcriptShare)
            title = LLM.title(fromNotes: notes)
        }
        Recording.discardAudio(in: dir)

        // Saved under the date already; the AI's title is applied unless the meeting has a name.
        guard let saved = Self.meeting(at: dir) else { throw AppError("Couldn't read the saved meeting.") }
        if saved.title == nil, let title, let renamed = try? move(saved, to: title) { return renamed }
        return saved
    }

    /// Asks the selected AI for notes and saves them as notes.md, tagged with the model that wrote them.
    private func writeNotes(transcript: String, in dir: URL, progressFrom start: Double) async throws -> String {
        let provider = Prefs.provider
        let model = Prefs.model(for: provider)
        update(dir) { $0.phase = .writingNotes(model: model); $0.progress = start }

        // The AI answers in one piece, so the bar eases towards 97% at a pace set by the transcript's
        // length (local models are slower), then jumps to done.
        let expected = provider == .ollama ? 40 + Double(transcript.count) / 400 : 10 + Double(transcript.count) / 4000
        let ticker = Task { [weak self] in
            let began = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let eased = 1 - exp(-Date().timeIntervalSince(began) / expected)
                self?.update(dir) { $0.progress = start + (0.97 - start) * eased }
            }
        }
        defer { ticker.cancel() }

        let context = (try? Data(contentsOf: dir.appendingPathComponent(NotesContext.fileName)))
            .flatMap { try? JSONDecoder().decode(NotesContext.self, from: $0) } ?? NotesContext(app: nil, participants: [])
        let notes = try await LLM.complete(
            provider: provider, model: model,
            user: LLM.userMessage(transcript: transcript, app: context.app.flatMap(MeetingApp.init(rawValue:)),
                                  recordedBy: Prefs.yourName, speakers: Transcriber.speakers(in: transcript),
                                  namesOnScreen: context.participants))
        let tagged = notes + "\n\n<!-- notes-model: \(model) (\(provider.title)) -->\n"
        try tagged.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return notes
    }

    /// Changes a job in place; progress updates smaller than 0.5% are skipped to avoid needless redraws.
    private func update(_ id: URL, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        change(&job)
        guard job != jobs[index] else { return }
        if job.phase == jobs[index].phase, abs(job.progress - jobs[index].progress) < 0.005, job.progress < 1 { return }
        jobs[index] = job
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

    func dismissLastMeeting() { lastMeeting = nil }

    func refreshRecent() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Self.notesRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        recent = dirs.compactMap(Self.meeting(at:)).sorted { $0.date > $1.date }.prefix(5).map { $0 }
    }

    /// Renames a saved meeting. An empty title goes back to the plain date name.
    func rename(_ meeting: Meeting, to title: String) {
        guard !isProcessing(meeting), let renamed = try? move(meeting, to: title) else { return }
        if lastMeeting?.id == meeting.id { lastMeeting = renamed }
        refreshRecent()
    }

    func moveToTrash(_ meeting: Meeting) {
        guard !isProcessing(meeting) else { return }
        try? FileManager.default.trashItem(at: meeting.id, resultingItemURL: nil)
        if lastMeeting?.id == meeting.id { lastMeeting = nil }
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
        let text = file == notes ? (try? String(contentsOf: notes, encoding: .utf8)) ?? "" : ""
        let context = (try? Data(contentsOf: dir.appendingPathComponent(NotesContext.fileName)))
            .flatMap { try? JSONDecoder().decode(NotesContext.self, from: $0) }
        return Meeting(id: dir, date: date, title: title?.isEmpty == false ? title : nil,
                       file: file, hasNotes: file == notes, summary: summaryBullets(in: text),
                       notesModel: notesModel(in: text), app: context?.app.flatMap(MeetingApp.init(rawValue:)))
    }

    /// The first bullets under "## Summary" in notes.md, for a preview in the menu.
    private static func summaryBullets(in notes: String, limit: Int = 3) -> [String] {
        let lines = notes.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Summary") }) else { return [] }
        return lines[(start + 1)...]
            .prefix { !$0.hasPrefix("## ") }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .prefix(limit)
            .map { String($0.dropFirst(2)) }
    }

    /// The model named in the hidden "<!-- notes-model: … -->" tag at the end of notes.md.
    private static func notesModel(in notes: String) -> String? {
        guard let tag = notes.range(of: "<!-- notes-model: ") else { return nil }
        let rest = notes[tag.upperBound...]
        return rest.range(of: " -->").map { String(rest[..<$0.lowerBound]) }
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

/// What the notes AI needs besides the transcript, saved next to it so notes can be regenerated later.
struct NotesContext: Codable {
    static let fileName = "meeting.json"
    let app: String?  // MeetingApp raw value
    let participants: [String]  // names seen on screen
}
