import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

struct OrgAdapterInfo: Decodable, Identifiable, Hashable {
    struct Test: Decodable, Hashable {
        let ok: Bool
        let reply: String?
        let latencyMs: Int?
        let model: String?
        let billing: String?
        let error: String?
        let errorCode: String?
        let apiEquivalentUsd: Double?
    }

    let type: String
    let label: String
    let installed: Bool
    let path: String?
    let version: String?
    let signedIn: Bool?
    let authMethod: String?
    let plan: String?
    let detail: String
    let models: [String]
    let agents: [String]
    let installHint: String
    let signInHint: String
    let signInCommand: [String]
    let test: Test?

    var id: String { type }
}

struct OrgDeskAdapterConfig: Decodable, Hashable {
    let model: String?
    let access: String?
    let useMySetup: Bool?
    let claudeAgent: String?
    let cwd: String?
    let reasoningEffort: String?
    let url: String?
    let baseUrl: String?
}

enum OrgAgentRuntime {
    static let local = "roachclaw_local"
    static let openAI = "openai_compatible"
    static let http = "http"
    static let cliTypes = ["claude_local", "codex_local", "gemini_local", "opencode_local", "cursor_local"]

    static func label(_ type: String?, adapters: [OrgAdapterInfo] = []) -> String {
        switch type ?? local {
        case local: return "RoachClaw on this Mac"
        case openAI: return "OpenAI-compatible endpoint"
        case http: return "Agent service"
        case "process": return "Program on this Mac"
        case "claude_local": return "Claude Code"
        case "codex_local": return "Codex"
        case "gemini_local": return "Gemini CLI"
        case "opencode_local": return "OpenCode"
        case "cursor_local": return "Cursor CLI"
        default: return adapters.first { $0.type == type }?.label ?? (type ?? "Agent")
        }
    }

    static func isCLI(_ type: String) -> Bool { cliTypes.contains(type) }
}

struct OrgHireAgentSheet: View {
    let companyID: String
    let config: RoachNetInstallerConfig
    let editing: OrgDeskAgent?
    var initialRuntime: String?
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var adapters: [OrgAdapterInfo] = []
    @State private var loadingAdapters = true
    @State private var name = ""
    @State private var title = ""
    @State private var instructions = ""
    @State private var runtime = OrgAgentRuntime.local
    @State private var model = ""
    @State private var access = "standard"
    @State private var useMySetup = true
    @State private var claudeAgent = ""
    @State private var cwd = ""
    @State private var reasoningEffort = ""
    @State private var endpoint = ""
    @State private var test: OrgAdapterInfo.Test?
    @State private var testing = false
    @State private var busy = false
    @State private var message: String?

    private var adapter: OrgAdapterInfo? { adapters.first { $0.type == runtime } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RoachKicker(editing == nil ? "Hire an agent" : "Agent settings")
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(RoachSecondaryButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    runsOn
                    if OrgAgentRuntime.isCLI(runtime) { cliSettings } else { otherSettings }
                    if let message {
                        Text(message)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                if OrgAgentRuntime.isCLI(runtime) {
                    Button(testing ? "Testing…" : "Test") { Task { await runTest() } }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(testing || adapter?.installed != true)
                        .help(
                            "Sends “Reply with the single word ok.” through the CLI, read-only, using its own sign-in (your plan or API key)."
                        )
                        .accessibilityIdentifier("org.hire.test")
                }
                Button(editing == nil ? "Hire" : "Save") { Task { await save() } }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || !canSave)
                    .accessibilityIdentifier("org.hire.save")
            }
        }
        .padding(22)
        .frame(width: 640, height: 700)
        .background(RoachPalette.background)
        .task { await load() }
        .accessibilityIdentifier("org.hire")
    }

    private var canSave: Bool {
        switch runtime {
        case OrgAgentRuntime.http: return !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
        case OrgAgentRuntime.openAI: return !endpoint.trimmingCharacters(in: .whitespaces).isEmpty && !model.isEmpty
        default: return OrgAgentRuntime.isCLI(runtime) ? adapter?.installed == true : true
        }
    }

    private var identity: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachFlowLayout(spacing: 8) {
                    TextField("Name, e.g. Ada", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .accessibilityIdentifier("org.hire.name")
                    TextField("Title, e.g. Staff Engineer", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Text("Instructions")
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                TextEditor(text: $instructions)
                    .font(.roach(size: 12))
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous).fill(
                            RoachPalette.panelRaised))
            }
        }
    }

    private var runsOn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Runs on")
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Picker("Runs on", selection: $runtime) {
                    Text(OrgAgentRuntime.label(OrgAgentRuntime.local)).tag(OrgAgentRuntime.local)
                    Divider()
                    ForEach(OrgAgentRuntime.cliTypes, id: \.self) { type in
                        let info = adapters.first { $0.type == type }
                        Text(OrgAgentRuntime.label(type) + (info?.installed == false ? " (not installed)" : "")).tag(
                            type)
                    }
                    Divider()
                    Text(OrgAgentRuntime.label(OrgAgentRuntime.openAI)).tag(OrgAgentRuntime.openAI)
                    Text(OrgAgentRuntime.label(OrgAgentRuntime.http)).tag(OrgAgentRuntime.http)
                }
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: runtime) { _, _ in
                    test = nil
                    message = nil
                }
                .accessibilityIdentifier("org.hire.runtime")
                Text(runtimeBlurb)
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runtimeBlurb: String {
        switch runtime {
        case OrgAgentRuntime.local:
            return
                "A RoachClaw agent loop on a model that RoachNet runs on this Mac. Runs cost $0 and keep working offline."
        case OrgAgentRuntime.openAI:
            return
                "The RoachClaw agent loop against any OpenAI-compatible server. Put its key in the company's secrets as openai-key."
        case OrgAgentRuntime.http:
            return "Your own agent service. RoachNet POSTs each run to it with a run key it can use to call back."
        default:
            return
                "Your own \(OrgAgentRuntime.label(runtime)), with the sign-in you already set up. RoachNet starts it with the issue, a run key for the Org and a guide to the Org's API, and never sees your account's credentials. Runs on a plan count as $0 here."
        }
    }

    @ViewBuilder
    private var cliSettings: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                if loadingAdapters {
                    Text("Looking for \(OrgAgentRuntime.label(runtime))…")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                } else if let adapter {
                    status(adapter)
                    if adapter.installed {
                        modelPicker(adapter)
                        accessPicker
                        if runtime == "claude_local" || runtime == "codex_local" {
                            Toggle(isOn: $useMySetup) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Use your \(adapter.label) setup")
                                        .font(.roach(size: 12, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(
                                        "On loads your own hooks, plugins, skills and MCP servers. Off runs a clean agent, which is quicker and uses fewer tokens."
                                    )
                                    .font(.roach(size: 11, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                        if runtime == "claude_local", !adapter.agents.isEmpty {
                            Picker("Custom agent", selection: $claudeAgent) {
                                Text("None").tag("")
                                ForEach(adapter.agents, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(width: 300)
                            .help("Run as one of the custom agents you defined in ~/.claude/agents.")
                        }
                        if runtime == "codex_local" {
                            Picker("Reasoning", selection: $reasoningEffort) {
                                Text("Codex default").tag("")
                                Text("Low").tag("low")
                                Text("Medium").tag("medium")
                                Text("High").tag("high")
                            }
                            .frame(width: 300)
                        }
                        folderField
                    }
                }
                if let test { testResult(test) }
            }
        }
    }

    private func status(_ adapter: OrgAdapterInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: adapter.installed
                    ? (adapter.signedIn == false ? "person.crop.circle.badge.exclamationmark" : "checkmark.seal.fill")
                    : "arrow.down.circle"
            )
            .foregroundStyle(adapter.installed && adapter.signedIn != false ? RoachPalette.green : RoachPalette.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(adapter.detail)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if adapter.installed, adapter.signedIn == false, !adapter.signInCommand.isEmpty {
                    Button("Sign in using Terminal") {
                        OrgTerminalHandoff.run(adapter.signInCommand, title: "Sign in to \(adapter.label)")
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
                if adapter.installed, let path = adapter.path {
                    Text(path)
                        .font(.roach(size: 10, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                        .textSelection(.enabled)
                }
                Button("Check again") { Task { await loadAdapters(refresh: true) } }
                    .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
    }

    private func modelPicker(_ adapter: OrgAdapterInfo) -> some View {
        RoachFlowLayout(spacing: 8) {
            Text("Model")
                .font(.roach(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
            if !adapter.models.isEmpty {
                Picker("Model", selection: $model) {
                    Text("\(adapter.label) default").tag("")
                    ForEach(adapter.models, id: \.self) { Text($0).tag($0) }
                    if !model.isEmpty && !adapter.models.contains(model) { Text(model).tag(model) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            TextField("or a model name", text: $model)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    private var accessPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Access", selection: $access) {
                Text("Read-only").tag("read_only")
                Text("Standard").tag("standard")
                Text("Full access").tag("full")
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            Text(accessHelp)
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(access == "full" ? RoachPalette.warning : RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessHelp: String {
        switch access {
        case "read_only": return "Reads files and talks to the Org. It can't edit files or run other commands."
        case "full":
            return
                "No sandbox and no prompts: it can run any command as you. Use it only for agents you'd trust at your own keyboard."
        default: return "Edits files in its working folder and talks to the Org. Other commands are refused."
        }
    }

    private var folderField: some View {
        RoachFlowLayout(spacing: 8) {
            TextField("Working folder (optional)", text: $cwd)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }
    }

    private func testResult(_ test: OrgAdapterInfo.Test) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: test.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(test.ok ? RoachPalette.green : RoachPalette.warning)
            VStack(alignment: .leading, spacing: 2) {
                if test.ok {
                    Text(
                        "Replied “\(test.reply ?? "")” in \(Double(test.latencyMs ?? 0) / 1_000, specifier: "%.1f") s on \(test.model ?? "its default model")."
                    )
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                    Text(
                        test.billing == "subscription_included"
                            ? "Included in your plan."
                            : (test.billing == "metered_api" ? "Billed to your API key." : "Billing unknown.")
                    )
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                } else {
                    Text(test.error ?? "The test didn't get a reply. Check the runtime and model, then test again.")
                        .font(.roach(size: 12, weight: .semibold))
                        .foregroundStyle(RoachPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("org.hire.test-result")
    }

    @ViewBuilder
    private var otherSettings: some View {
        switch runtime {
        case OrgAgentRuntime.local:
            RoachInsetPanel {
                RoachFlowLayout(spacing: 8) {
                    Text("Model")
                        .font(.roach(size: 12, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    TextField(config.roachClawDefaultModel, text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Text("Blank uses RoachClaw's default.")
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        case OrgAgentRuntime.openAI:
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://api.example.com/v1", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 380)
                    TextField("Model", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
        default:
            RoachInsetPanel {
                TextField("https://agent.example.com/run", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
            }
        }
    }

    private func load() async {
        if let agent = editing {
            name = agent.name
            title = agent.title ?? ""
            instructions = agent.instructions ?? ""
            runtime = agent.adapterType ?? OrgAgentRuntime.local
            let saved = agent.adapterConfig
            model = saved?.model ?? ""
            access = saved?.access ?? "standard"
            useMySetup = saved?.useMySetup ?? true
            claudeAgent = saved?.claudeAgent ?? ""
            cwd = saved?.cwd ?? ""
            reasoningEffort = saved?.reasoningEffort ?? ""
            endpoint = saved?.url ?? saved?.baseUrl ?? ""
        } else if let initialRuntime {
            runtime = initialRuntime
        }
        await loadAdapters(refresh: false)
    }

    private func loadAdapters(refresh: Bool) async {
        loadingAdapters = true
        defer { loadingAdapters = false }
        do {
            struct List: Decodable { let adapters: [OrgAdapterInfo] }
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/org/adapters\(refresh ? "?refresh=1" : "")")
            adapters = try JSONDecoder().decode(List.self, from: data).adapters
        } catch {
            message = "Couldn't check which agents are installed: \(error.localizedDescription)"
        }
    }

    private var adapterConfig: [String: Any] {
        var body: [String: Any] = [:]
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        if !trimmedModel.isEmpty { body["model"] = trimmedModel }
        switch runtime {
        case OrgAgentRuntime.http:
            body["url"] = endpoint.trimmingCharacters(in: .whitespaces)
        case OrgAgentRuntime.openAI:
            body["baseUrl"] = endpoint.trimmingCharacters(in: .whitespaces)
            body["apiKeySecret"] = "openai-key"
        case OrgAgentRuntime.local:
            break
        default:
            body["access"] = access
            body["useMySetup"] = useMySetup
            body["timeoutSec"] = 1_800
            if !claudeAgent.isEmpty { body["claudeAgent"] = claudeAgent }
            if !reasoningEffort.isEmpty { body["reasoningEffort"] = reasoningEffort }
            if !cwd.trimmingCharacters(in: .whitespaces).isEmpty {
                body["cwd"] = cwd.trimmingCharacters(in: .whitespaces)
            }
        }
        return body
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        do {
            let json = try JSONSerialization.data(withJSONObject: ["adapterConfig": adapterConfig, "probe": true])
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/org/adapters/\(runtime)/test", method: "POST", jsonBody: json)
            let result = try JSONDecoder().decode(OrgAdapterInfo.self, from: data)
            test = result.test
            if let index = adapters.firstIndex(where: { $0.type == result.type }) { adapters[index] = result }
        } catch {
            message = "The test didn't run: \(error.localizedDescription)"
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces), "adapterType": runtime, "adapterConfig": adapterConfig,
        ]
        body["title"] =
            title.trimmingCharacters(in: .whitespaces).isEmpty ? NSNull() : title.trimmingCharacters(in: .whitespaces)
        body["instructions"] =
            instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : instructions
        do {
            let json = try JSONSerialization.data(withJSONObject: body)
            if let agent = editing {
                _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                    using: config, path: "/api/org/companies/\(companyID)/agents/\(agent.id)", method: "PATCH",
                    jsonBody: json)
                onDone("\(name) now runs on \(OrgAgentRuntime.label(runtime, adapters: adapters)).")
            } else {
                _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                    using: config, path: "/api/org/companies/\(companyID)/agents", method: "POST", jsonBody: json)
                onDone(
                    "Hired \(name) on \(OrgAgentRuntime.label(runtime, adapters: adapters)). Assign an issue to put them to work."
                )
            }
            dismiss()
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

enum OrgTerminalHandoff {
    static func run(_ command: [String], title: String) {
        let quoted = command.map(DeveloperShell.quoted).joined(separator: " ")
        let script = """
            #!/bin/zsh
            clear
            echo \(DeveloperShell.quoted(title))
            \(quoted)
            echo
            echo "Done. You can close this window and click Check again in RoachNet."
            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "roachnet-sign-in-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("[RoachNet] Couldn't open Terminal for sign-in: \(error.localizedDescription)")
        }
    }
}
