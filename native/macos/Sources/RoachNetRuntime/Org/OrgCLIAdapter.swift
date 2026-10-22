import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct OrgCLIAdapter: OrgAdapter {
    let kind: OrgCLIKind

    struct Attempt {
        var result: OrgRunResult
        var stream: OrgCLIStream
        var missingSession: Bool
    }

    func run(_ context: OrgRunContext, _ io: OrgRunIO) -> OrgRunResult {
        let config = OrgBody(context.agent.adapterConfig)
        let override = config.string("command", max: 1_024)
        let start = OrgCLIProcess.baseEnvironment(executable: nil)
        guard
            let executable = OrgCLILocator.find(
                kind, override: override, home: start["HOME"] ?? NSHomeDirectory(), path: start["PATH"])
        else {
            let message =
                override == nil
                ? "\(kind.label) isn't installed on this Mac. \(kind.installHint)"
                : "There's no program at \(override ?? "")."
            return .failure(message, code: "adapter_missing")
        }

        let agentHome = Path.join(io.service.root, "agents", context.agent.id, "home")
        let bin = Path.join(agentHome, "bin")
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let guidePath = Path.join(agentHome, OrgCLIBriefing.guideName)
        try? OrgCLIBriefing.guide.write(toFile: guidePath, atomically: true, encoding: .utf8)
        let helperPath = Path.join(bin, OrgCLIBriefing.helperName)
        try? OrgCLIBriefing.helper.write(toFile: helperPath, atomically: true, encoding: .utf8)
        chmod(helperPath, 0o755)
        let cwd =
            context.project?.workspacePath.flatMap { Files.isDirectory($0) ? $0 : nil }
            ?? config.string("cwd", max: 1_024).flatMap { Files.isDirectory($0) ? $0 : nil } ?? agentHome

        var environment = OrgCLIProcess.baseEnvironment(executable: executable)
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? "")
        for (key, value) in context.agent.adapterConfig["env"].object {
            if let text = value.stringValue {
                environment[key] = io.service.resolveSecretReference(context.company.id, text) ?? ""
            }
        }
        if let project = context.project {
            for (key, value) in project.env { environment[key] = value }
            for (key, secretKey) in project.secretEnv {
                environment[key] = io.service.store.readSecret(companyId: context.company.id, key: secretKey) ?? ""
            }
        }
        environment["ROACHNET_ORG_API_URL"] = context.apiBaseURL
        environment["ROACHNET_ORG_API_KEY"] = context.runToken
        environment["ROACHNET_ORG_RUN_ID"] = context.run.id
        environment["ROACHNET_ORG_AGENT_ID"] = context.agent.id
        environment["ROACHNET_ORG_COMPANY_ID"] = context.company.id
        environment["ROACHNET_ORG_TASK_ID"] = context.issue?.id ?? ""
        environment["ROACHNET_ORG_WAKE_REASON"] = context.wakeReasons.first ?? ""
        environment["ROACHNET_ORG_WAKE_PAYLOAD_JSON"] = context.payload.serialized()
        environment["AGENT_HOME"] = agentHome
        io.service.runtime.tracer.redactor.register(context.runToken)

        let sessions = OrgCLISessions(context.agent.sessionState, kind: kind)
        let key = context.issue?.id ?? "_agent"
        let previous = config.bool("resumeSessions") == false ? nil : sessions.lookup(key, cwd: cwd)
        var request = OrgCLIRequest(
            kind: kind, identity: OrgCLIBriefing.identity(context, guidePath: guidePath),
            task: OrgCLIBriefing.task(context),
            model: config.string("model", max: 200), resume: previous, cwd: cwd, agentHome: agentHome,
            access: OrgCLIAccess.from(config.string("access", max: 20)), useMySetup: config.bool("useMySetup") ?? true,
            claudeAgent: config.string("claudeAgent", max: 120),
            reasoningEffort: config.string("reasoningEffort", max: 20),
            extraAllowedTools: config.strings("allowedTools", maxItems: 32) ?? [],
            extraArguments: config.strings("extraArgs", maxItems: 32) ?? [])
        let billing = defaultBilling(environment: environment, override: override)

        var attempt = execute(request, executable: executable, environment: environment, billing: billing, io: io)
        if previous != nil, attempt.result.status == "failed", attempt.missingSession {
            io.log("system", "The saved \(kind.label) session is gone, so this run starts a fresh one.\n")
            request.resume = nil
            attempt = execute(request, executable: executable, environment: environment, billing: billing, io: io)
        }
        var result = attempt.result
        if let id = attempt.stream.sessionId, !id.isEmpty {
            result.sessionState = sessions.saving(key, id: id, cwd: cwd)
        }
        if result.status == "succeeded", config.bool("postReply") ?? true, let issue = context.issue,
            let reply = attempt.stream.reply,
            !commented(io, issueId: issue.id, agentId: context.agent.id, since: context.run.startedAt)
        {
            _ = try? io.service.addComment(
                io.actor, context.company.id, issue.id, OrgBody(["body": JSON(String(reply.prefix(20_000)))]))
        }
        return result
    }

    private func commented(_ io: OrgRunIO, issueId: String, agentId: String, since: String?) -> Bool {
        guard let state = io.service.store.company(io.context.company.id) else { return false }
        return state.comments.contains { comment in
            comment.issueId == issueId && comment.authorType == "agent" && comment.authorId == agentId
                && comment.createdAt >= (since ?? "")
        }
    }

    private func defaultBilling(environment: [String: String], override: String?) -> String? {
        func has(_ name: String) -> Bool { !(environment[name] ?? "").isEmpty }
        switch kind {
        case .claude: return has("ANTHROPIC_API_KEY") ? "metered_api" : nil
        case .codex:
            if has("OPENAI_API_KEY") || has("CODEX_API_KEY") { return "metered_api" }
            let status = OrgCLIDetector.detect(kind, override: override)
            return status.authMethod == "api_key"
                ? "metered_api" : (status.signedIn == true ? "subscription_included" : nil)
        case .gemini: return has("GEMINI_API_KEY") || has("GOOGLE_API_KEY") ? "metered_api" : "subscription_included"
        case .cursor: return has("CURSOR_API_KEY") ? "metered_api" : nil
        case .opencode: return nil
        }
    }

    private func execute(
        _ request: OrgCLIRequest, executable: String, environment: [String: String], billing: String?, io: OrgRunIO
    ) -> Attempt {
        let invocation = OrgCLICommand.invocation(request)
        let span = io.trace?.child(
            .span, kind.label,
            input: [
                "command": JSON(Path.basename(executable)), "cwd": JSON(request.cwd), "resume": JSON(request.resume),
                "model": JSON(request.model), "access": JSON(request.access.rawValue),
            ], metadata: JSONObject([("adapter", JSON(kind.rawValue))]))
        var environment = environment
        if let span { environment["TRACEPARENT"] = span.traceparent }
        let stream = OrgCLIStream(kind: kind, trace: span, configuredModel: request.model, billing: billing) { line in
            io.log("stdout", line + "\n")
        }
        io.log(
            "system",
            "\(kind.label): \(Path.basename(executable)) \(Self.loggable(invocation.arguments))\(request.resume.map { " (resuming \($0))" } ?? "")\n"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = invocation.stdin == nil ? FileHandle.nullDevice : stdin
        let pending = OrgLocked(Data())
        let errorTail = OrgLocked(Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            pending.mutate { $0 = Self.feedLines($0 + data, into: stream) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            io.log("stderr", String(decoding: data, as: UTF8.self))
            errorTail.mutate { tail in
                tail.append(data)
                if tail.count > 16_384 { tail = Data(tail.suffix(16_384)) }
            }
        }
        do {
            try process.run()
        } catch {
            span?.end(level: .error, statusMessage: "Could not start \(kind.label): \(error.localizedDescription)")
            return Attempt(
                result: .failure("Could not start \(kind.label): \(error.localizedDescription)", code: "spawn_failed"),
                stream: stream, missingSession: false)
        }
        if let text = invocation.stdin {
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                writer.write(Data(text.utf8))
                try? writer.close()
            }
        }
        var outcome = "succeeded"
        while process.isRunning {
            if io.isCancelled {
                outcome = "cancelled"
                break
            }
            if io.timedOut {
                outcome = "timed_out"
                break
            }
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(5)
            while process.isRunning && Date() < grace { usleep(100_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let rest = Self.drain(stdout.fileHandleForReading, timeout: 3)
        let leftover = Self.feedLines(pending.value + rest, into: stream)
        if !leftover.isEmpty { stream.feed(Substring(String(decoding: leftover, as: UTF8.self))) }
        let stderrText = String(
            decoding: errorTail.value + Self.drain(stderr.fileHandleForReading, timeout: 1), as: UTF8.self)

        let exit = process.terminationStatus
        let failed = outcome != "succeeded" || exit != 0 || stream.reportedFailure
        let problem = (stream.errorMessage?.nilIfEmpty ?? Self.lastLines(stderrText)).map { String($0.prefix(4_000)) }
        stream.finish(failed: failed, message: problem)

        var result = OrgRunResult()
        result.exitCode = Int(exit)
        result.summary = stream.reply.map { String($0.prefix(8_000)) }
        let usage = stream.totalUsage
        if !usage.isEmpty {
            result.usage = OrgUsage(
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                cachedInputTokens: usage.cachedInputTokens,
                provider: kind.provider, model: stream.model ?? request.model)
        }
        let paidBy = stream.billing ?? billing
        switch paidBy {
        case "subscription_included":
            result.billingType = "subscription_included"
            result.costStatus = "included"
            result.costCents = 0
        case "metered_api":
            result.billingType = "metered_api"
            if let usd = stream.costUsd {
                result.costCents = usd.isFinite ? Int(min(max(usd * 100, 0), Double(OrgLimits.maxAmount)).rounded()) : 0
                result.costStatus = "reported"
                if kind == .claude { stream.applyReportedTotal(usd) }
            } else {
                result.costStatus = "unpriced"
            }
        default:
            result.billingType = "unknown"
            result.costStatus = "unpriced"
        }

        let lowered = ((problem ?? "") + "\n" + stderrText).lowercased()
        let missingSession =
            request.resume != nil
            && [
                "no conversation found", "session not found", "no session found", "thread not found",
                "could not find session", "unknown session",
            ].contains { lowered.contains($0) }
        if outcome != "succeeded" {
            result.status = outcome
            result.error = outcome == "timed_out" ? "The run hit its time limit." : "The run was cancelled."
            result.errorCode = outcome
        } else if failed {
            result.status = "failed"
            let (code, hint) = Self.classify(lowered, kind: kind)
            result.errorCode = code ?? "exit_\(exit)"
            result.error = [problem ?? "\(kind.label) exited with status \(exit).", hint].compactMap { $0 }.joined(
                separator: " ")
        }

        var metadata = JSONObject([
            ("billing", JSON(paidBy)), ("turns", JSON(stream.turns)), ("toolCalls", JSON(stream.toolCalls)),
            ("sessionId", JSON(stream.sessionId)), ("exitCode", JSON(Int(exit))), ("outcome", JSON(outcome)),
        ])
        if paidBy == "subscription_included", let usd = stream.costUsd { metadata["apiEquivalentUsd"] = JSON(usd) }
        if !stream.rateLimit.isNullish { metadata["rateLimit"] = stream.rateLimit }
        span?.end(
            output: JSON(result.summary), level: result.status == "succeeded" ? nil : .error,
            statusMessage: result.error, metadata: metadata,
            model: stream.model)
        return Attempt(result: result, stream: stream, missingSession: missingSession)
    }

    static func feedLines(_ data: Data, into stream: OrgCLIStream) -> Data {
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            stream.feed(Substring(String(decoding: data[start..<newline], as: UTF8.self)))
            start = data.index(after: newline)
        }
        let rest = Data(data[start...])
        if rest.count > 32 << 20 {
            stream.feed(Substring(String(decoding: rest, as: UTF8.self)))
            return Data()
        }
        return rest
    }

    static func drain(_ handle: FileHandle, timeout: TimeInterval) -> Data {
        let box = OrgLocked(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = handle.readDataToEndOfFile()
            box.mutate { $0 = data }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.value
    }

    static func lastLines(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.suffix(4).joined(separator: " · ")
    }

    static func loggable(_ arguments: [String]) -> String {
        var shown: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                shown.append("…")
                skipNext = false
                continue
            }
            if argument == "--append-system-prompt" {
                shown.append(argument)
                skipNext = true
                continue
            }
            if argument.count > 200 || argument.hasPrefix("--prompt=") {
                shown.append("…")
                continue
            }
            shown.append(argument.contains(" ") ? "'\(argument)'" : argument)
        }
        return shown.joined(separator: " ")
    }

    static func classify(_ text: String, kind: OrgCLIKind) -> (String?, String?) {
        if text.contains("requires a newer version") || text.contains("upgrade to the latest") {
            return ("cli_outdated", "Update \(kind.label), or pick a model it supports.")
        }
        if text.contains("not logged in") || text.contains("please run /login") || text.contains("please log in")
            || text.contains("unauthorized")
            || text.contains("invalid api key") || text.contains("authentication") || text.contains("401")
        {
            return ("not_signed_in", kind.signInHint)
        }
        if text.contains("rate limit") || text.contains("usage limit") || text.contains("quota") || text.contains("429")
        {
            return (
                "rate_limited", "Your \(kind.label) plan's limit was reached; the run can try again once it resets."
            )
        }
        return (nil, nil)
    }
}

struct OrgCLISessions {
    let state: JSON
    let kind: OrgCLIKind

    init(_ state: JSON?, kind: OrgCLIKind) {
        self.state = state ?? .null
        self.kind = kind
    }

    func lookup(_ key: String, cwd: String) -> String? {
        guard state["adapter"].stringValue == kind.rawValue else { return nil }
        let entry = state["sessions"][key]
        guard entry["cwd"].stringValue == cwd else { return nil }
        return entry["id"].stringValue?.nilIfEmpty
    }

    func saving(_ key: String, id: String, cwd: String) -> JSON {
        var sessions = state["adapter"].stringValue == kind.rawValue ? state["sessions"].object : JSONObject()
        sessions[key] = ["id": JSON(id), "cwd": JSON(cwd), "updatedAt": JSON(JS.isoNow())]
        var entries: [(String, JSON)] = []
        for (name, value) in sessions { entries.append((name, value)) }
        if entries.count > 50 {
            entries.sort { ($0.1["updatedAt"].stringValue ?? "") > ($1.1["updatedAt"].stringValue ?? "") }
            entries = Array(entries.prefix(50))
        }
        return ["adapter": JSON(kind.rawValue), "sessionId": JSON(id), "sessions": .object(JSONObject(entries))]
    }
}
