import Foundation

struct Segment {
    let start: TimeInterval
    let end: TimeInterval
    var speaker: String
    let text: String
}

enum Transcriber {
    /// Biases Whisper towards meeting vocabulary; accent-neutral so it suits any speaker. Only used for
    /// English: in auto-detect mode an English prompt would nudge Whisper into English.
    private static let hint = "A work meeting in English with speakers of different accents, discussing product, engineering and business topics."
    private struct Raw: Codable {
        let start: Double
        let end: Double
        let text: String
    }

    /// Reports (part, of parts, overall fraction 0…1). Parts are weighted by their audio length.
    typealias Progress = @Sendable (_ part: Int, _ parts: Int, _ fraction: Double) -> Void

    static func transcribe(tracks: [Track], engine: STTEngine, language: TranscriptionLanguage,
                           progress: @escaping Progress) async throws -> [Segment] {
        let parts = tracks.flatMap { track in track.chunks.map { (speaker: track.speaker, chunk: $0) } }
        let weights = parts.map { part in
            Double((try? part.chunk.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + 1
        }
        let total = weights.reduce(0, +)
        let count = parts.count
        var done = 0.0
        var segments: [Segment] = []
        for (index, part) in parts.enumerated() {
            let base = done
            let weight = weights[index]
            let report: @Sendable (Double) -> Void = { progress(index + 1, count, (base + weight * $0) / total) }
            report(0)
            let raw = try await cached(part.chunk.url) {
                engine == .local ? try await local(part.chunk.url, language: language, progress: report)
                                 : try await openAI(part.chunk.url, language: language)
            }
            done += weight
            report(1)
            segments += raw.map {
                Segment(start: part.chunk.offset + $0.start, end: part.chunk.offset + $0.end,
                        speaker: part.speaker, text: $0.text)
            }
        }
        return segments.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
    }

    /// Each part's result is saved next to its WAV, so a retry after a failure resumes where it stopped
    /// instead of transcribing the whole meeting again.
    private static func cached(_ wav: URL, _ transcribe: () async throws -> [Raw]) async throws -> [Raw] {
        let cache = wav.deletingPathExtension().appendingPathExtension("segments.json")
        if let data = try? Data(contentsOf: cache), let raw = try? JSONDecoder().decode([Raw].self, from: data) {
            return raw
        }
        let raw = try await transcribe()
        try? JSONEncoder().encode(raw).write(to: cache)
        return raw
    }

    /// Speaker names in order of first appearance, read back from a formatted transcript.
    static func speakers(in transcript: String) -> [String] {
        var seen = Set<String>()
        return transcript.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let rest = line[line.index(after: close)...]
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// "[mm:ss] Speaker: text", merging consecutive lines from the same speaker.
    static func format(_ segments: [Segment]) -> String {
        var lines: [(start: TimeInterval, speaker: String, text: String)] = []
        for s in segments {
            if let last = lines.last, last.speaker == s.speaker {
                lines[lines.count - 1].text += " " + s.text
            } else {
                lines.append((s.start, s.speaker, s.text))
            }
        }
        return lines.map {
            let t = Int($0.start)
            return String(format: "[%02d:%02d] %@: %@", t / 60, t % 60, $0.speaker, $0.text)
        }.joined(separator: "\n\n")
    }

    private static func openAI(_ wav: URL, language: TranscriptionLanguage) async throws -> [Raw] {
        guard let key = Keychain.get(Provider.openai.rawValue) else {
            throw AppError("Add an OpenAI API key in Settings to use the Whisper API.")
        }
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        // Leaving out "language" makes the API detect it.
        let fields: [(String, String)] = [("model", "whisper-1"), ("response_format", "verbose_json")]
            + (language == .english ? [("language", "en"), ("prompt", hint)] : [])
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: wav))
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let json = try await HTTP.json(request, body: body)
        let segments = json["segments"] as? [[String: Any]] ?? []
        return segments.compactMap { seg in
            // Whisper invents text on silence; drop segments it itself flags as non-speech.
            guard (seg["no_speech_prob"] as? Double ?? 0) < 0.6,
                  let start = seg["start"] as? Double, let end = seg["end"] as? Double,
                  let text = seg["text"] as? String else { return nil }
            return Raw(start: start, end: end, text: text.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func local(_ wav: URL, language: TranscriptionLanguage,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> [Raw] {
        // Apps launched from Finder don't get the shell's PATH, so look in Homebrew's prefixes directly.
        // Older whisper-cpp formulae named the binary "whisper-cpp" instead of "whisper-cli".
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin"].flatMap { ["\($0)/whisper-cli", "\($0)/whisper-cpp"] }
        guard let bin = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw AppError("whisper.cpp not found in /opt/homebrew/bin or /usr/local/bin. Run: brew install whisper-cpp")
        }
        guard FileManager.default.fileExists(atPath: Prefs.whisperModel) else {
            throw AppError("Whisper model not found at \(Prefs.whisperModel). See the README.")
        }
        let outBase = wav.deletingPathExtension().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["-m", Prefs.whisperModel, "-f", wav.path, "-l", language.whisperCode,
                             "-oj", "-of", outBase, "-np", "-pp"]
            + (language == .english ? ["--prompt", hint] : [])
        process.standardOutput = FileHandle.nullDevice
        // With -pp whisper-cli prints "progress = 45%" lines to stderr; read them live for the progress bar.
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let percents = text.components(separatedBy: "progress =").dropFirst()
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber)) }
            if let percent = percents.last { progress(Double(min(percent, 100)) / 100) }
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                errors.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    done.resume()
                } else {
                    done.resume(throwing: AppError("whisper-cli failed (exit \(p.terminationStatus))."))
                }
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }

        struct Output: Decodable {
            struct Seg: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Seg]
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: outBase + ".json"))
        return try JSONDecoder().decode(Output.self, from: data).transcription.map {
            Raw(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000,
                text: $0.text.trimmingCharacters(in: .whitespaces))
        }
    }
}
