import Foundation
import SwiftUI
import RoachNetDesign

struct DeveloperTerminalPromptState: Equatable {
    let workingDirectory: String
    let exitCode: Int32
}

struct DeveloperTerminalTranscriptChunk {
    let visibleText: String
    let prompt: DeveloperTerminalPromptState?
}

struct DeveloperAssistFailurePresentation: Equatable {
    let status: String
    let surfacedError: String?
}

struct DeveloperInlinePromptDirective: Equatable {
    let instruction: String
    let rawLine: String
}

enum DeveloperWorkspacePathLabel {
    static func displayName(title: String, path: String) -> String {
        if title.caseInsensitiveCompare("Install") == .orderedSame {
            return "Contained app"
        }

        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
        return lastPathComponent.isEmpty ? path : lastPathComponent
    }
}

enum DeveloperTerminalTranscript {
    private static let escapePattern = NSRegularExpression.escapedPattern(for: "\u{001B}")
    private static let promptExpression = try! NSRegularExpression(
        pattern: "__RN_PROMPT__(.*?)__STATUS__(-?\\d+)__",
        options: []
    )
    private static let bootstrapNoiseFragments = [
        "prompt=",
        "rprompt=",
        "prompt_eol_mark=",
        "ps2=",
        "__rn_prompt__",
        "precmd()",
    ]
    private static let shellPromptLineExpression = try! NSRegularExpression(
        pattern: #"^[^@\s]+@[^ \s]+ .* %$"#,
        options: []
    )
    private static let ansiExpressions = [
        try! NSRegularExpression(pattern: "\(escapePattern)\\[[0-9;?]*[ -/]*[@-~]", options: []),
    ]

    static func consume(_ chunk: String) -> DeveloperTerminalTranscriptChunk {
        let normalized = normalizeLineEndings(in: stripANSISequences(from: chunk))
        let range = NSRange(normalized.startIndex..., in: normalized)

        let prompt = promptExpression.matches(in: normalized, options: [], range: range).last.flatMap { match -> DeveloperTerminalPromptState? in
            guard
                let directoryRange = Range(match.range(at: 1), in: normalized),
                let exitCodeRange = Range(match.range(at: 2), in: normalized)
            else {
                return nil
            }

            return DeveloperTerminalPromptState(
                workingDirectory: String(normalized[directoryRange]),
                exitCode: Int32(normalized[exitCodeRange]) ?? 0
            )
        }

        var visibleText = promptExpression.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "")
        if prompt != nil, visibleText.hasPrefix("\n") {
            visibleText.removeFirst()
        }

        return DeveloperTerminalTranscriptChunk(
            visibleText: stripUnsupportedControlCharacters(from: visibleText),
            prompt: prompt
        )
    }

    static func stripBootstrapNoise(from value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "%" else { return false }
                let lowered = trimmed.lowercased()
                if bootstrapNoiseFragments.contains(where: { lowered.contains($0) }) {
                    return false
                }

                let promptRange = NSRange(trimmed.startIndex..., in: trimmed)
                if shellPromptLineExpression.firstMatch(in: trimmed, options: [], range: promptRange) != nil {
                    return false
                }

                return true
            }
            .joined(separator: "\n")
    }

    private static func normalizeLineEndings(in value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func stripANSISequences(from value: String) -> String {
        ansiExpressions.reduce(value) { partial, expression in
            let range = NSRange(partial.startIndex..., in: partial)
            return expression.stringByReplacingMatches(in: partial, options: [], range: range, withTemplate: "")
        }
    }

    private static func stripUnsupportedControlCharacters(from value: String) -> String {
        String(
            String.UnicodeScalarView(
                value.unicodeScalars.filter { scalar in
                    scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
                }
            )
        )
    }
}

enum DeveloperInlineAssistSupport {
    private static let fencedCodeExpression = try! NSRegularExpression(
        pattern: "```[A-Za-z0-9_+.-]*\\n([\\s\\S]*?)```",
        options: []
    )
    private static let inlinePromptPrefixes = ["roachclaw:", "ai:", "rn:"]

    static func cleanedCompletion(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if
            let match = fencedCodeExpression.firstMatch(in: trimmed, options: [], range: range),
            let blockRange = Range(match.range(at: 1), in: trimmed)
        {
            return trimmed[blockRange].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    static func lineCommentPrefix(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "swift", "ts", "tsx", "js", "jsx", "go", "rs", "cs":
            return "// "
        case "py", "sh", "zsh", "rb", "yaml", "yml":
            return "# "
        case "html":
            return "<!-- "
        case "css":
            return "/* "
        default:
            return ""
        }
    }

    static func promptDirective(in text: String, fileExtension: String) -> DeveloperInlinePromptDirective? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.components(separatedBy: .newlines).reversed() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let stripped = stripCommentWrappers(from: trimmedLine, fileExtension: fileExtension)
            let lowered = stripped.lowercased()

            guard let prefix = inlinePromptPrefixes.first(where: { lowered.hasPrefix($0) }) else {
                continue
            }

            let instruction = stripped.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { continue }

            return DeveloperInlinePromptDirective(
                instruction: instruction,
                rawLine: trimmedLine
            )
        }

        return nil
    }

    static func integratingAcceptedCompletion(_ completion: String, into text: String, fileExtension: String) -> String {
        let cleaned = completion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        guard let directive = promptDirective(in: text, fileExtension: fileExtension) else {
            let separator = text.hasSuffix("\n") ? "" : "\n"
            return text + separator + cleaned
        }

        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        guard let targetIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == directive.rawLine }) else {
            let separator = text.hasSuffix("\n") ? "" : "\n"
            return text + separator + cleaned
        }

        let indentation = String(lines[targetIndex].prefix { $0 == " " || $0 == "\t" })
        let adjustedCompletionLines = cleaned.components(separatedBy: "\n").map { line -> String in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            return indentation + line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        lines.remove(at: targetIndex)
        lines.insert(contentsOf: adjustedCompletionLines, at: targetIndex)
        return lines.joined(separator: "\n")
    }

    static func failurePresentation(
        description: String,
        roachClawReady: Bool,
        hasCloudFallback: Bool,
        automatic: Bool
    ) -> DeveloperAssistFailurePresentation {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.contains("cancelled") || lowered.contains("canceled") {
            return DeveloperAssistFailurePresentation(
                status: automatic
                    ? "Inline assist standing by."
                    : "RoachClaw coding assist was reset before the reply landed.",
                surfacedError: nil
            )
        }

        if !roachClawReady && !hasCloudFallback {
            return DeveloperAssistFailurePresentation(
                status: automatic
                    ? "RoachClaw needs a live model before inline assist can stage the next lines."
                    : "RoachClaw needs a live model before it can answer coding requests.",
                surfacedError: nil
            )
        }

        if lowered.contains("status 500"), !roachClawReady {
            return DeveloperAssistFailurePresentation(
                status: automatic
                    ? "RoachClaw is still warming the coding lane."
                    : "RoachClaw is still warming the coding lane before it can answer.",
                surfacedError: nil
            )
        }

        if lowered.contains("timed out") {
            return DeveloperAssistFailurePresentation(
                status: automatic
                    ? "RoachClaw timed out while shaping the next lines."
                    : "RoachClaw timed out before the coding reply landed.",
                surfacedError: trimmed
            )
        }

        return DeveloperAssistFailurePresentation(
            status: automatic
                ? "Inline assist could not finish this pass."
                : "RoachClaw coding assist failed.",
            surfacedError: trimmed.isEmpty ? nil : trimmed
        )
    }

    private static func stripCommentWrappers(from line: String, fileExtension: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = lineCommentPrefix(for: fileExtension).trimmingCharacters(in: .whitespacesAndNewlines)

        if !prefix.isEmpty, value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasPrefix("<!--") {
            value.removeFirst(4)
            if value.hasSuffix("-->") {
                value.removeLast(3)
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasPrefix("/*") {
            value.removeFirst(2)
            if value.hasSuffix("*/") {
                value.removeLast(2)
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value
    }
}

enum DeveloperRailSection: String, CaseIterable, Identifiable {
    case assist = "Thread"
    case memory = "RoachBrain"
    case secrets = "Secrets"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .assist:
            return "Thread, context, and recent asks stay nearby."
        case .memory:
            return "Pinned recalls and local search stay close."
        case .secrets:
            return "Keychain-backed values stay off the file tree."
        }
    }

    var accent: Color {
        switch self {
        case .assist:
            return RoachPalette.magenta
        case .memory:
            return RoachPalette.cyan
        case .secrets:
            return RoachPalette.bronze
        }
    }
}
