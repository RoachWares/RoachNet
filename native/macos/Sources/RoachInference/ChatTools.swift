import Foundation

public struct ToolSpec: Equatable {
    public var name: String
    public var description: String
    public var parameters: String

    public init(name: String, description: String = "", parameters: String = "{\"type\":\"object\",\"properties\":{}}")
    {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public var definition: String {
        let escapedName = ChatTools.quote(name)
        let escapedDescription = ChatTools.quote(description)
        return
            "{\"type\": \"function\", \"function\": {\"name\": \(escapedName), \"description\": \(escapedDescription), \"parameters\": \(parameters)}}"
    }
}

public struct ToolCall: Equatable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct RichMessage: Equatable {
    public var role: ChatMessage.Role
    public var content: String
    public var toolCalls: [ToolCall]
    public var toolName: String?

    public init(role: ChatMessage.Role, content: String, toolCalls: [ToolCall] = [], toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }
}

public enum ChatTools {
    public static func quote(_ text: String) -> String {
        let data =
            (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]))
            ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    public static func render(
        _ template: ChatTemplate, messages: [RichMessage], tools: [ToolSpec], defaultSystem: String?,
        think: Bool?, supportsThinking: Bool
    ) -> String {
        var plain: [ChatMessage] = []
        switch template {
        case .chatML:
            var system = messages.first?.role == .system ? messages[0].content : (defaultSystem ?? "")
            if !tools.isEmpty {
                system +=
                    (system.isEmpty ? "" : "\n\n")
                    + "# Tools\n\nYou may call one or more functions to assist with the user query.\n\n"
                    + "You are provided with function signatures within <tools></tools> XML tags:\n<tools>\n"
                    + tools.map(\.definition).joined(separator: "\n")
                    + "\n</tools>\n\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\n"
                    + "<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>"
            }
            if !system.isEmpty { plain.append(ChatMessage(role: .system, content: system)) }
            var pendingResults: [String] = []
            func flushResults() {
                guard !pendingResults.isEmpty else { return }
                plain.append(
                    ChatMessage(
                        role: .user,
                        content: pendingResults.map { "<tool_response>\n\($0)\n</tool_response>" }.joined(
                            separator: "\n")))
                pendingResults = []
            }
            for message in messages where message.role != .system {
                if message.role == .tool {
                    pendingResults.append(message.content)
                    continue
                }
                flushResults()
                var content = message.content
                for call in message.toolCalls {
                    content +=
                        (content.isEmpty ? "" : "\n")
                        + "<tool_call>\n{\"name\": \(quote(call.name)), \"arguments\": \(call.arguments)}\n</tool_call>"
                }
                plain.append(ChatMessage(role: message.role, content: content))
            }
            flushResults()
            var prompt = template.render(plain, defaultSystem: nil)
            if supportsThinking && think == false { prompt += "<think>\n\n</think>\n\n" }
            return prompt
        case .llama3:
            var firstUser = true
            for message in messages {
                switch message.role {
                case .user where firstUser && !tools.isEmpty:
                    firstUser = false
                    let content =
                        "Given the following functions, please respond with a JSON for a function call with its proper arguments that best answers the given prompt.\n\n"
                        + "Respond in the format {\"name\": function name, \"parameters\": dictionary of argument name and its value}. Do not use variables.\n\n"
                        + tools.map(\.definition).joined(separator: "\n\n") + "\n\n" + message.content
                    plain.append(ChatMessage(role: .user, content: content))
                case .assistant where !message.toolCalls.isEmpty:
                    let calls = message.toolCalls.map {
                        "{\"name\": \(quote($0.name)), \"parameters\": \($0.arguments)}"
                    }.joined(separator: "; ")
                    plain.append(ChatMessage(role: .assistant, content: calls))
                default:
                    plain.append(ChatMessage(role: message.role, content: message.content))
                }
            }
            return template.render(plain, defaultSystem: defaultSystem)
        case .mistral:
            let lastUser = messages.lastIndex { $0.role == .user }
            var out = ""
            var system = ""
            for (index, message) in messages.enumerated() {
                switch message.role {
                case .system: system = message.content + "\n\n"
                case .user:
                    if index == lastUser, !tools.isEmpty {
                        out +=
                            "[AVAILABLE_TOOLS] [" + tools.map(\.definition).joined(separator: ", ")
                            + "][/AVAILABLE_TOOLS]"
                    }
                    out += "[INST] \(system)\(message.content) [/INST]"
                    system = ""
                case .assistant:
                    if !message.toolCalls.isEmpty {
                        out +=
                            "[TOOL_CALLS] ["
                            + message.toolCalls.map {
                                "{\"name\": \(quote($0.name)), \"arguments\": \($0.arguments), \"id\": \(quote(String($0.id.suffix(9))))}"
                            }.joined(separator: ", ") + "]</s>"
                    } else {
                        out += "\(message.content)</s>"
                    }
                case .tool:
                    out += "[TOOL_RESULTS] {\"content\": \(quote(message.content))}[/TOOL_RESULTS]"
                }
            }
            return out
        case .gemma, .phi3, .plain:
            var system = messages.first?.role == .system ? messages[0].content : (defaultSystem ?? "")
            if !tools.isEmpty {
                system +=
                    (system.isEmpty ? "" : "\n\n") + "You can call these functions:\n"
                    + tools.map(\.definition).joined(separator: "\n")
                    + "\n\nTo call one, reply with only <tool_call>{\"name\": <function-name>, \"arguments\": <args-json-object>}</tool_call>."
            }
            if !system.isEmpty { plain.append(ChatMessage(role: .system, content: system)) }
            for message in messages where message.role != .system {
                var content = message.content
                if message.role == .tool { content = "Result of \(message.toolName ?? "the function"): \(content)" }
                for call in message.toolCalls {
                    content +=
                        "<tool_call>{\"name\": \(quote(call.name)), \"arguments\": \(call.arguments)}</tool_call>"
                }
                plain.append(ChatMessage(role: message.role == .tool ? .user : message.role, content: content))
            }
            return template.render(plain, defaultSystem: nil)
        }
    }

    public static func parse(_ text: String, known: [String]) -> (content: String, calls: [ToolCall]) {
        var content = text
        var calls: [ToolCall] = []
        func call(from object: Any) -> ToolCall? {
            guard let dict = object as? [String: Any], let name = dict["name"] as? String,
                known.isEmpty || known.contains(name)
            else { return nil }
            let arguments = dict["arguments"] ?? dict["parameters"] ?? [String: Any]()
            let argumentText: String
            if let string = arguments as? String {
                argumentText = string
            } else {
                argumentText =
                    (try? JSONSerialization.data(
                        withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            }
            return ToolCall(
                id: "call_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)).lowercased(),
                name: name, arguments: argumentText)
        }
        func json(_ text: String) -> Any? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        }

        while let open = content.range(of: "<tool_call>") {
            let after = content[open.upperBound...]
            let close = after.range(of: "</tool_call>")
            let body = String(close.map { after[..<$0.lowerBound] } ?? after).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let object = json(body), let parsed = call(from: object) else { break }
            calls.append(parsed)
            content.removeSubrange(open.lowerBound..<(close?.upperBound ?? content.endIndex))
        }
        if let marker = content.range(of: "[TOOL_CALLS]") {
            let body = content[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let array = json(body) as? [Any] {
                let parsed = array.compactMap(call(from:))
                if !parsed.isEmpty {
                    calls += parsed
                    content.removeSubrange(marker.lowerBound...)
                }
            }
        }
        if calls.isEmpty {
            var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<|python_tag|>") { trimmed = String(trimmed.dropFirst("<|python_tag|>".count)) }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let array = json(trimmed) as? [Any], !array.isEmpty {
                let parsed = array.compactMap(call(from:))
                if parsed.count == array.count,
                    (array.first as? [String: Any])?.keys.contains(where: { $0 == "parameters" || $0 == "arguments" })
                        == true
                {
                    return ("", parsed)
                }
            }
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
                let pieces = trimmed.components(separatedBy: "; ")
                let parsed = pieces.compactMap { json($0).flatMap(call(from:)) }
                if !parsed.isEmpty, parsed.count == pieces.count,
                    (json(pieces[0]) as? [String: Any])?.keys.contains(where: {
                        $0 == "parameters" || $0 == "arguments"
                    }) == true
                {
                    calls = parsed
                    content = ""
                }
            }
        }
        return (content.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }
}

public struct ThinkingSplitter {
    public enum Part: Equatable {
        case thinking(String)
        case content(String)
    }

    private var buffer = ""
    private var state: State
    private enum State { case undecided, thinking, content }

    public init(startsInside: Bool = false) {
        state = startsInside ? .thinking : .undecided
    }

    public mutating func feed(_ piece: String) -> [Part] {
        buffer += piece
        var parts: [Part] = []
        while true {
            switch state {
            case .undecided:
                let trimmed = buffer.drop { $0 == "\n" || $0 == " " }
                if trimmed.hasPrefix("<think>") {
                    buffer = String(trimmed.dropFirst("<think>".count))
                    state = .thinking
                    continue
                }
                if "<think>".hasPrefix(trimmed) { return parts }
                state = .content
                continue
            case .thinking:
                if let close = buffer.range(of: "</think>") {
                    let thought = String(buffer[..<close.lowerBound])
                    if !thought.isEmpty { parts.append(.thinking(thought)) }
                    buffer = String(buffer[close.upperBound...].drop { $0 == "\n" })
                    state = .content
                    continue
                }
                let keep = ThinkingSplitter.partialSuffix(buffer, of: "</think>")
                let ready = String(buffer.dropLast(keep))
                if !ready.isEmpty { parts.append(.thinking(ready)) }
                buffer = String(buffer.suffix(keep))
                return parts
            case .content:
                if !buffer.isEmpty { parts.append(.content(buffer)) }
                buffer = ""
                return parts
            }
        }
    }

    public mutating func finish() -> [Part] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        return state == .thinking ? [.thinking(buffer)] : [.content(buffer)]
    }

    public static func partialSuffix(_ text: String, of tag: String) -> Int {
        var length = min(text.count, tag.count - 1)
        while length > 0 {
            if tag.hasPrefix(String(text.suffix(length))) { return length }
            length -= 1
        }
        return 0
    }
}
