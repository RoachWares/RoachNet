import Foundation
import RoachInference

/// Each model API's own shape for a reply, streamed or whole: Ollama chat
/// and generate, OpenAI chat completions, completions and responses, and
/// Anthropic messages. All of them run through `execute`.
extension NativeModelServer {
    private func errorText(_ error: Error) -> String { (error as? RuntimeError)?.message ?? "\(error)" }

    // MARK: Ollama

    /// `/api/chat` with no messages, or `/api/generate` with no prompt: load (or unload) only.
    private func loadOnly(_ request: ModelRequest, chat: Bool) throws -> HTTPResponse {
        if SubscriptionModels.parse(request.model) == nil {
            if keepAlive(request.keepAlive) == 0 {
                unload((try? NativeModelStore.normalize(request.model).name) ?? request.model)
            } else {
                _ = try load(request.model, contextLength: request.options["num_ctx"].numberValue.map { Int($0) }, keepAlive: keepAlive(request.keepAlive))
            }
        }
        var out = JSONObject([("model", JSON(request.model)), ("created_at", JSON(JS.isoNow()))])
        if chat { out["message"] = ["role": "assistant", "content": ""] } else { out["response"] = "" }
        out["done"] = true
        out["done_reason"] = keepAlive(request.keepAlive) == 0 ? "unload" : "load"
        return .json(200, .object(out))
    }

    private static func ollamaCalls(_ calls: [ToolCall]) -> JSON {
        .array(calls.enumerated().map { index, call in
            ["id": JSON(call.id), "function": ["index": JSON(index), "name": JSON(call.name), "arguments": argumentsObject(call.arguments)]]
        })
    }

    private static func ollamaDone(_ reply: ModelReply) -> String {
        reply.finish == "length" ? "length" : "stop"
    }

    func answerOllama(_ body: JSON, chat: Bool, traceparent: String?) throws -> HTTPResponse {
        let request = chat ? try ModelRequest.ollamaChat(body) : try ModelRequest.ollamaGenerate(body)
        let empty = chat ? request.messages.isEmpty : (request.rawPrompt ?? request.messages.last?.content ?? "").isEmpty
        if empty && body["images"].isUndefined { return try loadOnly(request, chat: chat) }
        let model = request.model
        let endpoint = chat ? "chat" : "generate"

        func piece(content: String, thinking: String = "", calls: [ToolCall] = [], done: Bool) -> JSONObject {
            var out = JSONObject([("model", JSON(model)), ("created_at", JSON(JS.isoNow()))])
            if chat {
                var message = JSONObject([("role", "assistant"), ("content", JSON(content))])
                if !thinking.isEmpty { message["thinking"] = JSON(thinking) }
                if !calls.isEmpty { message["tool_calls"] = NativeModelServer.ollamaCalls(calls) }
                out["message"] = .object(message)
            } else {
                out["response"] = JSON(content)
                if !thinking.isEmpty { out["thinking"] = JSON(thinking) }
            }
            out["done"] = JSON(done)
            return out
        }
        func final(_ reply: ModelReply, whole: Bool) -> JSON {
            var out = whole ? piece(content: reply.content, thinking: reply.thinking, calls: reply.toolCalls, done: true) : piece(content: "", done: true)
            out["done_reason"] = JSON(NativeModelServer.ollamaDone(reply))
            for (key, value) in reply.timings { out[key] = value }
            return .object(out)
        }

        if !request.stream {
            return .json(200, final(try execute(request, endpoint: endpoint, traceparent: traceparent, writer: nil), whole: true))
        }
        try preflight(request)
        return .ndjsonStream { [self] writer in
            do {
                let reply = try self.execute(request, endpoint: endpoint, traceparent: traceparent, writer: writer) { delta in
                    switch delta {
                    case .content(let text): writer.write(self.line(.object(piece(content: text, done: false))))
                    case .thinking(let text): writer.write(self.line(.object(piece(content: "", thinking: text, done: false))))
                    }
                }
                if !reply.toolCalls.isEmpty { writer.write(self.line(.object(piece(content: "", calls: reply.toolCalls, done: false)))) }
                writer.write(self.line(final(reply, whole: false)))
            } catch {
                writer.write(self.line(["error": JSON(self.errorText(error))]))
            }
        }
    }

    // MARK: OpenAI chat completions and completions

    private static func openAIUsage(_ reply: ModelReply) -> JSON {
        ["prompt_tokens": JSON(reply.promptTokens), "completion_tokens": JSON(reply.outputTokens),
         "total_tokens": JSON(reply.promptTokens + reply.outputTokens),
         "prompt_tokens_details": ["cached_tokens": JSON(reply.cachedTokens)]]
    }

    private static func openAIFinish(_ reply: ModelReply) -> String {
        switch reply.finish {
        case "length": return "length"
        case "tool_calls": return "tool_calls"
        default: return "stop"
        }
    }

    private static func openAICalls(_ calls: [ToolCall], streamed: Bool) -> JSON {
        .array(calls.enumerated().map { index, call in
            var out = JSONObject([("id", JSON(call.id)), ("type", "function"),
                                  ("function", ["name": JSON(call.name), "arguments": JSON(call.arguments)])])
            if streamed { out["index"] = JSON(index) }
            return .object(out)
        })
    }

    private static func sse(_ writer: HTTPStreamWriter, _ value: JSON, event: String? = nil) {
        let head = event.map { "event: \($0)\n" } ?? ""
        writer.write(Data((head + "data: " + value.serialized() + "\n\n").utf8))
    }

    private static func eventStream(_ produce: @escaping (HTTPStreamWriter) -> Void) -> HTTPResponse {
        var response = HTTPResponse(status: 200, headers: [("content-type", "text/event-stream"), ("cache-control", "no-store")])
        response.stream = produce
        return response
    }

    func answerOpenAIChat(_ body: JSON, traceparent: String?) throws -> HTTPResponse {
        let request = try ModelRequest.openAIChat(body)
        let id = "chatcmpl-" + JS.randomHex(12)
        let created = NativeModelServer.created()
        let model = request.model
        if !request.stream {
            let reply = try execute(request, endpoint: "v1/chat/completions", traceparent: traceparent, writer: nil)
            var message = JSONObject([("role", "assistant"), ("content", reply.content.isEmpty && !reply.toolCalls.isEmpty ? .null : JSON(reply.content))])
            if !reply.thinking.isEmpty {
                message["reasoning_content"] = JSON(reply.thinking)
                message["reasoning"] = JSON(reply.thinking)
            }
            if !reply.toolCalls.isEmpty { message["tool_calls"] = NativeModelServer.openAICalls(reply.toolCalls, streamed: false) }
            return .json(200, ["id": JSON(id), "object": "chat.completion", "created": created, "model": JSON(model),
                               "choices": [["index": 0, "message": .object(message), "logprobs": .null, "finish_reason": JSON(NativeModelServer.openAIFinish(reply))]],
                               "usage": NativeModelServer.openAIUsage(reply)])
        }
        try preflight(request)
        return NativeModelServer.eventStream { [self] writer in
            func chunk(_ delta: JSON, finish: JSON = .null) {
                NativeModelServer.sse(writer, ["id": JSON(id), "object": "chat.completion.chunk", "created": created, "model": JSON(model),
                                               "choices": [["index": 0, "delta": delta, "logprobs": .null, "finish_reason": finish]]])
            }
            chunk(["role": "assistant", "content": ""])
            do {
                let reply = try self.execute(request, endpoint: "v1/chat/completions", traceparent: traceparent, writer: writer) { delta in
                    switch delta {
                    case .content(let text): chunk(["content": JSON(text)])
                    case .thinking(let text): chunk(["reasoning_content": JSON(text), "reasoning": JSON(text)])
                    }
                }
                if !reply.toolCalls.isEmpty { chunk(["tool_calls": NativeModelServer.openAICalls(reply.toolCalls, streamed: true)]) }
                chunk([:], finish: JSON(NativeModelServer.openAIFinish(reply)))
                if request.includeUsage {
                    NativeModelServer.sse(writer, ["id": JSON(id), "object": "chat.completion.chunk", "created": created, "model": JSON(model),
                                                   "choices": [], "usage": NativeModelServer.openAIUsage(reply)])
                }
            } catch {
                NativeModelServer.sse(writer, ["error": ["message": JSON(self.errorText(error)), "type": "server_error"]])
            }
            writer.write(Data("data: [DONE]\n\n".utf8))
        }
    }

    func answerCompletions(_ body: JSON, traceparent: String?) throws -> HTTPResponse {
        let request = try ModelRequest.openAICompletions(body)
        let id = "cmpl-" + JS.randomHex(12)
        let created = NativeModelServer.created()
        let model = request.model
        if !request.stream {
            let reply = try execute(request, endpoint: "v1/completions", traceparent: traceparent, writer: nil)
            return .json(200, ["id": JSON(id), "object": "text_completion", "created": created, "model": JSON(model),
                               "choices": [["index": 0, "text": JSON(reply.content), "logprobs": .null, "finish_reason": JSON(NativeModelServer.openAIFinish(reply))]],
                               "usage": NativeModelServer.openAIUsage(reply)])
        }
        try preflight(request)
        return NativeModelServer.eventStream { [self] writer in
            func chunk(_ text: String, finish: JSON = .null) {
                NativeModelServer.sse(writer, ["id": JSON(id), "object": "text_completion", "created": created, "model": JSON(model),
                                               "choices": [["index": 0, "text": JSON(text), "logprobs": .null, "finish_reason": finish]]])
            }
            do {
                let reply = try self.execute(request, endpoint: "v1/completions", traceparent: traceparent, writer: writer) { delta in
                    if case .content(let text) = delta { chunk(text) }
                }
                chunk("", finish: JSON(NativeModelServer.openAIFinish(reply)))
                if request.includeUsage {
                    NativeModelServer.sse(writer, ["id": JSON(id), "object": "text_completion", "created": created, "model": JSON(model),
                                                   "choices": [], "usage": NativeModelServer.openAIUsage(reply)])
                }
            } catch {
                NativeModelServer.sse(writer, ["error": ["message": JSON(self.errorText(error)), "type": "server_error"]])
            }
            writer.write(Data("data: [DONE]\n\n".utf8))
        }
    }

    // MARK: OpenAI responses

    fileprivate static func responseItems(_ reply: ModelReply) -> [JSON] {
        var items: [JSON] = []
        if !reply.thinking.isEmpty { items.append(ResponsesStream.reasoningItem("rs_" + JS.randomHex(12), reply.thinking)) }
        if !reply.content.isEmpty || reply.toolCalls.isEmpty { items.append(ResponsesStream.messageItem("msg_" + JS.randomHex(12), reply.content)) }
        for call in reply.toolCalls { items.append(ResponsesStream.callItem("fc_" + JS.randomHex(12), call)) }
        return items
    }

    fileprivate static func responseObject(id: String, created: JSON, request: ModelRequest, body: JSON, status: String,
                                           output: [JSON], reply: ModelReply?) -> JSON {
        var out = JSONObject([("id", JSON(id)), ("object", "response"), ("created_at", created), ("status", JSON(status)),
                              ("model", JSON(request.model)), ("output", .array(output)), ("error", .null),
                              ("incomplete_details", status == "incomplete" ? ["reason": "max_output_tokens"] : .null),
                              ("instructions", body["instructions"].isUndefined ? .null : body["instructions"]),
                              ("parallel_tool_calls", true), ("tool_choice", body["tool_choice"].isUndefined ? "auto" : body["tool_choice"]),
                              ("tools", body["tools"].isUndefined ? .array([]) : body["tools"]),
                              ("text", body["text"].isUndefined ? ["format": ["type": "text"]] : body["text"]),
                              ("usage", .null)])
        if let reply {
            out["usage"] = ["input_tokens": JSON(reply.promptTokens), "input_tokens_details": ["cached_tokens": JSON(reply.cachedTokens)],
                            "output_tokens": JSON(reply.outputTokens), "output_tokens_details": ["reasoning_tokens": 0],
                            "total_tokens": JSON(reply.promptTokens + reply.outputTokens)]
        }
        return .object(out)
    }

    func answerResponses(_ body: JSON, traceparent: String?) throws -> HTTPResponse {
        let request = try ModelRequest.responses(body)
        let id = "resp_" + JS.randomHex(16)
        let created = NativeModelServer.created()
        if !request.stream {
            let reply = try execute(request, endpoint: "v1/responses", traceparent: traceparent, writer: nil)
            return .json(200, NativeModelServer.responseObject(id: id, created: created, request: request, body: body,
                                                              status: reply.finish == "length" ? "incomplete" : "completed",
                                                              output: NativeModelServer.responseItems(reply), reply: reply))
        }
        try preflight(request)
        return NativeModelServer.eventStream { [self] writer in
            let stream = ResponsesStream(writer: writer)
            let opening = NativeModelServer.responseObject(id: id, created: created, request: request, body: body, status: "in_progress", output: [], reply: nil)
            stream.send("response.created", ["response": opening])
            stream.send("response.in_progress", ["response": opening])
            do {
                let reply = try self.execute(request, endpoint: "v1/responses", traceparent: traceparent, writer: writer) { delta in
                    switch delta {
                    case .thinking(let text): stream.delta(.reasoning, text)
                    case .content(let text): stream.delta(.message, text)
                    }
                }
                if reply.toolCalls.isEmpty && stream.output.isEmpty { stream.delta(.message, "") }
                stream.close()
                for call in reply.toolCalls { stream.call(call) }
                let status = reply.finish == "length" ? "incomplete" : "completed"
                stream.send(status == "completed" ? "response.completed" : "response.incomplete",
                            ["response": NativeModelServer.responseObject(id: id, created: created, request: request, body: body, status: status,
                                                                          output: stream.output, reply: reply)])
            } catch {
                stream.send("error", ["code": "server_error", "message": JSON(self.errorText(error)), "param": .null])
                stream.send("response.failed", ["response": NativeModelServer.responseObject(id: id, created: created, request: request, body: body,
                                                                                            status: "failed", output: stream.output, reply: nil)])
            }
        }
    }
}

/// The Responses API's event stream: output items opened and closed in turn,
/// each event numbered.
final class ResponsesStream {
    enum Kind { case reasoning, message }
    let writer: HTTPStreamWriter
    private var sequence = 0
    private(set) var output: [JSON] = []
    private var open: Kind?
    private var openID = ""
    private var openText = ""

    init(writer: HTTPStreamWriter) { self.writer = writer }

    func send(_ type: String, _ fields: JSONObject) {
        var data = fields
        data["type"] = JSON(type)
        data["sequence_number"] = JSON(sequence)
        sequence += 1
        writer.write(Data("event: \(type)\ndata: \(JSON.object(data).serialized())\n\n".utf8))
    }

    static func textPart(_ text: String) -> JSON { ["type": "output_text", "text": JSON(text), "annotations": []] }
    static func reasoningItem(_ id: String, _ text: String) -> JSON {
        ["type": "reasoning", "id": JSON(id), "summary": [], "content": [["type": "reasoning_text", "text": JSON(text)]]]
    }
    static func messageItem(_ id: String, _ text: String) -> JSON {
        ["type": "message", "id": JSON(id), "status": "completed", "role": "assistant", "content": [textPart(text)]]
    }
    static func callItem(_ id: String, _ call: ToolCall) -> JSON {
        ["type": "function_call", "id": JSON(id), "call_id": JSON(call.id), "name": JSON(call.name), "arguments": JSON(call.arguments), "status": "completed"]
    }

    func delta(_ kind: Kind, _ text: String) {
        if open != kind {
            close()
            open = kind
            openText = ""
            openID = (kind == .reasoning ? "rs_" : "msg_") + JS.randomHex(12)
            let index = output.count
            switch kind {
            case .reasoning:
                send("response.output_item.added", ["output_index": JSON(index), "item": ["type": "reasoning", "id": JSON(openID), "summary": [], "content": []]])
                send("response.content_part.added", ["item_id": JSON(openID), "output_index": JSON(index), "content_index": 0,
                                                     "part": ["type": "reasoning_text", "text": ""]])
            case .message:
                send("response.output_item.added", ["output_index": JSON(index),
                                                    "item": ["type": "message", "id": JSON(openID), "status": "in_progress", "role": "assistant", "content": []]])
                send("response.content_part.added", ["item_id": JSON(openID), "output_index": JSON(index), "content_index": 0, "part": ResponsesStream.textPart("")])
            }
        }
        guard !text.isEmpty else { return }
        openText += text
        let fields: JSONObject = ["item_id": JSON(openID), "output_index": JSON(output.count), "content_index": 0, "delta": JSON(text)]
        send(kind == .reasoning ? "response.reasoning_text.delta" : "response.output_text.delta", fields)
    }

    func close() {
        guard let kind = open else { return }
        let index = output.count
        let base: JSONObject = ["item_id": JSON(openID), "output_index": JSON(index), "content_index": 0]
        var done = base
        done["text"] = JSON(openText)
        var part = base
        let item: JSON
        switch kind {
        case .reasoning:
            send("response.reasoning_text.done", done)
            part["part"] = ["type": "reasoning_text", "text": JSON(openText)]
            item = ResponsesStream.reasoningItem(openID, openText)
        case .message:
            send("response.output_text.done", done)
            part["part"] = ResponsesStream.textPart(openText)
            item = ResponsesStream.messageItem(openID, openText)
        }
        send("response.content_part.done", part)
        send("response.output_item.done", ["output_index": JSON(index), "item": item])
        output.append(item)
        open = nil
    }

    func call(_ call: ToolCall) {
        close()
        let index = output.count
        let id = "fc_" + JS.randomHex(12)
        send("response.output_item.added", ["output_index": JSON(index),
                                            "item": ["type": "function_call", "id": JSON(id), "call_id": JSON(call.id), "name": JSON(call.name),
                                                     "arguments": "", "status": "in_progress"]])
        send("response.function_call_arguments.delta", ["item_id": JSON(id), "output_index": JSON(index), "delta": JSON(call.arguments)])
        send("response.function_call_arguments.done", ["item_id": JSON(id), "output_index": JSON(index), "arguments": JSON(call.arguments)])
        let item = ResponsesStream.callItem(id, call)
        send("response.output_item.done", ["output_index": JSON(index), "item": item])
        output.append(item)
    }
}

// MARK: Anthropic messages

extension NativeModelServer {
    fileprivate static func anthropicStop(_ reply: ModelReply) -> String {
        switch reply.finish {
        case "tool_calls": return "tool_use"
        case "length": return "max_tokens"
        case "stop_sequence": return "stop_sequence"
        default: return "end_turn"
        }
    }

    fileprivate static func anthropicID(_ call: ToolCall) -> String {
        call.id.hasPrefix("call_") ? "toolu_" + call.id.dropFirst(5) : call.id
    }

    fileprivate static func anthropicUsage(_ reply: ModelReply?, input: Int = 0) -> JSON {
        let prompt = reply?.promptTokens ?? input
        let cached = reply?.cachedTokens ?? 0
        return ["input_tokens": JSON(prompt - cached), "cache_creation_input_tokens": 0, "cache_read_input_tokens": JSON(cached),
                "output_tokens": JSON(reply?.outputTokens ?? 0)]
    }

    func answerAnthropic(_ body: JSON, traceparent: String?) throws -> HTTPResponse {
        let request = try ModelRequest.anthropicMessages(body)
        let id = "msg_" + JS.randomHex(16)
        let model = request.model
        if !request.stream {
            let reply = try execute(request, endpoint: "v1/messages", traceparent: traceparent, writer: nil)
            var content: [JSON] = []
            if !reply.thinking.isEmpty { content.append(["type": "thinking", "thinking": JSON(reply.thinking), "signature": ""]) }
            if !reply.content.isEmpty || reply.toolCalls.isEmpty { content.append(["type": "text", "text": JSON(reply.content)]) }
            for call in reply.toolCalls {
                content.append(["type": "tool_use", "id": JSON(NativeModelServer.anthropicID(call)), "name": JSON(call.name),
                                "input": NativeModelServer.argumentsObject(call.arguments)])
            }
            return .json(200, ["id": JSON(id), "type": "message", "role": "assistant", "model": JSON(model), "content": .array(content),
                               "stop_reason": JSON(NativeModelServer.anthropicStop(reply)), "stop_sequence": .null,
                               "usage": NativeModelServer.anthropicUsage(reply)])
        }
        try preflight(request)
        return NativeModelServer.eventStream { [self] writer in
            let stream = AnthropicStream(writer: writer)
            stream.send("message_start", ["message": ["id": JSON(id), "type": "message", "role": "assistant", "model": JSON(model), "content": [],
                                                      "stop_reason": .null, "stop_sequence": .null, "usage": NativeModelServer.anthropicUsage(nil)]])
            do {
                let reply = try self.execute(request, endpoint: "v1/messages", traceparent: traceparent, writer: writer) { delta in
                    switch delta {
                    case .thinking(let text): stream.delta(.thinking, text)
                    case .content(let text): stream.delta(.text, text)
                    }
                }
                stream.close()
                for call in reply.toolCalls { stream.toolUse(id: NativeModelServer.anthropicID(call), call) }
                stream.send("message_delta", ["delta": ["stop_reason": JSON(NativeModelServer.anthropicStop(reply)), "stop_sequence": .null],
                                              "usage": NativeModelServer.anthropicUsage(reply)])
                stream.send("message_stop", [:])
            } catch {
                stream.send("error", ["error": ["type": "api_error", "message": JSON(self.errorText(error))]])
            }
        }
    }

    /// `/v1/messages/count_tokens`: the prompt as the model would see it.
    func countAnthropicTokens(_ body: JSON) throws -> HTTPResponse {
        let request = try ModelRequest.anthropicMessages(body)
        if SubscriptionModels.parse(request.model) != nil {
            let characters = request.messages.reduce(0) { $0 + $1.content.count } + request.tools.reduce(0) { $0 + $1.definition.count }
            return .json(200, ["input_tokens": JSON(max(1, characters / 4))])
        }
        let item = try load(request.model, contextLength: nil, keepAlive: keepAlive(request.keepAlive))
        let engine = item.engine
        let text = ChatTools.render(engine.chatTemplate, messages: request.messages, tools: request.effectiveTools,
                                    defaultSystem: engine.defaultSystemPrompt, think: request.think, supportsThinking: engine.supportsThinking)
        return .json(200, ["input_tokens": JSON(engine.tokenizer.encode(text, addSpecial: true, parseSpecial: true).count)])
    }
}

/// Anthropic's event stream: content blocks opened and closed in turn.
final class AnthropicStream {
    enum Kind { case thinking, text }
    let writer: HTTPStreamWriter
    private var index = -1
    private var open: Kind?

    init(writer: HTTPStreamWriter) { self.writer = writer }

    func send(_ type: String, _ fields: JSONObject) {
        var data = JSONObject([("type", JSON(type))])
        for (key, value) in fields { data[key] = value }
        writer.write(Data("event: \(type)\ndata: \(JSON.object(data).serialized())\n\n".utf8))
    }

    func delta(_ kind: Kind, _ text: String) {
        if open != kind {
            close()
            open = kind
            index += 1
            let block: JSON = kind == .thinking ? ["type": "thinking", "thinking": "", "signature": ""] : ["type": "text", "text": ""]
            send("content_block_start", ["index": JSON(index), "content_block": block])
        }
        guard !text.isEmpty else { return }
        let delta: JSON = kind == .thinking ? ["type": "thinking_delta", "thinking": JSON(text)] : ["type": "text_delta", "text": JSON(text)]
        send("content_block_delta", ["index": JSON(index), "delta": delta])
    }

    func close() {
        guard open != nil else { return }
        send("content_block_stop", ["index": JSON(index)])
        open = nil
    }

    func toolUse(id: String, _ call: ToolCall) {
        close()
        index += 1
        send("content_block_start", ["index": JSON(index), "content_block": ["type": "tool_use", "id": JSON(id), "name": JSON(call.name), "input": [:]]])
        send("content_block_delta", ["index": JSON(index), "delta": ["type": "input_json_delta", "partial_json": JSON(call.arguments)]])
        send("content_block_stop", ["index": JSON(index)])
    }
}
