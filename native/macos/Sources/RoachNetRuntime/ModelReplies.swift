import Foundation
import RoachInference

struct ModelReply {
    var model: String
    var content = ""
    var thinking = ""
    var toolCalls: [ToolCall] = []
    var promptTokens = 0
    var cachedTokens = 0
    var outputTokens = 0
    var finish = "stop"
    var timings = JSONObject()
}

enum ModelDelta {
    case thinking(String)
    case content(String)
}

struct ToolGate {
    static let markers = ["<tool_call>", "[TOOL_CALLS]", "<|python_tag|>"]
    let active: Bool
    let bareStarts: Set<Character>
    private(set) var emitted = ""
    private var pending = ""
    private var held = false

    init(active: Bool, template: ChatTemplate) {
        self.active = active
        switch template {
        case .llama3: bareStarts = ["{"]
        case .mistral: bareStarts = ["[", "{"]
        default: bareStarts = []
        }
    }

    mutating func feed(_ piece: String) -> String {
        guard active else {
            emitted += piece
            return piece
        }
        guard !held else { return "" }
        pending += piece
        let found = ToolGate.markers.compactMap { pending.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        if let found {
            held = true
            let before = String(pending[..<found.lowerBound])
            pending = ""
            return emit(before)
        }
        if emitted.isEmpty, !bareStarts.isEmpty {
            let trimmed = pending.drop { $0.isWhitespace }
            guard let first = trimmed.first else { return "" }
            if bareStarts.contains(first) {
                held = true
                return ""
            }
        }
        let keep = ToolGate.markers.map { ThinkingSplitter.partialSuffix(pending, of: $0) }.max() ?? 0
        let ready = String(pending.dropLast(keep))
        pending = String(pending.suffix(keep))
        return emit(ready)
    }

    private mutating func emit(_ text: String) -> String {
        emitted += text
        return text
    }

    func remainder(final: String) -> String {
        let shown = emitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final.hasPrefix(shown) else { return "" }
        return String(final.dropFirst(shown.count))
    }
}

final class AfterThinkingConstraint: GenerationConstraint {
    let inner: GenerationConstraint
    private var tail = ""
    private var done = false

    init(_ inner: GenerationConstraint) { self.inner = inner }

    private func split(_ piece: String) -> String? {
        let text = tail + piece
        guard let close = text.range(of: "</think>") else { return nil }
        return String(text[close.upperBound...])
    }

    func allows(_ piece: String) -> Bool {
        guard !done else { return inner.allows(piece) }
        guard let rest = split(piece) else { return true }
        return rest.isEmpty || inner.allows(rest)
    }

    func allows(_ piece: String, thenPartial partial: [UInt8]) -> Bool {
        guard !done else { return inner.allows(piece, thenPartial: partial) }
        guard let rest = split(piece) else { return true }
        return inner.allows(rest, thenPartial: partial)
    }

    func accept(_ piece: String) {
        guard !done else {
            inner.accept(piece)
            return
        }
        if let rest = split(piece) {
            done = true
            if !rest.isEmpty { inner.accept(rest) }
        } else {
            tail = String((tail + piece).suffix(8))
        }
    }

    var isComplete: Bool { done && inner.isComplete }
    var canEnd: Bool { done && inner.canEnd }
}

private final class ReplyCollector {
    var splitter = ThinkingSplitter()
    var gate: ToolGate
    var thinking = ""
    var content = ""
    let splitThinking: Bool
    let keepThinking: Bool
    let streamContent: Bool
    let onDelta: (ModelDelta) -> Void

    init(
        gate: ToolGate, splitThinking: Bool, keepThinking: Bool, streamContent: Bool,
        onDelta: @escaping (ModelDelta) -> Void
    ) {
        self.gate = gate
        self.splitThinking = splitThinking
        self.keepThinking = keepThinking
        self.streamContent = streamContent
        self.onDelta = onDelta
    }

    func feed(_ piece: String) {
        if splitThinking { take(splitter.feed(piece)) } else { contentPiece(piece) }
    }

    func finish() {
        if splitThinking { take(splitter.finish()) }
    }

    private func take(_ parts: [ThinkingSplitter.Part]) {
        for part in parts {
            switch part {
            case .thinking(let text):
                thinking += text
                if keepThinking { onDelta(.thinking(text)) }
            case .content(let text):
                contentPiece(text)
            }
        }
    }

    private func contentPiece(_ text: String) {
        content += text
        guard streamContent else { return }
        let ready = gate.feed(text)
        if !ready.isEmpty { onDelta(.content(ready)) }
    }
}

extension NativeModelServer {
    func execute(
        _ request: ModelRequest, endpoint: String, traceparent: String?, writer: HTTPStreamWriter?, plans: Bool,
        onDelta: @escaping (ModelDelta) -> Void = { _ in }
    ) throws -> ModelReply {
        if let (provider, model) = SubscriptionModels.parse(request.model) {
            try NativeModelServer.requirePlans(request, plans)
            return try executePlan(
                request, provider: provider, model: model, endpoint: endpoint, traceparent: traceparent,
                onDelta: onDelta)
        }
        var replied = false
        do {
            return try executeNative(request, endpoint: endpoint, traceparent: traceparent, writer: writer) { delta in
                replied = true
                onDelta(delta)
            }
        } catch let error as RuntimeError where error.statusCode == 502 && !replied && splitModelBroke(request.model) {
            RuntimeLog.write("cluster: \(request.model) lost a Mac before replying; loading it again without that Mac")
            return try executeNative(
                request, endpoint: endpoint, traceparent: traceparent, writer: writer, onDelta: onDelta)
        }
    }

    func splitModelBroke(_ rawName: String) -> Bool {
        guard let name = try? NativeModelStore.normalize(rawName).name else { return false }
        return lockedLoaded { $0[name]?.isBroken ?? false }
    }

    private func executeNative(
        _ request: ModelRequest, endpoint: String, traceparent: String?, writer: HTTPStreamWriter?,
        onDelta: @escaping (ModelDelta) -> Void
    ) throws -> ModelReply {
        let started = Date()
        let (values, profile) = settings(request)
        let item = try load(
            request.model, contextLength: values["num_ctx"].clampedInt(), keepAlive: keepAlive(request.keepAlive))
        let loadDuration = Date().timeIntervalSince(started)
        let engine = item.engine
        var options = NativeModelServer.options(.object(values))
        if values["num_predict"].isUndefined { options.maxTokens = -1 }

        var messages = request.messages
        if request.rawPrompt == nil {
            var head: [RichMessage] = []
            if messages.first?.role == .system {
                head.append(messages.removeFirst())
            } else if let system = profile["system"].stringValue, !system.isEmpty {
                head.append(RichMessage(role: .system, content: system))
            }
            let opening = profile["messages"].array.map {
                RichMessage(
                    role: ChatMessage.Role(rawValue: $0["role"].stringValue ?? "user") ?? .user,
                    content: $0["content"].stringValue ?? "")
            }
            messages = head + opening + messages
        }

        let tools = request.rawPrompt == nil ? request.effectiveTools : []
        var forced: [ToolSpec] = []
        switch request.toolChoice {
        case .required: forced = tools
        case .named(let name):
            forced = tools.filter { $0.name == name }
            if forced.isEmpty { throw requestError("tool_choice names \(name), which isn't one of the tools.", 400) }
        default: break
        }
        var constraint: GenerationConstraint?
        if !forced.isEmpty {
            constraint = JSONConstraint(schema: NativeModelServer.callSchema(forced))
        } else {
            switch request.format {
            case .json: constraint = JSONConstraint(requireObject: true)
            case .schema(let node): constraint = JSONConstraint(schema: node)
            case .text: break
            }
        }
        var think = request.think
        let splitThinking = request.rawPrompt == nil && engine.supportsThinking
        if let inner = constraint, splitThinking {
            if think == true && forced.isEmpty { constraint = AfterThinkingConstraint(inner) } else { think = false }
        }
        options.constraint = constraint

        var text =
            request.rawPrompt
            ?? ChatTools.render(
                engine.chatTemplate, messages: messages, tools: tools, defaultSystem: engine.defaultSystemPrompt,
                think: think, supportsThinking: engine.supportsThinking)
        var tokens = engine.tokenizer.encode(text, addSpecial: true, parseSpecial: true)
        let budget = item.contextLength - max(64, min(1024, item.contextLength / 8))
        if tokens.count > budget, request.rawPrompt == nil {
            var trimmed = messages
            let floor = trimmed.first?.role == .system ? 1 : 0
            while tokens.count > budget, trimmed.count > floor + 1 {
                trimmed.remove(at: floor)
                while trimmed.count > floor + 1, trimmed[floor].role == .tool { trimmed.remove(at: floor) }
                text = ChatTools.render(
                    engine.chatTemplate, messages: trimmed, tools: tools, defaultSystem: engine.defaultSystemPrompt,
                    think: think, supportsThinking: engine.supportsThinking)
                tokens = engine.tokenizer.encode(text, addSpecial: true, parseSpecial: true)
            }
            messages = trimmed
        }
        let prefilledCall = !forced.isEmpty && engine.chatTemplate == .chatML
        if prefilledCall { tokens += engine.tokenizer.encode("<tool_call>\n", addSpecial: false, parseSpecial: true) }
        if tokens.count > item.contextLength - 8 {
            tokens = Array(tokens.suffix(max(1, item.contextLength / 2)))
        }
        let remaining = item.contextLength - tokens.count
        if options.maxTokens < 0 || options.maxTokens > remaining { options.maxTokens = max(1, remaining) }

        let input: JSON =
            request.rawPrompt.map { JSON($0) }
            ?? .array(messages.map { ["role": JSON($0.role.rawValue), "content": JSON($0.content)] })
        let prepared = Prepared(
            item: item, tokens: tokens, options: options, loadDuration: loadDuration, started: started,
            endpoint: endpoint, traceInput: input, traceparent: traceparent)
        let collector = ReplyCollector(
            gate: ToolGate(active: !tools.isEmpty, template: engine.chatTemplate),
            splitThinking: splitThinking, keepThinking: think != false, streamContent: forced.isEmpty, onDelta: onDelta)
        let result = try run(prepared, writer: writer) { piece in collector.feed(piece) }
        collector.finish()

        var reply = ModelReply(model: request.model)
        let names = tools.map(\.name)
        if !forced.isEmpty {
            let body = collector.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = ChatTools.parse("<tool_call>\n\(body)\n</tool_call>", known: names).calls.first {
                reply.toolCalls = [call]
            } else {
                reply.content = collector.content
                onDelta(.content(collector.content))
            }
        } else if tools.isEmpty {
            reply.content = collector.content
        } else {
            let parsed = ChatTools.parse(collector.content, known: names)
            reply.content = parsed.content
            reply.toolCalls = parsed.calls
            let rest = collector.gate.remainder(final: parsed.content)
            if !rest.isEmpty { onDelta(.content(rest)) }
        }
        reply.thinking = think == false ? "" : collector.thinking
        reply.promptTokens = result.promptTokenCount
        reply.cachedTokens = result.reusedPromptTokens
        reply.outputTokens = result.tokens.count
        if !reply.toolCalls.isEmpty {
            reply.finish = "tool_calls"
        } else {
            switch result.stopReason {
            case .length: reply.finish = "length"
            case .cancelled: reply.finish = "cancelled"
            case .stopSequence: reply.finish = "stop_sequence"
            case .endOfGeneration: reply.finish = "stop"
            }
        }
        reply.timings = timings(result, load: loadDuration, started: started)
        return reply
    }

    private func settings(_ request: ModelRequest) -> (values: JSONObject, profile: JSON) {
        let profile = store.entry(request.model)?.manifest["profile"] ?? .undefined
        var values = profile["parameters"].object
        for (key, value) in request.options { values[key] = value }
        return (values, profile)
    }

    static let planRefusalMessage =
        "Plan models (claude:…, codex:…) answer RoachNet and requests with its owner's API token. "
        + "Give this client an admin RoachClaw API token (Settings › RoachClaw › API tokens) as its API key, or pick a local model."

    static func requirePlans(_ request: ModelRequest, _ plans: Bool) throws {
        if !plans, SubscriptionModels.parse(request.model) != nil { throw requestError(planRefusalMessage, 403) }
    }

    func preflight(_ request: ModelRequest) throws {
        guard SubscriptionModels.parse(request.model) == nil else { return }
        let values = settings(request).values
        _ = try load(
            request.model, contextLength: values["num_ctx"].clampedInt(), keepAlive: keepAlive(request.keepAlive))
    }

    static func callSchema(_ tools: [ToolSpec]) -> JSONSchemaNode {
        let anyObject = JSONSchemaNode.object(properties: [:], order: [], required: [], additional: true)
        var arguments = anyObject
        if tools.count == 1, let parameters = try? JSON.parse(tools[0].parameters),
            let node = try? ModelRequest.schema(parameters)
        {
            if case .object = node { arguments = node }
        }
        return .object(
            properties: ["name": .literals(tools.map { JSON($0.name).serialized() }), "arguments": arguments],
            order: ["name", "arguments"], required: ["name", "arguments"], additional: false)
    }

    private func executePlan(
        _ request: ModelRequest, provider: SubscriptionModels.Provider, model: String, endpoint: String,
        traceparent: String?, onDelta: @escaping (ModelDelta) -> Void
    ) throws -> ModelReply {
        guard let subscriptions else { throw requestError("Plan models aren't available in this runtime.", 404) }
        let started = Date()
        let tools = request.effectiveTools
        var notes: [String] = []
        if !tools.isEmpty {
            var note =
                "You can call these functions:\n" + tools.map(\.definition).joined(separator: "\n")
                + "\n\nTo call one, reply with only <tool_call>{\"name\": <function-name>, \"arguments\": <args-json-object>}</tool_call>."
            switch request.toolChoice {
            case .required: note += " You must call one of them now."
            case .named(let name): note += " You must call \(name) now."
            default: break
            }
            notes.append(note)
        }
        switch request.format {
        case .json: notes.append("Reply with only a JSON object: no prose and no code fences.")
        case .schema:
            notes.append(
                "Reply with only a JSON value that matches this JSON Schema, with no prose and no code fences:\n"
                    + request.formatSource.serialized())
        case .text: break
        }
        var messages: [JSON] = []
        var system = request.messages.first?.role == .system ? request.messages[0].content : ""
        if !notes.isEmpty { system += (system.isEmpty ? "" : "\n\n") + notes.joined(separator: "\n\n") }
        if !system.isEmpty { messages.append(["role": "system", "content": JSON(system)]) }
        if let raw = request.rawPrompt { messages.append(["role": "user", "content": JSON(raw)]) }
        for message in request.messages where message.role != .system {
            var content = message.content
            for call in message.toolCalls {
                content +=
                    "<tool_call>{\"name\": \(JSON(call.name).serialized()), \"arguments\": \(call.arguments)}</tool_call>"
            }
            if message.role == .tool {
                messages.append([
                    "role": "user", "content": JSON("Result of \(message.toolName ?? "the function"): \(content)"),
                ])
            } else {
                messages.append(["role": JSON(message.role.rawValue), "content": JSON(content)])
            }
        }

        let trace = subscriptionTrace(
            name: "\(endpoint) \(request.model)", model: request.model, provider: provider, input: .array(messages),
            traceparent: traceparent)
        var gate = ToolGate(active: !tools.isEmpty, template: .plain)
        let structured = request.format != .text
        let answer: SubscriptionModels.Reply
        do {
            answer = try subscriptions.reply(provider, model: model, messages: messages) { piece in
                guard !structured else { return }
                let ready = gate.feed(piece)
                if !ready.isEmpty { onDelta(.content(ready)) }
            }
            if let first = answer.firstTokenMs { trace?.observation.markFirstToken(at: first) }
            var metadata = JSONObject([
                ("engine", JSON(provider == .claude ? "claude-code" : "codex")), ("plan", JSON(provider.label)),
            ])
            if let usd = answer.apiEquivalentUsd { metadata["apiEquivalentUsd"] = JSON(usd) }
            trace?.observation.end(
                output: trace?.enrichesParent == true ? .null : JSON(answer.text), usage: answer.usage,
                cost: TraceCost(totalUsd: 0, status: "included", billingType: "subscription_included"),
                metadata: metadata, model: answer.model)
            trace?.ownTrace?.end(status: "ok", output: JSON(answer.text))
        } catch {
            let message = (error as? RuntimeError)?.message ?? "\(error)"
            trace?.observation.end(level: .error, statusMessage: message)
            trace?.ownTrace?.end(status: "error", message: message)
            throw error
        }

        var reply = ModelReply(model: request.model)
        if structured {
            reply.content = NativeModelServer.unfenced(answer.text)
            onDelta(.content(reply.content))
        } else if tools.isEmpty {
            reply.content = answer.text
        } else {
            let parsed = ChatTools.parse(answer.text, known: tools.map(\.name))
            reply.content = parsed.content
            reply.toolCalls = parsed.calls
            let rest = gate.remainder(final: parsed.content)
            if !rest.isEmpty { onDelta(.content(rest)) }
        }
        reply.promptTokens = answer.usage.inputTokens
        reply.cachedTokens = answer.usage.cachedInputTokens
        reply.outputTokens = answer.usage.outputTokens
        reply.finish = reply.toolCalls.isEmpty ? "stop" : "tool_calls"
        reply.timings = JSONObject([
            ("total_duration", JSON(Double(Int64(Date().timeIntervalSince(started) * 1_000_000_000)))),
            ("prompt_eval_count", JSON(answer.usage.inputTokens - answer.usage.cachedInputTokens)),
            ("eval_count", JSON(answer.usage.outputTokens)),
        ])
        return reply
    }

    static func unfenced(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        trimmed = String(trimmed.drop { $0 != "\n" }.dropFirst())
        if trimmed.hasSuffix("```") { trimmed = String(trimmed.dropLast(3)) }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func argumentsObject(_ text: String) -> JSON {
        (try? JSON.parse(text)).flatMap { $0.isObject ? $0 : nil } ?? JSON(text)
    }

    static func created() -> JSON { JSON(Double(Int(Date().timeIntervalSince1970))) }
}
