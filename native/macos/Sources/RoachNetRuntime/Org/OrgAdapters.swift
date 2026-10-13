import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-run services handed to an adapter: logging, cancellation, and an
/// agent-scoped actor for acting on the company through OrgService.
final class OrgRunIO {
    let service: OrgService
    unowned let engine: OrgEngine
    let context: OrgRunContext
    let actor: OrgActor
    /// The run's root observation in RoachTrace (nil when tracing is off).
    var trace: ObservationHandle?

    init(service: OrgService, engine: OrgEngine, context: OrgRunContext) {
        self.service = service
        self.engine = engine
        self.context = context
        actor = OrgActor(kind: .agent, userId: nil, agentId: context.agent.id, companyId: context.company.id, runId: context.run.id, source: "run")
    }

    var isCancelled: Bool { engine.isCancelled(context.run.id) }
    var timedOut: Bool { Date() >= context.deadline }
    var remainingMs: Int { max(1_000, Int(context.deadline.timeIntervalSinceNow * 1_000)) }

    func log(_ stream: String, _ text: String) {
        service.store.appendRunLog(companyId: context.company.id, runId: context.run.id, stream: stream, text: text)
    }

    func secret(_ reference: String?) -> String? {
        guard let reference, !reference.isEmpty else { return nil }
        let key = reference.hasPrefix("secret:") ? String(reference.dropFirst(7)) : reference
        let value = service.store.readSecret(companyId: context.company.id, key: key)
        // Whatever an adapter reads stays out of traces.
        service.runtime.tracer.redactor.register(value)
        return value
    }

    /// Price for one call, for the trace: local is free, a configured rate is an
    /// estimate, the person's pricing table comes next, else unpriced.
    func traceCost(_ usage: OrgUsage, billingType: String, centsPerMillion: (input: Int, output: Int)?) -> TraceCost {
        if billingType == "local" { return .local }
        if let rate = centsPerMillion {
            let cents = (Double(usage.inputTokens) * Double(rate.input) + Double(usage.outputTokens) * Double(rate.output)) / 1_000_000
            return TraceCost(totalUsd: cents / 100, status: "estimated", billingType: billingType)
        }
        return service.runtime.tracer.price(model: usage.model, usage: usage.traceUsage, billingType: billingType)
    }
}

protocol OrgAdapter {
    func run(_ context: OrgRunContext, _ io: OrgRunIO) -> OrgRunResult
}

enum OrgAdapters {
    static func make(_ type: String) -> OrgAdapter {
        switch type {
        case "openai_compatible": return OrgAgentLoopAdapter(mode: .openAICompatible)
        case "http": return OrgHTTPAdapter()
        case "process": return OrgProcessAdapter()
        default:
            if let kind = OrgCLIKind.from(type) { return OrgCLIAdapter(kind: kind) }
            return OrgAgentLoopAdapter(mode: .roachClawLocal)
        }
    }

    /// https anywhere, or plain http only to this machine.
    static func allowedEndpoint(_ raw: String, loopbackOnly: Bool = false) -> Bool {
        guard let url = WebURL(raw) else { return false }
        let host = url.bareHostname.lowercased()
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if loopbackOnly { return (url.scheme == "http" || url.scheme == "https") && loopback }
        return url.scheme == "https" || (url.scheme == "http" && loopback)
    }
}

// MARK: - Agent loop (roachclaw_local and openai_compatible)

/// A JSON-action agent loop. The model answers with one JSON action per turn;
/// RoachNet executes it through OrgService as the agent and feeds back the result.
struct OrgAgentLoopAdapter: OrgAdapter {
    enum Mode { case roachClawLocal, openAICompatible }
    let mode: Mode

    struct ChatTurn { var content: String; var usage: OrgUsage }

    func run(_ context: OrgRunContext, _ io: OrgRunIO) -> OrgRunResult {
        let config = OrgBody(context.agent.adapterConfig)
        let maxSteps = min(max(config.int("maxSteps") ?? 6, 1), 24)
        let runtime = io.service.runtime
        let model = config.string("model") ?? runtime.defaultModel
        var baseURL: String
        var headers: [String: String] = ["content-type": "application/json"]
        switch mode {
        case .roachClawLocal:
            baseURL = config.string("baseUrl", max: 512) ?? runtime.modelServerBaseUrl
            guard OrgAdapters.allowedEndpoint(baseURL, loopbackOnly: true) else {
                return .failure("roachclaw_local agents only talk to a model server on this Mac.", code: "adapter_config")
            }
            if config.string("baseUrl") == nil { _ = runtime.ensureOllama() }
        case .openAICompatible:
            guard let configured = config.string("baseUrl", max: 512), OrgAdapters.allowedEndpoint(configured) else {
                return .failure("openai_compatible agents need an https baseUrl (or http on this Mac).", code: "adapter_config")
            }
            baseURL = configured
            if let key = io.secret(config.string("apiKeySecret")) { headers["authorization"] = "Bearer \(key)" }
        }
        while baseURL.hasSuffix("/") { baseURL.removeLast() }

        var messages: [JSON] = [["role": "system", "content": JSON(systemPrompt(context))], ["role": "user", "content": JSON(taskPrompt(context))]]
        // A RoachClaw agent can think with a plan model (claude:…, codex:…) served by RoachNet.
        let plan = mode == .roachClawLocal ? SubscriptionModels.parse(model)?.0 : nil
        let localBilling = plan == nil ? "local" : "subscription_included"
        var usage = OrgUsage(provider: plan?.kind.provider ?? (mode == .roachClawLocal ? "roachclaw_local" : (config.string("provider") ?? "openai_compatible")), model: model)
        var summary: String?
        var currentIssue = context.issue
        if let issue = currentIssue, ["todo", "backlog", "blocked"].contains(issue.status) {
            _ = try? io.service.checkoutIssue(io.actor, context.company.id, issue.id, OrgBody(.object(JSONObject())))
        }
        for step in 0..<maxSteps {
            if io.isCancelled { var result = OrgRunResult(); result.status = "cancelled"; result.usage = usage; return result }
            if io.timedOut { var result = OrgRunResult.failure("The run hit its time limit.", code: "timeout"); result.status = "timed_out"; result.usage = usage; return result }
            let turn: ChatTurn
            let generation = io.trace?.child(.generation, "step \(step + 1)", input: .array(messages), model: model, provider: usage.provider,
                                             modelParameters: ["temperature": JSON(config.raw["temperature"].numberValue ?? 0.2)])
            var callHeaders = headers
            if let generation { callHeaders["traceparent"] = generation.traceparent }
            do {
                turn = try chat(baseURL: baseURL, headers: callHeaders, model: model, messages: messages, config: config, timeoutMs: io.remainingMs)
                var stepUsage = turn.usage
                stepUsage.model = model
                let rate = config.amount("inputCentsPerMillion").flatMap { input in config.amount("outputCentsPerMillion").map { (input, $0) } }
                generation?.end(output: JSON(turn.content), usage: stepUsage.traceUsage,
                                cost: plan != nil ? TraceCost(totalUsd: 0, status: "included", billingType: "subscription_included")
                                    : io.traceCost(stepUsage, billingType: mode == .roachClawLocal ? "local" : "metered_api", centsPerMillion: rate))
            } catch {
                generation?.end(level: .error, statusMessage: "Model call failed: \(error)")
                io.log("error", "model call failed: \(error)")
                var result = OrgRunResult.failure("Model call failed: \(error)", code: "model_error")
                result.usage = usage
                return result
            }
            usage.inputTokens = usage.inputTokens.orgAdding(turn.usage.inputTokens)
            usage.outputTokens = usage.outputTokens.orgAdding(turn.usage.outputTokens)
            io.log("assistant", turn.content)
            messages.append(["role": "assistant", "content": JSON(turn.content)])
            guard let action = OrgAgentLoopAdapter.extractAction(turn.content) else {
                summary = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let issue = currentIssue, let text = summary, !text.isEmpty {
                    _ = try? io.service.addComment(io.actor, context.company.id, issue.id, OrgBody(["body": JSON(text)]))
                }
                break
            }
            let name = action["action"].stringValue ?? "finish"
            if name == "finish" {
                summary = action["summary"].stringValue ?? summary
                if let issue = currentIssue, let text = summary, !text.isEmpty, action["comment"].boolValue != false {
                    _ = try? io.service.addComment(io.actor, context.company.id, issue.id, OrgBody(["body": JSON(text)]))
                }
                break
            }
            let tool = io.trace?.child(.tool, name, input: action)
            let outcome = perform(name, action, context, io, &currentIssue)
            tool?.end(output: outcome, level: outcome["ok"].boolValue == false ? .warning : nil,
                      statusMessage: outcome["ok"].boolValue == false ? outcome["error"].stringValue : nil)
            io.log("tool", "\(name): \(outcome.serialized())")
            messages.append(["role": "user", "content": JSON("Result of \(name): \(outcome.serialized())\n\nReply with your next JSON action (step \(step + 2) of \(maxSteps)).")])
        }
        var result = OrgRunResult()
        result.summary = summary ?? "Reached the step limit."
        result.usage = usage
        switch mode {
        case .roachClawLocal:
            result.billingType = localBilling; result.costStatus = plan == nil ? "reported" : "included"; result.costCents = 0
        case .openAICompatible:
            result.billingType = "metered_api"
            if let input = config.amount("inputCentsPerMillion"), let output = config.amount("outputCentsPerMillion") {
                let priced = usage.inputTokens.orgMultiplied(by: input).orgAdding(usage.outputTokens.orgMultiplied(by: output))
                result.costCents = min(priced.orgAdding(999_999) / 1_000_000, OrgLimits.maxAmount)
                result.costStatus = "estimated"
            } else {
                result.costStatus = "unpriced"
            }
        }
        return result
    }

    private func chat(baseURL: String, headers: [String: String], model: String, messages: [JSON], config: OrgBody, timeoutMs: Int) throws -> ChatTurn {
        let temperature = config.raw["temperature"].numberValue ?? 0.2
        switch mode {
        case .roachClawLocal:
            // The engine holds each reply to one well-formed action, so a small
            // local model can't wander into prose or broken JSON.
            let body: JSON = ["model": JSON(model), "messages": .array(messages), "stream": false, "format": OrgAgentLoopAdapter.actionSchema,
                              "options": ["temperature": JSON(temperature), "num_ctx": JSON(config.int("contextLength") ?? 4_096),
                                          "num_predict": JSON(config.int("maxOutputTokens") ?? 1_024)]]
            let response = try HTTPClient.request(baseURL + "/api/chat", method: "POST", headers: headers, body: body.serializedData(), timeoutMs: timeoutMs, maxResponseBytes: 8 << 20)
            guard (200..<300).contains(response.status) else { throw RuntimeError("model server returned \(response.status)") }
            let json = try JSON.parse(response.body)
            return ChatTurn(content: json["message"]["content"].stringValue ?? "",
                            usage: OrgUsage(inputTokens: (json["prompt_eval_count"].clampedInt(0...(1 << 50)) ?? 0), outputTokens: (json["eval_count"].clampedInt(0...(1 << 50)) ?? 0)))
        case .openAICompatible:
            let body: JSON = ["model": JSON(model), "messages": .array(messages), "temperature": JSON(temperature)]
            let response = try HTTPClient.request(baseURL + "/v1/chat/completions", method: "POST", headers: headers, body: body.serializedData(), timeoutMs: timeoutMs, maxResponseBytes: 8 << 20)
            guard (200..<300).contains(response.status) else { throw RuntimeError("provider returned \(response.status)") }
            let json = try JSON.parse(response.body)
            return ChatTurn(content: json["choices"][0]["message"]["content"].stringValue ?? "",
                            usage: OrgUsage(inputTokens: (json["usage"]["prompt_tokens"].clampedInt(0...(1 << 50)) ?? 0), outputTokens: (json["usage"]["completion_tokens"].clampedInt(0...(1 << 50)) ?? 0)))
        }
    }

    /// Every action the loop performs, as a JSON Schema for structured output.
    static let actionSchema: JSON = [
        "type": "object",
        "properties": [
            "action": ["enum": ["checkout", "comment", "set_status", "create_issue", "write_document", "request_approval", "hire_agent", "finish"]],
            "issue": ["type": "string"], "body": ["type": "string"],
            "status": ["enum": ["todo", "in_progress", "in_review", "done", "blocked"]],
            "comment": ["type": ["string", "boolean"]], "title": ["type": "string"], "description": ["type": "string"],
            "assignee": ["type": "string"], "priority": ["enum": ["critical", "high", "medium", "low"]],
            "key": ["type": "string"], "changeSummary": ["type": "string"], "summary": ["type": "string"],
            "name": ["type": "string"], "role": ["type": "string"], "instructions": ["type": "string"], "reason": ["type": "string"],
        ],
        "required": ["action"],
    ]

    /// Finds the first balanced JSON object in model output (fenced or not).
    static func extractAction(_ text: String) -> JSON? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "{" else { index += 1; continue }
            var depth = 0, inString = false, escaped = false, end = index
            while end < scalars.count {
                let c = scalars[end]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            if depth == 0 && end < scalars.count {
                var candidate = String.UnicodeScalarView()
                candidate.append(contentsOf: scalars[index...end])
                if let parsed = try? JSON.parse(String(candidate)), parsed.isObject, parsed["action"].stringValue != nil { return parsed }
            }
            index += 1
        }
        return nil
    }

    private func perform(_ name: String, _ action: JSON, _ context: OrgRunContext, _ io: OrgRunIO, _ currentIssue: inout OrgIssue?) -> JSON {
        let companyId = context.company.id
        let service = io.service
        do {
            switch name {
            case "checkout":
                let ref = action["issue"].stringValue ?? ""
                let result = try service.checkoutIssue(io.actor, companyId, ref, OrgBody(.object(JSONObject())))
                if let state = service.store.company(companyId), let issue = service.findIssue(state, ref) { currentIssue = issue }
                return ["ok": true, "issue": result["issue"]["identifier"], "description": JSON(currentIssue?.description ?? "")]
            case "comment":
                guard let issue = currentIssue else { return ["ok": false, "error": "No issue is checked out."] }
                _ = try service.addComment(io.actor, companyId, issue.id, OrgBody(["body": action["body"]]))
                return ["ok": true]
            case "set_status":
                guard let issue = currentIssue else { return ["ok": false, "error": "No issue is checked out."] }
                var patch = JSONObject([("status", action["status"])])
                if action["comment"].stringValue != nil { patch["comment"] = action["comment"] }
                let result = try service.updateIssue(io.actor, companyId, issue.id, OrgBody(.object(patch)))
                return ["ok": true, "status": result["issue"]["status"]]
            case "create_issue":
                var body = JSONObject([("title", action["title"]), ("description", action["description"]), ("priority", action["priority"].stringValue.map { JSON($0) } ?? "medium")])
                if let parent = currentIssue { body["parentId"] = JSON(parent.id) }
                if let assignee = action["assignee"].stringValue { body["assigneeAgentId"] = JSON(assignee) }
                let result = try service.createIssue(io.actor, companyId, OrgBody(.object(body)))
                return ["ok": true, "identifier": result["issue"]["identifier"]]
            case "write_document":
                guard let issue = currentIssue else { return ["ok": false, "error": "No issue is checked out."] }
                let result = try service.putDocument(io.actor, companyId, issue.id, action["key"].stringValue ?? "notes",
                                                     OrgBody(["title": action["title"], "body": action["body"], "changeSummary": action["changeSummary"]]))
                return ["ok": true, "revision": result["document"]["revisionNumber"]]
            case "request_approval":
                let result = try service.requestApproval(io.actor, companyId, OrgBody(["summary": action["summary"], "issueIds": currentIssue.map { JSON([$0.id]) } ?? .array([])]))
                return ["ok": true, "approvalId": result["approval"]["id"]]
            case "hire_agent":
                let result = try service.createAgent(io.actor, companyId, OrgBody(["name": action["name"], "role": action["role"], "title": action["title"],
                                                                                    "instructions": action["instructions"], "reason": action["reason"]]))
                return ["ok": true, "agentId": result["agent"]["id"], "status": result["agent"]["status"]]
            default:
                return ["ok": false, "error": JSON("Unknown action \(name).")]
            }
        } catch let error as RuntimeError {
            return ["ok": false, "error": JSON(error.message)]
        } catch {
            return ["ok": false, "error": JSON("\(error)")]
        }
    }

    private func systemPrompt(_ context: OrgRunContext) -> String {
        let agent = context.agent
        var lines: [String] = []
        lines.append("You are \(agent.name), the \(agent.title ?? agent.role) of \(context.company.name), an AI-run company on RoachNet.")
        if let description = context.company.description, !description.isEmpty { lines.append("Company mission: \(description)") }
        if let manager = agent.reportsTo.flatMap({ id in context.agents.first { $0.id == id } }) { lines.append("You report to \(manager.name) (@\(manager.urlKey)).") }
        let reports = context.agents.filter { $0.reportsTo == agent.id }
        if !reports.isEmpty { lines.append("Your reports: " + reports.map { "\($0.name) (@\($0.urlKey), \($0.role))" }.joined(separator: ", ") + ".") }
        if let capabilities = agent.capabilities, !capabilities.isEmpty { lines.append("Capabilities: \(capabilities)") }
        if let instructions = agent.instructions, !instructions.isEmpty { lines.append("Instructions:\n\(instructions)") }
        for skill in context.skills { lines.append("Skill \(skill.name):\n\(String(skill.markdown.prefix(6_000)))") }
        lines.append("""
        Act by replying with exactly one JSON object per turn and nothing else. Available actions:
        {"action":"checkout","issue":"PREFIX-N"}  pick up one of your assigned issues
        {"action":"comment","body":"..."}  comment on the current issue
        {"action":"set_status","status":"in_progress|in_review|done|blocked|todo","comment":"optional"}
        {"action":"create_issue","title":"...","description":"...","assignee":"agent url key (optional)","priority":"critical|high|medium|low"}  delegate a sub-task
        {"action":"write_document","key":"plan","title":"...","body":"markdown"}
        {"action":"request_approval","summary":"..."}  ask the board for a decision
        \(agent.canCreateAgents ? "{\"action\":\"hire_agent\",\"name\":\"...\",\"role\":\"engineer\",\"title\":\"...\",\"instructions\":\"...\",\"reason\":\"...\"}\n" : ""){"action":"finish","summary":"what you did"}  end this run
        Keep work small and concrete. Finish when the run's purpose is handled.
        """)
        return lines.joined(separator: "\n\n")
    }

    private func taskPrompt(_ context: OrgRunContext) -> String {
        var lines = ["Wake reason: \(context.wakeReasons.joined(separator: ", "))."]
        if let issue = context.issue {
            lines.append("Current issue \(issue.identifier) [\(issue.status), \(issue.priority)]: \(issue.title)")
            if let description = issue.description, !description.isEmpty { lines.append("Description:\n\(String(description.prefix(8_000)))") }
            if !context.comments.isEmpty {
                lines.append("Recent comments:\n" + context.comments.suffix(10).map { comment in
                    let author = comment.authorType == "agent" ? (context.agents.first { $0.id == comment.authorId }?.name ?? "agent") : comment.authorType
                    return "- \(author): \(String(comment.body.prefix(1_500)))"
                }.joined(separator: "\n"))
            }
            if !context.children.isEmpty { lines.append("Sub-issues:\n" + context.children.map { "- \($0.identifier) [\($0.status)] \($0.title)" }.joined(separator: "\n")) }
        } else if !context.assignedIssues.isEmpty {
            lines.append("Your open issues:\n" + context.assignedIssues.prefix(20).map { "- \($0.identifier) [\($0.status), \($0.priority)] \($0.title)" }.joined(separator: "\n"))
        } else {
            lines.append("You have no assigned issues. Review the company and finish if nothing needs doing.")
        }
        if let payload = context.payload.objectValue, !payload.isEmpty { lines.append("Wake details: \(JSON.object(payload).serialized())") }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - HTTP adapter

/// POSTs the run context to an agent service and reads back its result.
struct OrgHTTPAdapter: OrgAdapter {
    func run(_ context: OrgRunContext, _ io: OrgRunIO) -> OrgRunResult {
        let config = OrgBody(context.agent.adapterConfig)
        guard let url = config.string("url", max: 2_000), OrgAdapters.allowedEndpoint(url) else {
            return .failure("http agents need an https url (or http on this Mac).", code: "adapter_config")
        }
        var headers = ["content-type": "application/json"]
        for (key, value) in context.agent.adapterConfig["headers"].object { if let text = value.stringValue { headers[key.lowercased()] = text } }
        if let token = io.secret(config.string("authSecret")) { headers["authorization"] = "Bearer \(token)" }
        let body: JSON = [
            "run": ["id": JSON(context.run.id), "wakeReasons": JSON(context.wakeReasons), "payload": context.payload],
            "agent": ["id": JSON(context.agent.id), "name": JSON(context.agent.name), "role": JSON(context.agent.role), "instructions": JSON(context.agent.instructions)],
            "company": ["id": JSON(context.company.id), "name": JSON(context.company.name)],
            "issue": context.issue.map { OrgCodec.json($0) } ?? .null,
            "comments": .array(context.comments.map { OrgCodec.json($0) }),
            "api": ["baseUrl": JSON(context.apiBaseURL), "runToken": JSON(context.runToken), "header": "x-roachnet-org-key"],
            "sessionState": context.agent.sessionState ?? .null,
        ]
        io.log("system", "POST \(url)")
        let span = io.trace?.child(.span, "POST \(WebURL(url)?.bareHostname ?? "agent service")", metadata: JSONObject([("url", JSON(url))]))
        if let span { headers["traceparent"] = span.traceparent }
        defer { span?.end() }
        do {
            let response = try HTTPClient.request(url, method: "POST", headers: headers, body: body.serializedData(), timeoutMs: io.remainingMs, maxResponseBytes: 4 << 20)
            let json = (try? JSON.parse(response.body)) ?? .object(JSONObject())
            io.log("stdout", String(decoding: response.body.prefix(16_000), as: UTF8.self))
            guard (200..<300).contains(response.status) else { return .failure("Agent service returned \(response.status).", code: "http_\(response.status)") }
            return OrgHTTPAdapter.parseResult(json, defaultProvider: "http")
        } catch {
            return .failure("Agent service call failed: \(error)", code: "http_error")
        }
    }

    static func parseResult(_ json: JSON, defaultProvider: String) -> OrgRunResult {
        var result = OrgRunResult()
        let status = json["status"].stringValue ?? "succeeded"
        result.status = ["succeeded", "failed", "cancelled", "timed_out"].contains(status) ? status : "succeeded"
        result.summary = json["summary"].stringValue
        result.error = json["error"].stringValue
        if json["usage"].isObject {
            let usage = json["usage"]
            result.usage = OrgUsage(inputTokens: (usage["inputTokens"].clampedInt(0...(1 << 50)) ?? 0), outputTokens: (usage["outputTokens"].clampedInt(0...(1 << 50)) ?? 0),
                                    cachedInputTokens: (usage["cachedInputTokens"].clampedInt(0...(1 << 50)) ?? 0), provider: usage["provider"].stringValue ?? defaultProvider, model: usage["model"].stringValue)
        }
        if let cents = json["costCents"].clampedInt(0...(1 << 50)) {
            result.costCents = cents; result.costStatus = "reported"; result.billingType = json["billingType"].stringValue ?? "metered_api"
        } else if result.usage != nil {
            result.costStatus = "unpriced"; result.billingType = json["billingType"].stringValue ?? "unknown"
        }
        if json["sessionState"].isObject { result.sessionState = json["sessionState"] }
        return result
    }
}

// MARK: - Process adapter (owner-configured host commands)

/// Runs a host command for the agent. Only the RoachNet owner can configure it.
/// The command reaches the Org API with a short-lived run token.
struct OrgProcessAdapter: OrgAdapter {
    func run(_ context: OrgRunContext, _ io: OrgRunIO) -> OrgRunResult {
        let config = OrgBody(context.agent.adapterConfig)
        guard let command = config.string("command", max: 1_024), Path.isAbsolute(command), Files.exists(command) else {
            return .failure("process agents need an absolute command path that exists.", code: "adapter_config")
        }
        let arguments = config.strings("args", maxItems: 64) ?? []
        let home = Path.join(io.service.root, "agents", context.agent.id, "home")
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let cwd = context.project?.workspacePath.flatMap { Files.isDirectory($0) ? $0 : nil } ?? config.string("cwd", max: 1_024).flatMap { Files.isDirectory($0) ? $0 : nil } ?? home

        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL"] { if let value = parent[key] { environment[key] = value } }
        for (key, value) in context.agent.adapterConfig["env"].object { if let text = value.stringValue { environment[key] = io.service.resolveSecretReference(context.company.id, text) ?? "" } }
        if let project = context.project {
            for (key, value) in project.env { environment[key] = value }
            for (key, secretKey) in project.secretEnv { environment[key] = io.service.store.readSecret(companyId: context.company.id, key: secretKey) ?? "" }
        }
        environment["ROACHNET_ORG_API_URL"] = context.apiBaseURL
        environment["ROACHNET_ORG_API_KEY"] = context.runToken
        environment["ROACHNET_ORG_RUN_ID"] = context.run.id
        environment["ROACHNET_ORG_AGENT_ID"] = context.agent.id
        environment["ROACHNET_ORG_COMPANY_ID"] = context.company.id
        environment["ROACHNET_ORG_TASK_ID"] = context.issue?.id ?? ""
        environment["ROACHNET_ORG_WAKE_REASON"] = context.wakeReasons.first ?? ""
        environment["ROACHNET_ORG_WAKE_PAYLOAD_JSON"] = context.payload.serialized()
        environment["AGENT_HOME"] = home
        let span = io.trace?.child(.span, "process \(Path.basename(command))", input: ["command": JSON(command), "args": JSON(arguments), "cwd": JSON(cwd)])
        // W3C's environment carrier: a process agent can nest its own model calls.
        if let span { environment["TRACEPARENT"] = span.traceparent }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let lastLine = LockedBox<String>("")
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            io.log("stdout", text)
            if let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { lastLine.value = String(line) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { io.log("stderr", String(decoding: data, as: UTF8.self)) }
        }
        do {
            try process.run()
        } catch {
            span?.end(level: .error, statusMessage: "Could not start \(command): \(error.localizedDescription)")
            return .failure("Could not start \(command): \(error.localizedDescription)", code: "spawn_failed")
        }
        var outcome = "succeeded"
        while process.isRunning {
            if io.isCancelled { outcome = "cancelled"; break }
            if io.timedOut { outcome = "timed_out"; break }
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(5)
            while process.isRunning && Date() < grace { usleep(100_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        span?.end(output: JSON(lastLine.value.isEmpty ? nil : String(lastLine.value.prefix(2_000))), level: process.terminationStatus == 0 && outcome == "succeeded" ? nil : .error,
                  statusMessage: outcome != "succeeded" ? outcome : (process.terminationStatus == 0 ? nil : "exit \(process.terminationStatus)"),
                  metadata: JSONObject([("exitCode", JSON(Int(process.terminationStatus))), ("outcome", JSON(outcome))]))
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        var result: OrgRunResult
        if let parsed = try? JSON.parse(lastLine.value), parsed.isObject, parsed["summary"].stringValue != nil || parsed["usage"].isObject {
            result = OrgHTTPAdapter.parseResult(parsed, defaultProvider: "process")
        } else {
            result = OrgRunResult()
            result.summary = lastLine.value.isEmpty ? nil : String(lastLine.value.prefix(2_000))
        }
        result.exitCode = Int(process.terminationStatus)
        if outcome != "succeeded" {
            result.status = outcome
            result.error = outcome == "timed_out" ? "The run hit its time limit." : "The run was cancelled."
            result.errorCode = outcome
        } else if process.terminationStatus != 0 && result.status == "succeeded" {
            result.status = "failed"
            result.error = "Command exited with status \(process.terminationStatus)."
            result.errorCode = "exit_\(process.terminationStatus)"
        }
        return result
    }
}
