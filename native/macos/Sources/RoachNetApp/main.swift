import SwiftUI
import AppKit
import AVKit
import Carbon
import WebKit
import RoachNetCore
import RoachNetDesign

enum WorkspacePane: String, CaseIterable, Identifiable {
    case suite = "Suite"
    case home = "Home"
    case dev = "Dev"
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
        case .dev: return "terminal.fill"
        case .roachClaw: return "sparkles"
        case .maps: return "map.fill"
        case .education: return "graduationcap.fill"
        case .archives: return "shippingbox.fill"
        case .knowledge: return "books.vertical.fill"
        case .runtime: return "server.rack"
        }
    }

    var assetName: String? {
        switch self {
        case .roachClaw:
            return "roachclaw-logo.png"
        default:
            return nil
        }
    }

    var subtitle: String {
        switch self {
        case .suite: return "App surfaces"
        case .home: return "Command grid"
        case .dev: return "Code and shell"
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
    let isInstalled: Bool
}

struct PresentedWebSurface {
    let title: String
    let url: URL
}

private struct GuideFeature: Identifiable {
    let id: String
    let title: String
    let detail: String
}

private struct ReadinessStep: Identifiable {
    let id: String
    let title: String
    let detail: String
    let status: String
    let systemImage: String
    let accent: Color
    let routePath: String?
    let isReady: Bool
}

private enum CommandPaletteTarget: Hashable {
    case pane(WorkspacePane)
    case route(title: String, path: String)
    case service(serviceName: String)
    case refreshRuntime
    case launchGuide
    case externalURL(String)
}

private enum HomeMenuSection: String, CaseIterable, Identifiable {
    case commandDeck = "Command Deck"
    case installedModules = "Installed Modules"
    case availableModules = "Available Modules"

    var id: String { rawValue }
}

private struct CommandPaletteEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let target: CommandPaletteTarget
    let keywords: [String]

    init(
        id: String,
        title: String,
        detail: String,
        systemImage: String,
        target: CommandPaletteTarget,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.target = target
        self.keywords = keywords
    }
}

private extension Notification.Name {
    static let roachNetOpenCommandPalette = Notification.Name("roachnet.open-command-palette")
    static let roachNetOpenDetachedCommandPalette = Notification.Name("roachnet.open-detached-command-palette")
}

private enum RoachNetGlobalHotKey {
    static let commandPaletteID: UInt32 = 1
    static let keyCode: UInt32 = UInt32(kVK_ANSI_R)
    static let modifiers: UInt32 = UInt32(cmdKey) | UInt32(shiftKey)
    static let hint = "Shift-Command-R"
}

private func roachNetFourCharCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { partial, byte in
        (partial << 8) + OSType(byte)
    }
}

private func filteredCommandPaletteEntries(
    from entries: [CommandPaletteEntry],
    query: String
) -> [CommandPaletteEntry] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
        return entries
    }

    let normalizedQuery = trimmedQuery.lowercased()
    return entries.filter { entry in
        let haystack = "\(entry.title) \(entry.detail) \(entry.keywords.joined(separator: " "))".lowercased()
        return haystack.contains(normalizedQuery)
    }
}

private extension CommandPaletteTarget {
    var activatesMainShellWhenSelectedFromDetachedPalette: Bool {
        switch self {
        case .externalURL:
            return false
        case .pane, .route, .service, .refreshRuntime, .launchGuide:
            return true
        }
    }
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
        GeometryReader { proxy in
            let isTight = proxy.size.width < 980

            ZStack {
                RoachBackground()

                VStack(spacing: 16) {
                    RoachInsetPanel {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title)
                                        .font(.system(size: isTight ? 21 : 24, weight: .bold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(url.absoluteString)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(RoachPalette.muted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                HStack(spacing: 12) {
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

                            VStack(alignment: .leading, spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title)
                                        .font(.system(size: isTight ? 21 : 24, weight: .bold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(url.absoluteString)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(RoachPalette.muted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                HStack(spacing: 12) {
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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    NativeWebView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                }
                .padding(isTight ? 16 : 24)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct CommandPaletteSheet: View {
    let entries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var queryFocused: Bool

    private var filteredEntries: [CommandPaletteEntry] {
        filteredCommandPaletteEntries(from: entries, query: query)
    }

    var body: some View {
        GeometryReader { proxy in
            let isTight = proxy.size.width < 760 || proxy.size.height < 560

            ZStack {
                RoachBackground()

                RoachPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Command Palette")
                                        .font(.system(size: isTight ? 24 : 28, weight: .bold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text("Jump through the command deck without hunting through the shell.")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                    Text("Cmd-K inside RoachNet · \(RoachNetGlobalHotKey.hint) from anywhere on your Mac")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(RoachPalette.green)
                                }

                                Spacer()

                                Button("Close") {
                                    onDismiss()
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }

                            VStack(alignment: .leading, spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Command Palette")
                                        .font(.system(size: isTight ? 24 : 28, weight: .bold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text("Jump through the command deck without hunting through the shell.")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                    Text("Cmd-K inside RoachNet · \(RoachNetGlobalHotKey.hint) from anywhere on your Mac")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(RoachPalette.green)
                                }

                                Button("Close") {
                                    onDismiss()
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }

                        RoachInsetPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(RoachPalette.green)

                                    TextField("Search commands, views, tools, modules, and routes", text: $query)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(RoachPalette.text)
                                        .focused($queryFocused)
                                }
                                Text("Showing \(min(filteredEntries.count, 18)) of \(entries.count) commands")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                            }
                            .padding(.horizontal, 4)
                        }

                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(filteredEntries.prefix(18)) { entry in
                                    Button {
                                        onSelect(entry)
                                    } label: {
                                        RoachInsetPanel {
                                            HStack(spacing: 12) {
                                                Image(systemName: entry.systemImage)
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundStyle(RoachPalette.green)
                                                    .frame(width: 30, height: 30)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                            .fill(RoachPalette.panelGlass)
                                                    )

                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(entry.title)
                                                        .font(.system(size: 15, weight: .semibold))
                                                        .foregroundStyle(RoachPalette.text)
                                                    Text(entry.detail)
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundStyle(RoachPalette.muted)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }

                                                Spacer()
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(RoachCardButtonStyle())
                                }

                                if filteredEntries.isEmpty {
                                    RoachInsetPanel {
                                        Text("No commands matched that search yet.")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(RoachPalette.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: min(proxy.size.width - 28, 700), maxHeight: min(proxy.size.height - 28, 540))
                .padding(14)
            }
        }
        .onAppear {
            queryFocused = true
        }
        .onExitCommand {
            onDismiss()
        }
    }
}

private struct DetachedCommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var queryFocused: Bool

    private var filteredEntries: [CommandPaletteEntry] {
        filteredCommandPaletteEntries(from: entries, query: query)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                RoachPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("RoachNet Command Bar")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(RoachPalette.text)
                                Text("Quick-launch commands without bringing the full shell forward.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                            }

                            Spacer()

                            Text(RoachNetGlobalHotKey.hint)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(RoachPalette.panelGlass)
                                )
                        }

                        RoachInsetPanel {
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(RoachPalette.green)

                                TextField("Search commands, modules, routes, and installs", text: $query)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(RoachPalette.text)
                                    .focused($queryFocused)
                            }
                            .padding(.horizontal, 4)
                        }

                        Text("Showing \(min(filteredEntries.count, 8)) of \(entries.count) commands")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)

                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(filteredEntries.prefix(8)) { entry in
                                    Button {
                                        onSelect(entry)
                                    } label: {
                                        RoachInsetPanel {
                                            HStack(spacing: 12) {
                                                Image(systemName: entry.systemImage)
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(RoachPalette.green)
                                                    .frame(width: 28, height: 28)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                            .fill(RoachPalette.panelGlass)
                                                    )

                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(entry.title)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(RoachPalette.text)
                                                    Text(entry.detail)
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundStyle(RoachPalette.muted)
                                                        .lineLimit(2)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }

                                                Spacer()
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(RoachCardButtonStyle())
                                }

                                if filteredEntries.isEmpty {
                                    RoachInsetPanel {
                                        Text("No commands matched that search yet.")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(RoachPalette.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(
                    width: min(proxy.size.width - 32, 680),
                    height: min(proxy.size.height - 40, 420)
                )
                .padding(.top, 22)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
        }
        .onAppear {
            queryFocused = true
        }
        .onExitCommand {
            onDismiss()
        }
    }
}

private final class DetachedCommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DetachedCommandPaletteCoordinator: ObservableObject {
    private var windowController: DetachedCommandPaletteWindowController?

    func present(
        entries: [CommandPaletteEntry],
        onSelect: @escaping (CommandPaletteEntry) -> Void
    ) {
        dismiss()

        let controller = DetachedCommandPaletteWindowController(entries: entries) { [weak self] entry in
            self?.dismiss()
            onSelect(entry)
        } onClose: { [weak self] in
            self?.windowController = nil
        }

        windowController = controller
        controller.showPalette()
    }

    func dismiss() {
        windowController?.close()
        windowController = nil
    }
}

private final class DetachedCommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        entries: [CommandPaletteEntry],
        onSelect: @escaping (CommandPaletteEntry) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose

        let window = DetachedCommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.isFloatingPanel = true
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace, .transient]
        window.animationBehavior = .utilityWindow
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let rootView = DetachedCommandPaletteView(
            entries: entries,
            onSelect: { [weak self] entry in
                onSelect(entry)
                self?.close()
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )

        window.contentViewController = NSHostingController(rootView: rootView)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showPalette() {
        guard let window else { return }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let width: CGFloat = 720
            let height: CGFloat = 460
            let origin = NSPoint(
                x: frame.midX - (width / 2),
                y: max(frame.minY + 40, frame.maxY - height - 88)
            )
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        }

        window.orderFrontRegardless()
        window.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
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
    @Published var selectedChatModel: String = ""
    @Published var roachBrainQuery: String = ""
    @Published var roachBrainMemories: [RoachBrainMemory] = []
    @Published var selectedWikipediaOptionId: String = "none"
    @Published var isApplyingDefaults = false
    @Published var isSendingPrompt = false
    @Published var isRelocatingStorage = false
    @Published var activeActions: Set<String> = []
    @Published var presentedWebSurface: PresentedWebSurface?
    private var attemptedRoachClawBootstrap = false
    private var attemptedRoachClawServiceBootstrap = false
    private var attemptedInstalledServiceBootstrap = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var queuedRefreshRequested = false
    private var queuedRefreshSilent = true
    private var lastHandledIncomingURL: (value: String, date: Date)?

    var setupCompleted: Bool { config.setupCompletedAt != nil }
    var installPath: String { config.installPath.isEmpty ? RoachNetRepositoryLocator.defaultInstallPath() : config.installPath }
    var installedAppPath: String {
        config.installedAppPath.isEmpty ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath) : config.installedAppPath
    }
    var storagePath: String {
        config.storagePath.isEmpty ? RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath) : config.storagePath
    }
    var chatModelOptions: [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        let configuredExoModel = config.exoModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.distributedInferenceBackend == "exo", !configuredExoModel.isEmpty, seen.insert(configuredExoModel).inserted {
            ordered.append(configuredExoModel)
        }

        let preferredModels = [
            snapshot?.roachClaw.resolvedDefaultModel,
            snapshot?.roachClaw.defaultModel,
            config.roachClawDefaultModel,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        for modelName in preferredModels {
            if seen.insert(modelName).inserted {
                ordered.append(modelName)
            }
        }

        for modelName in snapshot?.installedModels.map(\.name) ?? [] {
            if seen.insert(modelName).inserted {
                ordered.append(modelName)
            }
        }

        return ordered
    }
    var recommendedLocalModels: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        let recommendedClass = snapshot?.systemInfo.hardwareProfile.recommendedModelClass.lowercased() ?? ""
        let memoryTier = snapshot?.systemInfo.hardwareProfile.memoryTier.lowercased() ?? ""

        func append(_ modelName: String) {
            guard !modelName.isEmpty, seen.insert(modelName).inserted else { return }
            ordered.append(modelName)
        }

        // Keep first boot fast with a compact coder model, then surface the
        // larger machine-appropriate upgrade path in the same order the UI shows it.
        append("qwen2.5-coder:1.5b")

        if recommendedClass.contains("7b") || recommendedClass.contains("14b") || memoryTier == "balanced" || memoryTier == "high" {
            append("qwen2.5-coder:7b")
        }

        if recommendedClass.contains("14b") || memoryTier == "high" {
            append("qwen2.5-coder:14b")
        }

        append(config.roachClawDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines))
        return ordered
    }
    var recommendedLocalModelSummary: String {
        if let hardwareProfile = snapshot?.systemInfo.hardwareProfile {
            return "\(hardwareProfile.platformLabel) is best suited to \(hardwareProfile.recommendedModelClass). RoachNet quickstarts with qwen2.5-coder:1.5b so the first local lane comes up faster."
        }

        return "RoachNet quickstarts with qwen2.5-coder:1.5b, then recommends a larger local coder model once hardware guidance is available."
    }
    var displayedRoachClawDefaultModel: String {
        let configuredModel = config.roachClawDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let roachClaw = snapshot?.roachClaw

        if config.pendingRoachClawSetup, !configuredModel.isEmpty {
            return configuredModel
        }

        let resolvedModel = roachClaw?.resolvedDefaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolvedModel.isEmpty {
            return resolvedModel
        }

        let fallbackModel = roachClaw?.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackModel.isEmpty {
            return fallbackModel
        }

        return configuredModel
    }
    var selectedChatModelLabel: String {
        chatModelLabel(for: resolvedChatModel())
    }
    var hasCloudChatFallback: Bool {
        preferredCloudChatModel(excluding: nil) != nil
    }
    var roachBrainSuggestedMatches: [RoachBrainMatch] {
        let query = [promptDraft, chatLines.last?.text ?? "", displayedRoachClawDefaultModel]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        return RoachBrainStore.search(roachBrainMemories, query: query, tags: ["roachclaw", "chat"], limit: 4)
    }
    var roachBrainVisibleMatches: [RoachBrainMatch] {
        let trimmedQuery = roachBrainQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return Array(
                roachBrainMemories
                    .sorted { lhs, rhs in
                        if lhs.pinned != rhs.pinned {
                            return lhs.pinned && !rhs.pinned
                        }
                        return lhs.lastAccessedAt > rhs.lastAccessedAt
                    }
                    .prefix(6)
                    .map { RoachBrainMatch(memory: $0, score: $0.pinned ? 100 : 10, matchedTags: []) }
            )
        }
        return RoachBrainStore.search(roachBrainMemories, query: trimmedQuery, tags: ["roachclaw", "chat"], limit: 6)
    }
    var roachBrainPinnedCount: Int {
        roachBrainMemories.filter(\.pinned).count
    }
    var roachTailActionInFlight: Bool {
        activeActions.contains { $0.hasPrefix("roachtail-") }
    }

    func refreshConfigOnly() {
        config = RoachNetRepositoryLocator.readConfig()
        statusLine = setupCompleted ? "Setup complete." : "Setup still required."
        synchronizeSelectedChatModel()
        refreshRoachBrain()
    }

    func dismissPendingLaunchIntro() {
        guard config.pendingLaunchIntro else { return }

        do {
            var updatedConfig = config
            updatedConfig.pendingLaunchIntro = false
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
            config = updatedConfig
        } catch {
            errorLine = error.localizedDescription
        }
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
        if refreshInFlight {
            queuedRefreshRequested = true
            queuedRefreshSilent = queuedRefreshSilent && silently
            return
        }

        refreshInFlight = true
        defer {
            refreshInFlight = false

            if queuedRefreshRequested {
                let nextSilent = queuedRefreshSilent
                queuedRefreshRequested = false
                queuedRefreshSilent = true

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.refreshRuntimeState(silently: nextSilent)
                }
            }
        }

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
            errorLine = nil
            persistRoachClawSetupCompletionIfNeeded()
            synchronizeWikipediaSelection()
            synchronizeSelectedChatModel()
            await bootstrapRoachClawServiceIfNeeded(using: currentConfig)
            await bootstrapInstalledServicesIfNeeded(using: currentConfig)
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
        var currentConfig = config
        let suggestedModel = recommendedLocalModels.first ?? config.roachClawDefaultModel
        if currentConfig.roachClawDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentConfig.roachClawDefaultModel = suggestedModel
        }
        let currentModel = currentConfig.roachClawDefaultModel
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
            persistRoachClawSetupCompletionIfNeeded()
            synchronizeSelectedChatModel()
            if snapshot?.roachClaw.ready == true {
                statusLine = "Local AI defaults saved."
            } else {
                statusLine = "RoachClaw queued the first local model."
            }
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
        if snapshot?.roachClaw.ready != true {
            await bootstrapRoachClawIfNeeded(using: currentConfig)
        }

        let selectedModel = resolvedChatModel()
        let brainMatches = roachBrainContextMatches(for: trimmedPrompt, tags: ["roachclaw", "chat"])
        let preferredCloudModel = isCloudModel(selectedModel) ? selectedModel : preferredCloudChatModel(excluding: nil)
        let cloudFallbackModel = preferredCloudChatModel(excluding: selectedModel)
        let roachClawReady = snapshot?.roachClaw.ready == true
        let canUseCloudWarmupLane =
            snapshot?.internetConnected == true &&
            preferredCloudModel != nil

        guard roachClawReady || canUseCloudWarmupLane else {
            errorLine = "RoachClaw is still staging its first local model. Keep RoachNet open, or use a connected cloud lane once internet is available."
            statusLine = "Local AI still warming up."
            return
        }

        let shouldPreferCloudWarmupLane =
            (!roachClawReady && canUseCloudWarmupLane) ||
            (
                !isCloudModel(selectedModel) &&
                snapshot?.internetConnected == true &&
                cloudFallbackModel != nil &&
                !chatLines.contains(where: { $0.role == "User" }) &&
                (config.pendingRoachClawSetup || selectedModel == config.roachClawDefaultModel)
            )
        let primaryModel = shouldPreferCloudWarmupLane ? (preferredCloudModel ?? selectedModel) : selectedModel
        let primaryTimeout: TimeInterval
        if isCloudModel(primaryModel) {
            primaryTimeout = 45
        } else if cloudFallbackModel != nil, snapshot?.internetConnected == true {
            primaryTimeout = 12
        } else {
            primaryTimeout = 30
        }

        chatLines.append(.init(role: "User", text: trimmedPrompt))
        promptDraft = ""
        isSendingPrompt = true
        errorLine = nil
        statusLine = isCloudModel(primaryModel)
            ? (roachClawReady ? "Routing prompt through the cloud lane." : "Local AI is still warming up, so RoachNet is using the cloud lane.")
            : "Running local prompt."

        do {
            let response = try await ManagedAppRuntimeBridge.shared.sendChat(
                using: currentConfig,
                model: primaryModel,
                prompt: composedRoachBrainPrompt(from: trimmedPrompt, matches: brainMatches, mode: "RoachClaw workbench"),
                timeout: primaryTimeout
            )
            try? RoachBrainStore.markAccessed(memoryIDs: brainMatches.map(\.id), storagePath: storagePath)
            if primaryModel != selectedModel {
                selectedChatModel = primaryModel
                chatLines.append(
                    .init(
                        role: "System",
                        text: "\(selectedModel) is still warming up, so RoachNet used \(primaryModel) for this first prompt."
                    )
                )
            }
            chatLines.append(.init(role: "RoachClaw", text: response.isEmpty ? "No content returned." : response))
            rememberRoachClawExchange(prompt: trimmedPrompt, response: response, model: primaryModel)
            statusLine = "Prompt complete."
        } catch {
            let fallbackModel = preferredCloudChatModel(excluding: primaryModel)
            if !isCloudModel(primaryModel), let fallbackModel {
                do {
                    statusLine = "Local AI stalled. Retrying with a cloud lane."
                    let fallbackResponse = try await ManagedAppRuntimeBridge.shared.sendChat(
                        using: currentConfig,
                        model: fallbackModel,
                        prompt: composedRoachBrainPrompt(from: trimmedPrompt, matches: brainMatches, mode: "RoachClaw workbench"),
                        timeout: 45
                    )
                    try? RoachBrainStore.markAccessed(memoryIDs: brainMatches.map(\.id), storagePath: storagePath)
                    selectedChatModel = fallbackModel
                    chatLines.append(
                        .init(
                            role: "System",
                            text: "\(primaryModel) stalled, so RoachNet retried with \(fallbackModel)."
                        )
                    )
                    chatLines.append(
                        .init(
                            role: "RoachClaw",
                            text: fallbackResponse.isEmpty ? "No content returned." : fallbackResponse
                        )
                    )
                    rememberRoachClawExchange(prompt: trimmedPrompt, response: fallbackResponse, model: fallbackModel)
                    statusLine = "Prompt complete."
                    isSendingPrompt = false
                    return
                } catch {
                    errorLine = error.localizedDescription
                    statusLine = "Prompt failed."
                    isSendingPrompt = false
                    return
                }
            }

            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("timed out") {
                errorLine = "The selected model took too long to answer. Open Model Store or switch to a cloud lane from the RoachClaw workbench."
            } else {
                errorLine = description
            }
            statusLine = "Prompt failed."
        }

        isSendingPrompt = false
    }

    func requestDeveloperAssist(prompt: String) async throws -> String {
        guard setupCompleted else {
            throw NSError(domain: "RoachNetDeveloperAssist", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Finish setup before using the coding assistant."
            ])
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw NSError(domain: "RoachNetDeveloperAssist", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Enter a coding task before calling RoachClaw."
            ])
        }

        let currentConfig = config
        if snapshot?.roachClaw.ready != true {
            await bootstrapRoachClawIfNeeded(using: currentConfig)
        }

        let selectedModel = resolvedChatModel()
        let brainMatches = roachBrainContextMatches(for: trimmedPrompt, tags: ["dev", "assist"])
        let preferredCloudModel = preferredCloudChatModel(excluding: selectedModel)
        let shouldPreferCloudWarmupLane =
            snapshot?.roachClaw.ready != true &&
            snapshot?.internetConnected == true &&
            preferredCloudModel != nil
        let primaryModel = shouldPreferCloudWarmupLane ? (preferredCloudModel ?? selectedModel) : selectedModel
        let primaryTimeout: TimeInterval = isCloudModel(primaryModel) ? 45 : 30

        do {
            let response = try await ManagedAppRuntimeBridge.shared.sendChat(
                using: currentConfig,
                model: primaryModel,
                prompt: composedRoachBrainPrompt(from: trimmedPrompt, matches: brainMatches, mode: "Dev Studio assist"),
                timeout: primaryTimeout
            )
            try? RoachBrainStore.markAccessed(memoryIDs: brainMatches.map(\.id), storagePath: storagePath)
            rememberRoachClawExchange(prompt: trimmedPrompt, response: response, model: primaryModel, extraTags: ["dev", "assist"])
            return response
        } catch {
            if !isCloudModel(primaryModel), let fallbackModel = preferredCloudChatModel(excluding: primaryModel) {
                let response = try await ManagedAppRuntimeBridge.shared.sendChat(
                    using: currentConfig,
                    model: fallbackModel,
                    prompt: composedRoachBrainPrompt(from: trimmedPrompt, matches: brainMatches, mode: "Dev Studio assist"),
                    timeout: 45
                )
                try? RoachBrainStore.markAccessed(memoryIDs: brainMatches.map(\.id), storagePath: storagePath)
                rememberRoachClawExchange(prompt: trimmedPrompt, response: response, model: fallbackModel, extraTags: ["dev", "assist", "cloud"])
                return response
            }
            throw error
        }
    }

    func saveLatestRoachClawResponseToRoachBrain() {
        guard
            let response = chatLines.last(where: { $0.role == "RoachClaw" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            !response.isEmpty
        else {
            return
        }

        let latestPrompt = chatLines.last(where: { $0.role == "User" })?.text ?? promptDraft
        do {
            _ = try RoachBrainStore.capture(
                storagePath: storagePath,
                title: roachBrainMemoryTitle(from: latestPrompt),
                body: """
                Request:
                \(latestPrompt)

                Response:
                \(response)
                """,
                source: "RoachClaw Workbench",
                tags: ["roachclaw", "chat", "saved", resolvedChatModel()],
                pinned: true
            )
            refreshRoachBrain()
            statusLine = "Saved the last RoachClaw response into RoachBrain."
            errorLine = nil
        } catch {
            errorLine = error.localizedDescription
            statusLine = "RoachBrain save failed."
        }
    }

    func shutdownRuntime() async {
        refreshLoopTask?.cancel()
        await ManagedAppRuntimeBridge.shared.stopRuntime(using: config)
    }

    func openRoute(_ routePath: String, title: String) async {
        do {
            let url = try await ManagedAppRuntimeBridge.shared.resolveRouteURL(using: config, path: routePath)
            presentedWebSurface = PresentedWebSurface(title: title, url: url)
        } catch {
            errorLine = error.localizedDescription
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "roachnet" else { return }

        let dedupeWindow: TimeInterval = 1.0
        if
            let lastHandledIncomingURL,
            lastHandledIncomingURL.value == url.absoluteString,
            Date().timeIntervalSince(lastHandledIncomingURL.date) < dedupeWindow
        {
            return
        }
        lastHandledIncomingURL = (url.absoluteString, Date())

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            errorLine = "RoachNet couldn't read that App Store install link."
            return
        }

        let route = (url.host ?? url.path.replacingOccurrences(of: "/", with: "")).lowercased()
        switch route {
        case "install-content":
            await handleInstallContentURL(components)
        case "open-pane":
            handleOpenPaneURL(components)
        default:
            errorLine = "RoachNet didn't recognize that install link."
            statusLine = "Unknown App Store link."
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
                let host = homeURL.host ?? "RoachNet"
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
            _ = try await ManagedAppRuntimeBridge.shared.downloadBaseMapAssets(using: self.config)
        }
    }

    func installService(_ service: ManagedSystemService) async {
        guard !(service.installed ?? false) else {
            await openService(service)
            return
        }

        await runAction("service-\(service.service_name)", status: "Installing \(service.friendly_name ?? service.service_name).") {
            _ = try await ManagedAppRuntimeBridge.shared.installService(
                using: self.config,
                serviceName: service.service_name
            )
        }
    }

    func clearFailedDownloads(filetype: String? = nil) async {
        let failedJobs = (snapshot?.downloads ?? []).filter { job in
            job.status == "failed" && (filetype == nil || job.filetype == filetype)
        }

        guard !failedJobs.isEmpty else {
            statusLine = "No failed downloads to clear."
            return
        }

        await runAction(
            "downloads-clear-\(filetype ?? "all")",
            status: "Clearing failed download history."
        ) {
            for job in failedJobs {
                try await ManagedAppRuntimeBridge.shared.removeDownloadJob(
                    using: self.config,
                    jobId: job.jobId
                )
            }
        }
    }

    func affectRoachTail(_ action: String) async {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else { return }

        let actionID = "roachtail-\(trimmedAction)"
        guard !activeActions.contains(actionID) else { return }

        activeActions.insert(actionID)
        errorLine = nil

        switch trimmedAction {
        case "enable":
            statusLine = "Arming RoachTail."
        case "disable":
            statusLine = "Disabling RoachTail."
        case "refresh-join-code":
            statusLine = "Refreshing the RoachTail join code."
        case "clear-peers":
            statusLine = "Clearing linked RoachTail peers."
        default:
            statusLine = "Updating RoachTail."
        }

        defer {
            activeActions.remove(actionID)
        }

        do {
            let result = try await ManagedAppRuntimeBridge.shared.affectRoachTail(
                using: config,
                action: trimmedAction
            )
            try? await Task.sleep(for: .milliseconds(250))
            snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: config)
            statusLine = result.message ?? "RoachTail updated."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "RoachTail update failed."
        }
    }

    func downloadMapCollection(_ slug: String) async {
        await runAction("map-\(slug)", status: "Queueing map collection.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadMapCollection(using: self.config, slug: slug)
        }
    }

    func downloadEducationTier(categorySlug: String, tierSlug: String) async {
        await runAction("education-\(categorySlug)-\(tierSlug)", status: "Queueing education content.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadEducationTier(
                using: self.config,
                categorySlug: categorySlug,
                tierSlug: tierSlug
            )
        }
    }

    func downloadEducationResource(categorySlug: String, resourceId: String) async {
        await runAction("education-resource-\(resourceId)", status: "Queueing course install.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadEducationResource(
                using: self.config,
                categorySlug: categorySlug,
                resourceId: resourceId
            )
        }
    }

    func downloadRemoteZim(_ url: String) async {
        await runAction("remote-zim-\(url.hashValue)", status: "Queueing knowledge pack.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadRemoteZim(
                using: self.config,
                url: url
            )
        }
    }

    func downloadRemoteMap(_ url: String) async {
        await runAction("remote-map-\(url.hashValue)", status: "Queueing map pack.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadRemoteMap(
                using: self.config,
                url: url
            )
        }
    }

    func applyWikipediaSelection() async {
        let optionId = selectedWikipediaOptionId
        await runAction("wikipedia-\(optionId)", status: "Updating Wikipedia selection.") {
            _ = try await ManagedAppRuntimeBridge.shared.selectWikipedia(using: self.config, optionId: optionId)
        }
    }

    func refreshRoachBrain() {
        roachBrainMemories = RoachBrainStore.load(storagePath: storagePath)
    }

    func queueRoachClawModel(_ modelName: String) async {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            errorLine = "RoachNet didn't receive a model name for that App Store install link."
            return
        }

        if snapshot == nil {
            await refreshRuntimeState(silently: true)
        }

        do {
            var updatedConfig = config
            updatedConfig.installRoachClaw = true
            updatedConfig.pendingRoachClawSetup = true
            updatedConfig.roachClawDefaultModel = trimmedModel
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
            config = updatedConfig
            selectedChatModel = trimmedModel
            attemptedRoachClawBootstrap = false
            statusLine = "Queueing \(trimmedModel) for RoachClaw."
            await applyRoachClawDefaults()
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Model queue failed."
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

    private func roachBrainContextMatches(for prompt: String, tags: [String]) -> [RoachBrainMatch] {
        refreshRoachBrain()
        return RoachBrainStore.search(
            roachBrainMemories,
            query: prompt,
            tags: tags + [displayedRoachClawDefaultModel],
            limit: 4
        )
    }

    private func composedRoachBrainPrompt(from prompt: String, matches: [RoachBrainMatch], mode: String) -> String {
        let contextBlock = RoachBrainStore.contextBlock(for: matches)
        guard !contextBlock.isEmpty else { return prompt }

        return """
        You are responding inside \(mode).

        \(contextBlock)

        Use the RoachBrain notes only if they materially help this request.

        User request:
        \(prompt)
        """
    }

    private func rememberRoachClawExchange(
        prompt: String,
        response: String,
        model: String,
        extraTags: [String] = []
    ) {
        do {
            _ = try RoachBrainStore.capture(
                storagePath: storagePath,
                title: roachBrainMemoryTitle(from: prompt),
                body: """
                Request:
                \(prompt)

                Response:
                \(response)
                """,
                source: "RoachClaw Workbench",
                tags: ["roachclaw", "chat", model] + extraTags
            )
            refreshRoachBrain()
        } catch {
            errorLine = error.localizedDescription
        }
    }

    private func roachBrainMemoryTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "RoachClaw exchange" }
        let compact = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return compact.count > 56 ? String(compact.prefix(53)) + "..." : compact
    }

    private func handleInstallContentURL(_ components: URLComponents) async {
        guard setupCompleted else {
            selectedPane = .home
            errorLine = "Finish setup before installing App Store content from roachnet.org."
            statusLine = "Setup still required."
            return
        }

        let action = queryValue("action", in: components) ?? queryValue("type", in: components) ?? ""

        switch action {
        case "base-map-assets":
            selectedPane = .maps
            await downloadBaseMapAssets()
        case "map-collection":
            guard let slug = queryValue("slug", in: components) else {
                errorLine = "RoachNet couldn't tell which map collection to install."
                statusLine = "Install link incomplete."
                return
            }
            selectedPane = .maps
            await downloadMapCollection(slug)
        case "education-tier":
            guard
                let categorySlug = queryValue("category", in: components),
                let tierSlug = queryValue("tier", in: components)
            else {
                errorLine = "RoachNet couldn't tell which education pack to install."
                statusLine = "Install link incomplete."
                return
            }
            selectedPane = .education
            await downloadEducationTier(categorySlug: categorySlug, tierSlug: tierSlug)
        case "education-resource":
            guard
                let categorySlug = queryValue("category", in: components),
                let resourceId = queryValue("resource", in: components) ?? queryValue("resourceId", in: components)
            else {
                errorLine = "RoachNet couldn't tell which course to install."
                statusLine = "Install link incomplete."
                return
            }
            selectedPane = .education
            await downloadEducationResource(categorySlug: categorySlug, resourceId: resourceId)
        case "direct-download":
            guard let remoteURL = queryValue("url", in: components) else {
                errorLine = "RoachNet couldn't read the download URL from that App Store link."
                statusLine = "Install link incomplete."
                return
            }

            let fileType = (
                queryValue("filetype", in: components)
                ?? queryValue("resourceType", in: components)
                ?? ""
            ).lowercased()

            switch fileType {
            case "zim", "knowledge", "education":
                selectedPane = .education
                await downloadRemoteZim(remoteURL)
            case "map", "pmtiles":
                selectedPane = .maps
                await downloadRemoteMap(remoteURL)
            default:
                errorLine = "RoachNet couldn't tell what kind of content that App Store link should install."
                statusLine = "Install link incomplete."
            }
        case "wikipedia-option":
            guard let optionId = queryValue("option", in: components) ?? queryValue("optionId", in: components) else {
                errorLine = "RoachNet couldn't tell which Wikipedia pack to install."
                statusLine = "Install link incomplete."
                return
            }
            selectedPane = .education
            selectedWikipediaOptionId = optionId
            await applyWikipediaSelection()
        case "roachclaw-model":
            guard let modelName = queryValue("model", in: components) else {
                errorLine = "RoachNet couldn't tell which RoachClaw model to install."
                statusLine = "Install link incomplete."
                return
            }
            selectedPane = .roachClaw
            await queueRoachClawModel(modelName)
        default:
            errorLine = "RoachNet didn't recognize that App Store install action."
            statusLine = "Unknown install action."
        }
    }

    private func handleOpenPaneURL(_ components: URLComponents) {
        guard let paneValue = queryValue("pane", in: components)?.lowercased() else { return }

        switch paneValue {
        case "home":
            selectedPane = .home
        case "dev":
            selectedPane = .dev
        case "roachclaw":
            selectedPane = .roachClaw
        case "maps":
            selectedPane = .maps
        case "education":
            selectedPane = .education
        case "archives":
            selectedPane = .archives
        case "vault":
            selectedPane = .knowledge
        case "runtime":
            selectedPane = .runtime
        default:
            break
        }
    }

    private func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
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
        let resolvedDefaultModel = snapshot.roachClaw.resolvedDefaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard resolvedDefaultModel.isEmpty || config.pendingRoachClawSetup else { return }

        attemptedRoachClawBootstrap = true
        let bootstrapModel = recommendedLocalModels.first ?? config.roachClawDefaultModel

        do {
            if config.roachClawDefaultModel != bootstrapModel {
                var updatedConfig = config
                updatedConfig.roachClawDefaultModel = bootstrapModel
                try RoachNetRepositoryLocator.writeConfig(updatedConfig)
                self.config = updatedConfig
            }
            try await ManagedAppRuntimeBridge.shared.applyRoachClawDefaults(
                using: self.config,
                model: bootstrapModel,
                workspacePath: snapshot.roachClaw.workspacePath
            )
            self.snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: self.config)
            persistRoachClawSetupCompletionIfNeeded()
            synchronizeSelectedChatModel()
            if self.snapshot?.roachClaw.ready == true {
                statusLine = "RoachClaw defaults staged."
            } else {
                statusLine = "RoachClaw is staging the first local model."
            }
        } catch {
            errorLine = "RoachClaw still needs one more pass: \(error.localizedDescription)"
        }
    }

    private func bootstrapRoachClawServiceIfNeeded(using config: RoachNetInstallerConfig) async {
        guard !attemptedRoachClawServiceBootstrap else { return }
        guard config.installRoachClaw else { return }
        guard let snapshot else { return }

        let ollamaService = snapshot.services.first { $0.service_name == "nomad_ollama" }
        guard let ollamaService, !(ollamaService.installed ?? false) else { return }

        attemptedRoachClawServiceBootstrap = true
        statusLine = "Installing the contained RoachClaw lane."

        do {
            _ = try await ManagedAppRuntimeBridge.shared.installService(
                using: config,
                serviceName: ollamaService.service_name
            )
            self.snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: config)
            synchronizeWikipediaSelection()
            synchronizeSelectedChatModel()
            statusLine = "RoachClaw lane queued."
        } catch {
            errorLine = "RoachClaw couldn’t install its contained Ollama lane: \(error.localizedDescription)"
            statusLine = "RoachClaw still needs attention."
        }
    }

    private func persistRoachClawSetupCompletionIfNeeded() {
        guard snapshot?.roachClaw.ready == true, config.pendingRoachClawSetup else { return }

        do {
            var updatedConfig = config
            updatedConfig.pendingRoachClawSetup = false
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
            config = updatedConfig
        } catch {
            errorLine = error.localizedDescription
        }
    }

    private func bootstrapInstalledServicesIfNeeded(using config: RoachNetInstallerConfig) async {
        guard !attemptedInstalledServiceBootstrap else { return }
        guard let currentSnapshot = snapshot else { return }

        let servicesToStart = currentSnapshot.services.filter { service in
            guard service.installed ?? false else { return false }
            let status = service.status?.lowercased() ?? ""
            return !["running", "starting", "installing", "updating", "restarting"].contains(status)
        }

        guard !servicesToStart.isEmpty else { return }

        attemptedInstalledServiceBootstrap = true
        statusLine = "Restoring installed modules."

        var failedServices: [String] = []

        for service in servicesToStart {
            do {
                _ = try await ManagedAppRuntimeBridge.shared.affectService(
                    using: config,
                    serviceName: service.service_name,
                    action: "start"
                )
            } catch {
                failedServices.append(service.friendly_name ?? service.service_name)
            }
        }

        if let refreshedSnapshot = try? await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: config) {
            snapshot = refreshedSnapshot
            synchronizeWikipediaSelection()
            synchronizeSelectedChatModel()
        }

        if failedServices.isEmpty {
            statusLine = "Installed modules restored."
        } else {
            errorLine = "RoachNet could not restart: \(failedServices.joined(separator: ", "))."
            statusLine = "Some modules still need attention."
        }
    }

    func saveInferenceRoutingSettings() async {
        errorLine = nil
        statusLine = "Saving AI routing."

        do {
            try RoachNetRepositoryLocator.writeConfig(config)
            synchronizeSelectedChatModel()
            await refreshRuntimeState(silently: true)
            statusLine = "AI routing saved."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "AI routing update failed."
        }
    }

    func chatModelLabel(for modelName: String) -> String {
        if modelName == config.exoModelId, config.distributedInferenceBackend == "exo" {
            return "Exo · \(modelName)"
        }
        return isCloudModel(modelName) ? "Cloud · \(modelName)" : "Local · \(modelName)"
    }

    private func resolvedChatModel() -> String {
        let trimmedSelection = selectedChatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty {
            return trimmedSelection
        }

        if let first = chatModelOptions.first {
            return first
        }

        return config.roachClawDefaultModel
    }

    private func synchronizeSelectedChatModel() {
        let options = chatModelOptions

        guard !options.isEmpty else {
            selectedChatModel = config.roachClawDefaultModel
            return
        }

        let trimmedSelection = selectedChatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.contains(trimmedSelection) {
            return
        }

        if let preferredModel = preferredInitialChatModel(from: options) {
            selectedChatModel = preferredModel
            return
        }

        selectedChatModel = options[0]
    }

    private func preferredInitialChatModel(from options: [String]) -> String? {
        let trimmedExoModel = config.exoModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.distributedInferenceBackend == "exo", !trimmedExoModel.isEmpty, options.contains(trimmedExoModel) {
            return trimmedExoModel
        }

        if config.pendingRoachClawSetup,
           snapshot?.internetConnected == true,
           let cloudModel = preferredCloudChatModel(excluding: nil),
           options.contains(cloudModel) {
            return cloudModel
        }

        let resolvedLocals = [
            snapshot?.roachClaw.resolvedDefaultModel,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if let localModel = resolvedLocals.first(where: { options.contains($0) }) {
            return localModel
        }

        if snapshot?.internetConnected == true,
           let cloudModel = preferredCloudChatModel(excluding: nil),
           options.contains(cloudModel) {
            return cloudModel
        }

        let preferredLocals = [
            snapshot?.roachClaw.defaultModel,
            config.roachClawDefaultModel,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if let localModel = preferredLocals.first(where: { options.contains($0) }) {
            return localModel
        }

        return options.first
    }

    private func preferredCloudChatModel(excluding currentModel: String?) -> String? {
        let cloudModels = snapshot?.installedModels
            .filter { isCloudModel($0.name) }
            .map(\.name) ?? []

        return cloudModels.first { $0 != currentModel }
    }

    private func isCloudModel(_ modelName: String) -> Bool {
        modelName.localizedCaseInsensitiveContains(":cloud")
    }

    func openStorageInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: storagePath))
    }

    func promptForStorageRelocation() async {
        guard let destinationPath = Self.chooseDirectory(startingAt: storagePath) else {
            return
        }

        await relocateStorage(to: destinationPath)
    }

    private func relocateStorage(to destinationPath: String) async {
        let normalizedDestination = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        let currentStoragePath = storagePath

        guard normalizedDestination != currentStoragePath else {
            statusLine = "Storage location unchanged."
            return
        }

        isRelocatingStorage = true
        errorLine = nil
        statusLine = "Moving RoachNet content."

        do {
            await ManagedAppRuntimeBridge.shared.stopRuntime()
            try Self.moveStorageDirectory(from: currentStoragePath, to: normalizedDestination)

            var updatedConfig = config
            updatedConfig.storagePath = normalizedDestination
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
            config = updatedConfig
            snapshot = nil

            await refreshRuntimeState()
            statusLine = "RoachNet content moved."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Storage move failed."
        }

        isRelocatingStorage = false
    }

    private static func chooseDirectory(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose RoachNet Content Folder"
        panel.message = "Select the folder RoachNet should use for maps, archives, downloads, and local content."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()

        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private static func moveStorageDirectory(from sourcePath: String, to destinationPath: String) throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL

        guard sourceURL.path != destinationURL.path else {
            return
        }

        if destinationURL.path.hasPrefix(sourceURL.path + "/") || sourceURL.path.hasPrefix(destinationURL.path + "/") {
            throw NSError(domain: "RoachNetStorage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Choose a storage folder outside the current RoachNet content directory."
            ])
        }

        var sourceIsDirectory: ObjCBool = false
        let sourceExists = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory)

        if !sourceExists || !sourceIsDirectory.boolValue {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            return
        }

        var destinationIsDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory)

        if destinationExists {
            guard destinationIsDirectory.boolValue else {
                throw NSError(domain: "RoachNetStorage", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Choose a folder, not a file, for RoachNet content."
                ])
            }

            let destinationContents = try fileManager.contentsOfDirectory(atPath: destinationURL.path)
            if !destinationContents.isEmpty {
                throw NSError(domain: "RoachNetStorage", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Choose an empty folder for the new RoachNet content location."
                ])
            }

            try fileManager.removeItem(at: destinationURL)
        } else {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
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

@MainActor
private final class LaunchGuidePlaybackController: ObservableObject {
    let player: AVPlayer?
    private var windowController: LaunchGuideVideoWindowController?
    @Published private(set) var isPresentingWindow = false

    var hasVideo: Bool { player != nil }

    init() {
        if let url = Bundle.module.url(forResource: "roachnet-launch-guide", withExtension: "mp4") {
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            self.player = player
        } else {
            self.player = nil
        }
    }

    func playFromStart() {
        player?.seek(to: .zero)
        player?.play()
    }

    func presentVideoWindow() {
        guard let player else { return }

        if windowController == nil {
            windowController = LaunchGuideVideoWindowController(player: player) { [weak self] in
                guard let self else { return }
                self.isPresentingWindow = false
                self.player?.pause()
            }
        }

        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isPresentingWindow = true
        playFromStart()
    }

    func pause() {
        player?.pause()
    }

    func dismissVideoWindow() {
        player?.pause()
        windowController?.close()
        isPresentingWindow = false
    }
}

private final class LaunchGuideVideoWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(player: AVPlayer, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let playerView = AVPlayerView(frame: .zero)
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false

        let contentViewController = NSViewController()
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.addSubview(playerView)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        contentViewController.view = contentView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RoachNet Launch Guide"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = contentViewController

        super.init(window: window)

        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct LaunchGuideFeatureColumn: View {
    let featureRows: [GuideFeature]
    let onDismiss: () -> Void

    var body: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 16) {
                RoachKicker("Guided Tour")
                Text("Start here before you roam.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(RoachPalette.text)
                Text("This silent walkthrough shows the main RoachNet surfaces and the quickest path through the app.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)

                VStack(spacing: 10) {
                    ForEach(featureRows) { feature in
                        RoachInsetPanel {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(feature.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                Text(feature.detail)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Skip for now") {
                        onDismiss()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("Start Using RoachNet") {
                        onDismiss()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 360)
    }
}

private struct LaunchGuideVideoColumn: View {
    @ObservedObject var playbackController: LaunchGuidePlaybackController
    let onDismiss: () -> Void

    var body: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RoachNet Launch Guide")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text("Auto-plays on first launch and stays available from the main app header.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }

                    Spacer()

                    RoachTag("First Launch", accent: RoachPalette.green)
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        if playbackController.hasVideo {
                            Text("The walkthrough plays in its own floating window so the main app stays stable while you settle in.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(RoachPalette.text)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(playbackController.isPresentingWindow ? "Guide window is open now." : "Guide window is ready to open.")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("What it covers")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                Text("Home, AI Control, Easy Setup, map packs, reference bundles, archives, runtime health, and the command deck.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("Guide video unavailable")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text("Rebuild `roachnet-launch-guide.mp4` and relaunch the app to restore the guided tour.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button(playbackController.isPresentingWindow ? "Replay Video" : "Open Video") {
                        playbackController.presentVideoWindow()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(!playbackController.hasVideo)

                    Spacer()

                    Button("Close Guide") {
                        onDismiss()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                }
            }
        }
    }
}

private struct LaunchGuideSheet: View {
    let onDismiss: () -> Void
    @StateObject private var playbackController = LaunchGuidePlaybackController()

    private let featureRows: [GuideFeature] = [
        .init(
            id: "home",
            title: "Home command grid",
            detail: "Jump into Maps, AI Control, Easy Setup, Offline Web Apps, Install Apps, Docs, and Settings from the native shell."
        ),
        .init(
            id: "roachclaw",
            title: "RoachClaw workbench",
            detail: "Check Ollama and OpenClaw status, confirm the default model, and send a local test prompt without leaving the app."
        ),
        .init(
            id: "field",
            title: "Field content",
            detail: "Stage offline map packs, pick Wikipedia bundles, queue education tiers, and review mirrored sites already on disk."
        ),
        .init(
            id: "runtime",
            title: "Runtime recovery",
            detail: "Use Runtime and Diagnostics to inspect the local gateway, logs, and storage paths when something needs attention."
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.56)
                .ignoresSafeArea()

            GeometryReader { proxy in
                let isCompact = proxy.size.width < 1280

                Group {
                    if isCompact {
                        VStack(spacing: 16) {
                            LaunchGuideFeatureColumn(featureRows: featureRows, onDismiss: onDismiss)
                            LaunchGuideVideoColumn(playbackController: playbackController, onDismiss: onDismiss)
                        }
                    } else {
                        HStack(spacing: 18) {
                            LaunchGuideFeatureColumn(featureRows: featureRows, onDismiss: onDismiss)
                            LaunchGuideVideoColumn(playbackController: playbackController, onDismiss: onDismiss)
                        }
                    }
                }
                .frame(
                    maxWidth: min(proxy.size.width - 40, 1160),
                    maxHeight: min(proxy.size.height - 40, 720),
                    alignment: .center
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            playbackController.pause()
        }
        .onDisappear {
            playbackController.dismissVideoWindow()
        }
    }
}

struct RoachNetMacApp: App {
    @NSApplicationDelegateAdaptor(RoachNetMacAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup("RoachNet") {
            RootWorkspaceView(model: model)
                .background(MainWindowConfigurator())
                .frame(minWidth: 760, idealWidth: 1100, minHeight: 560, idealHeight: 760)
                .onAppear {
                    appDelegate.model = model
                }
                .onOpenURL { url in
                    Task { await model.handleIncomingURL(url) }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)

        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.minSize = NSSize(width: 760, height: 560)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed
            window.isMovableByWindowBackground = false
            window.isRestorable = false
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct RootWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @AppStorage("hasSeenLaunchGuide") private var hasSeenLaunchGuide = false
    @Namespace private var sidebarMotion
    @StateObject private var detachedPaletteCoordinator = DetachedCommandPaletteCoordinator()
    @State private var showLaunchGuide = false
    @State private var showCommandPalette = false
    @State private var sidebarCollapsed = false
    @State private var homeMenuSection: HomeMenuSection = .commandDeck
    private let topTitlebarInset: CGFloat = 30
    private let surfacePadding: CGFloat = 16
    private let shellSpring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)

    private var activePane: WorkspacePane {
        guard let selectedPane = model.selectedPane, visiblePanes.contains(selectedPane) else {
            return .home
        }

        return selectedPane
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactShell = proxy.size.width < 960
            let isTightShell = proxy.size.width < 1180 || proxy.size.height < 760
            let isVeryTightShell = proxy.size.width < 900 || proxy.size.height < 680
            let autoCollapsed = proxy.size.width < 1220
            let effectiveSidebarCollapsed = sidebarCollapsed || autoCollapsed
            let shellPadding = isVeryTightShell ? 10.0 : (isTightShell ? 12.0 : surfacePadding)
            let verticalInset = proxy.size.height < 700 ? 16.0 : (isTightShell ? 22.0 : topTitlebarInset)
            let sidebarWidth = effectiveSidebarCollapsed ? (isVeryTightShell ? 68.0 : 74.0) : (isTightShell ? 252.0 : 272.0)
            let shellSpacing = effectiveSidebarCollapsed ? 8.0 : (isTightShell ? 14.0 : 18.0)

            ZStack {
                RoachBackground()

                Group {
                    if isCompactShell {
                        VStack(alignment: .leading, spacing: 12) {
                            compactShellHeader(isTight: isTightShell)
                            compactNavigation(isTight: isTightShell)
                            detailPane(isTight: isTightShell)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        HStack(alignment: .top, spacing: shellSpacing) {
                            sidebar(isCollapsed: effectiveSidebarCollapsed, isTight: isTightShell, isVeryTight: isVeryTightShell)
                                .frame(width: sidebarWidth)

                            detailPane(isTight: isTightShell)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: 1440, maxHeight: .infinity, alignment: .topLeading)
                .padding(shellPadding)
                .padding(.top, verticalInset)
                .padding(.bottom, 12)
                .animation(shellSpring, value: effectiveSidebarCollapsed)
                .animation(shellSpring, value: activePane)

                if showLaunchGuide {
                    LaunchGuideSheet {
                        hasSeenLaunchGuide = true
                        model.dismissPendingLaunchIntro()
                        showLaunchGuide = false
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }

                if showCommandPalette {
                    CommandPaletteSheet(
                        entries: commandPaletteEntries,
                        onSelect: { entry in
                            performCommand(entry)
                        },
                        onDismiss: { showCommandPalette = false }
                    )
                    .transition(.opacity)
                    .zIndex(15)
                }
            }
        }
        .task {
            if !visiblePanes.contains(model.selectedPane ?? .home) {
                model.selectedPane = .home
            }

            await model.refreshRuntimeState()
            model.startPolling()

            if model.setupCompleted && model.config.pendingLaunchIntro && !hasSeenLaunchGuide {
                try? await Task.sleep(for: .milliseconds(450))
                showLaunchGuide = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .roachNetOpenCommandPalette)) { _ in
            detachedPaletteCoordinator.dismiss()
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .roachNetOpenDetachedCommandPalette)) { _ in
            presentDetachedCommandPalette()
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

    private func sidebar(isCollapsed: Bool, isTight: Bool, isVeryTight: Bool) -> some View {
        RoachPanel {
            ZStack(alignment: .top) {
                if isCollapsed {
                    VStack(alignment: .center, spacing: 14) {
                        RoachOrbitMark()
                            .matchedGeometryEffect(id: "sidebar-mark", in: sidebarMotion)
                            .frame(width: isVeryTight ? 58 : 66, height: isVeryTight ? 58 : 66)
                            .padding(.top, 2)

                        sidebarToggleButton(isCollapsed: true)
                            .matchedGeometryEffect(id: "sidebar-toggle", in: sidebarMotion)

                        VStack(spacing: 10) {
                            ForEach(visiblePanes) { pane in
                                Button {
                                    model.selectedPane = pane
                                } label: {
                                    RoachSidebarTile(
                                        title: pane.rawValue,
                                        subtitle: pane.subtitle,
                                        systemName: pane.icon,
                                        assetName: pane.assetName,
                                        isSelected: activePane == pane,
                                        isCompact: true
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("\(pane.rawValue): \(pane.subtitle)")
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Spacer(minLength: 0)

                        Button {
                            showCommandPalette = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                                .frame(width: isVeryTight ? 44 : 48, height: isVeryTight ? 44 : 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(RoachPalette.panelRaised.opacity(0.70))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(RoachPalette.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open Command Bar")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .leading)),
                            removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.88, anchor: .leading))
                        )
                    )
                } else {
                    VStack(alignment: .leading, spacing: isTight ? 14 : 18) {
                        HStack(spacing: 14) {
                            RoachOrbitMark()
                                .matchedGeometryEffect(id: "sidebar-mark", in: sidebarMotion)
                                .frame(width: isTight ? 82 : 96, height: isTight ? 82 : 96)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("RoachNet")
                                    .font(.system(size: isTight ? 26 : 30, weight: .bold))
                                    .foregroundStyle(RoachPalette.text)
                                Text("Your local command center")
                                    .font(.system(size: isTight ? 11 : 12, weight: .regular))
                                    .foregroundStyle(RoachPalette.muted)
                            }

                            Spacer(minLength: 0)

                            sidebarToggleButton(isCollapsed: false)
                                .matchedGeometryEffect(id: "sidebar-toggle", in: sidebarMotion)
                        }

                        VStack(spacing: isTight ? 8 : 10) {
                            ForEach(visiblePanes) { pane in
                                Button {
                                    model.selectedPane = pane
                                } label: {
                                    RoachSidebarTile(
                                        title: pane.rawValue,
                                        subtitle: pane.subtitle,
                                        systemName: pane.icon,
                                        assetName: pane.assetName,
                                        isSelected: activePane == pane
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
                                RoachStatusRow(title: "Storage", value: model.storagePath, accent: RoachPalette.green)
                            }
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .leading)),
                            removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .leading))
                        )
                    )
                }
            }
            .animation(shellSpring, value: isCollapsed)
        }
        .clipped()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarToggleButton(isCollapsed: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                sidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: isCollapsed ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.72))
                )
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    private func compactShellHeader(isTight: Bool) -> some View {
        RoachPanel {
            HStack(spacing: 16) {
                RoachOrbitMark()
                    .frame(width: isTight ? 76 : 88, height: isTight ? 76 : 88)

                VStack(alignment: .leading, spacing: 4) {
                    Text("RoachNet")
                        .font(.system(size: isTight ? 26 : 30, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                    Text("Your local command center")
                        .font(.system(size: isTight ? 11 : 12, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }

                Spacer(minLength: 0)

                Button {
                    showCommandPalette = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.72))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func compactNavigation(isTight: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(visiblePanes) { pane in
                    Button {
                        model.selectedPane = pane
                    } label: {
                        HStack(spacing: 8) {
                            RoachModuleMark(
                                systemName: pane.icon,
                                assetName: pane.assetName,
                                size: isTight ? 13 : 14,
                                isSelected: activePane == pane
                            )
                            Text(pane.rawValue)
                                .font(.system(size: isTight ? 12 : 13, weight: .semibold))
                        }
                        .foregroundStyle(activePane == pane ? RoachPalette.text : RoachPalette.muted)
                        .padding(.horizontal, isTight ? 12 : 14)
                        .padding(.vertical, isTight ? 9 : 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    activePane == pane
                                        ? RoachPalette.panelSoft.opacity(0.80)
                                        : RoachPalette.panelRaised.opacity(0.46)
                                )
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    activePane == pane ? RoachPalette.green.opacity(0.28) : RoachPalette.border,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func detailPane(isTight: Bool) -> some View {
        RoachPanel {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: isTight ? 16 : 18) {
                    headerBar(isTight: isTight)

                    if let errorLine = model.errorLine {
                        RoachNotice(title: "Runtime notice", detail: errorLine)
                    }

                    commandTray(isTight: isTight)
                    workspacePulse

                    if model.setupCompleted {
                        Group {
                            switch activePane {
                            case .suite, .home:
                                home
                            case .dev:
                                DevWorkspaceView(model: model)
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
                        }
                        .id(activePane.rawValue)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        lockedState
                            .id("locked")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.bottom, 12)
                .frame(maxWidth: isTight ? 1180 : 1260, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(shellSpring, value: activePane)
                .animation(shellSpring, value: model.setupCompleted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func headerBar(isTight: Bool) -> some View {
        let commandLabel = isTight ? "Command" : "Command Bar"
        let sidebarLabel = sidebarCollapsed ? (isTight ? "Sidebar" : "Show Sidebar") : (isTight ? "Focus" : "Focus Mode")

        return responsiveBar {
            if activePane == .roachClaw {
                HStack(alignment: .center, spacing: 14) {
                    RoachModuleMark(
                        systemName: activePane.icon,
                        assetName: activePane.assetName,
                        size: isTight ? 42 : 50,
                        isSelected: true,
                        glow: true
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(activePane.rawValue)
                            .font(.system(size: isTight ? 26 : 30, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text(activePane.subtitle)
                            .font(.system(size: isTight ? 13 : 14, weight: .regular))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activePane.rawValue)
                        .font(.system(size: isTight ? 26 : 30, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                    Text(activePane.subtitle)
                        .font(.system(size: isTight ? 13 : 14, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        } actions: {
            Button(commandLabel) {
                showCommandPalette = true
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            Button("Guide") {
                showLaunchGuide = true
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            Button(sidebarLabel) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    sidebarCollapsed.toggle()
                }
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            RoachTag(model.setupCompleted ? "Local ready" : "Setup required", accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning)
        }
    }

    private func commandTray(isTight: Bool) -> some View {
        Button {
            showCommandPalette = true
        } label: {
            RoachCommandTray(
                label: "Command Bar",
                prompt: isTight
                    ? "Jump the shell from one place. Cmd-K here, \(RoachNetGlobalHotKey.hint) from anywhere."
                    : "Jump between maps, education, archives, models, runtime, and sources from one place. Cmd-K here, \(RoachNetGlobalHotKey.hint) system-wide."
            )
        }
        .buttonStyle(RoachCardButtonStyle())
        .contentShape(Rectangle())
        .keyboardShortcut("k", modifiers: [.command])
    }

    private var workspacePulse: some View {
        RoachInsetPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    pulseSummary
                    Spacer(minLength: 16)
                    pulseChips
                }

                VStack(alignment: .leading, spacing: 12) {
                    pulseSummary
                    pulseChips
                }
            }
        }
    }

    private var pulseSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoachKicker("Workspace Pulse")
            Text("A clean local shell with the current runtime state, AI lane, and content root surfaced up front.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RoachPalette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pulseChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                workspacePulseChip(
                    title: "Setup",
                    value: model.setupCompleted ? "Ready" : "Locked",
                    accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning
                )
                workspacePulseChip(
                    title: "Runtime",
                    value: model.isLoading ? "Loading" : (model.snapshot == nil ? "Waiting" : "Live"),
                    accent: model.snapshot == nil ? RoachPalette.warning : RoachPalette.green
                )
                workspacePulseChip(
                    title: "AI",
                    value: model.displayedRoachClawDefaultModel,
                    accent: RoachPalette.cyan
                )
                workspacePulseChip(
                    title: "Storage",
                    value: URL(fileURLWithPath: model.storagePath).lastPathComponent,
                    accent: RoachPalette.magenta
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                workspacePulseChip(
                    title: "Setup",
                    value: model.setupCompleted ? "Ready" : "Locked",
                    accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning
                )
                workspacePulseChip(
                    title: "Runtime",
                    value: model.isLoading ? "Loading" : (model.snapshot == nil ? "Waiting" : "Live"),
                    accent: model.snapshot == nil ? RoachPalette.warning : RoachPalette.green
                )
                workspacePulseChip(
                    title: "AI",
                    value: model.displayedRoachClawDefaultModel,
                    accent: RoachPalette.cyan
                )
                workspacePulseChip(
                    title: "Storage",
                    value: URL(fileURLWithPath: model.storagePath).lastPathComponent,
                    accent: RoachPalette.magenta
                )
            }
        }
    }

    private func workspacePulseChip(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suite: some View {
        let installedServices = serviceCatalogServices.filter { $0.installed ?? false }
        let availableServices = serviceCatalogServices.filter { !($0.installed ?? false) }

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader("Suite", title: "Everything stays together.", detail: "Installed modules open from here, and missing ones can be staged without leaving the app.")

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                        suiteCard(title: "Dev", detail: "Native coding, shell, and secrets surfaces.", value: "Projects and AI assist", pane: .dev)
                        suiteCard(title: "Maps", detail: "Offline regions and route assets.", value: "\(model.snapshot?.mapCollections.count ?? 0) collections", pane: .maps)
                        suiteCard(title: "Education", detail: "Wikipedia and curated reference packs.", value: educationSummary, pane: .education)
                        suiteCard(title: "Archives", detail: "Saved websites and captured references.", value: "\(model.snapshot?.siteArchives.count ?? 0) saved", pane: .archives)
                        suiteCard(title: "RoachClaw", detail: "Local AI with Ollama as the default lane.", value: roachClawSummary, pane: .roachClaw)
                    }

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachInfoPill(title: "Installed Modules", value: "\(installedServices.count)")
                        RoachInfoPill(title: "Available Modules", value: "\(availableServices.count)")
                        RoachInfoPill(title: "Failed Installs", value: "\(serviceCatalogServices.filter { $0.installation_status == "error" }.count)")
                    }
                }
            }

            if !installedServices.isEmpty {
                serviceModuleSection(
                    title: "Installed Modules",
                    detail: "Launch the modules already staged in this RoachNet install.",
                    services: installedServices
                )
            }

            if !availableServices.isEmpty {
                serviceModuleSection(
                    title: "Available Modules",
                    detail: "Project NOMAD-derived modules can be installed directly from the native shell.",
                    services: availableServices
                )
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
        let installedServices = serviceCatalogServices.filter { $0.installed ?? false }
        let availableServices = serviceCatalogServices.filter { !($0.installed ?? false) }

        return VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.magenta) {
                VStack(alignment: .leading, spacing: 18) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            HStack(alignment: .top, spacing: 16) {
                                RoachModuleMark(
                                    systemName: WorkspacePane.home.icon,
                                    size: 56,
                                    isSelected: true,
                                    glow: true
                                )

                                RoachSectionHeader(
                                    "Home",
                                    title: "One local control center for maps, models, and the next move.",
                                    detail: "Use the command grid, pull the detached palette with \(RoachNetGlobalHotKey.hint), and keep the machine pointed at the right lane."
                                )
                            }

                            Spacer(minLength: 16)

                            HStack(spacing: 12) {
                                Button("Open Dev") {
                                    model.selectedPane = .dev
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())

                                Button("RoachClaw") {
                                    model.selectedPane = .roachClaw
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Maps") {
                                    model.selectedPane = .maps
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 16) {
                                RoachModuleMark(
                                    systemName: WorkspacePane.home.icon,
                                    size: 52,
                                    isSelected: true,
                                    glow: true
                                )

                                RoachSectionHeader(
                                    "Home",
                                    title: "One local control center for maps, models, and the next move.",
                                    detail: "Use the command grid, pull the detached palette with \(RoachNetGlobalHotKey.hint), and keep the machine pointed at the right lane."
                                )
                            }

                            HStack(spacing: 12) {
                                Button("Open Dev") {
                                    model.selectedPane = .dev
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())

                                Button("RoachClaw") {
                                    model.selectedPane = .roachClaw
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Maps") {
                                    model.selectedPane = .maps
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }
                    }

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 14) {
                        RoachFeatureTile(
                            "Runtime",
                            title: roachClaw?.preferredMode ?? hardware?.recommendedRuntime ?? "native_local",
                            detail: model.snapshot?.internetConnected == true
                                ? "Network available. RoachNet can pull updates without leaving the local lane."
                                : "Offline mode is fine. The core shell stays on the machine.",
                            systemName: "server.rack",
                            accent: RoachPalette.green
                        )
                        RoachFeatureTile(
                            "AI Lane",
                            title: model.displayedRoachClawDefaultModel,
                            detail: roachClaw?.ollama.available == true
                                ? "Contained Ollama is connected and ready for RoachClaw work."
                                : "Use AI Control or Easy Setup to finish the local model lane.",
                            systemName: "sparkles",
                            accent: RoachPalette.magenta
                        )
                        RoachFeatureTile(
                            "Vault",
                            title: "\(model.snapshot?.knowledgeFiles.count ?? 0) local files",
                            detail: "Maps, docs, notes, and archives stay grouped under one storage root.",
                            systemName: "books.vertical.fill",
                            accent: RoachPalette.cyan
                        )
                        RoachFeatureTile(
                            "Command Bar",
                            title: RoachNetGlobalHotKey.hint,
                            detail: "Surface the detached palette over the desktop instead of opening the whole shell.",
                            systemName: "command.circle",
                            accent: RoachPalette.bronze
                        )
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            RoachTag(model.snapshot?.internetConnected == true ? "Online now" : "Offline mode", accent: model.snapshot?.internetConnected == true ? RoachPalette.green : RoachPalette.warning)
                            RoachTag("Local-first", accent: RoachPalette.green)
                            RoachTag("Contained install", accent: RoachPalette.magenta)
                            RoachTag(URL(fileURLWithPath: model.storagePath).lastPathComponent, accent: RoachPalette.cyan)
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader(
                        "Command Grid",
                        title: "Launch what matters.",
                        detail: "Installed modules, command surfaces, and the next install lane all stay in one native grid."
                    )

                    homeMenuStrip(
                        installedCount: installedServices.count,
                        availableCount: availableServices.count
                    )

                    if homeMenuSection == .commandDeck {
                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                            ForEach(homeGridItems) { item in
                                Button {
                                    Task { await model.openRoute(item.routePath, title: item.title) }
                                } label: {
                                    commandGridCard(item)
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }
                        }
                    } else if homeMenuSection == .installedModules {
                        if installedServices.isEmpty {
                            emptyHomeMenuState(
                                title: "No modules installed yet.",
                                detail: "Use the Available Modules tab here on Home to stage the Project NOMAD-derived services you actually want."
                            )
                        } else {
                            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                                ForEach(installedServices) { service in
                                    serviceModuleCard(service)
                                }
                            }
                        }
                    } else {
                        if availableServices.isEmpty {
                            emptyHomeMenuState(
                                title: "Nothing left to stage.",
                                detail: "All currently available modules are already installed in this RoachNet workspace."
                            )
                        } else {
                            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                                ForEach(availableServices) { service in
                                    serviceModuleCard(service)
                                }
                            }
                        }
                    }
                }
            }

            if readinessSteps.contains(where: { !$0.isReady }) {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Next Up",
                                title: "Finish the missing pieces without guessing.",
                                detail: "RoachNet surfaces what still needs a hand so you can keep the command deck calm."
                            )
                        } actions: {
                            Button("Easy Setup") {
                                Task { await model.openRoute("/easy-setup", title: "Easy Setup") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                            ForEach(readinessSteps.filter { !$0.isReady }) { step in
                                readinessCard(step)
                            }
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachKicker("System Meta")
                    responsiveBar {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RoachNet")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(RoachPalette.text)
                            Text("Offline command grid v\(bundleVersion)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }

                    } actions: {
                        Button("Guide") {
                            showLaunchGuide = true
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

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
        let chatModels = model.chatModelOptions
        let recommendedQuickstartModel = model.recommendedLocalModels.first ?? model.config.roachClawDefaultModel
        let cloudModels = chatModels.filter { $0.localizedCaseInsensitiveContains(":cloud") }
        let activeModelDownloads = model.snapshot?.downloads.filter { $0.filetype == "model" && $0.status != "failed" } ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.magenta) {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            HStack(alignment: .center, spacing: 16) {
                                RoachModuleMark(
                                    systemName: WorkspacePane.roachClaw.icon,
                                    assetName: WorkspacePane.roachClaw.assetName,
                                    size: 56,
                                    isSelected: true,
                                    glow: true
                                )

                                RoachSectionHeader(
                                    "RoachClaw",
                                    title: "Local AI, wired for the machine you are on.",
                                    detail: "Run the contained local lane first, keep cloud optional, and let RoachBrain pull the useful context back in when it matters."
                                )
                            }

                            Spacer(minLength: 16)

                            HStack(spacing: 12) {
                                Button("AI Control") {
                                    Task { await model.openRoute("/settings/ai", title: "AI Control") }
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Model Store") {
                                    Task { await model.openRoute("/settings/models", title: "Model Store") }
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button(model.isApplyingDefaults ? "Saving..." : "Apply Defaults") {
                                    Task { await model.applyRoachClawDefaults() }
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())
                                .disabled(model.isApplyingDefaults || model.snapshot == nil)
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 16) {
                                RoachModuleMark(
                                    systemName: WorkspacePane.roachClaw.icon,
                                    assetName: WorkspacePane.roachClaw.assetName,
                                    size: 52,
                                    isSelected: true,
                                    glow: true
                                )

                                RoachSectionHeader(
                                    "RoachClaw",
                                    title: "Local AI, wired for the machine you are on.",
                                    detail: "Run the contained local lane first, keep cloud optional, and let RoachBrain pull the useful context back in when it matters."
                                )
                            }

                            HStack(spacing: 12) {
                                Button("AI Control") {
                                    Task { await model.openRoute("/settings/ai", title: "AI Control") }
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Model Store") {
                                    Task { await model.openRoute("/settings/models", title: "Model Store") }
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button(model.isApplyingDefaults ? "Saving..." : "Apply Defaults") {
                                    Task { await model.applyRoachClawDefaults() }
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())
                                .disabled(model.isApplyingDefaults || model.snapshot == nil)
                            }
                        }
                    }

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 14) {
                        RoachFeatureTile(
                            "Ollama",
                            title: providerValue(providers["ollama"]),
                            detail: "Contained model lane inside this RoachNet install.",
                            systemName: "sparkles",
                            accent: RoachPalette.green
                        )
                        RoachFeatureTile(
                            "OpenClaw",
                            title: providerValue(providers["openclaw"]),
                            detail: "Agent runtime for the local workbench and tool lane.",
                            systemName: "bolt.horizontal.circle",
                            accent: RoachPalette.magenta
                        )
                        RoachFeatureTile(
                            "Workspace",
                            title: workspaceValue(roachClaw?.workspacePath),
                            detail: "RoachClaw stays contained unless you choose to import an external lane.",
                            systemName: "shippingbox.fill",
                            accent: RoachPalette.cyan
                        )
                        RoachFeatureTile(
                            "RoachBrain",
                            title: "\(model.roachBrainMemories.count) memories",
                            detail: model.roachBrainPinnedCount > 0
                                ? "\(model.roachBrainPinnedCount) pinned and ready for retrieval."
                                : "Recent prompts and replies stay searchable locally.",
                            systemName: "brain.head.profile",
                            accent: RoachPalette.bronze
                        )
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            RoachTag(model.config.distributedInferenceBackend == "exo" ? "exo route" : "single-machine", accent: model.config.distributedInferenceBackend == "exo" ? RoachPalette.magenta : RoachPalette.green)
                            RoachTag(model.displayedRoachClawDefaultModel, accent: RoachPalette.cyan)
                            if model.hasCloudChatFallback {
                                RoachTag("Cloud lane ready", accent: RoachPalette.cyan)
                            }
                        }
                    }
                }
            }

            RoachSpotlightPanel(accent: RoachPalette.green) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        RoachKicker("Workbench")
                        Spacer()
                        Menu {
                            ForEach(chatModels, id: \.self) { modelName in
                                Button(model.chatModelLabel(for: modelName)) {
                                    model.selectedChatModel = modelName
                                }
                            }

                            Divider()

                            Button("Open Model Store") {
                                Task { await model.openRoute("/settings/models", title: "Model Store") }
                            }
                        } label: {
                            Text(model.selectedChatModelLabel)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .menuStyle(.borderlessButton)
                    }

                    Text(model.hasCloudChatFallback
                        ? "Cloud-backed models are ready if the local lane needs a fast warmup."
                        : "The contained local lane stays primary. Add a cloud lane only when you want it.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Button("Quickstart Local") {
                                model.config.roachClawDefaultModel = recommendedQuickstartModel
                                model.selectedChatModel = recommendedQuickstartModel
                                Task { await model.applyRoachClawDefaults() }
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(model.isApplyingDefaults)

                            if let cloudModel = cloudModels.first {
                                Button("Use Cloud First") {
                                    model.selectedChatModel = cloudModel
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }

                            Button("Save to RoachBrain") {
                                model.saveLatestRoachClawResponseToRoachBrain()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(!model.chatLines.contains(where: { $0.role == "RoachClaw" }))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button("Quickstart Local") {
                                model.config.roachClawDefaultModel = recommendedQuickstartModel
                                model.selectedChatModel = recommendedQuickstartModel
                                Task { await model.applyRoachClawDefaults() }
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(model.isApplyingDefaults)

                            HStack(spacing: 12) {
                                if let cloudModel = cloudModels.first {
                                    Button("Use Cloud First") {
                                        model.selectedChatModel = cloudModel
                                    }
                                    .buttonStyle(RoachSecondaryButtonStyle())
                                }

                                Button("Save to RoachBrain") {
                                    model.saveLatestRoachClawResponseToRoachBrain()
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                                .disabled(!model.chatLines.contains(where: { $0.role == "RoachClaw" }))
                            }
                        }
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
                        .disabled(model.isSendingPrompt || chatModels.isEmpty)
                    }
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            RoachKicker("RoachBrain")
                            Spacer()
                            Text("\(model.roachBrainMemories.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }

                        TextField("Search local memory", text: $model.roachBrainQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.64))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )

                        if model.roachBrainVisibleMatches.isEmpty {
                            Text("Prompt RoachClaw a few times or save a reply to start building RoachBrain memory.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                        } else {
                            ForEach(model.roachBrainVisibleMatches.prefix(4)) { match in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(match.memory.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(RoachPalette.text)
                                            .lineLimit(1)
                                        Spacer()
                                        if match.memory.pinned {
                                            RoachTag("Pinned", accent: RoachPalette.magenta)
                                        }
                                    }

                                    Text(match.memory.summary)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)

                                    if !match.memory.tags.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(match.memory.tags.prefix(4), id: \.self) { tag in
                                                    RoachTag(tag, accent: RoachPalette.cyan)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.black.opacity(0.18))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(RoachPalette.border, lineWidth: 1)
                                )
                            }
                        }
                    }
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        RoachKicker("Model Lane")
                        Text("Pick the first lane on purpose.")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(model.recommendedLocalModelSummary)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)

                        if !activeModelDownloads.isEmpty {
                            downloadsPanel(title: "Local Model Queue", jobs: activeModelDownloads)
                        }

                        if !model.recommendedLocalModels.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(model.recommendedLocalModels, id: \.self) { modelName in
                                    RoachTag(
                                        modelName,
                                        accent: modelName == model.config.roachClawDefaultModel ? RoachPalette.green : RoachPalette.magenta
                                    )
                                }
                            }
                        }

                        if let installed = roachClaw?.installedModels, !installed.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                RoachKicker("Installed")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                                    ForEach(installed.prefix(8), id: \.self) { modelName in
                                        RoachTag(
                                            modelName,
                                            accent: modelName == roachClaw?.resolvedDefaultModel ? RoachPalette.green : RoachPalette.muted
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        RoachKicker("Routing")
                        Text("Keep one machine fast. Add exo only when you actually want the cluster lane.")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)

                        Picker("Inference Route", selection: $model.config.distributedInferenceBackend) {
                            Text("Disabled").tag("disabled")
                            Text("Exo").tag("exo")
                        }
                        .pickerStyle(.segmented)

                        if model.config.distributedInferenceBackend == "exo" {
                            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                                RoachInlineField(
                                    title: "exo Base URL",
                                    value: $model.config.exoBaseUrl,
                                    placeholder: "http://RoachNet:52415"
                                )
                                RoachInlineField(
                                    title: "exo Model ID",
                                    value: $model.config.exoModelId,
                                    placeholder: "llama-3.2-3b"
                                )
                            }
                        }

                        Button("Save Route") {
                            Task { await model.saveInferenceRoutingSettings() }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        if let skills = model.snapshot?.installedSkills, !skills.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                RoachKicker("Skills")
                                ForEach(skills.prefix(4)) { skill in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(skill.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(RoachPalette.text)
                                        Text(skill.slug)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(RoachPalette.muted)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var maps: some View {
        let collections = model.snapshot?.mapCollections ?? []
        let activeMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" && $0.status != "failed" } ?? []
        let failedMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" && $0.status == "failed" } ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                        RoachSectionHeader("Maps", title: "Offline regions, ready to stage.", detail: "Download region packs, install the base atlas, and open the full map surface when you need it.")
                    } actions: {
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

                    if !failedMapDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            RoachNotice(
                                title: "Map downloads need another pass",
                                detail: "\(failedMapDownloads.count) failed map jobs are still in the local queue history.",
                                accent: RoachPalette.warning
                            )

                            Button("Clear Failed") {
                                Task { await model.clearFailedDownloads(filetype: "map") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
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
        let activeEducationDownloads = model.snapshot?.downloads.filter { $0.filetype == "zim" && $0.status != "failed" } ?? []
        let failedEducationDownloads = model.snapshot?.downloads.filter { $0.filetype == "zim" && $0.status == "failed" } ?? []
        let selectedWikipediaName = wikipedia?.options.first(where: { $0.id == model.selectedWikipediaOptionId })?.name

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                        RoachSectionHeader("Education", title: "Wikipedia and reference packs.", detail: "Pick a Wikipedia bundle, queue recommended content tiers, or open the full docs and setup surfaces.")
                    } actions: {
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

                    if !failedEducationDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            RoachNotice(
                                title: "Some education downloads failed earlier",
                                detail: "\(failedEducationDownloads.count) failed jobs are still being shown from older attempts.",
                                accent: RoachPalette.warning
                            )

                            Button("Clear Failed") {
                                Task { await model.clearFailedDownloads(filetype: "zim") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
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
                    responsiveBar {
                        RoachSectionHeader("Archives", title: "Saved sites stay close.", detail: "Open the offline web app manager or review mirrored sites already on disk.")
                    } actions: {
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
        let roachTail = model.snapshot?.roachTail
        let failedDownloads = (model.snapshot?.downloads ?? []).filter { $0.status == "failed" }

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                        RoachSectionHeader("Runtime", title: "Contained and recoverable.", detail: "One local gateway in front, support services quietly doing their job behind it.")
                    } actions: {
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
                        RoachStatusRow(title: "Storage Root", value: model.storagePath, accent: RoachPalette.green)
                        RoachStatusRow(title: "Server Target", value: runtimeTargetLabel(serverInfo?.target), accent: RoachPalette.green)
                        RoachStatusRow(title: "Host", value: hostLabel(system?.os.hostname), accent: RoachPalette.green)
                    }

                    if !activeDownloads.isEmpty {
                        downloadsPanel(title: "Active Jobs", jobs: activeDownloads)
                    }

                    if !failedDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            RoachNotice(
                                title: "Download history contains failures",
                                detail: "\(failedDownloads.count) failed jobs are still in the local queue history and can be cleared without touching installed content.",
                                accent: RoachPalette.warning
                            )

                            Button("Clear Failed Jobs") {
                                Task { await model.clearFailedDownloads() }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }

            if let roachTail {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "RoachTail",
                                title: roachTail.enabled ? "Private device lane is armed." : "Private device lane is off.",
                                detail: "Pair iPhone and iPad builds with a one-time code, then keep chat carryover and App installs on the private bridge."
                            )
                        } actions: {
                            Toggle(
                                isOn: Binding(
                                    get: { model.snapshot?.roachTail.enabled ?? false },
                                    set: { nextValue in
                                        Task {
                                            await model.affectRoachTail(nextValue ? "enable" : "disable")
                                        }
                                    }
                                )
                            ) {
                                Text("Enabled")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                            }
                            .toggleStyle(.switch)
                            .disabled(model.roachTailActionInFlight)
                            .labelsHidden()
                        }

                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                            RoachMetricCard(label: "Network", value: roachTail.networkName, detail: "Private overlay name")
                            RoachMetricCard(label: "Peers", value: "\(roachTail.peers.count)", detail: "Linked devices")
                            RoachMetricCard(label: "State", value: roachTail.status.capitalized, detail: "Current overlay state")
                            RoachMetricCard(
                                label: "Join Code",
                                value: roachTail.joinCode ?? (roachTail.enabled ? "Pending" : "Off"),
                                detail: roachTail.enabled ? "Use this once on the phone." : "Enable RoachTail to mint a code."
                            )
                        }

                        if let bridgeURL = roachTail.advertisedUrl, !bridgeURL.isEmpty {
                            RoachStatusRow(title: "Bridge URL", value: bridgeURL, accent: RoachPalette.green)
                        } else if let companionURL = serverInfo?.companionAdvertisedUrl ?? serverInfo?.companionUrl {
                            RoachStatusRow(title: "Bridge URL", value: companionURL, accent: RoachPalette.green)
                        }

                        HStack(spacing: 12) {
                            Button(model.roachTailActionInFlight ? "Refreshing..." : "Refresh Join Code") {
                                Task { await model.affectRoachTail("refresh-join-code") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(model.roachTailActionInFlight || !roachTail.enabled)

                            Button(model.roachTailActionInFlight ? "Clearing..." : "Clear Peers") {
                                Task { await model.affectRoachTail("clear-peers") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(model.roachTailActionInFlight || roachTail.peers.isEmpty)
                        }

                        if !roachTail.peers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Linked Devices")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)

                                ForEach(roachTail.peers.prefix(4)) { peer in
                                    RoachStatusRow(
                                        title: peer.name,
                                        value: "\(peer.platform.capitalized) · \(peer.status.capitalized)\(peer.endpoint.map { " · \($0)" } ?? "")",
                                        accent: RoachPalette.green
                                    )
                                }
                            }
                        }

                        if !roachTail.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(roachTail.notes.prefix(3), id: \.self) { note in
                                    Text(note)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    responsiveBar {
                        RoachSectionHeader("Storage", title: "Keep content where you want it.", detail: "RoachNet can move the local content library to another folder without editing config files by hand.")
                    } actions: {
                        Button("Open Folder") {
                            model.openStorageInFinder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        Button(model.isRelocatingStorage ? "Moving..." : "Move Library") {
                            Task { await model.promptForStorageRelocation() }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.isRelocatingStorage)
                    }

                    RoachStatusRow(title: "Current Path", value: model.storagePath, accent: RoachPalette.green)
                    Text("Maps, Wikipedia packages, archives, and other local content now follow this shared storage root.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                RoachMetricCard(label: "CPU", value: runtimeCPUValue(system), detail: runtimeCPUDetail(system))
                RoachMetricCard(label: "Memory", value: memoryLabel(system?.mem.total), detail: memoryDetail(system))
                RoachMetricCard(label: "Logs", value: logPathValue(serverInfo), detail: "Runtime log location")
                RoachMetricCard(
                    label: "Providers",
                    value: providerSummary,
                    detail: "Ollama and OpenClaw state from the shared AI runtime layer."
                )
            }
        }
    }

    private var summaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 176), spacing: 16, alignment: .top)]
    }

    private var homeGridItems: [CommandGridItem] {
        [
            CommandGridItem(
                id: "maps",
                title: "Maps",
                detail: "View offline maps.",
                badge: "Core Capability",
                systemImage: "map.fill",
                routePath: "/maps",
                isInstalled: true
            ),
            CommandGridItem(
                id: "ai-control",
                title: "AI Control",
                detail: "Link Ollama and OpenClaw runtimes, verify endpoints, and tune local AI access.",
                badge: "Runtime",
                systemImage: "cpu.fill",
                routePath: "/settings/ai",
                isInstalled: true
            ),
            CommandGridItem(
                id: "easy-setup",
                title: "Easy Setup",
                detail: "Use the guided setup flow to connect runtimes, download content, and stage your offline toolkit.",
                badge: setupBadge,
                systemImage: "bolt.fill",
                routePath: "/easy-setup",
                isInstalled: true
            ),
            CommandGridItem(
                id: "offline-web",
                title: "Offline Web Apps",
                detail: "Mirror standard websites into browseable offline local web apps.",
                badge: "Archived",
                systemImage: "globe.badge.chevron.backward",
                routePath: "/site-archives",
                isInstalled: true
            ),
            CommandGridItem(
                id: "install-apps",
                title: "Install Apps",
                detail: "Browse RoachNet modules, stage upstream tools, and make them feel local.",
                badge: "App Store",
                systemImage: "square.grid.2x2.fill",
                routePath: "/settings/apps",
                isInstalled: true
            ),
            CommandGridItem(
                id: "docs",
                title: "Docs",
                detail: "Read RoachNet manuals, deployment notes, and field references.",
                badge: "Local Reference",
                systemImage: "doc.text.fill",
                routePath: "/docs/home",
                isInstalled: true
            ),
            CommandGridItem(
                id: "settings",
                title: "Settings",
                detail: "Tune RoachNet, providers, storage paths, and local services.",
                badge: "System",
                systemImage: "gearshape.fill",
                routePath: "/settings/system",
                isInstalled: true
            ),
        ]
    }

    private var serviceGridItems: [CommandGridItem] {
        serviceCatalogServices
            .sorted {
                ($0.display_order ?? 10_000, $0.friendly_name ?? $0.service_name)
                    < ($1.display_order ?? 10_000, $1.friendly_name ?? $1.service_name)
            }
            .map { service in
                let descriptor = brandedServiceDescriptor(for: service)
                let isInstalled = service.installed ?? false

                return CommandGridItem(
                    id: service.service_name,
                    title: descriptor.title,
                    detail: descriptor.detail,
                    badge: isInstalled
                        ? descriptor.badge
                        : (service.installation_status == "error" ? "Retry install" : "Available to install"),
                    systemImage: descriptor.systemImage,
                    routePath: service.ui_location ?? "",
                    isInstalled: isInstalled
                )
            }
    }

    private var commandPaletteEntries: [CommandPaletteEntry] {
        let paneEntries = visiblePanes.map { pane in
            CommandPaletteEntry(
                id: "pane-\(pane.rawValue)",
                title: pane.rawValue,
                detail: pane.subtitle,
                systemImage: pane.icon,
                target: .pane(pane),
                keywords: [pane.rawValue, pane.subtitle, "module", "pane"]
            )
        }

        let routeEntries = homeGridItems.map { item in
            CommandPaletteEntry(
                id: "route-\(item.id)",
                title: item.title,
                detail: item.detail,
                systemImage: item.systemImage,
                target: .route(title: item.title, path: item.routePath),
                keywords: [item.title, item.detail, item.routePath]
            )
        }

        let serviceEntries = serviceGridItems.map { item in
            CommandPaletteEntry(
                id: "service-\(item.id)",
                title: item.title,
                detail: item.detail,
                systemImage: item.systemImage,
                target: .service(serviceName: item.id),
                keywords: [item.title, item.detail, item.id, "service"]
            )
        }

        return paneEntries
            + routeEntries
            + serviceEntries
            + [
                CommandPaletteEntry(
                    id: "action-refresh-runtime",
                    title: "Refresh Runtime",
                    detail: "Pull a fresh native snapshot and recheck the local services.",
                    systemImage: "arrow.clockwise",
                    target: .refreshRuntime,
                    keywords: ["health", "services", "reload", "snapshot"]
                ),
                CommandPaletteEntry(
                    id: "action-launch-guide",
                    title: "Open Guided Tour",
                    detail: "Replay the first-launch walkthrough for the command deck.",
                    systemImage: "play.rectangle.fill",
                    target: .launchGuide,
                    keywords: ["guide", "tour", "help", "walkthrough"]
                ),
                CommandPaletteEntry(
                    id: "action-open-model-store",
                    title: "Open Model Store",
                    detail: "Jump straight into RoachClaw's local and cloud model shelf.",
                    systemImage: "shippingbox.fill",
                    target: .route(title: "Model Store", path: "/settings/models"),
                    keywords: ["models", "ollama", "cloud", "store", "ai"]
                ),
                CommandPaletteEntry(
                    id: "action-open-apps-store",
                    title: "Open Apps Store",
                    detail: "Open apps.roachnet.org for direct install handoffs into the native app.",
                    systemImage: "square.grid.2x2",
                    target: .externalURL("https://apps.roachnet.org"),
                    keywords: ["apps", "catalog", "store", "install", "downloads"]
                ),
                CommandPaletteEntry(
                    id: "action-open-runtime-health",
                    title: "Open Runtime Health",
                    detail: "Jump to the runtime settings and service-health lane.",
                    systemImage: "stethoscope",
                    target: .route(title: "Runtime Health", path: "/settings/system"),
                    keywords: ["runtime", "health", "services", "diagnostics"]
                ),
            ]
    }

    private func performCommand(_ entry: CommandPaletteEntry, fromDetachedPalette: Bool = false) {
        showCommandPalette = false

        if fromDetachedPalette, entry.target.activatesMainShellWhenSelectedFromDetachedPalette {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
        }

        switch entry.target {
        case let .pane(pane):
            model.selectedPane = pane
        case let .route(title, path):
            Task { await model.openRoute(path, title: title) }
        case let .service(serviceName):
            Task {
                if let service = model.snapshot?.services.first(where: { $0.service_name == serviceName }) {
                    if service.installed ?? false {
                        await model.openService(service)
                    } else {
                        await model.installService(service)
                    }
                }
            }
        case .refreshRuntime:
            Task { await model.refreshRuntimeState() }
        case .launchGuide:
            showLaunchGuide = true
        case let .externalURL(urlString):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentDetachedCommandPalette() {
        showCommandPalette = false
        detachedPaletteCoordinator.present(entries: commandPaletteEntries) { entry in
            performCommand(entry, fromDetachedPalette: true)
        }
    }

    private var providerSummary: String {
        guard model.snapshot != nil else {
            return "Warming up"
        }

        guard let providers = model.snapshot?.providers.providers else {
            return "Unavailable"
        }

        let available = providers.values.filter(\.available).count
        return "\(available) Active"
    }

    private var activeDownloads: [ManagedDownloadJob] {
        (model.snapshot?.downloads ?? []).filter { $0.status == "active" }
    }

    private var visiblePanes: [WorkspacePane] {
        WorkspacePane.allCases.filter { $0 != .suite }
    }

    private var readinessSteps: [ReadinessStep] {
        let snapshot = model.snapshot
        let wikipediaSelected = snapshot?.wikipediaState.currentSelection?.optionId != nil
        let mapCount = snapshot?.mapCollections.count ?? 0
        let providerReady = snapshot?.roachClaw.ollama.available == true || snapshot?.roachClaw.openclaw.available == true
        let moduleCount = serviceCatalogServices.filter { $0.installed ?? false }.count

        return [
            ReadinessStep(
                id: "runtime",
                title: "Local runtime",
                detail: "Keep the local gateway, settings, and command surfaces reachable from the native shell.",
                status: snapshot == nil ? "Needs attention" : "Ready",
                systemImage: "server.rack",
                accent: snapshot == nil ? RoachPalette.warning : RoachPalette.green,
                routePath: "/settings/system",
                isReady: snapshot != nil
            ),
            ReadinessStep(
                id: "providers",
                title: "AI providers",
                detail: "Link Ollama and OpenClaw so RoachClaw has a live lane instead of a placeholder.",
                status: providerReady ? "Ready" : "Link AI",
                systemImage: "cpu.fill",
                accent: providerReady ? RoachPalette.green : RoachPalette.warning,
                routePath: "/settings/ai",
                isReady: providerReady
            ),
            ReadinessStep(
                id: "maps",
                title: "Offline maps",
                detail: "Stage at least one map collection so the field lane is not empty on first use.",
                status: mapCount > 0 ? "\(mapCount) ready" : "Install maps",
                systemImage: "map.fill",
                accent: mapCount > 0 ? RoachPalette.green : RoachPalette.warning,
                routePath: "/maps",
                isReady: mapCount > 0
            ),
            ReadinessStep(
                id: "wikipedia",
                title: "Wikipedia bundle",
                detail: "Pick a Wikipedia package so the education lane has a real offline reference shelf.",
                status: wikipediaSelected ? "Selected" : "Choose one",
                systemImage: "books.vertical.fill",
                accent: wikipediaSelected ? RoachPalette.green : RoachPalette.warning,
                routePath: "/easy-setup",
                isReady: wikipediaSelected
            ),
            ReadinessStep(
                id: "modules",
                title: "Installed modules",
                detail: "Bring in the command-grid modules you actually want so the native shell opens meaningful lanes.",
                status: moduleCount > 0 ? "\(moduleCount) installed" : "Install modules",
                systemImage: "square.grid.2x2.fill",
                accent: moduleCount > 0 ? RoachPalette.green : RoachPalette.warning,
                routePath: "/settings/apps",
                isReady: moduleCount > 0
            ),
        ]
    }

    private func providerValue(_ provider: AIRuntimeStatusResponse?) -> String {
        guard let provider else {
            return model.snapshot == nil ? "Warming up" : "Unavailable"
        }

        if provider.available {
            return provider.source.capitalized
        }

        if provider.source == "configured" {
            return "Configured"
        }

        return "Unavailable"
    }

    private func memoryLabel(_ bytes: UInt64?) -> String {
        guard let bytes, bytes > 0 else {
            if let system = model.snapshot?.systemInfo {
                return "\(system.hardwareProfile.memoryTier.capitalized) tier"
            }
            return model.snapshot == nil ? "Warming up" : "Unavailable"
        }

        let gigabytes = Double(bytes) / 1_073_741_824
        return "\(Int(gigabytes.rounded())) GB"
    }

    private func aiRuntimeStatusLabel(_ roachClaw: RoachClawStatusResponse?) -> String {
        guard let roachClaw else {
            return model.snapshot == nil ? "Warming up" : "Not linked"
        }

        if roachClaw.ollama.available {
            return "Connected"
        }

        if roachClaw.openclaw.available {
            return "OpenClaw linked"
        }

        return "Not linked"
    }

    private func aiRuntimeStatusAccent(_ roachClaw: RoachClawStatusResponse?) -> Color {
        guard let roachClaw else {
            return model.snapshot == nil ? RoachPalette.muted : RoachPalette.warning
        }

        return (roachClaw.ollama.available || roachClaw.openclaw.available)
            ? RoachPalette.green
            : RoachPalette.warning
    }

    private func aiRuntimeDetail(_ roachClaw: RoachClawStatusResponse?) -> String {
        guard let roachClaw else {
            return "RoachNet is still checking the local AI lanes."
        }

        if roachClaw.ollama.available {
            return "Connected via \(roachClaw.ollama.source) at \(roachClaw.ollama.baseUrl ?? "configured endpoint")"
        }

        if roachClaw.openclaw.available {
            return "OpenClaw is reachable while the local Ollama lane catches up."
        }

        return "Use AI Control or Easy Setup to connect a runtime."
    }

    private func workspaceValue(_ path: String?) -> String {
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }

        return URL(fileURLWithPath: model.storagePath)
            .appendingPathComponent("openclaw")
            .path
    }

    private func runtimeTargetLabel(_ target: String?) -> String {
        if let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return target.capitalized
        }

        return model.snapshot == nil ? "Warming up" : "Native shell"
    }

    private func hostLabel(_ hostname: String?) -> String {
        if let hostname, !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hostname
        }

        return model.snapshot == nil ? "Warming up" : "This Mac"
    }

    private func runtimeCPUValue(_ system: SystemInfoResponse?) -> String {
        if let brand = system?.cpu.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            return brand
        }

        if let platform = system?.hardwareProfile.platformLabel.trimmingCharacters(in: .whitespacesAndNewlines), !platform.isEmpty, platform != "Unavailable" {
            return platform
        }

        return model.snapshot == nil ? "Warming up" : "Local profile"
    }

    private func runtimeCPUDetail(_ system: SystemInfoResponse?) -> String {
        if let hardwareProfile = system?.hardwareProfile {
            return "\(hardwareProfile.recommendedRuntime == "native_local" ? "Native" : "Managed") path for \(hardwareProfile.recommendedModelClass)"
        }

        return "Apple Silicon optimized path"
    }

    private func memoryDetail(_ system: SystemInfoResponse?) -> String {
        if let hardwareProfile = system?.hardwareProfile {
            return "\(hardwareProfile.memoryTier.capitalized) memory tier"
        }

        return "Memory tier"
    }

    private func logPathValue(_ serverInfo: ManagedAppServerInfo?) -> String {
        if let logPath = serverInfo?.logPath?.trimmingCharacters(in: .whitespacesAndNewlines), !logPath.isEmpty {
            return logPath
        }

        return model.snapshot == nil ? "Preparing logs" : "Managed by runtime"
    }

    private var roachClawSummary: String {
        model.displayedRoachClawDefaultModel
    }

    private var serviceCatalogServices: [ManagedSystemService] {
        model.snapshot?.services ?? []
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
        .buttonStyle(RoachCardButtonStyle())
    }

    private func homeMenuStrip(installedCount: Int, availableCount: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(HomeMenuSection.allCases) { section in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            homeMenuSection = section
                        }
                    } label: {
                        RoachTag(
                            homeMenuLabel(for: section, installedCount: installedCount, availableCount: availableCount),
                            accent: homeMenuSection == section ? RoachPalette.green : RoachPalette.muted
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func emptyHomeMenuState(title: String, detail: String) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func homeMenuLabel(
        for section: HomeMenuSection,
        installedCount: Int,
        availableCount: Int
    ) -> String {
        switch section {
        case .commandDeck:
            return "Command Deck"
        case .installedModules:
            return "Installed Modules · \(installedCount)"
        case .availableModules:
            return "Available Modules · \(availableCount)"
        }
    }

    private func responsiveBar<HeaderContent: View, ActionsContent: View>(
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder actions: () -> ActionsContent
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                header()
                Spacer(minLength: 12)
                HStack(spacing: 12) {
                    actions()
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                header()
                HStack(spacing: 12) {
                    actions()
                }
            }
        }
    }

    @ViewBuilder
    private func serviceModuleSection(
        title: String,
        detail: String,
        services: [ManagedSystemService]
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 16) {
                RoachSectionHeader("Modules", title: title, detail: detail)

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                    ForEach(services) { service in
                        serviceModuleCard(service)
                    }
                }
            }
        }
    }

    private func serviceModuleCard(_ service: ManagedSystemService) -> some View {
        let descriptor = brandedServiceDescriptor(for: service)
        let isInstalled = service.installed ?? false
        let actionLabel = moduleActionLabel(for: service)
        let actionBusy = model.activeActions.contains("service-\(service.service_name)")
        let status = moduleStatusLabel(for: service)
        let statusAccent = moduleStatusAccent(for: service)

        return RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: descriptor.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isInstalled ? RoachPalette.green : RoachPalette.warning)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.92))
                        )

                    Spacer(minLength: 10)

                    RoachTag(
                        isInstalled ? "Installed" : "Available",
                        accent: isInstalled ? RoachPalette.green : RoachPalette.warning
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(descriptor.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text(descriptor.detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    RoachStatusRow(title: "Status", value: status, accent: statusAccent)
                    RoachStatusRow(
                        title: "Surface",
                        value: moduleSurfaceLabel(for: service),
                        accent: isInstalled ? RoachPalette.green : RoachPalette.muted
                    )
                }

                HStack(spacing: 12) {
                    if isInstalled {
                        Button(actionBusy ? "Opening..." : actionLabel) {
                            Task { await model.openService(service) }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(actionBusy)
                    } else {
                        Button(actionBusy ? "Installing..." : actionLabel) {
                            Task { await model.installService(service) }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(actionBusy || service.installation_status == "installing")
                    }

                    if let poweredBy = service.powered_by, !poweredBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(poweredBy)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
        }
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
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                        .minimumScaleFactor(0.82)
                    Text(item.detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(item.isInstalled ? "Open module" : "Install module")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.isInstalled ? RoachPalette.green : RoachPalette.warning)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        }
    }

    private func moduleStatusLabel(for service: ManagedSystemService) -> String {
        if service.installed == true {
            return service.status?.capitalized ?? "Installed"
        }

        switch service.installation_status {
        case "installing":
            return "Installing"
        case "error":
            return "Needs retry"
        default:
            return "Available"
        }
    }

    private func moduleStatusAccent(for service: ManagedSystemService) -> Color {
        if service.installed == true {
            return RoachPalette.green
        }

        switch service.installation_status {
        case "installing":
            return RoachPalette.cyan
        case "error":
            return RoachPalette.warning
        default:
            return RoachPalette.muted
        }
    }

    private func moduleSurfaceLabel(for service: ManagedSystemService) -> String {
        guard let location = service.ui_location, !location.isEmpty else {
            return "Native only"
        }

        return location.hasPrefix("/") ? location : "Port \(location)"
    }

    private func moduleActionLabel(for service: ManagedSystemService) -> String {
        if service.installed == true {
            return "Open Module"
        }

        if service.installation_status == "installing" {
            return "Installing..."
        }

        if service.installation_status == "error" {
            return "Retry Install"
        }

        return "Install Module"
    }

    private func readinessCard(_ step: ReadinessStep) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(step.accent)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.92))
                        )

                    Spacer(minLength: 12)

                    RoachTag(step.status, accent: step.accent)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text(step.detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let routePath = step.routePath {
                    if step.isReady {
                        Button("Review") {
                            Task { await model.openRoute(routePath, title: step.title) }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    } else {
                        Button("Fix This") {
                            Task { await model.openRoute(routePath, title: step.title) }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
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
    weak var model: WorkspaceModel? {
        didSet {
            flushPendingURLsIfNeeded()
        }
    }
    private var isHandlingTermination = false
    private var pendingURLs: [URL] = []
    private var commandPaletteHotKeyRef: EventHotKeyRef?
    private var commandPaletteHotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerCommandPaletteHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterCommandPaletteHotKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            return .terminateNow
        }

        guard !isHandlingTermination else {
            return .terminateLater
        }

        isHandlingTermination = true

        Task {
            await model.shutdownRuntime()
            await MainActor.run {
                self.isHandlingTermination = false
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        flushPendingURLsIfNeeded()
    }

    private func registerCommandPaletteHotKey() {
        guard commandPaletteHotKeyRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else { return status }

            let delegate = Unmanaged<RoachNetMacAppDelegate>.fromOpaque(userData).takeUnretainedValue()
            delegate.handleHotKeyPress(hotKeyID: hotKeyID)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &commandPaletteHotKeyHandler
        )

        let hotKeyID = EventHotKeyID(
            signature: roachNetFourCharCode("RNCP"),
            id: RoachNetGlobalHotKey.commandPaletteID
        )

        RegisterEventHotKey(
            RoachNetGlobalHotKey.keyCode,
            RoachNetGlobalHotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &commandPaletteHotKeyRef
        )
    }

    private func unregisterCommandPaletteHotKey() {
        if let commandPaletteHotKeyRef {
            UnregisterEventHotKey(commandPaletteHotKeyRef)
            self.commandPaletteHotKeyRef = nil
        }

        if let commandPaletteHotKeyHandler {
            RemoveEventHandler(commandPaletteHotKeyHandler)
            self.commandPaletteHotKeyHandler = nil
        }
    }

    private func handleHotKeyPress(hotKeyID: EventHotKeyID) {
        guard hotKeyID.id == RoachNetGlobalHotKey.commandPaletteID else { return }

        DispatchQueue.main.async {
            let notificationName: Notification.Name = NSApp.isActive
                ? .roachNetOpenCommandPalette
                : .roachNetOpenDetachedCommandPalette
            NotificationCenter.default.post(name: notificationName, object: nil)
        }
    }

    private func flushPendingURLsIfNeeded() {
        guard let model, !pendingURLs.isEmpty else { return }

        let urls = pendingURLs
        pendingURLs.removeAll()

        for url in urls {
            Task { @MainActor in
                await model.handleIncomingURL(url)
            }
        }
    }
}

RoachNetMacApp.main()
