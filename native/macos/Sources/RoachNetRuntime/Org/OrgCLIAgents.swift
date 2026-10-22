import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum OrgCLIKind: String, CaseIterable {
    case claude = "claude_local"
    case codex = "codex_local"
    case gemini = "gemini_local"
    case opencode = "opencode_local"
    case cursor = "cursor_local"

    static func from(_ adapterType: String) -> OrgCLIKind? { OrgCLIKind(rawValue: adapterType) }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor CLI"
        }
    }

    var binaries: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .gemini: return ["gemini"]
        case .opencode: return ["opencode"]
        case .cursor: return ["cursor-agent"]
        }
    }

    var provider: String {
        switch self {
        case .claude: return "anthropic"
        case .codex: return "openai"
        case .gemini: return "google"
        case .opencode: return "opencode"
        case .cursor: return "cursor"
        }
    }

    var installHint: String {
        switch self {
        case .claude: return "Install Claude Code (claude.com/claude-code), then sign in with `claude auth login`."
        case .codex: return "Install the Codex CLI (developers.openai.com/codex), then sign in with `codex login`."
        case .gemini:
            return "Install Gemini CLI (`npm install -g @google/gemini-cli`), then run `gemini` once to sign in."
        case .opencode: return "Install OpenCode (opencode.ai), then sign in with `opencode auth login`."
        case .cursor: return "Install the Cursor CLI (cursor.com/cli), then sign in with `cursor-agent login`."
        }
    }

    var signInHint: String {
        switch self {
        case .claude: return "Run `claude auth login` in Terminal."
        case .codex: return "Run `codex login` in Terminal."
        case .gemini: return "Run `gemini` in Terminal once and sign in."
        case .opencode: return "Run `opencode auth login` in Terminal."
        case .cursor: return "Run `cursor-agent login` in Terminal."
        }
    }

    var signInCommand: [String] {
        switch self {
        case .claude: return ["auth", "login"]
        case .codex: return ["login"]
        case .gemini: return []
        case .opencode: return ["auth", "login"]
        case .cursor: return ["login"]
        }
    }
}

enum OrgCLIAccess: String, CaseIterable {
    case readOnly = "read_only"
    case standard
    case full

    static func from(_ raw: String?) -> OrgCLIAccess { raw.flatMap(OrgCLIAccess.init(rawValue:)) ?? .standard }
}

final class OrgLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&storage)
        lock.unlock()
    }
}

enum OrgCLILocator {
    static func searchPath(home: String, inherited: String?) -> [String] {
        var dirs = (inherited ?? "").split(separator: ":").map(String.init)
        dirs += [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "\(home)/.opencode/bin", "\(home)/.cursor/bin", "\(home)/.volta/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin",
        ]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func find(_ kind: OrgCLIKind, override: String?, home: String, path: String?) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return Path.isAbsolute(override) && FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        for dir in searchPath(home: home, inherited: path) {
            for name in kind.binaries {
                let candidate = Path.join(dir, name)
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}

struct OrgCLIOutput {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var text: String { (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum OrgCLIProcess {
    static func run(
        _ executable: String, _ arguments: [String], environment: [String: String], cwd: String? = nil,
        stdin: String? = nil, timeout: TimeInterval
    ) -> OrgCLIOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let collected = OrgLocked<(Data, Data)>((Data(), Data()))
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.mutate { $0.0.append(data) } }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.mutate { $0.1.append(data) } }
        }
        do { try process.run() } catch { return nil }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(50_000)
        }
        let grace = Date().addingTimeInterval(3)
        while process.isRunning && Date() < grace { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        var value = collected.value
        value.0.append(OrgCLIAdapter.drain(out.fileHandleForReading, timeout: 3))
        value.1.append(OrgCLIAdapter.drain(err.fileHandleForReading, timeout: 1))
        return OrgCLIOutput(
            status: process.terminationStatus, stdout: String(decoding: value.0, as: UTF8.self),
            stderr: String(decoding: value.1, as: UTF8.self), timedOut: timedOut)
    }

    static func baseEnvironment(executable: String?) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in [
            "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "TERM", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        ] {
            if let value = parent[key] { environment[key] = value }
        }
        if (environment["USER"] ?? "").isEmpty { environment["USER"] = NSUserName() }
        if (environment["LOGNAME"] ?? "").isEmpty { environment["LOGNAME"] = environment["USER"] }
        if (environment["HOME"] ?? "").isEmpty { environment["HOME"] = NSHomeDirectory() }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var dirs = OrgCLILocator.searchPath(home: home, inherited: parent["PATH"])
        if let executable { dirs.insert(Path.dirname(executable), at: 0) }
        var seen = Set<String>()
        environment["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
        if environment["TERM"] == nil { environment["TERM"] = "dumb" }
        environment["NO_COLOR"] = "1"
        return environment
    }
}

struct OrgCLIStatus {
    var kind: OrgCLIKind
    var path: String?
    var version: String?
    var signedIn: Bool?
    var authMethod: String?
    var plan: String?
    var detail: String
    var models: [String] = []
    var agents: [String] = []
    var checkedAt = JS.isoNow()

    var installed: Bool { path != nil }

    var json: JSON {
        [
            "type": JSON(kind.rawValue), "label": JSON(kind.label), "provider": JSON(kind.provider),
            "installed": JSON(installed), "path": JSON(path), "version": JSON(version),
            "signedIn": signedIn.map { JSON($0) } ?? .null, "authMethod": JSON(authMethod), "plan": JSON(plan),
            "detail": JSON(detail), "models": JSON(models), "agents": JSON(agents),
            "installHint": JSON(kind.installHint), "signInHint": JSON(kind.signInHint),
            "signInCommand": JSON(path.map { [$0] + kind.signInCommand } ?? []), "checkedAt": JSON(checkedAt),
        ]
    }
}

enum OrgCLIDetector {
    private static let cache = OrgLocked<[String: (Date, OrgCLIStatus)]>([:])

    static func detectAll(refresh: Bool = false) -> [OrgCLIStatus] {
        let results = OrgLocked<[OrgCLIKind: OrgCLIStatus]>([:])
        let group = DispatchGroup()
        for kind in OrgCLIKind.allCases {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let status = detect(kind, override: nil, refresh: refresh)
                results.mutate { $0[kind] = status }
                group.leave()
            }
        }
        group.wait()
        return OrgCLIKind.allCases.compactMap { results.value[$0] }
    }

    static func detect(_ kind: OrgCLIKind, override: String?, refresh: Bool = false) -> OrgCLIStatus {
        let key = "\(kind.rawValue)|\(override ?? "")"
        if !refresh, let (at, status) = cache.value[key], Date().timeIntervalSince(at) < 30 { return status }
        let status = probe(kind, override: override)
        cache.mutate { $0[key] = (Date(), status) }
        return status
    }

    private static func probe(_ kind: OrgCLIKind, override: String?) -> OrgCLIStatus {
        let base = OrgCLIProcess.baseEnvironment(executable: nil)
        let home = base["HOME"] ?? NSHomeDirectory()
        guard let path = OrgCLILocator.find(kind, override: override, home: home, path: base["PATH"]) else {
            let detail = override == nil ? "Not installed. \(kind.installHint)" : "No program at that path."
            return OrgCLIStatus(kind: kind, path: nil, detail: detail)
        }
        let environment = OrgCLIProcess.baseEnvironment(executable: path)
        var status = OrgCLIStatus(kind: kind, path: path, detail: "")
        if let output = OrgCLIProcess.run(path, ["--version"], environment: environment, timeout: 15),
            output.status == 0
        {
            let first = output.text.split(separator: "\n").first.map(String.init) ?? ""
            if let range = first.range(of: #"\d+(\.\d+)+([-+.][0-9A-Za-z.]+)?"#, options: .regularExpression) {
                status.version = String(first[range])
            } else if !first.isEmpty {
                status.version = String(first.prefix(80))
            }
        }
        switch kind {
        case .claude:
            if let output = OrgCLIProcess.run(
                path, ["auth", "status", "--json"], environment: environment, timeout: 15),
                let json = try? JSON.parse(output.stdout), json.isObject
            {
                status.signedIn = json["loggedIn"].boolValue
                let method = json["authMethod"].stringValue ?? ""
                if status.signedIn == true {
                    status.authMethod =
                        method == "claude.ai" || method.contains("oauth") || method.contains("subscription")
                        ? "subscription" : "api_key"
                }
                status.plan = json["subscriptionType"].stringValue
            }
            status.models = ["sonnet", "opus", "haiku"]
            status.agents = claudeAgents(home: home)
        case .codex:
            if let output = OrgCLIProcess.run(path, ["login", "status"], environment: environment, timeout: 15) {
                let text = output.text.lowercased()
                if text.contains("not logged in") {
                    status.signedIn = false
                } else if text.contains("logged in") {
                    status.signedIn = true
                    status.authMethod = text.contains("api key") ? "api_key" : "subscription"
                    if text.contains("chatgpt") { status.plan = "chatgpt" }
                }
            }
            if let output = OrgCLIProcess.run(path, ["debug", "models"], environment: environment, timeout: 15),
                let json = try? JSON.parse(output.stdout)
            {
                let items = json["models"].arrayValue ?? json.arrayValue ?? []
                status.models = items.compactMap { item in
                    guard item["visibility"].stringValue.map({ $0 == "list" }) ?? true else { return nil }
                    return item["slug"].stringValue ?? item["id"].stringValue
                }
            }
        case .cursor:
            if let output = OrgCLIProcess.run(path, ["status"], environment: environment, timeout: 15) {
                let text = output.text.lowercased()
                if text.contains("not logged in") || text.contains("not authenticated") {
                    status.signedIn = false
                } else if text.contains("logged in") || text.contains("authenticated") {
                    status.signedIn = true
                    status.authMethod = "subscription"
                }
            }
        case .gemini, .opencode:
            break
        }
        status.detail = summary(status)
        return status
    }

    private static func summary(_ status: OrgCLIStatus) -> String {
        let version = status.version.map { " \($0)" } ?? ""
        switch status.signedIn {
        case .some(true):
            let how =
                status.authMethod == "api_key"
                ? "with an API key" : "with \(status.plan.map { "a \(planName($0)) plan" } ?? "a subscription")"
            return "\(status.kind.label)\(version), signed in \(how)."
        case .some(false):
            return "\(status.kind.label)\(version) is installed but not signed in. \(status.kind.signInHint)"
        case .none:
            return "\(status.kind.label)\(version) is installed. Run a test to check its sign-in."
        }
    }

    static func planName(_ plan: String) -> String {
        switch plan.lowercased() {
        case "chatgpt": return "ChatGPT"
        case "": return plan
        default: return plan.prefix(1).uppercased() + plan.dropFirst()
        }
    }

    static func claudeAgents(home: String) -> [String] {
        let dir = Path.join(home, ".claude", "agents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }
}

struct OrgCLIInvocation {
    var arguments: [String]
    var stdin: String?
}

struct OrgCLIRequest {
    var kind: OrgCLIKind
    var identity: String
    var task: String
    var model: String?
    var resume: String?
    var cwd: String
    var agentHome: String
    var access: OrgCLIAccess
    var useMySetup: Bool
    var claudeAgent: String?
    var reasoningEffort: String?
    var extraAllowedTools: [String] = []
    var extraArguments: [String] = []
}

enum OrgCLICommand {
    static func claudeTools(_ access: OrgCLIAccess, extra: [String]) -> [String] {
        var tools = ["Bash(roachnet-org:*)", "Bash(curl:*)", "Read", "Grep", "Glob", "LS", "TodoWrite"]
        if access == .standard {
            tools += [
                "Edit", "MultiEdit", "Write", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(ls:*)",
            ]
        }
        return tools + extra
    }

    static func invocation(_ request: OrgCLIRequest) -> OrgCLIInvocation {
        let model = request.model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch request.kind {
        case .claude:
            var args = ["-p", "--output-format", "stream-json", "--verbose"]
            if let model { args += ["--model", model] }
            if let resume = request.resume { args += ["--resume", resume] }
            if let agent = request.claudeAgent?.nilIfEmpty { args += ["--agent", agent] }
            switch request.access {
            case .full: args += ["--dangerously-skip-permissions"]
            case .readOnly:
                args += [
                    "--permission-mode", "dontAsk", "--allowedTools",
                    claudeTools(.readOnly, extra: request.extraAllowedTools).joined(separator: ","),
                ]
            case .standard:
                args += [
                    "--permission-mode", "acceptEdits", "--allowedTools",
                    claudeTools(.standard, extra: request.extraAllowedTools).joined(separator: ","),
                ]
            }
            if request.cwd != request.agentHome { args += ["--add-dir", request.agentHome] }
            if !request.useMySetup { args += ["--setting-sources", "project,local", "--strict-mcp-config"] }
            args += ["--append-system-prompt", request.identity]
            return OrgCLIInvocation(arguments: args + request.extraArguments, stdin: request.task)
        case .codex:
            var args = request.resume.map { ["exec", "resume", $0] } ?? ["exec"]
            args += ["--json", "--skip-git-repo-check"]
            if let model { args += ["-m", model] }
            if let effort = request.reasoningEffort?.nilIfEmpty {
                args += ["-c", "model_reasoning_effort=\"\(effort)\""]
            }
            switch request.access {
            case .full: args += ["--dangerously-bypass-approvals-and-sandbox"]
            case .readOnly: args += ["-c", "sandbox_mode=\"read-only\""]
            case .standard:
                args += ["-c", "sandbox_mode=\"workspace-write\"", "-c", "sandbox_workspace_write.network_access=true"]
            }
            if request.resume == nil {
                args += ["-C", request.cwd]
                if request.cwd != request.agentHome { args += ["--add-dir", request.agentHome] }
            }
            if !request.useMySetup { args += ["--ignore-user-config"] }
            args += request.extraArguments + ["-"]
            return OrgCLIInvocation(arguments: args, stdin: request.identity + "\n\n---\n\n" + request.task)
        case .gemini:
            var args = ["--output-format", "stream-json"]
            args += [
                "--approval-mode",
                request.access == .full ? "yolo" : (request.access == .standard ? "auto_edit" : "default"),
            ]
            if let model { args += ["--model", model] }
            if let resume = request.resume { args += ["--resume", resume] }
            if request.cwd != request.agentHome { args += ["--include-directories", request.agentHome] }
            args += request.extraArguments + ["--prompt=" + request.identity + "\n\n---\n\n" + request.task]
            return OrgCLIInvocation(arguments: args, stdin: nil)
        case .opencode:
            var args = ["run", "--format", "json"]
            if let model { args += ["--model", model] }
            if let resume = request.resume { args += ["--session", resume] }
            args += request.extraArguments + [request.identity + "\n\n---\n\n" + request.task]
            return OrgCLIInvocation(arguments: args, stdin: nil)
        case .cursor:
            var args = ["-p", "--output-format", "stream-json"]
            if let model { args += ["--model", model] }
            if let resume = request.resume { args += ["--resume", resume] }
            if request.access == .full { args += ["--force"] }
            args += request.extraArguments + [request.identity + "\n\n---\n\n" + request.task]
            return OrgCLIInvocation(arguments: args, stdin: nil)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum OrgCLIBriefing {
    static let guideName = "ROACHNET_ORG.md"

    static func identity(_ context: OrgRunContext, guidePath: String) -> String {
        let agent = context.agent
        var lines: [String] = []
        lines.append(
            "You are \(agent.name), the \(agent.title ?? agent.role) of \(context.company.name), an AI-run company on RoachNet. You work as one of its agents, alongside the others."
        )
        if let description = context.company.description, !description.isEmpty {
            lines.append("Company mission: \(description)")
        }
        if let manager = agent.reportsTo.flatMap({ id in context.agents.first { $0.id == id } }) {
            lines.append("You report to \(manager.name) (@\(manager.urlKey)).")
        }
        let teammates = context.agents.filter { $0.id != agent.id && $0.status != "terminated" }
        if !teammates.isEmpty {
            lines.append(
                "Teammates (assign work with their id, wake them with @urlKey):\n"
                    + teammates.prefix(40).map {
                        "- \($0.name), \($0.title ?? $0.role): id \($0.id), @\($0.urlKey)\($0.reportsTo == agent.id ? " (reports to you)" : "")"
                    }.joined(separator: "\n"))
        }
        if let capabilities = agent.capabilities, !capabilities.isEmpty {
            lines.append("Capabilities: \(capabilities)")
        }
        if let instructions = agent.instructions, !instructions.isEmpty {
            lines.append("Instructions:\n\(instructions)")
        }
        for skill in context.skills { lines.append("Skill \(skill.name):\n\(String(skill.markdown.prefix(6_000)))") }
        lines.append(
            """
            You work with your company through the RoachNet Org API. Run `roachnet-org METHOD PATH [JSON]` (it's on your PATH); \
            \(guidePath) lists every call. Your environment also has ROACHNET_ORG_API_URL, ROACHNET_ORG_API_KEY, \
            ROACHNET_ORG_COMPANY_ID, ROACHNET_ORG_AGENT_ID, ROACHNET_ORG_TASK_ID and ROACHNET_ORG_RUN_ID.
            - Check out your issue before working on it, comment as you go, and set its status when you stop (in_progress, in_review, done or blocked).
            - Delegate by creating an issue assigned to a teammate, with your issue as its parent; you wake again when it finishes. A @mention in a comment wakes that teammate.
            - Keep each run small and concrete. If you don't comment, your final reply is posted on the issue for you.
            """)
        return lines.joined(separator: "\n\n")
    }

    static func task(_ context: OrgRunContext) -> String {
        var lines = ["Wake reason: \(context.wakeReasons.joined(separator: ", "))."]
        if let issue = context.issue {
            lines.append(
                "Your issue \(issue.identifier) (id \(issue.id)) [\(issue.status), \(issue.priority)]: \(issue.title)")
            if let description = issue.description, !description.isEmpty {
                lines.append("Description:\n\(String(description.prefix(8_000)))")
            }
            if !context.comments.isEmpty {
                lines.append(
                    "Recent comments:\n"
                        + context.comments.suffix(12).map { comment in
                            let author =
                                comment.authorType == "agent"
                                ? (context.agents.first { $0.id == comment.authorId }?.name ?? "agent")
                                : comment.authorType
                            return "- \(author): \(String(comment.body.prefix(2_000)))"
                        }.joined(separator: "\n"))
            }
            if !context.children.isEmpty {
                lines.append(
                    "Sub-issues:\n"
                        + context.children.map { "- \($0.identifier) [\($0.status)] \($0.title)" }.joined(
                            separator: "\n"))
            }
        } else if !context.assignedIssues.isEmpty {
            lines.append(
                "Your open issues:\n"
                    + context.assignedIssues.prefix(20).map {
                        "- \($0.identifier) (id \($0.id)) [\($0.status), \($0.priority)] \($0.title)"
                    }.joined(separator: "\n"))
        } else {
            lines.append("You have no assigned issues. Check your inbox, and stop if nothing needs doing.")
        }
        if let workspace = context.project?.workspacePath { lines.append("Project workspace: \(workspace)") }
        if let payload = context.payload.objectValue, !payload.isEmpty {
            lines.append("Wake details: \(JSON.object(payload).serialized())")
        }
        return lines.joined(separator: "\n\n")
    }

    static let helperName = "roachnet-org"

    static let helper = #"""
        #!/bin/sh
        # roachnet-org METHOD PATH [JSON | @file | @-]
        # Calls your company's RoachNet Org API. PATH is relative to your company
        # (/issues/ROAC-1/comments); start it with // for /api/org itself (//me).
        set -eu
        method=${1:?usage: roachnet-org METHOD PATH [JSON | @file | @-]}
        path=${2:?usage: roachnet-org METHOD PATH [JSON | @file | @-]}
        case "$path" in
          //*) url="$ROACHNET_ORG_API_URL/api/org/${path#//}" ;;
          *) url="$ROACHNET_ORG_API_URL/api/org/companies/$ROACHNET_ORG_COMPANY_ID$path" ;;
        esac
        if [ $# -ge 3 ]; then
          exec curl -sS -X "$method" -H "x-roachnet-org-key: $ROACHNET_ORG_API_KEY" -H 'content-type: application/json' --data-binary "$3" "$url"
        fi
        exec curl -sS -X "$method" -H "x-roachnet-org-key: $ROACHNET_ORG_API_KEY" "$url"
        """#

    static let guide = #"""
        # RoachNet Org API

        Call your company with `roachnet-org METHOD PATH [JSON]`. It is on your PATH, sends your run key,
        and prints the JSON reply. Issues can be named by id or identifier (ROAC-12). Your current issue
        is $ROACHNET_ORG_TASK_ID (empty when you woke without one).

        ## Read
        - Who you are: `roachnet-org GET //me`
        - Your inbox: `roachnet-org GET /inbox`
        - Your open issues: `roachnet-org GET "/issues?assignee=me&status=todo,in_progress,blocked"`
        - One issue with comments and sub-issues: `roachnet-org GET /issues/ROAC-12`
        - Teammates: `roachnet-org GET /agents`

        ## Work an issue
        - Check it out first: `roachnet-org POST /issues/$ROACHNET_ORG_TASK_ID/checkout '{}'`
        - Comment: `roachnet-org POST /issues/$ROACHNET_ORG_TASK_ID/comments '{"body":"..."}'`
        - Status: `roachnet-org PATCH /issues/$ROACHNET_ORG_TASK_ID '{"status":"done","comment":"What changed."}'`
          (todo, in_progress, in_review, done, blocked)
        - Save a document: `roachnet-org PUT /issues/$ROACHNET_ORG_TASK_ID/documents/plan '{"title":"Plan","body":"markdown"}'`

        ## Delegate and talk
        - Hand a sub-task to a teammate. They wake on it, and you wake again when it's done:
          `roachnet-org POST /issues '{"title":"...","description":"...","assigneeAgentId":"agent_...","parentId":"ROAC-12"}'`
        - Wake a teammate from a comment: write `@their-url-key` in the body.
        - Ask the board for a decision: `roachnet-org POST /approvals '{"summary":"..."}'`

        For text with quotes or several lines, write the JSON to a file and send `@file.json`, or pipe it in with `@-`.
        Without the helper, the same calls are plain curl: add `-H "x-roachnet-org-key: $ROACHNET_ORG_API_KEY"`
        to `$ROACHNET_ORG_API_URL/api/org/companies/$ROACHNET_ORG_COMPANY_ID/...`.
        """#
}

enum OrgCLIProbe {
    static func test(_ kind: OrgCLIKind, _ body: OrgBody) -> JSON {
        let config = OrgBody(body.raw["adapterConfig"].isObject ? body.raw["adapterConfig"] : .object(JSONObject()))
        let override = config.string("command", max: 1_024)
        let status = OrgCLIDetector.detect(kind, override: override, refresh: true)
        var json = status.json.object
        guard body.bool("probe") == true, let path = status.path else { return .object(json) }

        let scratch = Path.join(NSTemporaryDirectory(), "roachnet-cli-test-\(JS.randomHex(6))")
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        var extra: [String] = []
        if kind == .claude { extra = ["--no-session-persistence"] }
        if kind == .codex { extra = ["--ephemeral"] }
        let request = OrgCLIRequest(
            kind: kind, identity: "RoachNet is checking that this agent can run.",
            task: "Reply with the single word ok.",
            model: config.string("model", max: 200), resume: nil, cwd: scratch, agentHome: scratch, access: .readOnly,
            useMySetup: config.bool("useMySetup") ?? true, claudeAgent: nil,
            reasoningEffort: config.string("reasoningEffort", max: 20),
            extraArguments: extra)
        let invocation = OrgCLICommand.invocation(request)
        var environment = OrgCLIProcess.baseEnvironment(executable: path)
        for (key, value) in config.raw["env"].object {
            if let text = value.stringValue, !text.hasPrefix("secret:") { environment[key] = text }
        }
        let started = Date()
        let output = OrgCLIProcess.run(
            path, invocation.arguments, environment: environment, cwd: scratch,
            stdin: invocation.stdin, timeout: 180)
        let latency = Int(Date().timeIntervalSince(started) * 1_000)
        let stream = OrgCLIStream(
            kind: kind, trace: nil, configuredModel: request.model,
            billing: status.authMethod == "api_key" ? "metered_api" : nil
        ) { _ in }
        for line in (output?.stdout ?? "").split(separator: "\n") { stream.feed(line) }
        let failed =
            output == nil || output?.timedOut == true || output?.status != 0 || stream.reportedFailure
            || stream.reply == nil
        let problem =
            stream.errorMessage?.nilIfEmpty ?? OrgCLIAdapter.lastLines(output?.stderr ?? "")
            ?? (output?.timedOut == true ? "No answer within three minutes." : nil)
        let (code, hint) = OrgCLIAdapter.classify(
            ((problem ?? "") + "\n" + (output?.stderr ?? "")).lowercased(), kind: kind)
        let usage = stream.totalUsage
        json["test"] = [
            "ok": JSON(!failed), "reply": JSON(stream.reply.map { String($0.prefix(500)) }), "latencyMs": JSON(latency),
            "model": JSON(stream.model ?? request.model),
            "billing": JSON(stream.billing ?? (status.authMethod == "subscription" ? "subscription_included" : nil)),
            "usage": [
                "input": JSON(usage.inputTokens), "output": JSON(usage.outputTokens),
                "cachedInput": JSON(usage.cachedInputTokens),
            ],
            "apiEquivalentUsd": JSON(stream.costUsd),
            "error": JSON(
                failed
                    ? [problem, hint].compactMap { $0 }.joined(separator: " ").nilIfEmpty
                        ?? "The test didn't get a reply." : nil),
            "errorCode": JSON(failed ? (code ?? "test_failed") : nil),
        ]
        if !failed, stream.billing == "subscription_included" || status.authMethod == "subscription" {
            json["signedIn"] = true
        }
        return .object(json)
    }
}
