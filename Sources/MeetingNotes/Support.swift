import Foundation
import Security

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Provider: String, CaseIterable, Identifiable {
    case anthropic, openai, gemini, mistral, ollama
    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "ChatGPT (OpenAI)"
        case .gemini: return "Gemini (Google)"
        case .mistral: return "Mistral"
        case .ollama: return "Ollama (local, free)"
        }
    }

    /// Ollama runs on this Mac and needs no key.
    var needsKey: Bool { self != .ollama }

    var keyHint: String {
        switch self {
        case .anthropic: return "Paste key (sk-ant-…)"
        case .openai: return "Paste key (sk-…)"
        case .gemini: return "Paste key (AIza…)"
        case .mistral, .ollama: return "Paste key"
        }
    }

    var keyURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")!
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")!
        case .ollama: return URL(string: "https://ollama.com/library")!
        }
    }

    /// Base URL of the provider's OpenAI-compatible API; Anthropic and Ollama use their own APIs instead.
    var openAICompatibleBase: String? {
        switch self {
        case .anthropic, .ollama: return nil
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: return "https://api.mistral.ai/v1"
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case english, auto
    var id: String { rawValue }
    var title: String { self == .english ? "English (most accurate for any accent)" : "Auto-detect" }
    /// Whisper's language code; "auto" detects it from the first 30 seconds of each 10-minute chunk.
    var whisperCode: String { self == .english ? "en" : "auto" }
}

enum STTEngine: String, CaseIterable, Identifiable {
    case local, openai
    var id: String { rawValue }
    var title: String { self == .local ? "Local whisper.cpp (free, offline)" : "OpenAI Whisper API" }
}

/// A provider and one of its models.
struct NotesTarget: Equatable {
    let provider: Provider
    let model: String
}

/// Non-secret settings, shared with the views through matching @AppStorage keys.
enum Prefs {
    static let defaultName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
    static let defaultWhisperModel =
        NSHomeDirectory() + "/Library/Application Support/MeetingNotes/ggml-large-v3-turbo-q5_0.bin"

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: ["aiNotesEnabled": true, "detectSpeakers": true, "yourName": defaultName])
    }

    static var aiNotesEnabled: Bool { defaults.bool(forKey: "aiNotesEnabled") }
    static var detectSpeakers: Bool { defaults.bool(forKey: "detectSpeakers") }
    static var yourName: String {
        let name = defaults.string(forKey: "yourName")?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? defaultName : name
    }
    static var provider: Provider { Provider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .anthropic }
    static var sttEngine: STTEngine { STTEngine(rawValue: defaults.string(forKey: "sttEngine") ?? "") ?? .local }
    static var transcriptionLanguage: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: defaults.string(forKey: "transcriptionLanguage") ?? "") ?? .english
    }
    static var whisperModel: String { defaults.string(forKey: "whisperModelPath") ?? defaultWhisperModel }
    // Key name kept from the Zoom-only version so existing settings carry over.
    static var autoDetectZoom: Bool { defaults.bool(forKey: "autoDetectZoom") }
    static var notesTarget: NotesTarget { NotesTarget(provider: provider, model: model(for: provider)) }

    /// The model to try when the main one fails, if the user turned that on.
    static var fallbackTarget: NotesTarget? {
        guard defaults.bool(forKey: "fallbackEnabled"),
              let provider = Provider(rawValue: defaults.string(forKey: "fallbackProvider") ?? ""),
              let model = defaults.string(forKey: "fallbackModel"), !model.isEmpty else { return nil }
        return NotesTarget(provider: provider, model: model)
    }

    static func model(for provider: Provider) -> String { defaults.string(forKey: "model.\(provider.rawValue)") ?? "" }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MeetingNotes",
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

enum HTTP {
    /// An API call that failed. Temporary failures (rate limits, overloaded or restarting servers, a dropped
    /// connection) are retried; others (bad key, unknown or retired model) fail straight away.
    struct Failure: LocalizedError {
        let message: String
        let isTemporary: Bool
        var retryAfter: UInt64?  // seconds, from the server's Retry-After header
        var errorDescription: String? { message }
    }

    /// Seconds to wait before retries 1, 2 and 3.
    private static let backoff: [UInt64] = [2, 8, 30]
    private static let temporaryStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504, 529]
    private static let temporaryNetworkErrors: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet]

    static func json(_ request: URLRequest, body: Data? = nil) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                return try await send(request, body: body)
            } catch let failure as Failure where failure.isTemporary && attempt < backoff.count {
                let wait = min(failure.retryAfter ?? backoff[attempt], 60)
                attempt += 1
                try await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    private static func send(_ request: URLRequest, body: Data?) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            if let body {
                (data, response) = try await URLSession.shared.upload(for: request, from: body)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch let error as URLError where temporaryNetworkErrors.contains(error.code) {
            throw Failure(message: error.localizedDescription, isTemporary: true)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            // OpenAI-style APIs send {"error": {"message": …}}; Ollama sends {"error": "…"}.
            let detail = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? json["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? "unknown error"
            throw Failure(message: "API error: \(detail)",
                          isTemporary: temporaryStatuses.contains(http?.statusCode ?? 0),
                          retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(UInt64.init))
        }
        return json
    }
}
