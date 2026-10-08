import Foundation

struct Segment {
    let start: TimeInterval
    let end: TimeInterval
    var speaker: String
    let text: String
}

enum Transcriber {
    /// Biases Whisper towards British / Indian English vocabulary and spelling.
    private static let hint = "A work meeting in British and Indian English, with product, engineering and business terms."
    private typealias Raw = (start: Double, end: Double, text: String)

    static func transcribe(tracks: [Track], engine: STTEngine) async throws -> [Segment] {
        var segments: [Segment] = []
        for track in tracks {
            for chunk in track.chunks {
                let raw = engine == .local ? try await local(chunk.url) : try await openAI(chunk.url)
                segments += raw.map { Segment(start: chunk.offset + $0.start, end: chunk.offset + $0.end, speaker: track.speaker, text: $0.text) }
            }
        }
        return segments.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
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

    private static func openAI(_ wav: URL) async throws -> [Raw] {
        guard let key = Keychain.get(Provider.openai.rawValue) else {
            throw AppError("Add an OpenAI API key in Settings to use the Whisper API.")
        }
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (name, value) in [("model", "whisper-1"), ("response_format", "verbose_json"),
                              ("language", "en"), ("prompt", hint)] {
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
            return (start, end, text.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func local(_ wav: URL) async throws -> [Raw] {
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        guard let bin = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw AppError("whisper-cli not found. Run: brew install whisper-cpp")
        }
        guard FileManager.default.fileExists(atPath: Prefs.whisperModel) else {
            throw AppError("Whisper model not found at \(Prefs.whisperModel). See the README.")
        }
        let outBase = wav.deletingPathExtension().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["-m", Prefs.whisperModel, "-f", wav.path, "-l", "en", "--prompt", hint,
                             "-oj", "-of", outBase, "-np"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
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
            (Double($0.offsets.from) / 1000, Double($0.offsets.to) / 1000, $0.text.trimmingCharacters(in: .whitespaces))
        }
    }
}
