import Foundation

enum RoachCopy {
    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func modelClass(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.last == "b" || trimmed.last == "B",
            Double(trimmed.dropLast()) != nil
        else { return trimmed }
        return String(trimmed.dropLast()) + "B"
    }

    static func modelClassLabel(_ raw: String) -> String {
        "\(modelClass(raw)) models"
    }

    static func status(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = knownIDs[key] { return known }
        let words = key.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
        guard !words.isEmpty else { return raw }
        return words.enumerated().map { index, word -> String in
            if let acronym = acronyms[word] { return acronym }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }
        .joined(separator: " ")
    }

    private static let knownIDs: [String: String] = [
        "armed": "On",
        "armed-local-only": "On, local only",
        "disarmed": "Off",
        "local-only": "Local only",
        "native-api": "Native API",
        "native-ready": "Ready",
        "ok": "OK",
    ]

    private static let acronyms: [String: String] = [
        "ai": "AI", "api": "API", "cli": "CLI", "cpu": "CPU", "gpu": "GPU", "gps": "GPS",
        "http": "HTTP", "id": "ID", "lan": "LAN", "llm": "LLM", "mcp": "MCP", "tls": "TLS",
        "tts": "TTS", "stt": "STT", "ui": "UI", "url": "URL",
    ]
}
