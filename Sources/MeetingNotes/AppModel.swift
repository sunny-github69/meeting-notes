import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(Date)
        case processing(String)
        case done(URL)
        case failed(String)
    }

    struct Meeting: Identifiable {
        let id: URL
        let date: Date
        let file: URL
        let hasNotes: Bool
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var speakerStatus: SpeakerDetector.Status?
    @Published private(set) var recent: [Meeting] = []
    @Published private(set) var models: [String] = []
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelsError: String?

    private let recorder = Recorder()
    private var session: (dir: URL, recording: Recording?)?
    private var autoStarted = false
    private var ignoreCurrentMeeting = false
    private var missedPolls = 0

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
            Task { @MainActor in await self?.pollZoom() }
        }
    }

    static var notesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingNotes")
    }

    // MARK: Recording

    func start(auto: Bool = false) async {
        guard !isBusy else { return }
        let dir = Self.notesRoot.appendingPathComponent(Self.folderFormat.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await recorder.start(into: dir, detectSpeakers: Prefs.detectSpeakers) { [weak self] status in
                self?.speakerStatus = status
            }
            session = (dir, nil)
            autoStarted = auto
            missedPolls = 0
            state = .recording(Date())
            if auto { Notifier.shared.post("Recording Zoom meeting", "Notes will be written when the meeting ends.") }
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
        await process()
    }

    func retry() async { await process() }

    private func process() async {
        guard let session, let recording = session.recording else { return }
        do {
            state = .processing("Transcribing…")
            let segments = try await Transcriber.transcribe(tracks: recording.tracks, engine: Prefs.sttEngine)
                .map { name($0, using: recording.speakers) }
            guard !segments.isEmpty else { throw AppError("No speech was detected.") }
            let transcript = Transcriber.format(segments)
            var result = session.dir.appendingPathComponent("transcript.md")
            try transcript.write(to: result, atomically: true, encoding: .utf8)

            if Prefs.aiNotesEnabled {
                let provider = Prefs.provider
                let model = Prefs.model(for: provider)
                state = .processing("Writing notes with \(model)…")
                var seen = Set<String>()
                let speakers = segments.map(\.speaker).filter { seen.insert($0).inserted }
                let notes = try await LLM.complete(
                    provider: provider, model: model,
                    user: LLM.userMessage(transcript: transcript, recordedBy: Prefs.yourName, speakers: speakers))
                result = session.dir.appendingPathComponent("notes.md")
                try notes.write(to: result, atomically: true, encoding: .utf8)
            }

            // Raw audio is only kept when something failed, so it can be retried.
            recording.tracks.flatMap(\.chunks).forEach { try? FileManager.default.removeItem(at: $0.url) }
            self.session = nil
            state = .done(result)
            refreshRecent()
            Notifier.shared.post("Meeting notes ready", "Click to open \(result.lastPathComponent).", open: result)
        } catch {
            state = .failed("\(error.localizedDescription) Audio kept in \(session.dir.lastPathComponent).")
            Notifier.shared.post("Meeting notes failed", error.localizedDescription)
        }
    }

    /// Replaces the track label with your name, or with whoever Zoom showed as the active speaker.
    /// Lines spoken while Zoom was hidden (or with no highlight) have no sample and stay unrecognised.
    private func name(_ segment: Segment, using speakers: [SpeakerDetector.Sample]) -> Segment {
        var segment = segment
        segment.speaker = segment.speaker == Track.you
            ? Prefs.yourName
            : SpeakerDetector.dominantSpeaker(in: speakers, from: segment.start, to: segment.end) ?? SpeakerDetector.unknownSpeaker
        return segment
    }

    // MARK: Zoom auto-detection

    /// Zoom spawns a "CptHost" helper process for as long as a meeting is running.
    private func pollZoom() async {
        guard Prefs.autoDetectZoom else { return }
        let inMeeting = await Task.detached { () -> Bool in
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", "CptHost"]
            pgrep.standardOutput = FileHandle.nullDevice
            do {
                try pgrep.run()
                pgrep.waitUntilExit()
                return pgrep.terminationStatus == 0
            } catch { return false }
        }.value

        if !inMeeting { ignoreCurrentMeeting = false }
        if isRecording {
            guard autoStarted else { return }
            missedPolls = inMeeting ? 0 : missedPolls + 1
            if missedPolls >= 2 { await stop() }
        } else if inMeeting && !ignoreCurrentMeeting {
            await start(auto: true)
        }
    }

    // MARK: Menu & settings helpers

    func refreshRecent() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.notesRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        recent = dirs
            .compactMap { dir -> Meeting? in
                guard let date = Self.folderFormat.date(from: dir.lastPathComponent) else { return nil }
                let notes = dir.appendingPathComponent("notes.md")
                let transcript = dir.appendingPathComponent("transcript.md")
                let file = [notes, transcript].first { fm.fileExists(atPath: $0.path) } ?? dir
                return Meeting(id: dir, date: date, file: file, hasNotes: file == notes)
            }
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { $0 }
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
