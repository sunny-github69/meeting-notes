import Foundation

/// Turns a transcript into notes.md text.
///
/// - Normal meetings go to the model in one request.
/// - Long ones (or a reply cut off at the model's output limit) are done map-reduce style: notes for each
///   part of the transcript first, then one request that combines them into the final notes.
/// - If the main model still fails after its automatic retries, the fallback model (if set) does the job.
@MainActor
struct NotesWriter {
    /// Reports the model at work, a detail such as "part 2 of 4", and progress through the notes (0…1).
    typealias Progress = @MainActor (_ model: String, _ detail: String?, _ fraction: Double) -> Void

    let transcript: String
    let header: String  // LLM.header(…): app, speakers, names on screen
    let progress: Progress

    /// The notes, and the model that wrote them.
    func write(primary: NotesTarget, fallback: NotesTarget?) async throws -> (notes: String, by: NotesTarget) {
        do {
            return (try await write(with: primary, label: nil), primary)
        } catch {
            guard let fallback, fallback != primary else { throw error }
            do {
                return (try await write(with: fallback, label: "fallback"), fallback)
            } catch let fallbackError {
                throw AppError("\(primary.model): \(error.localizedDescription) "
                               + "Fallback \(fallback.model): \(fallbackError.localizedDescription)")
            }
        }
    }

    // MARK: Single pass or map-reduce

    /// Characters (~4 per token) sent in a single request. Local models lose detail on long input well
    /// before their context window is full, so they get a much lower limit and smaller parts.
    private static func singlePassLimit(_ provider: Provider) -> Int { provider == .ollama ? 40_000 : 160_000 }
    private static func partSize(_ provider: Provider) -> Int { provider == .ollama ? 24_000 : 80_000 }

    private func write(with target: NotesTarget, label: String?) async throws -> String {
        if transcript.count <= Self.singlePassLimit(target.provider) {
            let reply = try await ask(target, system: LLM.systemPrompt,
                                      user: "\(header)\n\nTranscript:\n\(transcript)",
                                      detail: label, range: 0..<1)
            if !reply.truncated { return reply.text }
            // The notes didn't fit in one reply: redo in parts, each with its own output budget.
        }
        return try await mapReduce(with: target, label: label)
    }

    private func mapReduce(with target: NotesTarget, label: String?) async throws -> String {
        let parts = Self.split(transcript, maxCharacters: Self.partSize(target.provider))
        let mapShare = 0.8  // of the progress bar; combining takes the rest
        var partNotes: [String] = []
        for (index, part) in parts.enumerated() {
            let range = mapShare * Double(index) / Double(parts.count)..<mapShare * Double(index + 1) / Double(parts.count)
            let reply = try await ask(
                target, system: LLM.partPrompt,
                user: "\(header)\n\nTranscript, part \(index + 1) of \(parts.count):\n\(part)",
                detail: detail(label, "part \(index + 1) of \(parts.count)"), range: range)
            partNotes.append(reply.text)
        }
        let combined = partNotes.enumerated().map { "### Part \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
        let reply = try await ask(
            target, system: LLM.systemPrompt,
            user: """
            \(header)

            The transcript was too long to read in one go, so it was summarised in \(parts.count) consecutive \
            parts. Combine these part notes into the final meeting notes.

            \(combined)
            """,
            detail: detail(label, "combining \(parts.count) parts"), range: mapShare..<1)
        return reply.text
    }

    private func detail(_ label: String?, _ step: String) -> String {
        label.map { "\($0) · \(step)" } ?? step
    }

    /// Splits at paragraph (speaker-turn) boundaries into parts of at most `maxCharacters`; a single turn
    /// longer than that, e.g. a long monologue, is cut at a space.
    static func split(_ text: String, maxCharacters: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentCount = 0
        func flush() {
            if !current.isEmpty { parts.append(current) }
            current = ""
            currentCount = 0
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            for piece in pieces(of: paragraph, maxCharacters: maxCharacters) {
                let count = piece.count
                if currentCount > 0, currentCount + 2 + count > maxCharacters { flush() }
                current += currentCount > 0 ? "\n\n" + piece : piece
                currentCount += (currentCount > 0 ? 2 : 0) + count
            }
        }
        flush()
        return parts
    }

    private static func pieces(of paragraph: String, maxCharacters: Int) -> [String] {
        guard paragraph.count > maxCharacters else { return [paragraph] }
        var pieces: [String] = []
        var rest = Substring(paragraph)
        while rest.count > maxCharacters {
            let limit = rest.index(rest.startIndex, offsetBy: maxCharacters)
            let cut = rest[..<limit].lastIndex(of: " ") ?? limit
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    // MARK: One request, with an eased progress bar

    /// The AI answers in one piece, so while waiting the bar eases towards the end of `range` at a pace set
    /// by the request size (local models are slower), then jumps to the end when the reply arrives.
    private func ask(_ target: NotesTarget, system: String, user: String, detail: String?,
                     range: Range<Double>) async throws -> LLM.Reply {
        progress(target.model, detail, range.lowerBound)
        let expected = target.provider == .ollama ? 40 + Double(user.count) / 400 : 10 + Double(user.count) / 4000
        let ticker = Task {
            let began = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { break }
                let eased = 1 - exp(-Date().timeIntervalSince(began) / expected)
                progress(target.model, detail, range.lowerBound + (range.upperBound - range.lowerBound) * 0.97 * eased)
            }
        }
        defer { ticker.cancel() }
        let reply = try await LLM.complete(provider: target.provider, model: target.model, system: system, user: user)
        progress(target.model, detail, range.upperBound)
        return reply
    }
}
