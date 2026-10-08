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
        guard let key = Keychain.get(provider.rawValue) else {
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
        case .openai:
            var request = openAIRequest("chat/completions", key: key)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            let body: [String: Any] = ["model": model, "messages": [["role": "system", "content": systemPrompt],
                                                                    ["role": "user", "content": user]]]
            let json = try await HTTP.json(request, body: try JSONSerialization.data(withJSONObject: body))
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return message?["content"] as? String ?? ""
        }
    }

    /// Lists the models available to the key, newest first, so new releases appear without an app update.
    static func models(for provider: Provider) async throws -> [String] {
        guard let key = Keychain.get(provider.rawValue) else { return [] }
        switch provider {
        case .anthropic:
            let json = try await HTTP.json(anthropicRequest("models?limit=100", key: key))
            return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .openai:
            let json = try await HTTP.json(openAIRequest("models", key: key))
            let skip = ["audio", "realtime", "transcribe", "tts", "image", "search", "instruct", "embedding", "moderation"]
            return (json["data"] as? [[String: Any]] ?? [])
                .filter {
                    guard let id = $0["id"] as? String else { return false }
                    let isChat = id.hasPrefix("gpt") || id.range(of: "^o\\d", options: .regularExpression) != nil
                    return isChat && !skip.contains(where: id.contains)
                }
                .sorted { ($0["created"] as? Int ?? 0) > ($1["created"] as? Int ?? 0) }
                .compactMap { $0["id"] as? String }
        }
    }

    private static func anthropicRequest(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/\(path)")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private static func openAIRequest(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
