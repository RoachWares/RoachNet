import Foundation

public struct ChatMessage: Equatable {
    public enum Role: String { case system, user, assistant, tool }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum ChatTemplate: String, CaseIterable {
    case chatML = "chatml"
    case llama3
    case mistral
    case gemma
    case phi3
    case plain

    public static func detect(templateSource: String?, tokenizer: Tokenizer) -> ChatTemplate {
        let source = templateSource ?? ""
        if source.contains("<|im_start|>") { return .chatML }
        if source.contains("<|start_header_id|>") { return .llama3 }
        if source.contains("<start_of_turn>") { return .gemma }
        if source.contains("<|user|>") && source.contains("<|end|>") { return .phi3 }
        if source.contains("[INST]") { return .mistral }
        if tokenizer.id(of: "<|im_start|>") != nil { return .chatML }
        if tokenizer.id(of: "<|start_header_id|>") != nil { return .llama3 }
        return .plain
    }

    public static func defaultSystemPrompt(in templateSource: String?) -> String? {
        guard let source = templateSource else { return nil }
        let pattern = "<\\|im_start\\|>system\\\\n(.+?)<\\|im_end\\|>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            let range = Range(match.range(at: 1), in: source)
        else { return nil }
        let text = String(source[range])
        guard !text.contains("{{"), !text.contains("{%"), !text.contains("' +"), !text.contains("+ '") else {
            return nil
        }
        return text.replacingOccurrences(of: "\\n", with: "\n")
    }

    public func render(_ messages: [ChatMessage], defaultSystem: String? = nil, addGenerationPrompt: Bool = true)
        -> String
    {
        var messages = messages
        if let defaultSystem, messages.first?.role != .system {
            messages.insert(ChatMessage(role: .system, content: defaultSystem), at: 0)
        }
        var out = ""
        switch self {
        case .chatML:
            for message in messages {
                out += "<|im_start|>\(message.role.rawValue)\n\(message.content)<|im_end|>\n"
            }
            if addGenerationPrompt { out += "<|im_start|>assistant\n" }
        case .llama3:
            for message in messages {
                let role = message.role == .tool ? "ipython" : message.role.rawValue
                out +=
                    "<|start_header_id|>\(role)<|end_header_id|>\n\n\(message.content.trimmingCharacters(in: .whitespacesAndNewlines))<|eot_id|>"
            }
            if addGenerationPrompt { out += "<|start_header_id|>assistant<|end_header_id|>\n\n" }
        case .mistral:
            var system = ""
            for message in messages {
                switch message.role {
                case .system: system = message.content + "\n\n"
                case .user, .tool:
                    out += "[INST] \(system)\(message.content) [/INST]"
                    system = ""
                case .assistant:
                    out += "\(message.content)</s>"
                }
            }
        case .gemma:
            var system = ""
            for message in messages {
                switch message.role {
                case .system: system = message.content + "\n\n"
                case .user, .tool:
                    out += "<start_of_turn>user\n\(system)\(message.content)<end_of_turn>\n"
                    system = ""
                case .assistant:
                    out += "<start_of_turn>model\n\(message.content)<end_of_turn>\n"
                }
            }
            if addGenerationPrompt { out += "<start_of_turn>model\n" }
        case .phi3:
            for message in messages {
                out += "<|\(message.role == .tool ? "user" : message.role.rawValue)|>\n\(message.content)<|end|>\n"
            }
            if addGenerationPrompt { out += "<|assistant|>\n" }
        case .plain:
            for message in messages {
                switch message.role {
                case .system: out += "\(message.content)\n\n"
                case .user, .tool: out += "User: \(message.content)\n"
                case .assistant: out += "Assistant: \(message.content)\n"
                }
            }
            if addGenerationPrompt { out += "Assistant:" }
        }
        return out
    }
}
