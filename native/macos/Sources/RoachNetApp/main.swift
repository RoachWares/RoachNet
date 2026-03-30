import SwiftUI
import AppKit
import WebKit
import RoachNetCore
import RoachNetDesign

enum WorkspacePane: String, CaseIterable, Identifiable {
    case suite = "Suite"
    case home = "Home"
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
        case .home: return "house.fill"
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
        case .home: return "Command grid"
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

struct CommandGridItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let badge: String?
    let systemImage: String
    let routePath: String
}

struct PresentedWebSurface {
    let title: String
    let url: URL
}

private struct NativeWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

private struct EmbeddedRouteView: View {
    let title: String
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack {
            RoachBackground()

            VStack(spacing: 16) {
                RoachInsetPanel {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(RoachPalette.text)
                            Text(url.absoluteString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button("Open in Browser") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Close") {
                            onClose()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    }
                }

                NativeWebView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: 1)
                    )
            }
            .padding(24)
        }
        .frame(minWidth: 1080, minHeight: 760)
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var selectedPane: WorkspacePane? = .home
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
    @Published var selectedWikipediaOptionId: String = "none"
    @Published var isApplyingDefaults = false
    @Published var isSendingPrompt = false
    @Published var activeActions: Set<String> = []
    @Published var presentedWebSurface: PresentedWebSurface?
    private var attemptedRoachClawBootstrap = false
    private var refreshLoopTask: Task<Void, Never>?

    var setupCompleted: Bool { config.setupCompletedAt != nil }
    var installPath: String { config.installPath.isEmpty ? RoachNetRepositoryLocator.defaultInstallPath() : config.installPath }
    var installedAppPath: String {
        config.installedAppPath.isEmpty ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath) : config.installedAppPath
    }

    func refreshConfigOnly() {
        config = RoachNetRepositoryLocator.readConfig()
        statusLine = setupCompleted ? "Setup complete." : "Setup still required."
    }

    deinit {
        refreshLoopTask?.cancel()
    }

    func startPolling() {
        refreshLoopTask?.cancel()
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.refreshRuntimeState(silently: true)
            }
        }
    }

    func refreshRuntimeState(silently: Bool = false) async {
        refreshConfigOnly()
        guard setupCompleted else { return }
        let currentConfig = config

        if !silently {
            isLoading = true
            errorLine = nil
            statusLine = "Refreshing local runtime."
        }

        do {
            snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: currentConfig)
            synchronizeWikipediaSelection()
            await bootstrapRoachClawIfNeeded(using: currentConfig)
            if !silently {
                statusLine = "Local runtime ready."
            }
        } catch {
            if !silently {
                errorLine = error.localizedDescription
                statusLine = "Runtime unavailable."
            }
        }

        if !silently {
            isLoading = false
        }
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

    func openRoute(_ routePath: String, title: String) async {
        do {
            let url = try await ManagedAppRuntimeBridge.shared.resolveRouteURL(using: config, path: routePath)
            presentedWebSurface = PresentedWebSurface(title: title, url: url)
        } catch {
            errorLine = error.localizedDescription
        }
    }

    func openService(_ service: ManagedSystemService) async {
        guard let location = service.ui_location, !location.isEmpty else {
            errorLine = "This service does not expose a UI location yet."
            return
        }

        do {
            let resolvedPath: String

            if URL(string: location)?.scheme != nil {
                if let url = URL(string: location) {
                    presentedWebSurface = PresentedWebSurface(
                        title: service.friendly_name ?? service.service_name,
                        url: url
                    )
                    return
                }
                resolvedPath = location
            } else if Int(location) != nil {
                let homeURL = try await ManagedAppRuntimeBridge.shared.resolveRouteURL(using: config, path: "/home")
                let host = homeURL.host ?? "127.0.0.1"
                let scheme = homeURL.scheme ?? "http"
                resolvedPath = "\(scheme)://\(host):\(location)"
            } else if location.hasPrefix("/") {
                resolvedPath = location
            } else {
                resolvedPath = "/\(location)"
            }

            if let absoluteURL = URL(string: resolvedPath), absoluteURL.scheme != nil {
                presentedWebSurface = PresentedWebSurface(
                    title: service.friendly_name ?? service.service_name,
                    url: absoluteURL
                )
                return
            }

            let url = try await ManagedAppRuntimeBridge.shared.resolveRouteURL(using: config, path: resolvedPath)
            presentedWebSurface = PresentedWebSurface(
                title: service.friendly_name ?? service.service_name,
                url: url
            )
        } catch {
            errorLine = error.localizedDescription
        }
    }

    func downloadBaseMapAssets() async {
        await runAction("maps-base-assets", status: "Queueing base map assets.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadBaseMapAssets(using: config)
        }
    }

    func downloadMapCollection(_ slug: String) async {
        await runAction("map-\(slug)", status: "Queueing map collection.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadMapCollection(using: config, slug: slug)
        }
    }

    func downloadEducationTier(categorySlug: String, tierSlug: String) async {
        await runAction("education-\(categorySlug)-\(tierSlug)", status: "Queueing education content.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadEducationTier(
                using: config,
                categorySlug: categorySlug,
                tierSlug: tierSlug
            )
        }
    }

    func applyWikipediaSelection() async {
        let optionId = selectedWikipediaOptionId
        await runAction("wikipedia-\(optionId)", status: "Updating Wikipedia selection.") {
            _ = try await ManagedAppRuntimeBridge.shared.selectWikipedia(using: config, optionId: optionId)
        }
    }

    private func runAction(
        _ actionID: String,
        status: String,
        operation: @escaping () async throws -> Void
    ) async {
        guard !activeActions.contains(actionID) else { return }

        activeActions.insert(actionID)
        errorLine = nil
        statusLine = status

        do {
            try await operation()
            try? await Task.sleep(for: .milliseconds(400))
            await refreshRuntimeState(silently: true)
            statusLine = "Action queued successfully."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Action failed."
        }

        activeActions.remove(actionID)
    }

    private func synchronizeWikipediaSelection() {
        guard let wikipediaState = snapshot?.wikipediaState else { return }

        if let current = wikipediaState.currentSelection?.optionId {
            selectedWikipediaOptionId = current
            return
        }

        if wikipediaState.options.contains(where: { $0.id == selectedWikipediaOptionId }) {
            return
        }

        selectedWikipediaOptionId = wikipediaState.options.first?.id ?? "none"
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
            model.startPolling()
        }
        .sheet(
            isPresented: Binding(
                get: { model.presentedWebSurface != nil },
                set: { if !$0 { model.presentedWebSurface = nil } }
            )
        ) {
            if let surface = model.presentedWebSurface {
                EmbeddedRouteView(
                    title: surface.title,
                    url: surface.url,
                    onClose: { model.presentedWebSurface = nil }
                )
            }
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
                        switch model.selectedPane ?? .home {
                        case .suite:
                            suite
                        case .home:
                            home
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
                Text(model.selectedPane?.rawValue ?? "Home")
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

    private var home: some View {
        let system = model.snapshot?.systemInfo
        let hardware = system?.hardwareProfile
        let roachClaw = model.snapshot?.roachClaw

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader(
                        "Home",
                        title: "Offline command grid for maps, archives, local AI, and field ops.",
                        detail: "RoachNet keeps your maps, archives, and local AI online when everything else drops."
                    )

                    Text("Run field-ready tools, browse offline references, manage local models, and keep your day-to-day workflows moving without depending on an external network.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachInfoPill(title: "Offline First", value: "Maps, Docs, AI")
                        RoachInfoPill(title: "Runtime", value: roachClaw?.preferredMode ?? hardware?.recommendedRuntime ?? "native_local")
                        RoachInfoPill(title: "Default Model", value: roachClaw?.resolvedDefaultModel ?? roachClaw?.defaultModel ?? model.config.roachClawDefaultModel)
                    }
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                RoachMetricCard(
                    label: "Network State",
                    value: model.snapshot?.internetConnected == true ? "Internet Detected" : "Offline Mode",
                    detail: model.snapshot?.internetConnected == true
                        ? "RoachNet can fetch updates and content packs."
                        : "Local tools remain accessible inside the grid."
                )
                RoachMetricCard(
                    label: "AI Runtime",
                    value: roachClaw?.ollama.available == true ? "Connected" : "Not Linked",
                    detail: roachClaw?.ollama.available == true
                        ? "Connected via \(roachClaw?.ollama.source ?? "local") at \(roachClaw?.ollama.baseUrl ?? "configured endpoint")"
                        : "Use AI Control or Easy Setup to connect a runtime."
                )
                RoachMetricCard(
                    label: "Storage & Archives",
                    value: "\(model.snapshot?.knowledgeFiles.count ?? 0) Files",
                    detail: "Maps, ZIM archives, benchmarks, and knowledge files stay on your box."
                )
                RoachMetricCard(
                    label: "Privacy",
                    value: "Local-First Ops",
                    detail: "Keep model traffic, content access, and operations close to the machine."
                )
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader(
                        "Command Grid",
                        title: "Everything you need, in one calm place.",
                        detail: "Launch installed RoachNet services and the core command surfaces from the native shell."
                    )

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                        ForEach(homeGridItems) { item in
                            Button {
                                Task { await model.openRoute(item.routePath, title: item.title) }
                            } label: {
                                commandGridCard(item)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(serviceGridItems) { item in
                            Button {
                                Task {
                                    if let service = model.snapshot?.services.first(where: { $0.service_name == item.id }) {
                                        await model.openService(service)
                                    }
                                }
                            } label: {
                                commandGridCard(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachKicker("System Meta")
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RoachNet")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(RoachPalette.text)
                            Text("Offline command grid v\(bundleVersion)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }

                        Spacer()

                        footerAction(title: "Diagnostics", path: "/settings/system")
                        footerAction(title: "Stealth", path: "/settings/legal")
                        footerAction(title: "Debug Info", path: "/api/system/debug-info")
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
                        Button("Open AI Control") {
                            Task { await model.openRoute("/settings/ai", title: "AI Control") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
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
        let activeMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" } ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RoachSectionHeader("Maps", title: "Offline regions, ready to stage.", detail: "Download region packs, install the base atlas, and open the full map surface when you need it.")
                        Spacer()
                        Button("Open Full Maps") {
                            Task { await model.openRoute("/maps", title: "Maps") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        Button(model.activeActions.contains("maps-base-assets") ? "Installing..." : "Install Base Assets") {
                            Task { await model.downloadBaseMapAssets() }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.activeActions.contains("maps-base-assets"))
                    }

                    if !activeMapDownloads.isEmpty {
                        downloadsPanel(title: "Map Downloads", jobs: activeMapDownloads)
                    }
                }
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
                            Button(
                                (collection.installed_count ?? 0) >= (collection.total_count ?? collection.resources.count)
                                    ? "Installed"
                                    : (model.activeActions.contains("map-\(collection.slug)") ? "Queueing..." : "Download Collection")
                            ) {
                                Task { await model.downloadMapCollection(collection.slug) }
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(
                                model.activeActions.contains("map-\(collection.slug)") ||
                                (collection.installed_count ?? 0) >= (collection.total_count ?? collection.resources.count)
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
        let activeEducationDownloads = model.snapshot?.downloads.filter { $0.filetype == "zim" } ?? []
        let selectedWikipediaName = wikipedia?.options.first(where: { $0.id == model.selectedWikipediaOptionId })?.name

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        RoachSectionHeader("Education", title: "Wikipedia and reference packs.", detail: "Pick a Wikipedia bundle, queue recommended content tiers, or open the full docs and setup surfaces.")
                        Spacer()
                        Button("Open Docs") {
                            Task { await model.openRoute("/docs/home", title: "Docs") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        Button("Easy Setup") {
                            Task { await model.openRoute("/easy-setup", title: "Easy Setup") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachInfoPill(title: "Wikipedia", value: selectedWikipediaName ?? "Not selected")
                        RoachInfoPill(title: "Options", value: "\(wikipedia?.options.count ?? 0) packages")
                        RoachInfoPill(title: "Collections", value: "\(categories.count) categories")
                    }

                    if let wikipedia {
                        HStack(spacing: 12) {
                            Picker("Wikipedia", selection: $model.selectedWikipediaOptionId) {
                                ForEach(wikipedia.options) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 360, alignment: .leading)

                            Button(model.activeActions.contains("wikipedia-\(model.selectedWikipediaOptionId)") ? "Applying..." : "Apply Wikipedia") {
                                Task { await model.applyWikipediaSelection() }
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(model.activeActions.contains("wikipedia-\(model.selectedWikipediaOptionId)"))
                        }
                    }

                    if !activeEducationDownloads.isEmpty {
                        downloadsPanel(title: "Content Downloads", jobs: activeEducationDownloads)
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
                            let recommendedTier = category.tiers.first(where: { $0.recommended == true }) ?? category.tiers.first
                            Button(
                                model.activeActions.contains("education-\(category.slug)-\(recommendedTier?.slug ?? "")")
                                    ? "Queueing..."
                                    : "Download Recommended Tier"
                            ) {
                                if let recommendedTier {
                                    Task {
                                        await model.downloadEducationTier(
                                            categorySlug: category.slug,
                                            tierSlug: recommendedTier.slug
                                        )
                                    }
                                }
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(recommendedTier == nil || model.activeActions.contains("education-\(category.slug)-\(recommendedTier?.slug ?? "")"))
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
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RoachSectionHeader("Archives", title: "Saved sites stay close.", detail: "Open the offline web app manager or review mirrored sites already on disk.")
                        Spacer()
                        Button("Open Offline Web Apps") {
                            Task { await model.openRoute("/site-archives", title: "Offline Web Apps") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
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
                        Button("Settings") {
                            Task { await model.openRoute("/settings/system", title: "Settings") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
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

    private var homeGridItems: [CommandGridItem] {
        [
            CommandGridItem(
                id: "maps",
                title: "Maps",
                detail: "View offline maps.",
                badge: "Core Capability",
                systemImage: "map.fill",
                routePath: "/maps"
            ),
            CommandGridItem(
                id: "ai-control",
                title: "AI Control",
                detail: "Link Ollama and OpenClaw runtimes, verify endpoints, and tune local AI access.",
                badge: "Runtime",
                systemImage: "cpu.fill",
                routePath: "/settings/ai"
            ),
            CommandGridItem(
                id: "easy-setup",
                title: "Easy Setup",
                detail: "Use the guided setup flow to connect runtimes, download content, and stage your offline toolkit.",
                badge: setupBadge,
                systemImage: "bolt.fill",
                routePath: "/easy-setup"
            ),
            CommandGridItem(
                id: "offline-web",
                title: "Offline Web Apps",
                detail: "Mirror standard websites into browseable offline local web apps.",
                badge: "Archived",
                systemImage: "globe.badge.chevron.backward",
                routePath: "/site-archives"
            ),
            CommandGridItem(
                id: "install-apps",
                title: "Install Apps",
                detail: "Browse RoachNet modules, stage upstream tools, and make them feel local.",
                badge: "App Store",
                systemImage: "square.grid.2x2.fill",
                routePath: "/settings/apps"
            ),
            CommandGridItem(
                id: "docs",
                title: "Docs",
                detail: "Read RoachNet manuals, deployment notes, and field references.",
                badge: "Local Reference",
                systemImage: "doc.text.fill",
                routePath: "/docs/home"
            ),
            CommandGridItem(
                id: "settings",
                title: "Settings",
                detail: "Tune RoachNet, providers, storage paths, and local services.",
                badge: "System",
                systemImage: "gearshape.fill",
                routePath: "/settings/system"
            ),
        ]
    }

    private var serviceGridItems: [CommandGridItem] {
        let services = model.snapshot?.services ?? []

        return services
            .filter { ($0.installed ?? false) && !($0.ui_location ?? "").isEmpty }
            .sorted {
                ($0.display_order ?? 10_000, $0.friendly_name ?? $0.service_name)
                    < ($1.display_order ?? 10_000, $1.friendly_name ?? $1.service_name)
            }
            .map { service in
                let descriptor = brandedServiceDescriptor(for: service)

                return CommandGridItem(
                    id: service.service_name,
                    title: descriptor.title,
                    detail: descriptor.detail,
                    badge: descriptor.badge,
                    systemImage: descriptor.systemImage,
                    routePath: service.ui_location ?? ""
                )
            }
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
        if
            let selectedID = model.snapshot?.wikipediaState.currentSelection?.optionId,
            let name = model.snapshot?.wikipediaState.options.first(where: { $0.id == selectedID })?.name
        {
            return name
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

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0.0.0"
    }

    private var setupBadge: String {
        model.setupCompleted ? "Configured" : "Start Here"
    }

    private func brandedServiceDescriptor(
        for service: ManagedSystemService
    ) -> (title: String, detail: String, badge: String?, systemImage: String) {
        let poweredBy = service.powered_by?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBadge = poweredBy.flatMap { $0.isEmpty ? nil : "Powered by \($0)" } ?? "RoachNet Module"

        switch service.service_name {
        case "nomad_kiwix_server":
            return (
                title: "RoachNet Library",
                detail: "Open offline encyclopedias, survival references, and field manuals without leaving the native shell.",
                badge: defaultBadge,
                systemImage: "books.vertical.fill"
            )
        case "nomad_ollama":
            return (
                title: "RoachNet Chat",
                detail: "Run local AI chat and tooling with the model lane RoachNet is already managing.",
                badge: defaultBadge,
                systemImage: "sparkles"
            )
        case "nomad_kolibri":
            return (
                title: "RoachNet Academy",
                detail: "Launch structured education content and offline coursework from the same command grid.",
                badge: defaultBadge,
                systemImage: "graduationcap.fill"
            )
        case "nomad_flatnotes":
            return (
                title: "RoachNet Notes",
                detail: "Keep quick notes, fragments, and working references local to the machine.",
                badge: defaultBadge,
                systemImage: "note.text"
            )
        case "nomad_cyberchef":
            return (
                title: "RoachNet Data Lab",
                detail: "Use encoding, decoding, and analysis tools inside the broader RoachNet workflow.",
                badge: defaultBadge,
                systemImage: "hammer.fill"
            )
        default:
            return (
                title: service.friendly_name ?? service.service_name,
                detail: service.description ?? "Open this installed RoachNet service.",
                badge: defaultBadge,
                systemImage: "app.connected.to.app.below.fill"
            )
        }
    }

    private func commandGridCard(_ item: CommandGridItem) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(RoachPalette.green)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.92))
                        )

                    Spacer(minLength: 12)

                    if let badge = item.badge {
                        RoachTag(badge, accent: badge.localizedCaseInsensitiveContains("start")
                            ? RoachPalette.warning
                            : RoachPalette.magenta)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                    Text(item.detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        }
    }

    private func footerAction(title: String, path: String) -> some View {
        Button(title) {
            Task { await model.openRoute(path, title: title) }
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private func downloadsPanel(title: String, jobs: [ManagedDownloadJob]) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachKicker(title)

                ForEach(jobs.prefix(5)) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text((job.filepath as NSString).lastPathComponent)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(job.progress)%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)
                        }

                        Text(job.status ?? "queued")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(RoachPalette.border.opacity(0.8))
                                Capsule()
                                    .fill(RoachPalette.green)
                                    .frame(width: max(12, proxy.size.width * CGFloat(job.progress) / 100))
                            }
                        }
                        .frame(height: 6)

                        if let failedReason = job.failedReason, !failedReason.isEmpty {
                            Text(failedReason)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RoachPalette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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
