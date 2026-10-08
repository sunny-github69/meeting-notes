import Foundation
import Security

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Provider: String, CaseIterable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }
    var title: String { self == .anthropic ? "Claude (Anthropic)" : "ChatGPT (OpenAI)" }
}

enum STTEngine: String, CaseIterable, Identifiable {
    case local, openai
    var id: String { rawValue }
    var title: String { self == .local ? "Local whisper.cpp (free, offline)" : "OpenAI Whisper API" }
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
    static var whisperModel: String { defaults.string(forKey: "whisperModelPath") ?? defaultWhisperModel }
    static var autoDetectZoom: Bool { defaults.bool(forKey: "autoDetectZoom") }
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
    static func json(_ request: URLRequest, body: Data? = nil) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let detail = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? "unknown error"
            throw AppError("API error: \(detail)")
        }
        return json
    }
}
