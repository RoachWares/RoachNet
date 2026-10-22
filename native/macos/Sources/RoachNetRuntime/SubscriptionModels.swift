import Foundation

final class SubscriptionModels {
    enum Provider: String, CaseIterable {
        case claude
        case codex

        var kind: OrgCLIKind { self == .claude ? .claude : .codex }
        var label: String { self == .claude ? "Claude plan" : "ChatGPT plan" }
        var ownedBy: String { self == .claude ? "anthropic (Claude Code)" : "openai (Codex)" }
        var defaultModels: [String] { self == .claude ? ["sonnet", "opus", "haiku"] : [] }
    }

    struct Settings: Codable {
        var claude = false
        var codex = false
        func enabled(_ provider: Provider) -> Bool { provider == .claude ? claude : codex }
    }

    struct Reply {
        var text: String
        var usage: TraceUsage
        var model: String
        var apiEquivalentUsd: Double?
        var firstTokenMs: Int64?
        var stopReason: String
    }

    private let settingsPath: String
    private let state: OrgLocked<Settings>

    init(root: String) {
        settingsPath = Path.join(root, "subscriptions.json")
        let saved =
            (try? Data(contentsOf: URL(fileURLWithPath: Path.join(root, "subscriptions.json"))))
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        state = OrgLocked(saved)
    }

    var settings: Settings { state.value }

    func update(_ change: (inout Settings) -> Void) throws {
        state.mutate(change)
        try FileManager.default.createDirectory(atPath: Path.dirname(settingsPath), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state.value)
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        chmod(settingsPath, 0o600)
    }

    static func parse(_ name: String) -> (Provider, String)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for provider in Provider.allCases where trimmed.lowercased().hasPrefix(provider.rawValue + ":") {
            let model = String(trimmed.dropFirst(provider.rawValue.count + 1))
            return model.isEmpty ? nil : (provider, model)
        }
        return nil
    }

    func listed() -> [(provider: Provider, model: String)] {
        var out: [(Provider, String)] = []
        for provider in Provider.allCases where settings.enabled(provider) {
            let status = OrgCLIDetector.detect(provider.kind, override: nil)
            guard status.installed, status.signedIn != false else { continue }
            let models = status.models.isEmpty ? provider.defaultModels : status.models
            out += models.map { (provider, $0) }
        }
        return out
    }

    func status() -> JSON {
        .array(
            Provider.allCases.map { provider in
                var json = OrgCLIDetector.detect(provider.kind, override: nil).json.object
                json["provider"] = JSON(provider.rawValue)
                json["providerLabel"] = JSON(provider.label)
                json["enabled"] = JSON(settings.enabled(provider))
                let status = OrgCLIDetector.detect(provider.kind, override: nil)
                json["modelNames"] = JSON(
                    (status.models.isEmpty ? provider.defaultModels : status.models).map {
                        "\(provider.rawValue):\($0)"
                    })
                return .object(json)
            })
    }

    func reply(_ provider: Provider, model: String, messages: [JSON], onText: @escaping (String) -> Void) throws
        -> Reply
    {
        guard settings.enabled(provider) else {
            throw requestError(
                "\(provider.label) models are off. Turn them on in Settings › RoachClaw › Subscriptions.", 403)
        }
        let status = OrgCLIDetector.detect(provider.kind, override: nil)
        guard let path = status.path else {
            throw requestError("\(provider.kind.label) isn't installed on this Mac. \(provider.kind.installHint)", 404)
        }
        guard status.signedIn != false else {
            throw requestError("\(provider.kind.label) isn't signed in. \(provider.kind.signInHint)", 401)
        }

        let (system, prompt) = Self.render(messages)
        let scratch = Path.join(NSTemporaryDirectory(), "roachnet-plan-\(JS.randomHex(6))")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let arguments: [String]
        let stdin: String
        switch provider {
        case .claude:
            arguments = [
                "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--model", model,
                "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "project,local",
                "--disable-slash-commands", "--permission-mode", "dontAsk",
                "--system-prompt", system ?? "You are a helpful assistant. Answer directly and concisely.",
            ]
            stdin = prompt
        case .codex:
            let disabled = try Self.codexFeaturesToDisable(executable: path)
            arguments = Self.codexArguments(model: model, scratch: scratch, disabling: disabled)
            stdin =
                (system.map { $0 + "\n\n" } ?? "")
                + "Answer the conversation below directly, as the assistant. Don't run commands or touch files.\n\n"
                + prompt
        }

        let stream = OrgCLIStream(
            kind: provider.kind, trace: nil, configuredModel: model, billing: "subscription_included"
        ) { _ in }
        let started = TraceClock.nowMs()
        let firstToken = OrgLocked<Int64?>(nil)
        let streamed = OrgLocked(false)
        let output = OrgCLIProcess.stream(
            path, arguments, environment: OrgCLIProcess.baseEnvironment(executable: path), cwd: scratch,
            stdin: stdin, timeout: 600
        ) { line in
            if provider == .claude, line.contains("\"stream_event\""), let event = try? JSON.parse(String(line)),
                event["event"]["type"].stringValue == "content_block_delta",
                event["event"]["delta"]["type"].stringValue == "text_delta",
                let text = event["event"]["delta"]["text"].stringValue, !text.isEmpty
            {
                firstToken.mutate { if $0 == nil { $0 = TraceClock.nowMs() } }
                streamed.mutate { $0 = true }
                onText(text)
                return
            }
            stream.feed(line)
        }
        let failed = output.timedOut || output.status != 0 || stream.reportedFailure || stream.reply == nil
        if failed {
            let problem =
                stream.errorMessage?.nilIfEmpty ?? OrgCLIAdapter.lastLines(output.stderr)
                ?? (output.timedOut ? "No answer within ten minutes." : "No reply.")
            let (code, hint) = OrgCLIAdapter.classify(
                (problem + "\n" + output.stderr).lowercased(), kind: provider.kind)
            let statusCode = code == "not_signed_in" ? 401 : (code == "rate_limited" ? 429 : 502)
            throw requestError([problem, hint].compactMap { $0 }.joined(separator: " "), statusCode)
        }
        let text = stream.reply ?? ""
        if !streamed.value {
            firstToken.mutate { $0 = TraceClock.nowMs() }
            onText(text)
        }
        _ = started
        return Reply(
            text: text, usage: stream.totalUsage, model: stream.model ?? model, apiEquivalentUsd: stream.costUsd,
            firstTokenMs: firstToken.value, stopReason: "stop")
    }

    static let codexKeptFeatures: Set<String> = [
        "api_key_model_discovery", "compaction_image_budget", "content_item_kinds", "enable_request_compression",
        "fast_mode", "instant_interrupt", "system_proxy_fallback", "ultrafast_mode", "unbounded_connection_retries",
    ]

    static let codexRemovedOnAllowlist: Set<String> = [
        "collaboration_modes", "item_ids", "resize_all_images", "sqlite",
        "steer", "terminal_resize_reflow", "tool_search_always_defer_mcp_tools", "tui_app_server",
    ]

    static func codexArguments(model: String, scratch: String, disabling features: [String]) -> [String] {
        [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "-m", model,
            "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"",
        ]
            + features.flatMap { ["--disable", $0] } + ["-C", scratch, "-"]
    }

    static func codexFeaturesToDisable(listing: String) throws -> [String] {
        var known = Set<String>()
        var off: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count >= 3, let state = words.last, state == "true" || state == "false" else { continue }
            let name = words[0]
            known.insert(name)
            if words[1..<(words.count - 1)].joined(separator: " ") == "removed" {
                if state == "true", !codexRemovedOnAllowlist.contains(name) { throw codexCantSwitchOff(name) }
                continue
            }
            if codexKeptFeatures.contains(name) { continue }
            off.append(name)
        }
        guard known.contains("shell_tool") else { throw codexCantSwitchOff("shell_tool") }
        return off
    }

    private static func codexCantSwitchOff(_ feature: String) -> RuntimeError {
        requestError(
            "This Codex can't switch off its \(feature == "shell_tool" ? "shell" : "\(feature) tool"), so RoachNet doesn't use it for "
                + "ChatGPT plan models. Update Codex, or pick a Claude plan or a local model.", 502)
    }

    private static let codexFeatures = OrgLocked<[String: [String]]>([:])

    static func codexFeaturesToDisable(executable: String) throws -> [String] {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let build = "\(resolved)|\(size)|\(modified)"
        if let known = codexFeatures.value[build] { return known }
        let home = Path.join(NSTemporaryDirectory(), "roachnet-codex-\(JS.randomHex(8))")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        var environment = OrgCLIProcess.baseEnvironment(executable: executable)
        environment["CODEX_HOME"] = home
        guard
            let output = OrgCLIProcess.run(
                executable, ["features", "list"], environment: environment, cwd: home, timeout: 30),
            output.status == 0, !output.timedOut
        else {
            throw requestError(
                "RoachNet couldn't read which tools this Codex has (codex features list), so it doesn't use it for "
                    + "ChatGPT plan models. Update Codex, or pick a Claude plan or a local model.", 502)
        }
        let features = try codexFeaturesToDisable(listing: output.stdout)
        codexFeatures.mutate { $0[build] = features }
        return features
    }

    static func render(_ messages: [JSON]) -> (String?, String) {
        var system: [String] = []
        var turns: [(role: String, text: String)] = []
        for message in messages {
            let role = message["role"].stringValue ?? "user"
            let text = content(message["content"])
            guard !text.isEmpty else { continue }
            if role == "system" || role == "developer" { system.append(text) } else { turns.append((role, text)) }
        }
        let prompt: String
        if turns.count == 1, turns[0].role == "user" {
            prompt = turns[0].text
        } else {
            prompt =
                "The conversation so far:\n\n"
                + turns.map { "\($0.role == "assistant" ? "Assistant" : "User"): \($0.text)" }.joined(separator: "\n\n")
                + "\n\nReply as the assistant to the last user message."
        }
        return (system.isEmpty ? nil : system.joined(separator: "\n\n"), prompt)
    }

    private static func content(_ value: JSON) -> String {
        if let text = value.stringValue { return text }
        return value.array.compactMap { part in
            part["type"].stringValue == "text" || part["text"].stringValue != nil ? part["text"].stringValue : nil
        }.joined(separator: "\n")
    }
}

extension OrgCLIProcess {
    static func stream(
        _ executable: String, _ arguments: [String], environment: [String: String], cwd: String, stdin: String?,
        timeout: TimeInterval, onLine: @escaping (Substring) -> Void
    ) -> OrgCLIOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let pending = OrgLocked(Data())
        let errors = OrgLocked(Data())
        func split(_ data: Data) -> Data {
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                onLine(Substring(String(decoding: data[start..<newline], as: UTF8.self)))
                start = data.index(after: newline)
            }
            return Data(data[start...])
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { pending.mutate { $0 = split($0 + data) } }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errors.mutate {
                    $0.append(data)
                    if $0.count > 16_384 { $0 = Data($0.suffix(16_384)) }
                }
            }
        }
        do { try process.run() } catch {
            return OrgCLIOutput(
                status: -1, stdout: "",
                stderr: "Could not start \(Path.basename(executable)): \(error.localizedDescription)", timedOut: false)
        }
        if let stdin {
            let writer = input.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                writer.write(Data(stdin.utf8))
                try? writer.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(20_000)
        }
        let grace = Date().addingTimeInterval(3)
        while process.isRunning && Date() < grace { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let rest = split(pending.value + OrgCLIAdapter.drain(out.fileHandleForReading, timeout: 2))
        if !rest.isEmpty { onLine(Substring(String(decoding: rest, as: UTF8.self))) }
        return OrgCLIOutput(
            status: process.terminationStatus, stdout: "", stderr: String(decoding: errors.value, as: UTF8.self),
            timedOut: timedOut)
    }
}
