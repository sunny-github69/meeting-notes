import Foundation

enum LLM {
    static let systemPrompt = """
    You turn the automatic transcript of a Zoom meeting into meeting notes.

    The transcript comes from speech recognition of British and Indian English speakers, so it contains \
    mishearings, missing punctuation and mangled names or technical terms. Fix them using context, but never \
    invent facts. Speaker names come from Zoom's active-speaker indicator: usually right, occasionally off by \
    a line. "Not recognised" means the speaker could not be identified; do not guess who it was. Use names for \
    decisions and action-item owners when they are clear.

    Reply in Markdown with exactly these sections:
    ## Summary
    5-8 bullets, readable in 30 seconds.
    ## Decisions
    Bullets, or "None".
    ## Action items
    A checklist: "- [ ] task (owner, due date if mentioned)", or "None".
    ## Open questions
    Bullets, or "None".
    ## Detailed notes
    Long-form notes grouped by topic with ### sub-headings, in the order discussed. Keep the numbers, names, \
    reasons and trade-offs that were mentioned.
    """

    static func userMessage(transcript: String, recordedBy: String, speakers: [String]) -> String {
        """
        Recorded by: \(recordedBy)
        Speakers: \(speakers.joined(separator: ", "))

        Transcript:
        \(transcript)
        """
    }

    static func complete(provider: Provider, model: String, user: String) async throws -> String {
        let key = Keychain.get(provider.rawValue) ?? ""
        guard !provider.needsKey || !key.isEmpty else {
            throw AppError("Add your \(provider.title) API key in Settings.")
        }
        guard !model.isEmpty else { throw AppError("Pick a model in Settings.") }

        switch provider {
        case .anthropic:
            var request = anthropicRequest("messages", key: key)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            let body: [String: Any] = ["model": model, "max_tokens": 8192, "system": systemPrompt,
                                       "messages": [["role": "user", "content": user]]]
            let json = try await HTTP.json(request, body: try JSONSerialization.data(withJSONObject: body))
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        case .ollama:
            return try await ollamaComplete(model: model, user: user)
        case .openai, .gemini, .mistral:
            var request = openAIRequest(provider.openAICompatibleBase!, "chat/completions", key: key)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            let body: [String: Any] = ["model": model, "messages": [["role": "system", "content": systemPrompt],
                                                                    ["role": "user", "content": user]]]
            let json = try await HTTP.json(request, body: try JSONSerialization.data(withJSONObject: body))
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return message?["content"] as? String ?? ""
        }
    }

    /// Lists the chat models available to the key, newest first, so new releases appear without an app update.
    static func models(for provider: Provider) async throws -> [String] {
        let key = Keychain.get(provider.rawValue) ?? ""
        guard !provider.needsKey || !key.isEmpty else { return [] }

        switch provider {
        case .anthropic:
            let json = try await HTTP.json(anthropicRequest("models?limit=100", key: key))
            return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .ollama:
            let json = try await reachOllama { try await HTTP.json(URLRequest(url: URL(string: "\(ollamaBase)/tags")!)) }
            return (json["models"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .filter { !$0.contains("embed") }
        case .openai, .gemini, .mistral:
            let json = try await HTTP.json(openAIRequest(provider.openAICompatibleBase!, "models", key: key))
            return (json["data"] as? [[String: Any]] ?? [])
                .compactMap { item -> (id: String, created: Int)? in
                    // Gemini prefixes ids with "models/", but chat requests take the bare name.
                    guard let raw = item["id"] as? String else { return nil }
                    let id = raw.replacingOccurrences(of: "models/", with: "")
                    return isChatModel(id, item, provider) ? (id, item["created"] as? Int ?? 0) : nil
                }
                .sorted { ($0.created, $0.id) > ($1.created, $1.id) }
                .map(\.id)
        }
    }

    // MARK: Ollama (local)

    private static let ollamaBase = "http://localhost:11434/api"

    /// Uses Ollama's own chat API rather than its OpenAI-compatible one, because only this API lets us
    /// raise the context window: Ollama's default is a few thousand tokens and it silently drops the
    /// start of anything longer, which would cut most of a long meeting.
    private static func ollamaComplete(model: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(ollamaBase)/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1800  // local models take longer on an hour-long transcript
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let estimatedTokens = (systemPrompt.count + user.count) / 3 + 4096  // ~3 chars per token, plus the reply
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["num_ctx": min(max(8192, estimatedTokens), 131_072)],
            "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": user]],
        ]
        let json = try await reachOllama {
            try await HTTP.json(request, body: try JSONSerialization.data(withJSONObject: body))
        }
        let content = (json["message"] as? [String: Any])?["content"] as? String ?? ""
        // Reasoning models (e.g. DeepSeek-R1, Qwen3) may include their thinking inline.
        return content.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reachOllama<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw AppError("Can't reach Ollama on localhost:11434. Open the Ollama app and try again.")
        }
    }

    private static func isChatModel(_ id: String, _ item: [String: Any], _ provider: Provider) -> Bool {
        let skip = ["audio", "realtime", "transcribe", "tts", "image", "search", "instruct", "embed",
                    "moderation", "ocr", "live"]
        guard !skip.contains(where: id.contains) else { return false }
        switch provider {
        case .openai: return id.hasPrefix("gpt") || id.range(of: "^o\\d", options: .regularExpression) != nil
        case .gemini: return id.contains("gemini")
        case .mistral: return (item["capabilities"] as? [String: Any])?["completion_chat"] as? Bool ?? true
        case .anthropic, .ollama: return true
        }
    }

    private static func anthropicRequest(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/\(path)")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private static func openAIRequest(_ base: String, _ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
