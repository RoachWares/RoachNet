import Foundation

final class OrgCLIStream {
    let kind: OrgCLIKind
    private let trace: ObservationHandle?
    private let log: (String) -> Void
    private let lock = NSLock()

    private(set) var sessionId: String?
    private(set) var model: String?
    private(set) var finalText: String?
    private(set) var lastText = ""
    private(set) var usage = TraceUsage()
    private(set) var turnUsage = TraceUsage()
    private(set) var costUsd: Double?
    private(set) var billing: String?
    private(set) var errorMessage: String?
    private(set) var reportedFailure = false
    private(set) var turns = 0
    private(set) var toolCalls = 0
    private(set) var rateLimit: JSON = .null
    private(set) var sawResult = false

    private var generation: ObservationHandle?
    private var generationKey: String?
    private var generationUsage = TraceUsage()
    private var generationText = ""
    private var tools: [String: ObservationHandle] = [:]
    private let configuredModel: String?

    private var stepCost: Double?
    private var lastGeneration: ObservationHandle?

    init(
        kind: OrgCLIKind, trace: ObservationHandle?, configuredModel: String?, billing: String?,
        log: @escaping (String) -> Void
    ) {
        self.kind = kind
        self.trace = trace
        self.configuredModel = configuredModel
        self.billing = billing
        self.log = log
    }

    static func dollars(_ value: JSON) -> Double? {
        guard let number = value.numberValue, number.isFinite, number >= 0 else { return nil }
        return min(number, Double(OrgLimits.maxAmount) / 100)
    }

    func applyReportedTotal(_ usd: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let lastGeneration else { return }
        lastGeneration.update { $0.cost = TraceCost(totalUsd: usd, status: "reported", billingType: "metered_api") }
        lastGeneration.tracer.rollUp(lastGeneration.traceId)
    }

    var totalUsage: TraceUsage { usage.isEmpty ? turnUsage : usage }

    var reply: String? {
        let text = (finalText?.nilIfEmpty ?? lastText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func feed(_ line: Substring) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard trimmed.hasPrefix("{"), let event = try? JSON.parse(String(trimmed)), event.isObject else {
            log(String(trimmed.prefix(2_000)))
            return
        }
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .claude: claude(event)
        case .cursor: cursor(event)
        case .codex: codex(event)
        case .gemini: gemini(event)
        case .opencode: opencode(event)
        }
    }

    func finish(failed: Bool, message: String?) {
        lock.lock()
        defer { lock.unlock() }
        endGeneration(level: failed ? .error : nil, message: failed ? message : nil)
        for (_, tool) in tools { tool.end(level: .warning, statusMessage: "The run ended before this call finished.") }
        tools.removeAll()
    }

    private func claude(_ event: JSON) {
        switch event["type"].stringValue ?? "" {
        case "system" where event["subtype"].stringValue == "init":
            sessionId = event["session_id"].stringValue ?? sessionId
            model = event["model"].stringValue ?? model
            if let source = event["apiKeySource"].stringValue {
                billing = source == "none" ? "subscription_included" : "metered_api"
            }
            log("session \(sessionId ?? "?") · \(model ?? "default model")")
        case "assistant":
            let message = event["message"]
            let key = message["id"].stringValue ?? "turn-\(turns + 1)"
            if key != generationKey {
                endGeneration()
                startGeneration(key: key, model: message["model"].stringValue ?? model)
            }
            for block in message["content"].array {
                switch block["type"].stringValue ?? "" {
                case "text":
                    let text = block["text"].stringValue ?? ""
                    generationText += text
                    if !text.isEmpty {
                        lastText = text
                        log("assistant: \(text.prefix(1_500))")
                    }
                case "tool_use":
                    let id = block["id"].stringValue ?? "tool-\(toolCalls + 1)"
                    startTool(id: id, name: block["name"].stringValue ?? "tool", input: block["input"])
                default: break
                }
            }
            let tokens = message["usage"]
            if tokens.isObject {
                let read = (tokens["cache_read_input_tokens"].clampedInt(0...(1 << 50)) ?? 0)
                let created = (tokens["cache_creation_input_tokens"].clampedInt(0...(1 << 50)) ?? 0)
                generationUsage = TraceUsage(
                    inputTokens: (tokens["input_tokens"].clampedInt(0...(1 << 50)) ?? 0) + read + created,
                    outputTokens: (tokens["output_tokens"].clampedInt(0...(1 << 50)) ?? 0), cachedInputTokens: read)
            }
        case "user":
            for block in event["message"]["content"].array where block["type"].stringValue == "tool_result" {
                let id = block["tool_use_id"].stringValue ?? ""
                let content = block["content"].stringValue.map { JSON($0) } ?? block["content"]
                endTool(id: id, output: content, failed: block["is_error"].boolValue == true)
            }
        case "rate_limit_event":
            rateLimit = event["rate_limit_info"]
        case "result":
            sawResult = true
            endGeneration()
            sessionId = event["session_id"].stringValue ?? sessionId
            finalText = event["result"].stringValue ?? finalText
            costUsd = Self.dollars(event["total_cost_usd"]) ?? costUsd
            turns = event["num_turns"].clampedInt(0...(1 << 50)) ?? turns
            let tokens = event["usage"]
            if tokens.isObject {
                let read = (tokens["cache_read_input_tokens"].clampedInt(0...(1 << 50)) ?? 0)
                let created = (tokens["cache_creation_input_tokens"].clampedInt(0...(1 << 50)) ?? 0)
                usage = TraceUsage(
                    inputTokens: (tokens["input_tokens"].clampedInt(0...(1 << 50)) ?? 0) + read + created,
                    outputTokens: (tokens["output_tokens"].clampedInt(0...(1 << 50)) ?? 0), cachedInputTokens: read)
            }
            if event["is_error"].boolValue == true || (event["subtype"].stringValue.map { $0 != "success" } ?? false) {
                reportedFailure = true
                errorMessage = event["result"].stringValue ?? event["subtype"].stringValue
            }
        default:
            break
        }
    }

    private func cursor(_ event: JSON) {
        switch event["type"].stringValue ?? "" {
        case "system" where event["subtype"].stringValue == "init":
            sessionId = event["session_id"].stringValue ?? sessionId
            model = event["model"].stringValue ?? model
            if let source = event["apiKeySource"].stringValue {
                billing = source == "login" ? "subscription_included" : "metered_api"
            }
            if generation == nil { startGeneration(key: "cursor", model: model) }
        case "assistant":
            if generation == nil { startGeneration(key: "cursor", model: model) }
            guard event["model_call_id"].isUndefined else { return }
            let text = event["message"]["content"].array.compactMap {
                $0["type"].stringValue == "text" ? $0["text"].stringValue : nil
            }.joined()
            if !text.isEmpty {
                lastText = text
                generationText += text
                log("assistant: \(text.prefix(1_500))")
            }
        case "tool_call":
            let id = event["call_id"].stringValue ?? "tool-\(toolCalls + 1)"
            let call = event["tool_call"]
            var key = "tool"
            for (name, _) in call.object {
                key = name
                break
            }
            let body = call[key]
            let name =
                key.hasSuffix("ToolCall") ? String(key.dropLast("ToolCall".count)) : (body["name"].stringValue ?? key)
            if event["subtype"].stringValue == "started" {
                startTool(id: id, name: name, input: body["args"].isUndefined ? body["arguments"] : body["args"])
            } else {
                let result = body["result"]
                endTool(
                    id: id, output: result, failed: !result["error"].isUndefined || !result["failure"].isUndefined,
                    name: name)
            }
        case "result":
            sawResult = true
            endGeneration()
            sessionId = event["session_id"].stringValue ?? sessionId
            finalText = event["result"].stringValue ?? finalText
            if event["is_error"].boolValue == true {
                reportedFailure = true
                errorMessage = event["result"].stringValue
            }
        default:
            break
        }
    }

    private func codex(_ event: JSON) {
        switch event["type"].stringValue ?? "" {
        case "thread.started":
            sessionId = event["thread_id"].stringValue ?? sessionId
            log("thread \(sessionId ?? "?")")
        case "turn.started":
            endGeneration()
            startGeneration(key: "turn-\(turns + 1)", model: configuredModel)
        case "item.started", "item.updated":
            let item = event["item"]
            if let (name, input) = codexTool(item), let id = item["id"].stringValue, tools[id] == nil {
                startTool(id: id, name: name, input: input)
            }
        case "item.completed":
            let item = event["item"]
            let id = item["id"].stringValue ?? "item-\(toolCalls + 1)"
            switch item["type"].stringValue ?? "" {
            case "agent_message":
                let text = item["text"].stringValue ?? ""
                if !text.isEmpty {
                    lastText = text
                    generationText += text
                    log("assistant: \(text.prefix(1_500))")
                }
            case "reasoning":
                break
            case "error":
                let message = item["message"].stringValue ?? "error"
                log("codex: \(message.prefix(500))")
                trace?.event("codex notice", level: .warning, input: JSON(String(message.prefix(1_000))))
            default:
                if let (name, input) = codexTool(item) {
                    if tools[id] == nil { startTool(id: id, name: name, input: input) }
                    let status = item["status"].stringValue ?? ""
                    let exit = item["exit_code"].numberValue
                    var output = item["aggregated_output"]
                    if output.isUndefined { output = item["result"].isUndefined ? item["changes"] : item["result"] }
                    endTool(
                        id: id, output: output,
                        failed: status == "failed" || status == "declined" || (exit.map { $0 != 0 } ?? false))
                }
            }
        case "turn.completed":
            let tokens = event["usage"]
            let turn = TraceUsage(
                inputTokens: (tokens["input_tokens"].clampedInt(0...(1 << 50)) ?? 0),
                outputTokens: (tokens["output_tokens"].clampedInt(0...(1 << 50)) ?? 0),
                cachedInputTokens: (tokens["cached_input_tokens"].clampedInt(0...(1 << 50)) ?? 0))
            generationUsage = turn
            usage = usage + turn
            endGeneration()
        case "turn.failed":
            reportedFailure = true
            errorMessage = event["error"]["message"].stringValue ?? errorMessage
            endGeneration(level: .error, message: errorMessage)
        case "error":
            errorMessage = event["message"].stringValue ?? errorMessage
        default:
            break
        }
    }

    private func codexTool(_ item: JSON) -> (String, JSON)? {
        switch item["type"].stringValue ?? "" {
        case "command_execution": return ("shell", ["command": item["command"]])
        case "file_change": return ("apply_patch", ["changes": item["changes"]])
        case "mcp_tool_call":
            return ("\(item["server"].stringValue ?? "mcp").\(item["tool"].stringValue ?? "tool")", item["arguments"])
        case "web_search": return ("web_search", ["query": item["query"]])
        default: return nil
        }
    }

    private func gemini(_ event: JSON) {
        switch event["type"].stringValue ?? "" {
        case "init":
            sessionId = event["session_id"].stringValue ?? sessionId
            model = event["model"].stringValue ?? model
            startGeneration(key: "gemini", model: model)
        case "message" where event["role"].stringValue == "assistant":
            if generation == nil { startGeneration(key: "gemini", model: model) }
            let text = event["content"].stringValue ?? ""
            if event["delta"].boolValue == true { lastText += text } else if !text.isEmpty { lastText = text }
            generationText = lastText
        case "tool_use":
            startTool(
                id: event["tool_id"].stringValue ?? "tool-\(toolCalls + 1)",
                name: event["tool_name"].stringValue ?? "tool", input: event["parameters"])
        case "tool_result":
            let failed = event["status"].stringValue.map { $0 != "success" } ?? false
            endTool(
                id: event["tool_id"].stringValue ?? "",
                output: event["output"].isUndefined ? event["error"] : event["output"], failed: failed)
        case "error":
            let message = event["message"].stringValue ?? "error"
            log("gemini: \(message.prefix(500))")
            trace?.event("gemini notice", level: .warning, input: JSON(String(message.prefix(1_000))))
        case "result":
            sawResult = true
            let stats = event["stats"]
            usage = TraceUsage(
                inputTokens: (stats["input_tokens"].clampedInt(0...(1 << 50)) ?? stats["prompt_tokens"].clampedInt(
                    0...(1 << 50)) ?? 0),
                outputTokens: (stats["output_tokens"].clampedInt(0...(1 << 50)) ?? stats["candidates_tokens"]
                    .clampedInt(0...(1 << 50)) ?? 0),
                cachedInputTokens: (stats["cached"].clampedInt(0...(1 << 50)) ?? stats["cached_tokens"].clampedInt(
                    0...(1 << 50)) ?? 0))
            generationUsage = usage
            costUsd = Self.dollars(stats["total_cost_usd"]) ?? costUsd
            if let status = event["status"].stringValue, status != "success" {
                reportedFailure = true
                errorMessage = event["error"]["message"].stringValue ?? event["error"].stringValue ?? status
            }
            endGeneration()
        default:
            break
        }
    }

    private func opencode(_ event: JSON) {
        sessionId = event["sessionID"].stringValue ?? sessionId
        let part = event["part"]
        switch event["type"].stringValue ?? "" {
        case "step_start":
            endGeneration()
            startGeneration(key: part["id"].stringValue ?? "step-\(turns + 1)", model: configuredModel)
        case "text":
            let text = part["text"].stringValue ?? ""
            if !text.isEmpty {
                lastText = text
                generationText += text
                log("assistant: \(text.prefix(1_500))")
            }
        case "tool_use":
            let id = part["callID"].stringValue ?? part["id"].stringValue ?? "tool-\(toolCalls + 1)"
            let state = part["state"]
            startTool(id: id, name: part["tool"].stringValue ?? "tool", input: state["input"])
            let failed = state["status"].stringValue == "error"
            endTool(id: id, output: failed ? state["error"] : state["output"], failed: failed)
        case "step_finish":
            let tokens = part["tokens"]
            let step = TraceUsage(
                inputTokens: (tokens["input"].clampedInt(0...(1 << 50)) ?? 0)
                    + (tokens["cache"]["read"].clampedInt(0...(1 << 50)) ?? 0),
                outputTokens: (tokens["output"].clampedInt(0...(1 << 50)) ?? 0)
                    + (tokens["reasoning"].clampedInt(0...(1 << 50)) ?? 0),
                cachedInputTokens: (tokens["cache"]["read"].clampedInt(0...(1 << 50)) ?? 0))
            generationUsage = step
            usage = usage + step
            if let cost = Self.dollars(part["cost"]) {
                costUsd = min((costUsd ?? 0) + cost, Double(OrgLimits.maxAmount) / 100)
                stepCost = cost
            }
            if part["reason"].stringValue == "stop" { sawResult = true }
            endGeneration()
        case "error":
            reportedFailure = true
            errorMessage =
                event["error"]["data"]["message"].stringValue ?? event["message"].stringValue
                ?? event["error"]["name"].stringValue
        default:
            break
        }
    }

    private func startGeneration(key: String, model: String?) {
        turns += 1
        generationKey = key
        generationUsage = TraceUsage()
        generationText = ""
        generation = trace?.child(
            .generation, "turn \(turns)", model: model ?? self.model ?? configuredModel, provider: kind.provider)
    }

    private func endGeneration(level: TraceLevel? = nil, message: String? = nil) {
        guard let generation else {
            generationKey = nil
            return
        }
        turnUsage = turnUsage + generationUsage
        generation.end(
            output: generationText.isEmpty ? .null : JSON(generationText),
            usage: generationUsage.isEmpty ? nil : generationUsage, cost: turnCost(), level: level,
            statusMessage: message,
            model: model)
        lastGeneration = generation
        self.generation = nil
        generationKey = nil
        stepCost = nil
    }

    private func turnCost() -> TraceCost? {
        switch billing {
        case "subscription_included":
            return TraceCost(totalUsd: 0, status: "included", billingType: "subscription_included")
        case "metered_api":
            if let stepCost { return TraceCost(totalUsd: stepCost, status: "reported", billingType: "metered_api") }
            if kind == .claude { return nil }
            return trace?.tracer.price(
                model: model ?? configuredModel, usage: generationUsage, billingType: "metered_api")
        default:
            return nil
        }
    }

    private func startTool(id: String, name: String, input: JSON) {
        toolCalls += 1
        let parent = generation ?? trace
        tools[id] = parent?.child(.tool, name, input: input)
        log("tool: \(name) \(input.serialized().prefix(400))")
    }

    private func endTool(id: String, output: JSON, failed: Bool, name: String? = nil) {
        guard let tool = tools.removeValue(forKey: id) else { return }
        var shown = output
        if let text = output.stringValue, text.count > 8_000 { shown = JSON(String(text.prefix(8_000)) + "…") }
        tool.end(output: shown, level: failed ? .warning : nil, statusMessage: failed ? "The tool call failed." : nil)
    }
}
