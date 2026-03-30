import SwiftUI
import AppKit
import RoachNetCore
import RoachNetDesign

enum WorkspacePane: String, CaseIterable, Identifiable {
    case suite = "Suite"
    case overview = "Deck"
    case roachClaw = "RoachClaw"
    case maps = "Maps"
    case education = "Education"
    case archives = "Archives"
    case knowledge = "Vault"
    case runtime = "Runtime"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .suite: return "square.grid.3x2.fill"
        case .overview: return "square.grid.2x2.fill"
        case .roachClaw: return "sparkles"
        case .maps: return "map.fill"
        case .education: return "graduationcap.fill"
        case .archives: return "shippingbox.fill"
        case .knowledge: return "books.vertical.fill"
        case .runtime: return "server.rack"
        }
    }

    var subtitle: String {
        switch self {
        case .suite: return "App surfaces"
        case .overview: return "Local status"
        case .roachClaw: return "Models and skills"
        case .maps: return "Offline regions"
        case .education: return "Wikipedia and collections"
        case .archives: return "Saved websites"
        case .knowledge: return "Contained sources"
        case .runtime: return "Service health"
        }
    }
}

struct ChatLine: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var selectedPane: WorkspacePane? = .suite
    @Published var config: RoachNetInstallerConfig = RoachNetRepositoryLocator.readConfig()
    @Published var snapshot: ManagedAppSnapshot?
    @Published var isLoading = false
    @Published var errorLine: String?
    @Published var statusLine: String = "Native shell ready."
    @Published var chatLines: [ChatLine] = [
        .init(role: "System", text: "RoachNet is up."),
        .init(role: "RoachClaw", text: "Try a quick prompt when you want to test the local model."),
    ]
    @Published var promptDraft: String = ""
    @Published var isApplyingDefaults = false
    @Published var isSendingPrompt = false
    private var attemptedRoachClawBootstrap = false

    var setupCompleted: Bool { config.setupCompletedAt != nil }
    var installPath: String { config.installPath.isEmpty ? RoachNetRepositoryLocator.defaultInstallPath() : config.installPath }
    var installedAppPath: String {
        config.installedAppPath.isEmpty ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath) : config.installedAppPath
    }

    func refreshConfigOnly() {
        config = RoachNetRepositoryLocator.readConfig()
        statusLine = setupCompleted ? "Setup complete." : "Setup still required."
    }

    func refreshRuntimeState() async {
        refreshConfigOnly()
        guard setupCompleted else { return }
        let currentConfig = config

        isLoading = true
        errorLine = nil
        statusLine = "Refreshing local runtime."

        do {
            snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: currentConfig)
            await bootstrapRoachClawIfNeeded(using: currentConfig)
            statusLine = "Local runtime ready."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Runtime unavailable."
        }

        isLoading = false
    }

    func applyRoachClawDefaults() async {
        guard setupCompleted, !isApplyingDefaults else { return }
        let currentConfig = config
        let currentModel = config.roachClawDefaultModel
        let currentWorkspacePath = snapshot?.roachClaw.workspacePath

        isApplyingDefaults = true
        errorLine = nil
            statusLine = "Saving local AI defaults."

        do {
            try await ManagedAppRuntimeBridge.shared.applyRoachClawDefaults(
                using: currentConfig,
                model: currentModel,
                workspacePath: currentWorkspacePath
            )
            snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: currentConfig)
            statusLine = "Local AI defaults saved."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Local AI update failed."
        }

        isApplyingDefaults = false
    }

    func sendPrompt() async {
        guard setupCompleted, !isSendingPrompt else { return }

        let trimmedPrompt = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let currentConfig = config
        let selectedModel =
            snapshot?.roachClaw.resolvedDefaultModel ??
            snapshot?.roachClaw.defaultModel ??
            config.roachClawDefaultModel

        chatLines.append(.init(role: "User", text: trimmedPrompt))
        promptDraft = ""
        isSendingPrompt = true
        errorLine = nil
        statusLine = "Running local prompt."

        do {
            let response = try await ManagedAppRuntimeBridge.shared.sendChat(
                using: currentConfig,
                model: selectedModel,
                prompt: trimmedPrompt
            )
            chatLines.append(.init(role: "RoachClaw", text: response.isEmpty ? "No content returned." : response))
            statusLine = "Prompt complete."
        } catch {
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("timed out") {
                errorLine = "The local model took too long to answer. RoachNet is tuned for qwen2.5-coder:7b now, so refresh after setup finishes pulling it."
            } else {
                errorLine = description
            }
            statusLine = "Prompt failed."
        }

        isSendingPrompt = false
    }

    private func bootstrapRoachClawIfNeeded(using config: RoachNetInstallerConfig) async {
        guard !attemptedRoachClawBootstrap else { return }
        guard let snapshot else { return }
        guard snapshot.roachClaw.ollama.available else { return }
        guard snapshot.roachClaw.defaultModel == nil else { return }

        attemptedRoachClawBootstrap = true

        do {
            try await ManagedAppRuntimeBridge.shared.applyRoachClawDefaults(
                using: config,
                model: config.roachClawDefaultModel,
                workspacePath: snapshot.roachClaw.workspacePath
            )
            self.snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: config)
            statusLine = "RoachClaw defaults staged."
        } catch {
            errorLine = "RoachClaw still needs one more pass: \(error.localizedDescription)"
        }
    }
}

private struct ChatBubble: View {
    let line: ChatLine

    var body: some View {
        let roleLabel = line.role.uppercased()
        let accent = line.role == "RoachClaw" ? RoachPalette.green : RoachPalette.muted

        return VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(accent)
            Text(line.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RoachPalette.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
    }
}

@main
struct RoachNetMacApp: App {
    @NSApplicationDelegateAdaptor(RoachNetMacAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup("RoachNet") {
            RootWorkspaceView(model: model)
                .frame(minWidth: 1220, idealWidth: 1380, minHeight: 820, idealHeight: 900)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private struct RootWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ZStack {
            RoachBackground()

            HStack(alignment: .top, spacing: 20) {
                sidebar
                    .frame(width: 286)

                detailPane
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .task {
            await model.refreshRuntimeState()
        }
    }

    private var sidebar: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    RoachOrbitMark()
                        .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("RoachNet")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text("Your local command center")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(WorkspacePane.allCases) { pane in
                        Button {
                            model.selectedPane = pane
                        } label: {
                            RoachSidebarTile(
                                title: pane.rawValue,
                                subtitle: pane.subtitle,
                                systemName: pane.icon,
                                isSelected: model.selectedPane == pane
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachKicker("System")
                        RoachStatusRow(title: "Install", value: model.setupCompleted ? "Ready" : "Locked", accent: model.setupCompleted ? RoachPalette.success : RoachPalette.warning)
                        RoachStatusRow(title: "Runtime", value: model.snapshot == nil ? "Offline" : "Live", accent: model.snapshot == nil ? RoachPalette.warning : RoachPalette.green)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var detailPane: some View {
        RoachPanel {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    headerBar

                    if let errorLine = model.errorLine {
                        RoachNotice(title: "Runtime notice", detail: errorLine)
                    }

                    commandTray

                    if model.setupCompleted {
                        switch model.selectedPane ?? .overview {
                        case .suite:
                            suite
                        case .overview:
                            overview
                        case .roachClaw:
                            roachClaw
                        case .maps:
                            maps
                        case .education:
                            education
                        case .archives:
                            archives
                        case .knowledge:
                            knowledge
                        case .runtime:
                            runtime
                        }
                    } else {
                            lockedState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedPane?.rawValue ?? "Deck")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(RoachPalette.text)
                Text(model.selectedPane?.subtitle ?? "Local-first control surface")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
            }

            Spacer()

            RoachTag(model.setupCompleted ? "Local ready" : "Setup required", accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning)
        }
    }

    private var commandTray: some View {
        RoachCommandTray(
            label: "Command Bar",
            prompt: "Jump between maps, education, archives, models, runtime, and sources from one place."
        )
    }

    private var suite: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader("Suite", title: "Everything stays together.", detail: "Maps, education, archives, and local AI live in one calm workspace.")

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                        suiteCard(title: "Maps", detail: "Offline regions and route assets.", value: "\(model.snapshot?.mapCollections.count ?? 0) collections", pane: .maps)
                        suiteCard(title: "Education", detail: "Wikipedia and curated reference packs.", value: educationSummary, pane: .education)
                        suiteCard(title: "Archives", detail: "Saved websites and captured references.", value: "\(model.snapshot?.siteArchives.count ?? 0) saved", pane: .archives)
                        suiteCard(title: "RoachClaw", detail: "Local AI with Ollama as the default lane.", value: roachClawSummary, pane: .roachClaw)
                    }
                }
            }
        }
    }

    private var lockedState: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 18) {
                RoachSectionHeader("Locked", title: "Finish setup to open RoachNet.", detail: "The setup app handles the install first so this space can stay focused.")

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Install Root", value: model.installPath)
                    RoachInfoPill(title: "App Path", value: model.installedAppPath)
                    RoachInfoPill(title: "Status", value: "Waiting")
                }

                Button("Refresh Local State") {
                    model.refreshConfigOnly()
                }
                .buttonStyle(RoachPrimaryButtonStyle())
            }
        }
    }

    private var overview: some View {
        let system = model.snapshot?.systemInfo
        let hardware = system?.hardwareProfile
        let roachClaw = model.snapshot?.roachClaw

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                        RoachSectionHeader("Deck", title: "Everything you need, in one calm place.", detail: "RoachNet keeps your runtime, local AI, and saved knowledge close at hand.")

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachInfoPill(title: "Chip", value: hardware?.platformLabel ?? "Loading")
                        RoachInfoPill(title: "Model", value: roachClaw?.resolvedDefaultModel ?? roachClaw?.defaultModel ?? model.config.roachClawDefaultModel)
                        RoachInfoPill(title: "Runtime", value: roachClaw?.preferredMode ?? hardware?.recommendedRuntime ?? "native_local")
                    }
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                RoachMetricCard(label: "Providers", value: providerSummary, detail: "Local AI runtime health")
                RoachMetricCard(label: "Knowledge", value: "\(model.snapshot?.knowledgeFiles.count ?? 0) Files", detail: "Mounted in the workspace")
                RoachMetricCard(label: "Skills", value: "\(model.snapshot?.installedSkills.count ?? 0)", detail: "Installed OpenClaw skills")
            }

            if let hardware {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        RoachKicker("Apple Silicon")
                        RoachStatusRow(title: "Family", value: hardware.chipFamily, accent: hardware.isAppleSilicon ? RoachPalette.success : RoachPalette.warning)
                        RoachStatusRow(title: "Memory Tier", value: hardware.memoryTier, accent: RoachPalette.green)
                        RoachStatusRow(title: "Recommended Model Class", value: hardware.recommendedModelClass, accent: RoachPalette.green)
                    }
                }
            }
        }
    }

    private var roachClaw: some View {
        let roachClaw = model.snapshot?.roachClaw
        let providers = model.snapshot?.providers.providers ?? [:]

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                    RoachSectionHeader("RoachClaw", title: "Local AI, aligned.", detail: "A fast local default first, with room to grow later.")
                        Spacer()
                        Button(model.isApplyingDefaults ? "Saving..." : "Apply Defaults") {
                            Task { await model.applyRoachClawDefaults() }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.isApplyingDefaults || model.snapshot == nil)
                    }

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachInfoPill(title: "Ollama", value: providerValue(providers["ollama"]))
                        RoachInfoPill(title: "OpenClaw", value: providerValue(providers["openclaw"]))
                        RoachInfoPill(title: "Workspace", value: roachClaw?.workspacePath ?? "Loading")
                    }

                    if let openclaw = providers["openclaw"], !openclaw.available {
                            Text("OpenClaw isn’t running yet. RoachNet can still use local Ollama while the agent runtime catches up.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                    }
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        RoachKicker("Models")
                        if let installed = roachClaw?.installedModels, !installed.isEmpty {
                            ForEach(installed.prefix(8), id: \.self) { modelName in
                                Text(modelName)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RoachPalette.text)
                            }
                        } else {
                            Text("No local models detected yet.")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        RoachKicker("Skills")
                        if let skills = model.snapshot?.installedSkills, !skills.isEmpty {
                            ForEach(skills.prefix(8)) { skill in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(skill.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(skill.slug)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(RoachPalette.muted)
                                }
                            }
                        } else {
                            Text("No OpenClaw skills installed yet.")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        RoachKicker("Workbench")
                        Spacer()
                        Text(roachClaw?.resolvedDefaultModel ?? roachClaw?.defaultModel ?? model.config.roachClawDefaultModel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    ForEach(Array(model.chatLines.suffix(6))) { line in
                        ChatBubble(line: line)
                    }

                    HStack(alignment: .bottom, spacing: 12) {
                        TextField("Test the local model", text: $model.promptDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.92))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )
                            .lineLimit(1...4)

                        Button(model.isSendingPrompt ? "Sending..." : "Send") {
                            Task { await model.sendPrompt() }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.isSendingPrompt || roachClaw == nil)
                    }
                }
            }
        }
    }

    private var maps: some View {
        let collections = model.snapshot?.mapCollections ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                RoachSectionHeader("Maps", title: "Offline regions, ready to stage.", detail: "The Project NOMAD-style map collections are still in the backend. They just needed a native surface again.")
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                ForEach(collections.prefix(8)) { collection in
                    RoachInsetPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(collection.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(collection.description ?? "Offline regional map pack")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                            RoachStatusRow(
                                title: "Coverage",
                                value: "\(collection.installed_count ?? 0) / \(collection.total_count ?? collection.resources.count) ready",
                                accent: RoachPalette.green
                            )
                        }
                    }
                }
            }
        }
    }

    private var education: some View {
        let wikipedia = model.snapshot?.wikipediaState
        let categories = model.snapshot?.educationCategories ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader("Education", title: "Wikipedia and reference packs.", detail: "This is the old Education lane: Wikipedia plus curated offline learning collections.")

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachInfoPill(title: "Wikipedia", value: wikipedia?.currentSelection?.name ?? "Not selected")
                        RoachInfoPill(title: "Options", value: "\(wikipedia?.options.count ?? 0) packages")
                        RoachInfoPill(title: "Collections", value: "\(categories.count) categories")
                    }
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                ForEach(categories.prefix(6)) { category in
                    RoachInsetPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(category.description ?? "Curated offline education pack")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                            Text(category.tiers.first(where: { $0.recommended == true })?.name ?? category.tiers.first?.name ?? "Tiered")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)
                        }
                    }
                }
            }
        }
    }

    private var archives: some View {
        let archives = model.snapshot?.siteArchives ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                RoachSectionHeader("Archives", title: "Saved sites stay close.", detail: "Your web archiver is still here. This pane gives it a native home again.")
            }

            if archives.isEmpty {
                RoachInsetPanel {
                    Text("No archived sites yet.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            } else {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    ForEach(archives.prefix(12)) { archive in
                        RoachInsetPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(archive.title ?? archive.slug)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                Text(archive.url ?? archive.slug)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private var knowledge: some View {
        let files = model.snapshot?.knowledgeFiles ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                RoachSectionHeader("Vault", title: "Contained sources.", detail: "Your notes, references, and saved files stay close to the workspace.")
            }

            if files.isEmpty {
                RoachInsetPanel {
                    Text("No indexed files yet.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            } else {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    ForEach(files.prefix(12), id: \.self) { file in
                        RoachInsetPanel {
                            Text(file)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var runtime: some View {
        let system = model.snapshot?.systemInfo
        let serverInfo = model.snapshot?.serverInfo

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RoachSectionHeader("Runtime", title: "Contained and recoverable.", detail: "One local gateway in front, support services quietly doing their job behind it.")
                        Spacer()
                        Button(model.isLoading ? "Refreshing..." : "Refresh Runtime") {
                            Task { await model.refreshRuntimeState() }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(model.isLoading)
                    }

                    VStack(spacing: 12) {
                        RoachStatusRow(title: "Install Root", value: model.installPath, accent: RoachPalette.green)
                        RoachStatusRow(title: "Server Target", value: serverInfo?.target ?? "Loading", accent: RoachPalette.green)
                        RoachStatusRow(title: "Host", value: system?.os.hostname ?? "Loading", accent: RoachPalette.green)
                    }
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                RoachMetricCard(label: "CPU", value: system?.cpu.brand ?? "Loading", detail: "Apple Silicon optimized path")
                RoachMetricCard(label: "Memory", value: memoryLabel(system?.mem.total), detail: system?.hardwareProfile.memoryTier.capitalized ?? "Memory tier")
                RoachMetricCard(label: "Logs", value: serverInfo?.logPath ?? "Loading", detail: "Runtime log location")
            }
        }
    }

    private var summaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)]
    }

    private var providerSummary: String {
        guard let providers = model.snapshot?.providers.providers else {
            return "Loading"
        }

        let available = providers.values.filter(\.available).count
        return "\(available) Active"
    }

    private func providerValue(_ provider: AIRuntimeStatusResponse?) -> String {
        guard let provider else { return "Loading" }
        return provider.available ? (provider.source.capitalized) : "Unavailable"
    }

    private func memoryLabel(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Loading" }
        let gigabytes = Double(bytes) / 1_073_741_824
        return "\(Int(gigabytes.rounded())) GB"
    }

    private var roachClawSummary: String {
        let roachClaw = model.snapshot?.roachClaw
        return roachClaw?.resolvedDefaultModel ?? roachClaw?.defaultModel ?? model.config.roachClawDefaultModel
    }

    private var educationSummary: String {
        if let current = model.snapshot?.wikipediaState.currentSelection?.name {
            return current
        }
        return "\(model.snapshot?.educationCategories.count ?? 0) packs"
    }

    private func suiteCard(title: String, detail: String, value: String, pane: WorkspacePane) -> some View {
        Button {
            model.selectedPane = pane
        } label: {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text(detail)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RoachPalette.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
final class RoachNetMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
