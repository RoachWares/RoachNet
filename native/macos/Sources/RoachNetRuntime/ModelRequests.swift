import Foundation
import RoachInference

/// One generation request, whichever API it came in on (Ollama chat and
/// generate, OpenAI chat completions, completions and responses, Anthropic
/// messages). Each API's parser fills it; each API's renderer answers it.
struct ModelRequest {
    enum Format: Equatable { case text, json, schema(JSONSchemaNode) }
    enum ToolChoice: Equatable { case auto, none, required, named(String) }

    var model: String
    var messages: [RichMessage] = []
    /// A prompt sent as-is, with no chat template (`raw`, `/v1/completions`).
    var rawPrompt: String?
    var tools: [ToolSpec] = []
    var toolChoice: ToolChoice = .auto
    var format: Format = .text
    /// The schema as the client sent it (plan models are asked to follow it in words).
    var formatSource: JSON = .undefined
    /// nil: the model's default.
    var think: Bool?
    /// Ollama-style options (`temperature`, `num_predict`, `stop`, `num_ctx`, …).
    var options = JSONObject()
    var keepAlive: JSON = .undefined
    var stream = false
    /// OpenAI `stream_options.include_usage`: a last chunk with token counts.
    var includeUsage = false

    var effectiveTools: [ToolSpec] { toolChoice == .none ? [] : tools }

    // MARK: Ollama

    static func ollamaChat(_ body: JSON) throws -> ModelRequest {
        var request = ModelRequest(model: body["model"].stringValue ?? "")
        request.messages = body["messages"].array.map(ollamaMessage)
        request.tools = tools(body["tools"])
        request.format = try format(ollama: body["format"])
        request.formatSource = body["format"]
        request.think = body["think"].boolValue
        request.options = body["options"].object
        request.keepAlive = body["keep_alive"]
        request.stream = body["stream"].isUndefined ? true : body["stream"].truthy
        return request
    }

    static func ollamaGenerate(_ body: JSON) throws -> ModelRequest {
        var request = ModelRequest(model: body["model"].stringValue ?? "")
        let prompt = body["prompt"].stringValue ?? ""
        if body["raw"].truthy {
            request.rawPrompt = prompt
        } else {
            if let system = body["system"].stringValue, !system.isEmpty { request.messages.append(RichMessage(role: .system, content: system)) }
            request.messages.append(RichMessage(role: .user, content: prompt))
        }
        request.format = try format(ollama: body["format"])
        request.formatSource = body["format"]
        request.think = body["think"].boolValue
        request.options = body["options"].object
        request.keepAlive = body["keep_alive"]
        request.stream = body["stream"].isUndefined ? true : body["stream"].truthy
        return request
    }

    private static func ollamaMessage(_ message: JSON) -> RichMessage {
        let role = ChatMessage.Role(rawValue: message["role"].stringValue ?? "user") ?? .user
        let calls = message["tool_calls"].array.enumerated().map { index, call in
            ToolCall(id: call["id"].stringValue ?? "call_\(index)", name: call["function"]["name"].stringValue ?? "",
                     arguments: argumentsText(call["function"]["arguments"]))
        }
        return RichMessage(role: role, content: text(message["content"]), toolCalls: calls, toolName: message["tool_name"].stringValue ?? message["name"].stringValue)
    }

    // MARK: OpenAI

    static func openAIChat(_ body: JSON) throws -> ModelRequest {
        var request = ModelRequest(model: body["model"].stringValue ?? "")
        request.messages = body["messages"].array.map { message in
            var role = message["role"].stringValue ?? "user"
            if role == "developer" { role = "system" }
            let calls = message["tool_calls"].array.map { call in
                ToolCall(id: call["id"].stringValue ?? "", name: call["function"]["name"].stringValue ?? "", arguments: argumentsText(call["function"]["arguments"]))
            }
            return RichMessage(role: ChatMessage.Role(rawValue: role) ?? .user, content: text(message["content"]), toolCalls: calls,
                               toolName: message["name"].stringValue)
        }
        request.tools = tools(body["tools"])
        request.toolChoice = toolChoice(openAI: body["tool_choice"])
        request.format = try format(openAI: body["response_format"])
        request.formatSource = body["response_format"]["json_schema"]["schema"]
        request.think = think(effort: body["reasoning_effort"].stringValue ?? body["reasoning"]["effort"].stringValue)
        request.options = openAIOptions(body)
        request.stream = body["stream"].truthy
        request.includeUsage = body["stream_options"]["include_usage"].truthy
        return request
    }

    static func openAICompletions(_ body: JSON) throws -> ModelRequest {
        var request = ModelRequest(model: body["model"].stringValue ?? "")
        request.rawPrompt = body["prompt"].stringValue ?? body["prompt"].array.compactMap(\.stringValue).joined()
        request.options = openAIOptions(body)
        request.stream = body["stream"].truthy
        request.includeUsage = body["stream_options"]["include_usage"].truthy
        return request
    }

    /// OpenAI Responses: `input` is a string or a list of items.
    static func responses(_ body: JSON) throws -> ModelRequest {
        var request = ModelRequest(model: body["model"].stringValue ?? "")
        if let instructions = body["instructions"].stringValue, !instructions.isEmpty {
            request.messages.append(RichMessage(role: .system, content: instructions))
        }
        if let input = body["input"].stringValue {
            request.messages.append(RichMessage(role: .user, content: input))
        } else {
            for item in body["input"].array {
                switch item["type"].stringValue ?? "message" {
                case "function_call":
                    let call = ToolCall(id: item["call_id"].stringValue ?? "", name: item["name"].stringValue ?? "", arguments: argumentsText(item["arguments"]))
                    if let last = request.messages.last, last.role == .assistant {
                        request.messages[request.messages.count - 1].toolCalls.append(call)
                    } else {
                        request.messages.append(RichMessage(role: .assistant, content: "", toolCalls: [call]))
                    }
                case "function_call_output":
                    let name = request.messages.flatMap(\.toolCalls).first { $0.id == item["call_id"].stringValue }?.name
                    request.messages.append(RichMessage(role: .tool, content: text(item["output"]), toolName: name))
                default:
                    var role = item["role"].stringValue ?? "user"
                    if role == "developer" { role = "system" }
                    request.messages.append(RichMessage(role: ChatMessage.Role(rawValue: role) ?? .user, content: text(item["content"])))
                }
            }
        }
        // Responses lists tools flat: {type: "function", name, description, parameters}.
        request.tools = body["tools"].array.compactMap { tool in
            guard tool["type"].stringValue == "function" || tool["type"].isUndefined else { return nil }
            let function = tool["function"].isObject ? tool["function"] : tool
            guard let name = function["name"].stringValue else { return nil }
            return ToolSpec(name: name, description: function["description"].stringValue ?? "", parameters: schemaText(function["parameters"]))
        }
        request.toolChoice = toolChoice(openAI: body["tool_choice"])
        let textFormat = body["text"]["format"]
        if textFormat["type"].stringValue == "json_schema" {
            request.format = .schema(try schema(textFormat["schema"]))
            request.formatSource = textFormat["schema"]
        } else if textFormat["type"].stringValue == "json_object" {
            request.format = .json
        }
        request.think = think(effort: body["reasoning"]["effort"].stringValue)
        var options = JSONObject()
        if let value = body["temperature"].numberValue { options["temperature"] = JSON(value) }
        if let value = body["top_p"].numberValue { options["top_p"] = JSON(value) }
        if let value = body["max_output_tokens"].numberValue { options["num_predict"] = JSON(value) }
        request.options = options
        request.stream = body["stream"].truthy
        return request
    }

    private static func openAIOptions(_ body: JSON) -> JSONObject {
        var options = JSONObject()
        if let value = body["temperature"].numberValue { options["temperature"] = JSON(value) }
        if let value = body["top_p"].numberValue { options["top_p"] = JSON(value) }
        if let value = body["max_tokens"].numberValue ?? body["max_completion_tokens"].numberValue { options["num_predict"] = JSON(value) }
        if let value = body["seed"].numberValue { options["seed"] = JSON(value) }
        if let value = body["presence_penalty"].numberValue { options["presence_penalty"] = JSON(value) }
        if let value = body["frequency_penalty"].numberValue { options["frequency_penalty"] = JSON(value) }
        if let stop = body["stop"].stringValue { options["stop"] = .array([JSON(stop)]) } else if !body["stop"].array.isEmpty { options["stop"] = body["stop"] }
        return options
    }

    private static func toolChoice(openAI value: JSON) -> ToolChoice {
        switch value.stringValue {
        case "none": return .none
        case "required": return .required
        case "auto", nil: break
        default: return .auto
        }
        if let name = value["function"]["name"].stringValue ?? value["name"].stringValue { return .named(name) }
        return .auto
    }

    private static func think(effort: String?) -> Bool? {
        guard let effort else { return nil }
        return effort != "none" && effort != "minimal"
    }

    // MARK: Anthropic

    static func anthropicMessages(_ body: JSON) throws -> ModelRequest {
        var request = ModelRequest(model: body["model"].stringValue ?? "")
        if let system = body["system"].stringValue, !system.isEmpty {
            request.messages.append(RichMessage(role: .system, content: system))
        } else if !body["system"].array.isEmpty {
            request.messages.append(RichMessage(role: .system, content: text(body["system"])))
        }
        var names: [String: String] = [:]
        for message in body["messages"].array {
            let role = message["role"].stringValue == "assistant" ? ChatMessage.Role.assistant : .user
            if let content = message["content"].stringValue {
                request.messages.append(RichMessage(role: role, content: content))
                continue
            }
            var textParts: [String] = []
            var calls: [ToolCall] = []
            for block in message["content"].array {
                switch block["type"].stringValue ?? "" {
                case "text": textParts.append(block["text"].stringValue ?? "")
                case "tool_use":
                    let call = ToolCall(id: block["id"].stringValue ?? "", name: block["name"].stringValue ?? "", arguments: argumentsText(block["input"]))
                    names[call.id] = call.name
                    calls.append(call)
                case "tool_result":
                    if !textParts.isEmpty { request.messages.append(RichMessage(role: role, content: textParts.joined(separator: "\n"))); textParts = [] }
                    let id = block["tool_use_id"].stringValue ?? ""
                    request.messages.append(RichMessage(role: .tool, content: text(block["content"]), toolName: names[id]))
                default: break
                }
            }
            if !textParts.isEmpty || !calls.isEmpty {
                request.messages.append(RichMessage(role: role, content: textParts.joined(separator: "\n"), toolCalls: calls))
            }
        }
        request.tools = body["tools"].array.compactMap { tool in
            guard let name = tool["name"].stringValue else { return nil }
            return ToolSpec(name: name, description: tool["description"].stringValue ?? "", parameters: schemaText(tool["input_schema"]))
        }
        switch body["tool_choice"]["type"].stringValue {
        case "none": request.toolChoice = .none
        case "any": request.toolChoice = .required
        case "tool": request.toolChoice = body["tool_choice"]["name"].stringValue.map(ToolChoice.named) ?? .auto
        default: break
        }
        if body["thinking"]["type"].stringValue == "enabled" { request.think = true } else if body["thinking"]["type"].stringValue == "disabled" { request.think = false }
        var options = JSONObject()
        if let value = body["temperature"].numberValue { options["temperature"] = JSON(value) }
        if let value = body["top_p"].numberValue { options["top_p"] = JSON(value) }
        if let value = body["top_k"].numberValue { options["top_k"] = JSON(value) }
        if let value = body["max_tokens"].numberValue { options["num_predict"] = JSON(value) }
        if !body["stop_sequences"].array.isEmpty { options["stop"] = body["stop_sequences"] }
        request.options = options
        request.stream = body["stream"].truthy
        return request
    }

    // MARK: Shared pieces

    /// Message content as text: a string, or the text parts of a list.
    static func text(_ value: JSON) -> String {
        if let string = value.stringValue { return string }
        if value.isNullish { return "" }
        if !value.array.isEmpty {
            return value.array.compactMap { part -> String? in
                if let string = part.stringValue { return string }
                switch part["type"].stringValue ?? "text" {
                case "text", "input_text", "output_text": return part["text"].stringValue
                case "tool_result": return text(part["content"])
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return value.serialized()
    }

    static func argumentsText(_ value: JSON) -> String {
        if let string = value.stringValue { return string.isEmpty ? "{}" : string }
        if value.isNullish { return "{}" }
        return value.serialized()
    }

    static func schemaText(_ value: JSON) -> String {
        value.isObject ? value.serialized() : "{\"type\":\"object\",\"properties\":{}}"
    }

    /// Ollama and OpenAI chat tools: `{type: "function", function: {name, description, parameters}}`.
    static func tools(_ value: JSON) -> [ToolSpec] {
        value.array.compactMap { tool in
            let function = tool["function"].isObject ? tool["function"] : tool
            guard let name = function["name"].stringValue else { return nil }
            return ToolSpec(name: name, description: function["description"].stringValue ?? "", parameters: schemaText(function["parameters"]))
        }
    }

    static func format(ollama value: JSON) throws -> Format {
        if value.stringValue == "json" { return .json }
        if value.isObject { return .schema(try schema(value)) }
        return .text
    }

    static func format(openAI value: JSON) throws -> Format {
        switch value["type"].stringValue {
        case "json_object": return .json
        case "json_schema": return .schema(try schema(value["json_schema"]["schema"]))
        default: return .text
        }
    }

    // MARK: JSON Schema → constraint

    static func schema(_ value: JSON) throws -> JSONSchemaNode {
        guard value.isObject else { throw requestError("A JSON schema must be an object.", 400) }
        return node(value, root: value, depth: 0)
    }

    private static func node(_ value: JSON, root: JSON, depth: Int) -> JSONSchemaNode {
        guard depth < 24, value.isObject else { return .any }
        if let ref = value["$ref"].stringValue {
            // Local references only: #/$defs/Name and #/definitions/Name.
            let parts = ref.split(separator: "/").map(String.init)
            guard parts.first == "#", parts.count == 3 else { return .any }
            return node(root[parts[1]][parts[2]], root: root, depth: depth + 1)
        }
        if !value["const"].isUndefined { return .literals([value["const"].serialized()]) }
        if !value["enum"].array.isEmpty { return .literals(value["enum"].array.map { $0.serialized() }) }
        for key in ["anyOf", "oneOf"] where !value[key].array.isEmpty {
            let branches = value[key].array.map { node($0, root: root, depth: depth + 1) }
            return branches.contains(.any) ? .any : .union(branches)
        }
        if !value["allOf"].array.isEmpty, value["allOf"].array.count == 1 { return node(value["allOf"][0], root: root, depth: depth + 1) }
        if !value["type"].array.isEmpty {
            var copy = value.object
            return .union(value["type"].array.compactMap { type in
                copy["type"] = type
                return node(.object(copy), root: root, depth: depth + 1)
            })
        }
        switch value["type"].stringValue {
        case "object":
            var properties: [String: JSONSchemaNode] = [:]
            var order: [String] = []
            for (key, property) in value["properties"].object {
                properties[key] = node(property, root: root, depth: depth + 1)
                order.append(key)
            }
            let required = Set(value["required"].array.compactMap(\.stringValue))
            // Only the listed properties unless the schema opts in to more (as llama.cpp's grammars do).
            let additional = value["additionalProperties"].boolValue == true || value["additionalProperties"].isObject || properties.isEmpty
            return .object(properties: properties, order: order, required: required, additional: additional)
        case "array":
            let items = value["items"].isObject ? node(value["items"], root: root, depth: depth + 1) : .any
            return .array(items: items, minItems: value["minItems"].clampedInt(0...Int(Int32.max)) ?? 0, maxItems: value["maxItems"].clampedInt(0...Int(Int32.max)))
        case "string": return .string
        case "integer": return .number(integer: true)
        case "number": return .number(integer: false)
        case "boolean": return .boolean
        case "null": return .null
        default:
            if value["properties"].isObject {
                var copy = value.object
                copy["type"] = "object"
                return node(.object(copy), root: root, depth: depth + 1)
            }
            return .any
        }
    }
}
