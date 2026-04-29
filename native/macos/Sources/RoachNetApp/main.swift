import SwiftUI
import AppKit
import AVKit
import Carbon
import CoreImage
import CoreImage.CIFilterBuiltins
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
        case .suite: return "Installed surfaces"
        case .home: return "Your stack"
        case .dev: return "Code and ship"
        case .roachClaw: return "Private AI"
        case .maps: return "Offline atlas"
        case .education: return "Course packs"
        case .knowledge: return "Local shelf"
        case .runtime: return "Health and logs"
        }
    }

    var prefersPinnedDetailSurface: Bool {
        switch self {
        case .dev:
            return true
        default:
            return false
        }
    }
}

enum RuntimeSurfacePathKind {
    case installRoot
    case storageRoot
    case vaultFolder
    case logFile
}

enum RuntimeSurfacePathLabel {
    static func displayValue(_ path: String?, kind: RuntimeSurfacePathKind) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            switch kind {
            case .installRoot:
                return "Contained app"
            case .storageRoot:
                return "storage"
            case .vaultFolder:
                return "Contained vault"
            case .logFile:
                return "Runtime log"
            }
        }

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent

        switch kind {
        case .installRoot:
            return "Contained app"
        case .storageRoot:
            return lastPathComponent.isEmpty ? "storage" : lastPathComponent
        case .vaultFolder:
            return "Contained vault"
        case .logFile:
            return lastPathComponent.isEmpty ? "Runtime log" : lastPathComponent
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
    let systemImage: String
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

enum RoachClawContextScope: String, CaseIterable, Identifiable, Hashable {
    case vault
    case archives
    case projects
    case roachnet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vault:
            return "Vault"
        case .archives:
            return "Captured Sites"
        case .projects:
            return "Projects"
        case .roachnet:
            return "RoachNet"
        }
    }

    var detail: String {
        switch self {
        case .vault:
            return "Let RoachClaw read the contained library, imported Obsidian vaults, and currently opened vault asset."
        case .archives:
            return "Let RoachClaw see mirrored site titles and the captured web lane summary."
        case .projects:
            return "Let RoachClaw see the local project shelf so coding help can start from the real workspace."
        case .roachnet:
            return "Let RoachClaw read the active pane, installed packs, current model route, and the rest of the live RoachNet surface."
        }
    }

    var systemImage: String {
        switch self {
        case .vault:
            return "books.vertical.fill"
        case .archives:
            return "globe.badge.chevron.backward"
        case .projects:
            return "terminal.fill"
        case .roachnet:
            return "square.stack.3d.up.fill"
        }
    }

    var accent: Color {
        switch self {
        case .vault:
            return RoachPalette.green
        case .archives:
            return RoachPalette.cyan
        case .projects:
            return RoachPalette.magenta
        case .roachnet:
            return RoachPalette.bronze
        }
    }
}

struct RoachClawContextPermissions: Codable, Hashable {
    var vault = true
    var archives = true
    var projects = true
    var roachnet = true

    private enum CodingKeys: String, CodingKey {
        case vault
        case archives
        case projects
        case roachnet
    }

    init(vault: Bool = true, archives: Bool = true, projects: Bool = true, roachnet: Bool = true) {
        self.vault = vault
        self.archives = archives
        self.projects = projects
        self.roachnet = roachnet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vault = try container.decodeIfPresent(Bool.self, forKey: .vault) ?? true
        archives = try container.decodeIfPresent(Bool.self, forKey: .archives) ?? true
        projects = try container.decodeIfPresent(Bool.self, forKey: .projects) ?? true
        roachnet = try container.decodeIfPresent(Bool.self, forKey: .roachnet) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vault, forKey: .vault)
        try container.encode(archives, forKey: .archives)
        try container.encode(projects, forKey: .projects)
        try container.encode(roachnet, forKey: .roachnet)
    }

    func isEnabled(_ scope: RoachClawContextScope) -> Bool {
        switch scope {
        case .vault:
            return vault
        case .archives:
            return archives
        case .projects:
            return projects
        case .roachnet:
            return roachnet
        }
    }

    mutating func set(_ enabled: Bool, for scope: RoachClawContextScope) {
        switch scope {
        case .vault:
            vault = enabled
        case .archives:
            archives = enabled
        case .projects:
            projects = enabled
        case .roachnet:
            roachnet = enabled
        }
    }
}

private enum CommandPaletteTarget: Hashable {
    case pane(WorkspacePane)
    case route(title: String, path: String)
    case service(serviceName: String)
    case refreshRuntime
    case launchGuide
    case revealPath(String)
    case previewVaultFile(String)
    case importObsidianVault
    case openGlobalRoachClaw
    case stagePrompt(String)
    case stagePromptFromClipboard(String)
    case togglePromptDictation
    case toggleLatestReplySpeech
    case copyLatestReply
    case saveLatestReplyToRoachBrain
    case toggleContextScope(RoachClawContextScope)
    case setAllContext(Bool)
    case promoteLocalModel(String)
    case promoteCloudModel(String)
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
    let section: String
    let title: String
    let detail: String
    let systemImage: String
    let target: CommandPaletteTarget
    let badge: String?
    let shortcut: String?
    let keywords: [String]

    init(
        id: String,
        section: String,
        title: String,
        detail: String,
        systemImage: String,
        target: CommandPaletteTarget,
        badge: String? = nil,
        shortcut: String? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.target = target
        self.badge = badge
        self.shortcut = shortcut
        self.keywords = keywords
    }
}

private extension Notification.Name {
    static let roachNetOpenCommandPalette = Notification.Name("roachnet.open-command-palette")
    static let roachNetOpenDetachedCommandPalette = Notification.Name("roachnet.open-detached-command-palette")
}

private func roachWindowDebug(_ message: String) {
    guard ProcessInfo.processInfo.environment["ROACHNET_DEBUG_WINDOW_BOOT"] == "1" else {
        return
    }

    let line = "[RoachNet debug] \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
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

    let queryTokens = trimmedQuery
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)

    return entries
        .compactMap { entry -> (CommandPaletteEntry, Int)? in
            let score = commandPaletteScore(for: entry, queryTokens: queryTokens)
            guard score > 0 else { return nil }
            return (entry, score)
        }
        .sorted { (lhs: (CommandPaletteEntry, Int), rhs: (CommandPaletteEntry, Int)) in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            if lhs.0.section != rhs.0.section {
                return lhs.0.section < rhs.0.section
            }
            return lhs.0.title < rhs.0.title
        }
        .map(\.0)
}

private func commandPaletteScore(for entry: CommandPaletteEntry, queryTokens: [String]) -> Int {
    let title = entry.title.lowercased()
    let detail = entry.detail.lowercased()
    let section = entry.section.lowercased()
    let keywords = entry.keywords.map { $0.lowercased() }

    var score = 0
    for token in queryTokens {
        if title == token {
            score += 420
        } else if title.hasPrefix(token) {
            score += 280
        } else if title.contains(token) {
            score += 190
        }

        if keywords.contains(where: { $0 == token }) {
            score += 160
        } else if keywords.contains(where: { $0.contains(token) }) {
            score += 110
        }

        if section.contains(token) {
            score += 80
        }

        if detail.contains(token) {
            score += 46
        }
    }

    return score
}

private func groupedCommandPaletteEntries(_ entries: [CommandPaletteEntry]) -> [(String, [CommandPaletteEntry])] {
    var orderedSections: [String] = []
    var grouped: [String: [CommandPaletteEntry]] = [:]

    for entry in entries {
        if grouped[entry.section] == nil {
            orderedSections.append(entry.section)
        }
        grouped[entry.section, default: []].append(entry)
    }

    return orderedSections.map { section in
        (section, grouped[section] ?? [])
    }
}

private extension CommandPaletteTarget {
    var activatesMainShellWhenSelectedFromDetachedPalette: Bool {
        switch self {
        case .externalURL:
            return false
        case .pane, .route, .service, .refreshRuntime, .launchGuide, .revealPath, .previewVaultFile, .importObsidianVault, .openGlobalRoachClaw, .stagePrompt, .stagePromptFromClipboard, .togglePromptDictation, .toggleLatestReplySpeech, .copyLatestReply, .saveLatestReplyToRoachBrain, .toggleContextScope, .setAllContext, .promoteLocalModel, .promoteCloudModel:
            return true
        }
    }
}

private enum EmbeddedSurfaceSecurity {
    static func isTrustedNavigation(_ candidate: URL, relativeTo rootURL: URL) -> Bool {
        guard let scheme = candidate.scheme?.lowercased() else { return false }

        if scheme == "about" {
            return true
        }

        if rootURL.isFileURL {
            return candidate.isFileURL
        }

        guard scheme == "http" || scheme == "https" else { return false }

        let rootHost = rootURL.host?.lowercased()
        let candidateHost = candidate.host?.lowercased()
        guard rootHost == candidateHost else { return false }

        let rootPort = rootURL.port ?? defaultPort(for: rootURL)
        let candidatePort = candidate.port ?? defaultPort(for: candidate)
        return rootPort == candidatePort
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }
}

private struct NativeWebView: NSViewRepresentable {
    let url: URL

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var rootURL: URL

        init(url: URL) {
            rootURL = url
        }

        func update(url: URL) {
            rootURL = url
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let targetURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            guard EmbeddedSurfaceSecurity.isTrustedNavigation(targetURL, relativeTo: rootURL) else {
                NSWorkspace.shared.open(targetURL)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(url: url)
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

private struct CommandPaletteRow: View {
    let entry: CommandPaletteEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? RoachPalette.text : RoachPalette.green)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? RoachPalette.green.opacity(0.18) : RoachPalette.panelGlass)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    if let badge = entry.badge {
                        RoachTag(badge, accent: isSelected ? RoachPalette.text : RoachPalette.cyan)
                    }
                }

                Text(entry.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? RoachPalette.text : RoachPalette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill((isSelected ? RoachPalette.panelSoft : RoachPalette.panelGlass).opacity(0.92))
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            isSelected ? RoachPalette.green.opacity(0.18) : RoachPalette.panelRaised.opacity(0.76),
                            isSelected ? RoachPalette.panelSoft.opacity(0.88) : RoachPalette.panel.opacity(0.70),
                            Color.black.opacity(isSelected ? 0.12 : 0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? RoachPalette.green.opacity(0.42) : RoachPalette.border, lineWidth: 1)
        )
    }
}

private struct CommandPalettePreview: View {
    let entry: CommandPaletteEntry?

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                if let entry {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.systemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(RoachPalette.green)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(RoachPalette.panelGlass)
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.section.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.1)
                                .foregroundStyle(RoachPalette.green)
                            Text(entry.title)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(RoachPalette.text)
                            Text(entry.detail)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let shortcut = entry.shortcut {
                        HStack(spacing: 8) {
                            RoachTag("Shortcut", accent: RoachPalette.cyan)
                            Text(shortcut)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                        }
                    }

                    if let badge = entry.badge {
                        HStack(spacing: 8) {
                            RoachTag("State", accent: RoachPalette.magenta)
                            Text(badge)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }

                    if !entry.keywords.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search terms")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.1)
                                .foregroundStyle(RoachPalette.muted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(entry.keywords.prefix(6), id: \.self) { keyword in
                                        RoachTag(keyword, accent: RoachPalette.cyan)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Command Bar")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                        Text("Pick a command from the left. The preview stays readable so this acts more like a launcher and control surface than a flat search sheet.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }
            }
        }
    }
}

private struct CommandPaletteFeaturedRail: View {
    let entries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.systemImage)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(RoachPalette.green)
                                    Text(entry.section)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundStyle(RoachPalette.muted)
                                }

                                Text(entry.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 172, alignment: .leading)

                                Text(entry.detail)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .lineLimit(2)
                                    .frame(width: 172, alignment: .leading)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.78))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(RoachCardButtonStyle())
                    }
                }
            }
        }
    }
}

private struct CommandPaletteSheet: View {
    let entries: [CommandPaletteEntry]
    let featuredEntries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedEntryID: String?
    @FocusState private var queryFocused: Bool

    private var filteredEntries: [CommandPaletteEntry] {
        Array(filteredCommandPaletteEntries(from: entries, query: query).prefix(24))
    }

    private var groupedEntries: [(String, [CommandPaletteEntry])] {
        groupedCommandPaletteEntries(filteredEntries)
    }

    private var selectedEntry: CommandPaletteEntry? {
        if let selectedEntryID,
           let explicit = filteredEntries.first(where: { $0.id == selectedEntryID }) {
            return explicit
        }
        return filteredEntries.first
    }

    var body: some View {
        GeometryReader { proxy in
            let isTight = proxy.size.width < 900 || proxy.size.height < 620

            ZStack {
                RoachBackground()

                RoachPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Command Bar")
                                        .font(.system(size: isTight ? 24 : 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                    Text("Launch panes, steer RoachClaw, and jump into the next useful move without hunting through the shell.")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                    Text("Cmd-K in RoachNet · \(RoachNetGlobalHotKey.hint) anywhere on your Mac")
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
                                    Text("Command Bar")
                                        .font(.system(size: isTight ? 24 : 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                    Text("Launch panes, steer RoachClaw, and jump into the next useful move without hunting through the shell.")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                    Text("Cmd-K in RoachNet · \(RoachNetGlobalHotKey.hint) anywhere on your Mac")
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

                                    TextField("Search commands, panes, installs, voice, AI routes, and settings", text: $query)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(RoachPalette.text)
                                        .focused($queryFocused)
                                        .onSubmit {
                                            activateSelection()
                                        }
                                }
                                Text("Showing \(filteredEntries.count) of \(entries.count) commands")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                            }
                            .padding(.horizontal, 4)
                        }

                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !featuredEntries.isEmpty {
                            CommandPaletteFeaturedRail(entries: featuredEntries) { entry in
                                onSelect(entry)
                            }
                        }

                        if isTight {
                            paletteResultsList
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                paletteResultsList
                                    .frame(width: min(proxy.size.width * 0.54, 420), alignment: .leading)
                                CommandPalettePreview(entry: selectedEntry)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxWidth: min(proxy.size.width - 28, 920), maxHeight: min(proxy.size.height - 28, 620))
                .padding(14)
            }
        }
        .onAppear {
            selectedEntryID = filteredEntries.first?.id
            queryFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedEntryID = filteredEntries.first?.id
        }
        .onMoveCommand { direction in
            switch direction {
            case .down: moveSelection(delta: 1)
            case .up: moveSelection(delta: -1)
            default: break
            }
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var paletteResultsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groupedEntries, id: \.0) { section, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        ForEach(items) { entry in
                            Button {
                                onSelect(entry)
                            } label: {
                                CommandPaletteRow(entry: entry, isSelected: selectedEntry?.id == entry.id)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                guard hovering else { return }
                                selectedEntryID = entry.id
                            }
                        }
                    }
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

    private func moveSelection(delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let currentIndex = filteredEntries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), filteredEntries.count - 1)
        selectedEntryID = filteredEntries[nextIndex].id
    }

    private func activateSelection() {
        if let selectedEntry {
            onSelect(selectedEntry)
        }
    }
}

private struct DetachedCommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let featuredEntries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedEntryID: String?
    @FocusState private var queryFocused: Bool

    private var filteredEntries: [CommandPaletteEntry] {
        Array(filteredCommandPaletteEntries(from: entries, query: query).prefix(10))
    }

    private var selectedEntry: CommandPaletteEntry? {
        if let selectedEntryID,
           let explicit = filteredEntries.first(where: { $0.id == selectedEntryID }) {
            return explicit
        }
        return filteredEntries.first
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                RoachPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("RoachNet Command Bar")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                Text("Quick-launch the next useful move without bringing the full shell forward.")
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

                                TextField("Search commands, voice requests, installs, and AI controls", text: $query)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(RoachPalette.text)
                                    .focused($queryFocused)
                                    .onSubmit {
                                        activateSelection()
                                    }
                            }
                            .padding(.horizontal, 4)
                        }

                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !featuredEntries.isEmpty {
                            CommandPaletteFeaturedRail(entries: Array(featuredEntries.prefix(4))) { entry in
                                onSelect(entry)
                            }
                        }

                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(filteredEntries) { entry in
                                    Button {
                                        onSelect(entry)
                                    } label: {
                                        CommandPaletteRow(entry: entry, isSelected: selectedEntry?.id == entry.id)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hovering in
                                        guard hovering else { return }
                                        selectedEntryID = entry.id
                                    }
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
                    width: min(proxy.size.width - 32, 740),
                    height: min(proxy.size.height - 40, 520)
                )
                .padding(.top, 22)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
        }
        .onAppear {
            selectedEntryID = filteredEntries.first?.id
            queryFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedEntryID = filteredEntries.first?.id
        }
        .onMoveCommand { direction in
            switch direction {
            case .down: moveSelection(delta: 1)
            case .up: moveSelection(delta: -1)
            default: break
            }
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private func moveSelection(delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let currentIndex = filteredEntries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), filteredEntries.count - 1)
        selectedEntryID = filteredEntries[nextIndex].id
    }

    private func activateSelection() {
        if let selectedEntry {
            onSelect(selectedEntry)
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
        featuredEntries: [CommandPaletteEntry],
        onSelect: @escaping (CommandPaletteEntry) -> Void
    ) {
        dismiss()

        let controller = DetachedCommandPaletteWindowController(entries: entries, featuredEntries: featuredEntries) { [weak self] entry in
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
        featuredEntries: [CommandPaletteEntry],
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
            featuredEntries: featuredEntries,
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
    private static let roachClawContextPermissionsKey = "roachnet.roachclaw.context-permissions"

    @Published var selectedPane: WorkspacePane? = .home
    @Published var config: RoachNetInstallerConfig = RoachNetRepositoryLocator.readConfig()
    @Published var snapshot: ManagedAppSnapshot?
    @Published var isLoading = false
    @Published var errorLine: String?
    @Published var statusLine: String = "Native shell ready."
    @Published var chatLines: [ChatLine] = [
        .init(role: "System", text: "RoachNet is up."),
        .init(role: "RoachClaw", text: "Talk to the local lane, keep the good parts close, and stay private by default."),
    ]
    @Published var promptDraft: String = ""
    @Published var selectedChatModel: String = ""
    @Published var roachBrainQuery: String = ""
    @Published var roachBrainMemories: [RoachBrainMemory] = []
    @Published var selectedWikipediaOptionId: String = "none"
    @Published var isApplyingDefaults = false
    @Published var isSendingPrompt = false
    @Published var isDictatingPrompt = false
    @Published var isSpeakingLatestReply = false
    @Published var speechStatusLine: String?
    @Published var isRelocatingStorage = false
    @Published var activeActions: Set<String> = []
    @Published var roachClawContextPermissions = WorkspaceModel.loadRoachClawContextPermissions()
    @Published var presentedWebSurface: PresentedWebSurface?
    @Published var presentedVaultAsset: PresentedVaultAsset?
    @Published var importedObsidianVaults: [ImportedObsidianVault] = []
    @Published var selectedImportedVaultID: String?
    private var attemptedRoachClawBootstrap = false
    private var attemptedRoachClawServiceBootstrap = false
    private var attemptedInstalledServiceBootstrap = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var queuedRefreshRequested = false
    private var queuedRefreshSilent = true
    private var lastHandledIncomingURL: (value: String, date: Date)?
    private let speechController = RoachSpeechController()
    private var dictationSeedDraft = ""

    var setupCompleted: Bool { config.setupCompletedAt != nil || installLooksPrepared }
    var installPath: String { config.installPath.isEmpty ? RoachNetRepositoryLocator.defaultInstallPath() : config.installPath }
    var installedAppPath: String {
        config.installedAppPath.isEmpty ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath) : config.installedAppPath
    }
    var storagePath: String {
        config.storagePath.isEmpty ? RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath) : config.storagePath
    }
    private var installLooksPrepared: Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: URL(fileURLWithPath: installPath).appendingPathComponent("scripts/run-roachnet.mjs").path)
            && fileManager.fileExists(atPath: URL(fileURLWithPath: installPath).appendingPathComponent("admin/package.json").path)
            && fileManager.fileExists(atPath: installedAppPath)
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

    var roachBrainWikiStatus: RoachBrainWikiStatus {
        RoachBrainWikiStore.status(storagePath: storagePath)
    }
    var roachTailActionInFlight: Bool {
        activeActions.contains { $0.hasPrefix("roachtail-") }
    }
    var accountActionInFlight: Bool {
        activeActions.contains { $0.hasPrefix("account-") }
    }
    var roachSyncActionInFlight: Bool {
        activeActions.contains { $0.hasPrefix("roachsync-") }
    }
    var latestRoachClawReply: String? {
        chatLines.last(where: { $0.role == "RoachClaw" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var enabledRoachClawContextCount: Int {
        RoachClawContextScope.allCases.filter { roachClawContextPermissions.isEnabled($0) }.count
    }
    var hasFullRoachClawContextAccess: Bool {
        enabledRoachClawContextCount == RoachClawContextScope.allCases.count
    }

    func refreshConfigOnly() {
        config = RoachNetRepositoryLocator.readConfig()
        reconcilePreparedWorkspaceConfigIfNeeded()
        statusLine = setupCompleted ? "Setup complete." : "Setup still required."
        synchronizeSelectedChatModel()
        refreshRoachBrain()
        refreshImportedVaults()
    }

    func isRoachClawContextEnabled(_ scope: RoachClawContextScope) -> Bool {
        roachClawContextPermissions.isEnabled(scope)
    }

    func setRoachClawContext(_ scope: RoachClawContextScope, enabled: Bool) {
        roachClawContextPermissions.set(enabled, for: scope)
        persistRoachClawContextPermissions()
        statusLine = enabled
            ? "RoachClaw can now read the \(scope.title.lowercased()) lane for this workbench."
            : "RoachClaw no longer reads the \(scope.title.lowercased()) lane."
        errorLine = nil
    }

    func setAllRoachClawContext(enabled: Bool) {
        for scope in RoachClawContextScope.allCases {
            roachClawContextPermissions.set(enabled, for: scope)
        }
        persistRoachClawContextPermissions()
        statusLine = enabled
            ? "RoachClaw can now read the full local workbench context, including the vault."
            : "RoachClaw local context is locked back down."
        errorLine = nil
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

    private static func loadRoachClawContextPermissions() -> RoachClawContextPermissions {
        guard
            let data = UserDefaults.standard.data(forKey: roachClawContextPermissionsKey),
            let permissions = try? JSONDecoder().decode(RoachClawContextPermissions.self, from: data)
        else {
            return RoachClawContextPermissions()
        }

        return permissions
    }

    private func persistRoachClawContextPermissions() {
        guard let data = try? JSONEncoder().encode(roachClawContextPermissions) else { return }
        UserDefaults.standard.set(data, forKey: Self.roachClawContextPermissionsKey)
    }

    private func reconcilePreparedWorkspaceConfigIfNeeded() {
        guard config.setupCompletedAt == nil, installLooksPrepared else { return }

        var recoveredConfig = config
        recoveredConfig.setupCompletedAt = ISO8601DateFormatter().string(from: Date())

        do {
            try RoachNetRepositoryLocator.writeConfig(recoveredConfig)
            config = recoveredConfig
        } catch {
            config = recoveredConfig
            errorLine = error.localizedDescription
        }
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

        if isDictatingPrompt {
            speechController.stopTranscription(commitResult: false)
        }
        if isSpeakingLatestReply {
            speechController.stopSpeaking()
            isSpeakingLatestReply = false
        }

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
        speechStatusLine = nil
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

    func togglePromptDictation() async {
        guard setupCompleted else {
            errorLine = "Finish setup before opening the voice lane."
            return
        }

        if isDictatingPrompt {
            speechController.stopTranscription()
            return
        }

        dictationSeedDraft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        errorLine = nil
        speechStatusLine = "Listening on-device."

        do {
            try await speechController.startTranscription { [weak self] transcript in
                self?.applyDictationTranscript(transcript)
            } onFinish: { [weak self] transcript in
                self?.finishDictation(transcript)
            }
            isDictatingPrompt = true
            statusLine = "Voice prompt lane is live."
        } catch {
            isDictatingPrompt = false
            speechStatusLine = nil
            errorLine = error.localizedDescription
            statusLine = "Voice prompt lane unavailable."
        }
    }

    func toggleLatestReplySpeech() {
        if isSpeakingLatestReply {
            speechController.stopSpeaking()
            isSpeakingLatestReply = false
            speechStatusLine = "Reply playback stopped."
            return
        }

        guard let latestReply = latestRoachClawReply, !latestReply.isEmpty else {
            errorLine = "Run one prompt first so RoachNet has something to read back."
            return
        }

        errorLine = nil
        speechStatusLine = "Reading back the latest reply."
        isSpeakingLatestReply = true
        speechController.speak(latestReply) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.isSpeakingLatestReply = false
                self.speechStatusLine = finished ? "Reply playback finished." : "Reply playback stopped."
            }
        }
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

    func openPublicURL(_ rawURL: String, title: String) {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLine = "RoachNet could not open that URL."
            return
        }

        presentedWebSurface = PresentedWebSurface(title: title, url: url)
    }

    func previewVaultFile(_ file: String) {
        guard let url = resolveVaultFileURL(file) else {
            errorLine = "RoachNet could not find \(file) in the current vault lane."
            return
        }

        previewVaultURL(url, subtitle: file)
    }

    func previewVaultURL(_ url: URL, subtitle: String? = nil) {
        presentedVaultAsset = PresentedVaultAsset(
            title: url.lastPathComponent,
            subtitle: subtitle ?? url.path,
            url: url
        )
        errorLine = nil
    }

    func importObsidianVault() {
        guard let selectedPath = Self.chooseDirectory(startingAt: storagePath) else {
            return
        }

        do {
            let imported = try VaultWorkspaceStore.importVault(from: selectedPath, storagePath: storagePath)
            refreshImportedVaults()
            selectedImportedVaultID = imported.id
            errorLine = nil
            statusLine = "Imported \(imported.name) into the notes lane without moving the vault."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Obsidian import failed."
        }
    }

    func openImportedVaultInFinder(_ vault: ImportedObsidianVault) {
        NSWorkspace.shared.open(vault.url)
    }

    func revealPathInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealImportedVaultNote(_ noteURL: URL) {
        previewVaultFile(noteURL.path)
    }

    func refreshImportedVaults() {
        importedObsidianVaults = VaultWorkspaceStore.loadImportedVaults(storagePath: storagePath)

        if let selectedImportedVaultID,
           importedObsidianVaults.contains(where: { $0.id == selectedImportedVaultID }) {
            return
        }

        selectedImportedVaultID = importedObsidianVaults.first?.id
    }

    private func resolveVaultFileURL(_ file: String) -> URL? {
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: trimmed)
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let storageURL = URL(fileURLWithPath: storagePath)
        let candidateRoots = [
            storageURL,
            storageURL.appendingPathComponent("Vault", isDirectory: true),
            storageURL.appendingPathComponent("knowledge", isDirectory: true),
            storageURL.appendingPathComponent("docs", isDirectory: true),
            URL(fileURLWithPath: installPath),
        ]

        for root in candidateRoots {
            let candidate = root.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
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

    func affectAccount(_ action: String) async {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else { return }

        let actionID = "account-\(trimmedAction)"
        guard !activeActions.contains(actionID) else { return }

        activeActions.insert(actionID)
        errorLine = nil
        statusLine = trimmedAction == "refresh" ? "Refreshing account lane." : "Updating account lane."

        defer {
            activeActions.remove(actionID)
        }

        do {
            let result = try await ManagedAppRuntimeBridge.shared.affectAccount(
                using: config,
                action: trimmedAction
            )
            try? await Task.sleep(for: .milliseconds(200))
            snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: config)
            statusLine = result.message ?? "Account lane updated."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Account lane update failed."
        }
    }

    func affectRoachSync(_ action: String, folderPath: String? = nil) async {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else { return }

        let actionID = "roachsync-\(trimmedAction)"
        guard !activeActions.contains(actionID) else { return }

        activeActions.insert(actionID)
        errorLine = nil

        switch trimmedAction {
        case "enable":
            statusLine = "Arming RoachSync."
        case "disable":
            statusLine = "Disabling RoachSync."
        case "clear-peers":
            statusLine = "Clearing linked RoachSync peers."
        default:
            statusLine = "Refreshing RoachSync."
        }

        defer {
            activeActions.remove(actionID)
        }

        do {
            let result = try await ManagedAppRuntimeBridge.shared.affectRoachSync(
                using: config,
                action: trimmedAction,
                folderPath: folderPath
            )
            try? await Task.sleep(for: .milliseconds(250))
            snapshot = try await ManagedAppRuntimeBridge.shared.fetchSnapshot(using: config)
            statusLine = result.message ?? "RoachSync updated."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "RoachSync update failed."
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
        if !roachBrainMemories.isEmpty, RoachBrainWikiStore.status(storagePath: storagePath).pageCount == 0 {
            _ = try? RoachBrainWikiStore.rebuildFromMemories(storagePath: storagePath, memories: roachBrainMemories)
        }
    }

    private func applyDictationTranscript(_ transcript: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = [dictationSeedDraft, trimmedTranscript].filter { !$0.isEmpty }
        promptDraft = components.joined(separator: components.count > 1 ? "\n\n" : "")
    }

    private func finishDictation(_ transcript: String) {
        applyDictationTranscript(transcript)
        isDictatingPrompt = false
        speechStatusLine = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Voice lane closed."
            : "Voice prompt is ready."
        if errorLine == nil {
            statusLine = "Voice prompt staged."
        }
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

    func permissionedRoachClawContextBlock() -> String {
        var sections: [String] = []

        if roachClawContextPermissions.vault {
            let files = (snapshot?.knowledgeFiles ?? []).prefix(8).map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
            let excerptableVaultFiles = (snapshot?.knowledgeFiles ?? [])
                .compactMap { path -> URL? in
                    let url = URL(fileURLWithPath: path)
                    return RoachClawContextSupport.textExcerpt(for: url, maxCharacters: 260) == nil ? nil : url
                }
                .prefix(2)
            let importedVaultNoteSamples = selectedImportedVaultID
                .flatMap { selectedID in importedObsidianVaults.first(where: { $0.id == selectedID }) }
                .map { VaultWorkspaceStore.noteURLs(in: $0, limit: 3) }
                ?? importedObsidianVaults.first.map { VaultWorkspaceStore.noteURLs(in: $0, limit: 3) }
                ?? []
            let installedMapCollections = (snapshot?.mapCollections ?? [])
                .filter { ($0.installed_count ?? 0) > 0 }
                .prefix(4)
                .map(\.name)
            let installedEducationShelves = (snapshot?.educationCategories ?? [])
                .compactMap { category -> String? in
                    guard
                        let installedTierSlug = category.installedTierSlug,
                        let installedTier = category.tiers.first(where: { $0.slug == installedTierSlug })
                    else {
                        return nil
                    }
                    return "\(category.name) (\(installedTier.name))"
                }
                .prefix(4)
                .map { $0 }
            let installedWikipediaOption = snapshot?.wikipediaState.currentSelection?.optionId.flatMap { selectedID in
                snapshot?.wikipediaState.options.first(where: { $0.id == selectedID })?.name
            }
            let installedModelNames = (snapshot?.installedModels ?? []).prefix(6).map(\.name)
            let importedVaults = importedObsidianVaults.prefix(4).map { vault in
                "\(vault.name) (\(VaultWorkspaceStore.noteCount(in: vault)) notes)"
            }
            var lines: [String] = []
            lines.append("Vault lane:")
            lines.append("- Indexed files: \(snapshot?.knowledgeFiles.count ?? 0)")
            if !files.isEmpty {
                lines.append("- File samples: \(files.joined(separator: ", "))")
            }
            if let selectedImportedVault = importedObsidianVaults.first(where: { $0.id == selectedImportedVaultID }) ?? importedObsidianVaults.first {
                lines.append("- Active imported vault: \(selectedImportedVault.name)")
            }
            if !importedVaults.isEmpty {
                lines.append("- Imported vaults: \(importedVaults.joined(separator: " · "))")
            }
            let wikiStatus = RoachBrainWikiStore.status(storagePath: storagePath)
            if wikiStatus.pageCount > 0 {
                lines.append("- Compiled RoachBrain wiki: \(wikiStatus.pageCount) pages")
                lines.append("- Wiki index: \(wikiStatus.indexPath)")
            }
            if !installedMapCollections.isEmpty {
                lines.append("- Installed map packs: \(installedMapCollections.joined(separator: ", "))")
            }
            if !installedEducationShelves.isEmpty {
                lines.append("- Installed study shelves: \(installedEducationShelves.joined(separator: ", "))")
            }
            if let installedWikipediaOption {
                lines.append("- Current Wikipedia shelf: \(installedWikipediaOption)")
            }
            if !installedModelNames.isEmpty {
                lines.append("- Installed RoachClaw models: \(installedModelNames.joined(separator: ", "))")
            }
            if let presentedVaultAsset {
                lines.append("- Open preview: \(presentedVaultAsset.title) [\(presentedVaultAsset.subtitle)]")
                if let excerpt = RoachClawContextSupport.textExcerpt(for: presentedVaultAsset.url, maxCharacters: 320) {
                    lines.append("- Open asset excerpt:")
                    lines.append(excerpt)
                }
            }
            for noteURL in importedVaultNoteSamples {
                if let excerpt = RoachClawContextSupport.textExcerpt(for: noteURL, maxCharacters: 240) {
                    lines.append("- Imported note excerpt [\(noteURL.lastPathComponent)]:")
                    lines.append(excerpt)
                }
            }
            for sampleURL in excerptableVaultFiles {
                if let excerpt = RoachClawContextSupport.textExcerpt(for: sampleURL, maxCharacters: 220) {
                    lines.append("- Indexed file excerpt [\(sampleURL.lastPathComponent)]:")
                    lines.append(excerpt)
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if roachClawContextPermissions.archives {
            let archives = snapshot?.siteArchives ?? []
            let archiveSamples = archives.prefix(6).map { archive in
                archive.title ?? archive.slug
            }
            var lines: [String] = []
            lines.append("Captured web lane:")
            lines.append("- Archived sites: \(archives.count)")
            if !archiveSamples.isEmpty {
                lines.append("- Archive samples: \(archiveSamples.joined(separator: ", "))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if roachClawContextPermissions.projects {
            let projectNames = currentProjectLaneNames(limit: 6)
            var lines: [String] = []
            lines.append("Projects lane:")
            lines.append("- Projects root: \(RoachNetDeveloperPaths.projectsRoot(storagePath: storagePath))")
            if !projectNames.isEmpty {
                lines.append("- Known projects: \(projectNames.joined(separator: ", "))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if roachClawContextPermissions.roachnet {
            let activeDownloads = (snapshot?.downloads ?? []).filter { $0.status == "active" }.count
            let failedDownloads = (snapshot?.downloads ?? []).filter { $0.status == "failed" }.count
            let providers = snapshot?.providers.providers ?? [:]
            let liveCloudRoutes = providers.filter { $0.value.available }.map(\.key).sorted()
            var lines: [String] = []
            lines.append("RoachNet lane:")
            lines.append("- Active pane: \(selectedPane?.rawValue ?? "None")")
            lines.append("- Setup complete: \(setupCompleted ? "yes" : "no")")
            lines.append("- Current chat route: \(selectedChatModelLabel)")
            lines.append("- Default local model: \(displayedRoachClawDefaultModel)")
            lines.append("- RoachClaw ready: \(snapshot?.roachClaw.ready == true ? "yes" : "no")")
            lines.append("- Active downloads: \(activeDownloads)")
            if failedDownloads > 0 {
                lines.append("- Failed downloads waiting: \(failedDownloads)")
            }
            if !liveCloudRoutes.isEmpty {
                lines.append("- Cloud routes armed: \(liveCloudRoutes.joined(separator: ", "))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return "" }

        return """
        Explicitly permitted local app context:
        \(sections.joined(separator: "\n\n"))

        Use this local context only if it materially helps the request. Do not invent files, projects, or archives that are not listed here.
        """
    }

    private func composedRoachBrainPrompt(from prompt: String, matches: [RoachBrainMatch], mode: String) -> String {
        let contextBlock = RoachBrainStore.contextBlock(for: matches)
        let wikiContextBlock = RoachBrainWikiStore.contextBlock(storagePath: storagePath, query: prompt, matches: matches)
        let operatorProtocolBlock = RoachBrainWikiStore.operatorProtocolBlock()
        let researchProtocolBlock = RoachBrainWikiStore.researchProtocolBlock()
        let localContextBlock = permissionedRoachClawContextBlock()
        let contextSections = [operatorProtocolBlock, researchProtocolBlock, contextBlock, wikiContextBlock, localContextBlock].filter { !$0.isEmpty }
        guard !contextSections.isEmpty else { return prompt }

        return """
        You are responding inside \(mode).

        \(contextSections.joined(separator: "\n\n"))

        Use the extra context only if it materially helps this request.

        User request:
        \(prompt)
        """
    }

    private func currentProjectLaneNames(limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: RoachNetDeveloperPaths.projectsRoot(storagePath: storagePath), isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(limit)
            .map { $0 }
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
            selectedPane = .knowledge
            await downloadBaseMapAssets()
        case "map-collection":
            guard let slug = queryValue("slug", in: components) else {
                errorLine = "RoachNet couldn't tell which map collection to install."
                statusLine = "Install link incomplete."
                return
            }
            selectedPane = .knowledge
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
            selectedPane = .knowledge
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
            selectedPane = .knowledge
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
                selectedPane = .knowledge
                await downloadRemoteZim(remoteURL)
            case "map", "pmtiles":
                selectedPane = .knowledge
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
            selectedPane = .knowledge
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
            selectedPane = .knowledge
        case "education":
            selectedPane = .knowledge
        case "archives":
            selectedPane = .knowledge
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
        guard config.useDockerContainerization else { return }
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
        guard config.useDockerContainerization else { return }
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

private struct GlobalRoachClawPanel: View {
    @ObservedObject var model: WorkspaceModel
    let onDismiss: () -> Void

    @FocusState private var promptFocused: Bool

    private var recentThread: [ChatLine] {
        Array(model.chatLines.suffix(4))
    }

    private var latestPrompt: String? {
        model.chatLines.last(where: { $0.role == "User" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !model.isSendingPrompt
            && !model.chatModelOptions.isEmpty
            && !model.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var voiceLabel: String {
        model.isDictatingPrompt ? "Stop Voice" : "Voice Request"
    }

    var body: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 16) {
                header

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            RoachTag(model.selectedChatModelLabel, accent: RoachPalette.magenta)
                            RoachTag(model.isDictatingPrompt ? "Listening" : "Ready", accent: model.isDictatingPrompt ? RoachPalette.green : RoachPalette.cyan)
                            RoachTag(model.enabledRoachClawContextCount == 0 ? "Context locked" : "\(model.enabledRoachClawContextCount) lanes", accent: model.enabledRoachClawContextCount == 0 ? RoachPalette.warning : RoachPalette.green)
                        }

                        Text("Chat, ask for work, or start voice without leaving the surface you are using.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }

                composer

                if let speechStatus = model.speechStatusLine, !speechStatus.isEmpty {
                    Text(speechStatus)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.isDictatingPrompt ? RoachPalette.green : RoachPalette.muted)
                        .lineLimit(2)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let latestPrompt, !latestPrompt.isEmpty {
                            RoachInsetPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    RoachKicker("Last Ask")
                                    Text(latestPrompt)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(RoachPalette.muted)
                                        .lineLimit(3)
                                }
                            }
                        }

                        ForEach(recentThread) { line in
                            ChatBubble(line: line)
                        }

                        contextDeck
                    }
                    .padding(.bottom, 4)
                }

                footer
            }
        }
        .onAppear {
            promptFocused = true
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                headerTitle
                Spacer(minLength: 12)
                headerActions
            }

            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                headerActions
            }
        }
    }

    private var headerTitle: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(RoachPalette.green.opacity(0.14))
                    .frame(width: 52, height: 52)

                Image(systemName: "sparkles")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(RoachPalette.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                RoachKicker("RoachClaw Anywhere")
                Text("Ask without breaking flow.")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text("The same agent, memory, voice, and context controls float over every RoachNet surface.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(2)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button("Full Workbench") {
                model.selectedPane = .roachClaw
                onDismiss()
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            Button("Close") {
                onDismiss()
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }
    }

    private var composer: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    Button {
                        toggleVoice()
                    } label: {
                        Image(systemName: model.isDictatingPrompt ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(model.isDictatingPrompt ? RoachPalette.green : RoachPalette.magenta)
                    }
                    .buttonStyle(.plain)
                    .help(voiceLabel)

                    TextField("Ask RoachClaw, or start voice and speak the request", text: $model.promptDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RoachPalette.text)
                        .focused($promptFocused)
                        .lineLimit(2...6)
                        .onSubmit {
                            sendPrompt()
                        }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button(voiceLabel) {
                            toggleVoice()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button(model.isSendingPrompt ? "Sending..." : "Send to RoachClaw") {
                            sendPrompt()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(!canSend)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button(voiceLabel) {
                            toggleVoice()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button(model.isSendingPrompt ? "Sending..." : "Send to RoachClaw") {
                            sendPrompt()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(!canSend)
                    }
                }
            }
        }
    }

    private var contextDeck: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Context",
                    title: "Open the ground truth the request needs.",
                    detail: "Vault, project, captured web, and live app context stay permissioned while the global panel is open."
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(RoachClawContextScope.allCases) { scope in
                        let enabled = model.isRoachClawContextEnabled(scope)
                        Button {
                            model.setRoachClawContext(scope, enabled: !enabled)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: scope.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(scope.accent)
                                Text(scope.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Circle()
                                    .fill(enabled ? scope.accent : RoachPalette.warning)
                                    .frame(width: 7, height: 7)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(enabled ? scope.accent.opacity(0.12) : RoachPalette.panelRaised.opacity(0.68))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(enabled ? scope.accent.opacity(0.28) : RoachPalette.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button(model.hasFullRoachClawContextAccess ? "Lock All Context" : "Allow Full Context") {
                    model.setAllRoachClawContext(enabled: !model.hasFullRoachClawContextAccess)
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button(model.isSpeakingLatestReply ? "Stop Reply" : "Listen Back") {
                    model.toggleLatestReplySpeech()
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(model.latestRoachClawReply == nil)

                Button("Save Latest") {
                    model.saveLatestRoachClawResponseToRoachBrain()
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(model.latestRoachClawReply == nil)

                Spacer(minLength: 8)

                Text("Cmd-K opens the command bar. \(RoachNetGlobalHotKey.hint) opens it from the desktop.")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(model.isSpeakingLatestReply ? "Stop Reply" : "Listen Back") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.latestRoachClawReply == nil)

                    Button("Save Latest") {
                        model.saveLatestRoachClawResponseToRoachBrain()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.latestRoachClawReply == nil)
                }

                Text("Cmd-K in shell. \(RoachNetGlobalHotKey.hint) from the desktop.")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
            }
        }
    }

    private func sendPrompt() {
        guard canSend else { return }
        Task { await model.sendPrompt() }
    }

    private func toggleVoice() {
        Task { await model.togglePromptDictation() }
    }
}

private enum LaunchGuideAssetResolver {
    private static let fileName = "roachnet-launch-guide.mp4"
    private static let bundleNames = [
        "RoachNetMac_RoachNetApp.bundle",
        "RoachNetApp_RoachNetApp.bundle",
        "RoachNet_RoachNetApp.bundle",
    ]
    private static let sourceRelativePath = "RoachNetSource/native/macos/Sources/RoachNetApp/Resources/\(fileName)"

    static func resolveURL() -> URL? {
        let fileManager = FileManager.default
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            Bundle.main.sharedSupportURL,
        ]
        .compactMap { $0 }

        for root in roots {
            let directCandidate = root.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: directCandidate.path) {
                return directCandidate
            }

            for bundleName in bundleNames {
                let bundleCandidate = root
                    .appendingPathComponent(bundleName, isDirectory: true)
                    .appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: bundleCandidate.path) {
                    return bundleCandidate
                }
            }

            let sourceCandidate = root.appendingPathComponent(sourceRelativePath)
            if fileManager.fileExists(atPath: sourceCandidate.path) {
                return sourceCandidate
            }
        }

        return nil
    }
}

@MainActor
private final class LaunchGuidePlaybackController: ObservableObject {
    let player: AVPlayer?
    private var windowController: LaunchGuideVideoWindowController?
    @Published private(set) var isPresentingWindow = false

    var hasVideo: Bool { player != nil }

    init() {
        if let url = LaunchGuideAssetResolver.resolveURL() {
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
        RoachSpotlightPanel(accent: RoachPalette.magenta) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    RoachOrbitMark()
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        RoachKicker("First Launch")
                        Text("RoachNet starts here.")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text("Home, Dev, RoachClaw, maps, and the vault all stay under one root. This guide gets you moving fast.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        RoachTag("Local-first", accent: RoachPalette.green)
                        RoachTag("Contained runtime", accent: RoachPalette.magenta)
                        RoachTag(RoachNetGlobalHotKey.hint, accent: RoachPalette.cyan)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(featureRows) { feature in
                        RoachInsetPanel {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: feature.systemImage)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(RoachPalette.green)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(RoachPalette.panelGlass)
                                    )

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(feature.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(feature.detail)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use it like this")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text("Start on Home, pull the command bar when you need speed, then move into Dev or RoachClaw without losing the stack.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Skip Intro") {
                        onDismiss()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("Enter RoachNet") {
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
        RoachSpotlightPanel(accent: RoachPalette.cyan) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        RoachKicker("Launch Reel")
                        Text("Real shell. Real first run.")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text("This is the actual native RoachNet shell, not a concept render. Open the reel, then go straight into the app.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    RoachTag("Native Capture", accent: RoachPalette.green)
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        if playbackController.hasVideo {
                            Text("The guide opens in its own floating window so the shell stays usable while you get oriented.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(RoachPalette.text)
                                .fixedSize(horizontal: false, vertical: true)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    RoachTag("Home", accent: RoachPalette.green)
                                    RoachTag("RoachClaw", accent: RoachPalette.magenta)
                                    RoachTag("Vault Shelves", accent: RoachPalette.cyan)
                                    RoachTag("Runtime", accent: RoachPalette.bronze)
                                }
                            }

                            Text(playbackController.isPresentingWindow ? "Guide window is open now." : "Guide window is ready.")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("What it shows")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                Text("Home, RoachClaw, Easy Setup, vault shelves, runtime health, and the command bar.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("Guide video unavailable")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text("RoachNet can still open the shell cleanly. Rebuild `roachnet-launch-guide.mp4` later to restore the launch reel.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button(playbackController.isPresentingWindow ? "Replay Reel" : "Open Reel") {
                        playbackController.presentVideoWindow()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(!playbackController.hasVideo)

                    Spacer()

                    Button("Enter RoachNet") {
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
            detail: "Start in Home, see the runtime pulse, and move into the next lane without digging through menus.",
            systemImage: "square.grid.2x2.fill"
        ),
        .init(
            id: "command",
            title: "Command Bar",
            detail: "Use Cmd-K inside the shell or \(RoachNetGlobalHotKey.hint) from anywhere on the desktop.",
            systemImage: "command.circle.fill"
        ),
        .init(
            id: "roachclaw",
            title: "RoachClaw workbench",
            detail: "Check the local AI lane, confirm the default model, and send a real prompt without leaving the app.",
            systemImage: "sparkles"
        ),
        .init(
            id: "field",
            title: "Vault shelves",
            detail: "Stage atlas packs, queue study bundles, and keep captured or reference material inside one living shelf.",
            systemImage: "map.fill"
        ),
        .init(
            id: "runtime",
            title: "Runtime recovery",
            detail: "Use Runtime and Diagnostics to inspect the gateway, logs, and contained storage when something needs attention.",
            systemImage: "server.rack"
        ),
    ]

    var body: some View {
        ZStack {
            RoachBackground()
                .overlay(Color.black.opacity(0.64))
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
        WindowGroup("RoachNet", id: "main") {
            RootWorkspaceView(model: model)
                .background(MainWindowConfigurator())
                .frame(minWidth: 760, idealWidth: 1100, minHeight: 560, idealHeight: 760)
                .onAppear {
                    roachWindowDebug("RootWorkspaceView appeared.")
                    appDelegate.model = model
                }
                .onOpenURL { url in
                    Task { await model.handleIncomingURL(url) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        private weak var lastWindow: NSWindow?

        @MainActor
        func configure(window: NSWindow) {
            roachWindowDebug("Configuring main window attached to scene.")
            if lastWindow !== window {
                lastWindow = window
            }

            let minimumSize = NSSize(width: 760, height: 560)
            let preferredSize = NSSize(width: 1220, height: 852)
            window.minSize = minimumSize
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed
            window.isMovableByWindowBackground = false
            window.isRestorable = false

            var frame = window.frame
            let needsResize = frame.size.width < minimumSize.width || frame.size.height < minimumSize.height
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let isOffscreen = screenFrame.map { !$0.intersects(frame) } ?? false

            if needsResize || isOffscreen {
                frame.size.width = max(preferredSize.width, minimumSize.width)
                frame.size.height = max(preferredSize.height, minimumSize.height)

                if let screenFrame {
                    frame.origin.x = screenFrame.midX - (frame.size.width / 2)
                    frame.origin.y = screenFrame.midY - (frame.size.height / 2)
                }

                window.setFrame(frame, display: true, animate: false)
            }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            roachWindowDebug("Main window ordered front. Visible=\(window.isVisible)")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = RoachWindowAttachmentView(frame: .zero)
        view.onWindowAvailable = { window in
            Task { @MainActor in
                context.coordinator.configure(window: window)
            }
        }
        DispatchQueue.main.async { [weak view] in
            view?.notifyIfWindowAvailable()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let attachmentView = nsView as? RoachWindowAttachmentView else { return }
        attachmentView.onWindowAvailable = { window in
            Task { @MainActor in
                context.coordinator.configure(window: window)
            }
        }
        attachmentView.notifyIfWindowAvailable()
    }
}

private final class RoachWindowAttachmentView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfWindowAvailable()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in
            self?.notifyIfWindowAvailable()
        }
    }

    func notifyIfWindowAvailable() {
        guard let window else { return }
        onWindowAvailable?(window)
    }
}

private struct RootWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @AppStorage("hasSeenLaunchGuide") private var hasSeenLaunchGuide = false
    @AppStorage("recentCommandPaletteIDs") private var recentCommandPaletteIDsRaw = ""
    @Namespace private var sidebarMotion
    @StateObject private var detachedPaletteCoordinator = DetachedCommandPaletteCoordinator()
    @State private var showLaunchGuide = false
    @State private var showCommandPalette = false
    @State private var showGlobalRoachClaw = false
    @State private var sidebarCollapsed = false
    @State private var homeMenuSection: HomeMenuSection = .commandDeck
    @State private var didScheduleInitialRefresh = false
    private let topTitlebarInset: CGFloat = 18
    private let surfacePadding: CGFloat = 8
    private let shellSpring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)

    private var recentCommandPaletteIDs: [String] {
        recentCommandPaletteIDsRaw
            .split(separator: "|")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private var shellTitle: String {
        activePane.rawValue
    }

    private var shellDetail: String {
        switch activePane {
        case .suite:
            return "Installed surfaces, staged modules, and the next thing to open."
        case .home:
            return "Bring the important stuff home and keep it there."
        case .dev:
            return "A quieter desk for code, the shell, and the next real edit."
        case .roachClaw:
            return "A real chat lane first. Local by default, cloud only when it earns the trip."
        case .maps:
            return "Notes, captures, atlas packs, study shelves, and saved media under one library."
        case .education:
            return "Notes, captures, atlas packs, study shelves, and saved media under one library."
        case .knowledge:
            return "Notes, captures, atlas packs, study shelves, books, media, and installed packs under one shelf."
        case .runtime:
            return "The stack, the health, the sync state, and the logs in one place."
        }
    }

    private func displayedPane(for pane: WorkspacePane?) -> WorkspacePane {
        switch pane {
        case .maps?, .education?:
            return .knowledge
        case let pane? where visiblePanes.contains(pane):
            return pane
        default:
            return .home
        }
    }

    private var activePane: WorkspacePane {
        displayedPane(for: model.selectedPane)
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactShell = proxy.size.width < 900
            let isTightShell = proxy.size.width < 1180 || proxy.size.height < 760
            let isVeryTightShell = proxy.size.width < 900 || proxy.size.height < 680
            let autoCollapsed = proxy.size.width < 1080
            let effectiveSidebarCollapsed = sidebarCollapsed || autoCollapsed
            let shellPadding = isVeryTightShell ? 6.0 : (isTightShell ? 7.0 : surfacePadding)
            let verticalInset = proxy.size.height < 700 ? 10.0 : (isTightShell ? 14.0 : topTitlebarInset)
            let sidebarWidth = effectiveSidebarCollapsed ? (isVeryTightShell ? 64.0 : 70.0) : (isTightShell ? 268.0 : 292.0)
            let shellSpacing = effectiveSidebarCollapsed ? 8.0 : (isTightShell ? 12.0 : 16.0)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(shellPadding)
                .padding(.top, verticalInset)
                .padding(.bottom, 10)
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
                        featuredEntries: featuredCommandPaletteEntries,
                        onSelect: { entry in
                            performCommand(entry)
                        },
                        onDismiss: { showCommandPalette = false }
                    )
                    .transition(.opacity)
                    .zIndex(15)
                }

                if showGlobalRoachClaw {
                    Color.black.opacity(0.30)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeGlobalRoachClaw()
                        }
                        .transition(.opacity)
                        .zIndex(17)

                    GlobalRoachClawPanel(model: model) {
                        closeGlobalRoachClaw()
                    }
                    .frame(
                        width: max(340, min(proxy.size.width - 30, isCompactShell ? 620 : 720)),
                        height: max(420, min(proxy.size.height - 30, isCompactShell ? 640 : 690)),
                        alignment: .topTrailing
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, isCompactShell ? 16 : 26)
                    .padding(.trailing, isCompactShell ? 15 : 24)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .topTrailing)),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .topTrailing))
                        )
                    )
                    .zIndex(18)
                }
            }
        }
        .task {
            if model.selectedPane == .maps || model.selectedPane == .education {
                model.selectedPane = .knowledge
            } else if !visiblePanes.contains(model.selectedPane ?? .home) {
                model.selectedPane = .home
            }

            guard !didScheduleInitialRefresh else { return }
            didScheduleInitialRefresh = true

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                await model.refreshRuntimeState()
                model.startPolling()

                if model.setupCompleted && model.config.pendingLaunchIntro && !hasSeenLaunchGuide {
                    try? await Task.sleep(for: .milliseconds(450))
                    showLaunchGuide = true
                }
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
        .sheet(
            isPresented: Binding(
                get: { model.presentedVaultAsset != nil },
                set: { if !$0 { model.presentedVaultAsset = nil } }
            )
        ) {
            if let asset = model.presentedVaultAsset {
                VaultPreviewSurfaceView(
                    asset: asset,
                    onClose: { model.presentedVaultAsset = nil },
                    onOpenAsset: { url in
                        model.previewVaultURL(url)
                    }
                )
            }
        }
    }

    private func openGlobalRoachClaw() {
        detachedPaletteCoordinator.dismiss()
        showCommandPalette = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.10)) {
            showGlobalRoachClaw = true
        }
    }

    private func closeGlobalRoachClaw() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.08)) {
            showGlobalRoachClaw = false
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

                        Button {
                            openGlobalRoachClaw()
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(RoachPalette.green)
                                .frame(width: isVeryTight ? 44 : 48, height: isVeryTight ? 44 : 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(RoachPalette.green.opacity(0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(RoachPalette.green.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open RoachClaw anywhere")

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
                        HStack(spacing: 10) {
                            RoachOrbitMark()
                                .matchedGeometryEffect(id: "sidebar-mark", in: sidebarMotion)
                                .frame(width: isTight ? 64 : 72, height: isTight ? 64 : 72)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("RoachNet")
                                    .font(.system(size: isTight ? 19 : 22, weight: .bold))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.74)
                                Text("Contained stack on your hardware")
                                    .font(.system(size: isTight ? 11 : 12, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.82)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                                RoachKicker("At A Glance")
                                RoachStatusRow(title: "Install", value: model.setupCompleted ? "Ready" : "Locked", accent: model.setupCompleted ? RoachPalette.success : RoachPalette.warning)
                                RoachStatusRow(title: "Runtime", value: model.snapshot == nil ? "Offline" : "Live", accent: model.snapshot == nil ? RoachPalette.warning : RoachPalette.green)
                                RoachStatusRow(title: "Account", value: model.snapshot?.account.linked == true ? "Linked" : "Local", accent: model.snapshot?.account.linked == true ? RoachPalette.cyan : RoachPalette.bronze)
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
        let runtimeTitle = model.isLoading ? "Loading" : (model.snapshot == nil ? "Waiting" : "Live")
        let runtimeAccent = model.snapshot == nil ? RoachPalette.warning : RoachPalette.green
        let accountTitle = model.snapshot?.account.linked == true ? "Account linked" : "Account local"
        let accountAccent = model.snapshot?.account.linked == true ? RoachPalette.cyan : RoachPalette.bronze
        return RoachPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    RoachOrbitMark()
                        .frame(width: isTight ? 68 : 80, height: isTight ? 68 : 80)

                    VStack(alignment: .leading, spacing: 6) {
                        RoachKicker("Contained Shell")
                        Text("RoachNet")
                            .font(.system(size: isTight ? 26 : 30, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text("One root. The stack up front.")
                            .font(.system(size: isTight ? 12 : 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                        Text(shellDetail)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(RoachPalette.muted.opacity(0.88))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Button("Claw") {
                                    openGlobalRoachClaw()
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Command") {
                                    showCommandPalette = true
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Guide") {
                                    showLaunchGuide = true
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }

                            VStack(spacing: 8) {
                                Button("Claw") {
                                    openGlobalRoachClaw()
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Command") {
                                    showCommandPalette = true
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())

                                Button("Guide") {
                                    showLaunchGuide = true
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        RoachTag(runtimeTitle, accent: runtimeAccent)
                        RoachTag(accountTitle, accent: accountAccent)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func compactNavigation(isTight: Bool) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            RoachKicker("Surfaces")
                            Text("Jump where you need to go.")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                        }

                        Spacer(minLength: 12)

                        RoachTag(activePane.rawValue, accent: RoachPalette.green)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        RoachKicker("Surfaces")
                        Text("Jump where you need to go.")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        RoachTag(activePane.rawValue, accent: RoachPalette.green)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: isTight ? 136 : 154), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(visiblePanes) { pane in
                        Button {
                            model.selectedPane = pane
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                RoachModuleMark(
                                    systemName: pane.icon,
                                    assetName: pane.assetName,
                                    size: isTight ? 16 : 18,
                                    isSelected: activePane == pane
                                )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pane.rawValue)
                                        .font(.system(size: isTight ? 13 : 14, weight: .semibold))
                                        .foregroundStyle(activePane == pane ? RoachPalette.text : RoachPalette.text.opacity(0.92))
                                    Text(pane.subtitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                        .lineLimit(2)
                                }

                                if activePane == pane {
                                    RoachTag("Open now", accent: RoachPalette.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        activePane == pane
                                            ? RoachPalette.panelSoft.opacity(0.78)
                                            : RoachPalette.panelRaised.opacity(0.54)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(
                                        activePane == pane ? RoachPalette.green.opacity(0.24) : RoachPalette.border,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(RoachCardButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailPane(isTight: Bool) -> some View {
        GeometryReader { proxy in
            RoachPanel {
                if model.setupCompleted && activePane.prefersPinnedDetailSurface {
                    detailPaneStack(isTight: isTight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .frame(minHeight: proxy.size.height, alignment: .topLeading)
                } else {
                    ScrollView(showsIndicators: false) {
                        detailPaneStack(isTight: isTight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func detailPaneStack(isTight: Bool) -> some View {
        VStack(alignment: .leading, spacing: isTight ? 16 : 18) {
            headerBar(isTight: isTight)

            if let errorLine = model.errorLine {
                RoachNotice(title: "Runtime notice", detail: errorLine)
            }

            if model.setupCompleted && activePane == .home {
                commandTray(isTight: isTight)
            }

            detailPaneSurface
        }
        .padding(.bottom, 8)
        .frame(maxWidth: isTight ? 1280 : 1480, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(shellSpring, value: activePane)
        .animation(shellSpring, value: model.setupCompleted)
    }

    @ViewBuilder
    private var detailPaneSurface: some View {
        if model.setupCompleted {
            Group {
                switch activePane {
                case .suite, .home:
                    home
                case .dev:
                    DevWorkspaceView(model: model)
                case .roachClaw:
                    roachClaw
                case .maps, .education:
                    knowledge
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

    private func headerBar(isTight: Bool) -> some View {
        let commandLabel = isTight ? "Cmd-K" : "Command"
        let roachClawLabel = isTight ? "Claw" : "RoachClaw"
        let sidebarLabel = "Nav"
        let runtimeTitle = model.isLoading ? "Runtime loading" : (model.snapshot == nil ? "Runtime waiting" : "Runtime live")
        let runtimeAccent = model.snapshot == nil ? RoachPalette.warning : RoachPalette.green
        let accountTitle = model.snapshot?.account.linked == true ? "Account linked" : "Account local"
        let accountAccent = model.snapshot?.account.linked == true ? RoachPalette.cyan : RoachPalette.bronze
        return VStack(alignment: .leading, spacing: 10) {
            responsiveBar {
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
                            Text(shellTitle)
                                .font(.system(size: isTight ? 26 : 30, weight: .bold))
                                .foregroundStyle(RoachPalette.text)
                            Text(shellDetail)
                                .font(.system(size: isTight ? 13 : 14, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shellTitle)
                            .font(.system(size: isTight ? 26 : 30, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text(shellDetail)
                            .font(.system(size: isTight ? 13 : 14, weight: .regular))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }
            } actions: {
                Button(roachClawLabel) {
                    openGlobalRoachClaw()
                }
                .buttonStyle(RoachSecondaryButtonStyle())

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

                RoachTag(model.setupCompleted ? "Ready" : "Setup", accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    RoachTag(runtimeTitle, accent: runtimeAccent)
                    RoachTag(accountTitle, accent: accountAccent)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func commandTray(isTight: Bool) -> some View {
        Button {
            showCommandPalette = true
        } label: {
            RoachCommandTray(
                label: "Command Bar",
                prompt: isTight
                    ? "Cmd-K here. \(RoachNetGlobalHotKey.hint) over the desktop."
                    : "Jump anywhere fast. Cmd-K here, \(RoachNetGlobalHotKey.hint) from anywhere."
            )
        }
        .buttonStyle(RoachCardButtonStyle())
        .contentShape(Rectangle())
        .keyboardShortcut("k", modifiers: [.command])
    }

    private var suite: some View {
        let installedServices = serviceCatalogServices.filter { $0.installed ?? false }
        let availableServices = serviceCatalogServices.filter { !($0.installed ?? false) }

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader("Suite", title: "Installed surfaces, not browser tabs.", detail: "Open what is already on this machine, then stage the next useful module in the same app.")

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                        suiteCard(title: "Home", detail: "The contained shell and the next useful move.", value: "Status, command bar, and launch deck", pane: .home)
                        suiteCard(title: "Dev", detail: "Native coding, shell, and secrets surfaces.", value: "Projects and AI assist", pane: .dev)
                        suiteCard(
                            title: "Vault",
                            detail: "Files, captured sites, imported notes, atlas packs, and study shelves.",
                            value: "\(model.snapshot?.knowledgeFiles.count ?? 0) files · \(model.snapshot?.siteArchives.count ?? 0) captures · \(model.snapshot?.mapCollections.count ?? 0) map packs",
                            pane: .knowledge
                        )
                        suiteCard(title: "RoachClaw", detail: "Private AI, local by default.", value: roachClawSummary, pane: .roachClaw)
                        suiteCard(title: "Runtime", detail: "Health, logs, and service state.", value: providerSummary, pane: .runtime)
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
        RoachSpotlightPanel(accent: RoachPalette.bronze) {
            VStack(alignment: .leading, spacing: 18) {
                RoachSectionHeader(
                    "Setup",
                    title: "Finish setup. Then the full shell opens.",
                    detail: "Install work stays in setup so the main app stays clean once you are in."
                )

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Install Root", value: model.installPath)
                    RoachInfoPill(title: "App Path", value: model.installedAppPath)
                    RoachInfoPill(title: "Status", value: "Waiting")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Button("Refresh Local State") {
                            model.refreshConfigOnly()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button("Open Guide") {
                            showLaunchGuide = true
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Refresh Local State") {
                            model.refreshConfigOnly()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button("Open Guide") {
                            showLaunchGuide = true
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
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
                    responsiveBar {
                        HStack(alignment: .top, spacing: 16) {
                            RoachModuleMark(
                                systemName: WorkspacePane.home.icon,
                                size: 56,
                                isSelected: true,
                                glow: true
                            )

                            RoachSectionHeader(
                                "Home",
                                title: "Home is where the Roach is!",
                                detail: "RoachClaw, the vault, the dev desk, and the runtime stay under one root instead of dissolving into tabs, dashboards, and drift."
                            )
                        }
                    } actions: {
                        Button("Open Dev") {
                            model.selectedPane = .dev
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button("RoachClaw") {
                            model.selectedPane = .roachClaw
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            homeOverviewPanel(hardware: hardware, roachClaw: roachClaw)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            homeSignalDeck(
                                hardware: hardware,
                                installedServices: installedServices.count,
                                availableServices: availableServices.count
                            )
                            .frame(width: 320)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            homeOverviewPanel(hardware: hardware, roachClaw: roachClaw)

                            homeSignalDeck(
                                hardware: hardware,
                                installedServices: installedServices.count,
                                availableServices: availableServices.count
                            )
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    RoachSectionHeader(
                        "Command Grid",
                        title: "Open the next thing that matters.",
                        detail: "Core surfaces, installable shelves, and the next useful move stay in one grid."
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
                                title: "Bring the missing pieces home without guessing.",
                                detail: "RoachNet calls out the blockers instead of sending you hunting through setup cruft."
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

            responsiveBar {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contained desktop build v\(bundleVersion)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                    Text("AI, archive, the dev desk, and the runtime stay under one root.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            } actions: {
                Button("Guide") {
                    showLaunchGuide = true
                }
                .buttonStyle(RoachSecondaryButtonStyle())

                footerAction(title: "Diagnostics", path: "/settings/system")
                footerAction(title: "Debug Info", path: "/api/system/debug-info")
            }
        }
    }

    private func homeSignalDeck(
        hardware: SystemInfoResponse.HardwareProfile?,
        installedServices: Int,
        availableServices: Int
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    RoachMetricCard(
                        label: "Runtime",
                        value: model.snapshot == nil ? "Waiting" : "Live",
                        detail: model.snapshot?.internetConnected == true ? "Online, but still local-first." : "Offline is still fully usable."
                    )
                    RoachMetricCard(
                        label: "Account",
                        value: model.snapshot?.account.linked == true ? "Linked" : "Local",
                        detail: model.snapshot?.account.linked == true ? "Cloud chat and sync lane available." : "Everything stays on this box."
                    )
                    RoachMetricCard(
                        label: "Modules",
                        value: "\(installedServices) live / \(availableServices) staged",
                        detail: "Install what you need. Ignore the rest."
                    )
                    RoachMetricCard(
                        label: "Machine",
                        value: runtimeCPUValue(model.snapshot?.systemInfo),
                        detail: hardware == nil
                            ? "Apple Silicon optimized path"
                            : "\(hardware?.memoryTier.capitalized ?? "Local") memory · \(hardware?.recommendedModelClass ?? "default")"
                    )
                }

            }
        }
    }

    private func homeOverviewPanel(
        hardware: SystemInfoResponse.HardwareProfile?,
        roachClaw: RoachClawStatusResponse?
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "At A Glance",
                    title: "What matters, up front.",
                        detail: "Read the machine, see the blockers, and keep moving."
                )

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Runtime",
                        value: roachClaw?.preferredMode ?? hardware?.recommendedRuntime ?? "native_local",
                        detail: model.snapshot?.internetConnected == true
                            ? "Live, contained, and still in one root."
                            : "Offline is fine. The shell still moves.",
                        systemName: "server.rack",
                        accent: RoachPalette.green
                    )
                    RoachDigestRow(
                        "AI lane",
                        value: model.displayedRoachClawDefaultModel,
                        detail: roachClaw?.ollama.available == true
                            ? "Local RoachClaw is ready."
                            : "Finish the first local model from AI Control or Easy Setup.",
                        systemName: "sparkles",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Vault",
                        value: "\(model.snapshot?.knowledgeFiles.count ?? 0) local files",
                        detail: "Maps, notes, docs, and captures stay grouped together.",
                        systemName: "books.vertical.fill",
                        accent: RoachPalette.cyan
                    )
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
            RoachSpotlightPanel(accent: RoachPalette.green) {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                        RoachSectionHeader(
                            "RoachClaw",
                            title: "Keep the thread in front.",
                            detail: "Chat first, local by default, and keep voice, routing, memory, and app context inside one workbench."
                        )
                    } actions: {
                        Button("AI Control") {
                            Task { await model.openRoute("/settings/ai", title: "AI Control") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

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

                    roachClawWorkbenchSignalGrid(
                        recommendedQuickstartModel: recommendedQuickstartModel,
                        cloudModels: cloudModels.count
                    )

                    roachClawConversationAndActionDeck(
                        roachClaw: roachClaw,
                        recommendedQuickstartModel: recommendedQuickstartModel,
                        cloudModel: cloudModels.first,
                        activeModelDownloads: activeModelDownloads.count,
                        cloudModels: cloudModels.count
                    )
                }
            }

            roachClawOverviewPanel(roachClaw: roachClaw, providers: providers)

            LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 16) {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            RoachKicker("RoachBrain")
                            Spacer()
                            RoachTag("\(model.roachBrainWikiStatus.pageCount) wiki", accent: RoachPalette.cyan)
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
                            Text("Run a few real threads or pin a useful answer. The local memory shelf starts filling from there.")
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
                        Text("Pick the first route on purpose.")
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

                        RoachNotice(
                            title: "Compiled Wiki",
                            detail: model.roachBrainWikiStatus.pageCount == 0
                                ? "RoachBrain will compile saved turns into an Obsidian-readable local wiki as memory grows."
                                : "\(model.roachBrainWikiStatus.pageCount) linked pages are ready at index.md for RoachClaw context.",
                            accent: RoachPalette.cyan
                        )
                    }
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        RoachKicker("Routing")
                        Text("Keep one machine fast. Reach for the wider lane only when the local route stops being enough.")
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

    private func roachClawSignalDeck(
        roachClaw: RoachClawStatusResponse?,
        activeModelDownloads: Int,
        cloudModels: Int
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Signal Board",
                    title: "Read the AI lane fast.",
                    detail: "Default, memory, downloads, and fallback. No scavenger hunt."
                )

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    RoachMetricCard(
                        label: "Default",
                        value: model.displayedRoachClawDefaultModel,
                        detail: "Current chat default"
                    )
                    RoachMetricCard(
                        label: "Memory",
                        value: "\(model.roachBrainMemories.count)",
                        detail: model.roachBrainPinnedCount > 0 ? "\(model.roachBrainPinnedCount) pinned" : "No pinned recalls yet"
                    )
                    RoachMetricCard(
                        label: "Downloads",
                        value: activeModelDownloads == 0 ? "Clear" : "\(activeModelDownloads) active",
                        detail: activeModelDownloads == 0 ? "No models in flight" : "Model queue moving"
                    )
                    RoachMetricCard(
                        label: "Fallback",
                        value: cloudModels == 0 ? "Local only" : "\(cloudModels) cloud routes",
                        detail: roachClaw?.ready == true ? "Local route is ready first" : "Warmup still in progress"
                    )
                }
            }
        }
    }

    private func roachClawOverviewPanel(
        roachClaw: RoachClawStatusResponse?,
        providers: [String: AIRuntimeStatusResponse]
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Model lane",
                    title: "The AI stack, once.",
                    detail: "What is live, where it lives, and what RoachBrain already knows."
                )

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Ollama",
                        value: providerValue(providers["ollama"]),
                        detail: "Contained model lane inside this RoachNet install.",
                        systemName: "sparkles",
                        accent: RoachPalette.green
                    )
                    RoachDigestRow(
                        "OpenClaw",
                        value: providerValue(providers["openclaw"]),
                        detail: "Agent runtime for the local workbench and tool lane.",
                        systemName: "bolt.horizontal.circle",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Workspace",
                        value: workspaceValue(roachClaw?.workspacePath),
                        detail: "RoachClaw stays contained unless you deliberately open another lane.",
                        systemName: "shippingbox.fill",
                        accent: RoachPalette.cyan
                    )
                    RoachDigestRow(
                        "RoachBrain",
                        value: "\(model.roachBrainMemories.count) memories",
                        detail: model.roachBrainPinnedCount > 0
                            ? "\(model.roachBrainPinnedCount) pinned and ready for retrieval."
                            : "Recent prompts and replies stay searchable locally.",
                        systemName: "brain.head.profile",
                        accent: RoachPalette.bronze
                    )
                    RoachDigestRow(
                        "Compiled Wiki",
                        value: model.roachBrainWikiStatus.pageCount == 0 ? "Waiting" : "\(model.roachBrainWikiStatus.pageCount) pages",
                        detail: "Saved work becomes linked Markdown context RoachClaw can read before raw recall.",
                        systemName: "point.3.connected.trianglepath.dotted",
                        accent: RoachPalette.cyan
                    )
                }
            }
        }
    }

    private func roachClawWorkbenchSignalGrid(
        recommendedQuickstartModel: String,
        cloudModels: Int
    ) -> some View {
        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
            RoachMetricCard(
                label: "Selected",
                value: model.selectedChatModelLabel,
                detail: "Current workbench model"
            )
            RoachMetricCard(
                label: "Quickstart",
                value: recommendedQuickstartModel,
                detail: "Recommended contained first model"
            )
            RoachMetricCard(
                label: "Fallback",
                value: cloudModels == 0 ? "Local only" : "\(cloudModels) cloud routes",
                detail: model.hasCloudChatFallback ? "Cloud only when you ask for it." : "No remote provider armed."
            )
            RoachMetricCard(
                label: "RoachBrain",
                value: "\(model.roachBrainPinnedCount) pinned",
                detail: model.roachBrainMemories.isEmpty ? "Memory shelf is still empty." : "\(model.roachBrainMemories.count) local recalls indexed"
            )
            RoachMetricCard(
                label: "Wiki",
                value: model.roachBrainWikiStatus.pageCount == 0 ? "Ready" : "\(model.roachBrainWikiStatus.pageCount) pages",
                detail: "Compiled markdown context"
            )
        }
    }

    private func roachClawConversationAndActionDeck(
        roachClaw: RoachClawStatusResponse?,
        recommendedQuickstartModel: String,
        cloudModel: String?,
        activeModelDownloads: Int,
        cloudModels: Int
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                roachClawConversationDock
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    roachClawActionDock(
                        recommendedQuickstartModel: recommendedQuickstartModel,
                        cloudModel: cloudModel
                    )

                    roachClawSignalDeck(
                        roachClaw: roachClaw,
                        activeModelDownloads: activeModelDownloads,
                        cloudModels: cloudModels
                    )
                }
                .frame(width: 320, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 14) {
                roachClawConversationDock
                VStack(alignment: .leading, spacing: 14) {
                    roachClawActionDock(
                        recommendedQuickstartModel: recommendedQuickstartModel,
                        cloudModel: cloudModel
                    )

                    roachClawSignalDeck(
                        roachClaw: roachClaw,
                        activeModelDownloads: activeModelDownloads,
                        cloudModels: cloudModels
                    )
                }
            }
        }
    }

    private var roachClawStarterPrompts: [String] {
        [
            "Give me the next useful move for this machine.",
            "Summarize what RoachNet is running right now.",
            "Turn the latest local context into a clean action list.",
            "What should I pin into RoachBrain from this thread?",
        ]
    }

    private var roachClawConversationDock: some View {
        let threadLines = Array(model.chatLines.suffix(24))
        let hasMessages = !threadLines.isEmpty
        let latestPrompt = model.chatLines.last(where: { $0.role == "User" })?.text
        let threadTitle = latestPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? latestPrompt!
            : "Fresh thread"
        let laneTitle = model.hasCloudChatFallback ? "Web lane active" : "Private lane first"

        return RoachInsetPanel {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        RoachPalette.magenta.opacity(0.24),
                                                        RoachPalette.cyan.opacity(0.16),
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 42, height: 42)

                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(RoachPalette.text)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("RoachClaw")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .tracking(1.2)
                                            .foregroundStyle(RoachPalette.magenta)
                                        Text(hasMessages ? "Keep the thread in front." : "What can RoachClaw help with?")
                                            .font(.system(size: 24, weight: .bold, design: .rounded))
                                            .foregroundStyle(RoachPalette.text)
                                    }
                                }

                                Text(hasMessages
                                     ? "This lane stays chat-first. Threads stay in front while routing, voice, and memory stay one move off to the side."
                                     : "Your thread stays with this workbench. Pair the private local lane when the machine should answer first.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 8) {
                                RoachTag(laneTitle, accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                RoachTag(model.selectedChatModelLabel, accent: RoachPalette.magenta)
                                RoachTag("\(threadLines.count) turns", accent: RoachPalette.cyan)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    RoachPalette.magenta.opacity(0.24),
                                                    RoachPalette.cyan.opacity(0.16),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 42, height: 42)

                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(RoachPalette.text)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("RoachClaw")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .tracking(1.2)
                                        .foregroundStyle(RoachPalette.magenta)
                                    Text(hasMessages ? "Keep the thread in front." : "What can RoachClaw help with?")
                                        .font(.system(size: 24, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                }
                            }

                            Text(hasMessages
                                 ? "This lane stays chat-first. Threads stay in front while routing, voice, and memory stay one move off to the side."
                                 : "Your thread stays with this workbench. Pair the private local lane when the machine should answer first.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)

                            HStack(spacing: 8) {
                                RoachTag(laneTitle, accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                RoachTag(model.selectedChatModelLabel, accent: RoachPalette.magenta)
                                RoachTag("\(threadLines.count) turns", accent: RoachPalette.cyan)
                            }
                        }
                    }

                    if let speechStatusLine = model.speechStatusLine {
                        HStack(spacing: 10) {
                            Image(systemName: model.isDictatingPrompt ? "waveform.circle.fill" : "speaker.wave.2.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(model.isDictatingPrompt ? RoachPalette.green : RoachPalette.cyan)
                            Text(speechStatusLine)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                            Spacer(minLength: 8)
                            Text(model.isDictatingPrompt ? "Voice prompt live" : "Reply playback")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(model.isDictatingPrompt ? RoachPalette.green : RoachPalette.cyan)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.60))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                    }
                }

                if hasMessages {
                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(threadTitle)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                        .lineLimit(1)
                                    Text("Recent turns stay readable here while route, context, and voice stay one move away.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                }

                                Spacer(minLength: 12)

                                HStack(spacing: 8) {
                                    RoachTag("Thread anchored", accent: RoachPalette.magenta)
                                    RoachTag(model.hasCloudChatFallback ? "Web lane" : "Private lane", accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(threadTitle)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                Text("Recent turns stay readable here while route, context, and voice stay one move away.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                HStack(spacing: 8) {
                                    RoachTag("Thread anchored", accent: RoachPalette.magenta)
                                    RoachTag(model.hasCloudChatFallback ? "Web lane" : "Private lane", accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                }
                            }
                        }

                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(threadLines) { line in
                                    ChatBubble(line: line)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 390, idealHeight: 460, maxHeight: 560)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            RoachPalette.panelRaised.opacity(0.84),
                                            RoachPalette.panel.opacity(0.74),
                                            Color.black.opacity(0.28),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(RoachPalette.borderStrong, lineWidth: 1)
                        )
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(RoachPalette.cyan.opacity(0.14))
                                        .frame(width: 54, height: 54)
                                    Image(systemName: "message.badge.waveform.fill")
                                        .font(.system(size: 21, weight: .bold))
                                        .foregroundStyle(RoachPalette.cyan)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Start with one clear ask.")
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                    Text("Use a starter prompt or drop straight into the composer. Keep the thread here instead of letting it dissolve into stray tabs and notes.")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                }
                            }

                            HStack(spacing: 8) {
                                RoachTag("Thread-first lane", accent: RoachPalette.magenta)
                                RoachTag("Private lane first", accent: RoachPalette.green)
                                RoachTag("Context stays gated", accent: RoachPalette.cyan)
                            }
                        }

                        roachClawStarterPromptDeck(roachClawStarterPrompts)
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        RoachPalette.panelRaised.opacity(0.76),
                                        RoachPalette.panel.opacity(0.62),
                                        Color.black.opacity(0.18),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(RoachPalette.borderStrong, lineWidth: 1)
                    )
                }

                roachClawWorkingSetDock

                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 12) {
                            roachClawComposerField
                            roachClawSendButton
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            roachClawComposerField
                            roachClawSendButton
                        }
                    }

                    Text(model.hasCloudChatFallback
                         ? "The web lane stays ready from anywhere. Promote the private local lane when this machine should answer first."
                         : "RoachClaw stays private-first. Open a wider web lane only when the thread genuinely needs it.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
    }

    private var roachClawWorkingSetDock: some View {
        let replies = Array(model.chatLines.filter { $0.role == "RoachClaw" }.suffix(3))
        let memories = Array(
            model.roachBrainMemories
                .sorted { lhs, rhs in
                    if lhs.pinned != rhs.pinned {
                        return lhs.pinned && !rhs.pinned
                    }
                    return lhs.lastAccessedAt > rhs.lastAccessedAt
                }
                .prefix(3)
        )

        return RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                responsiveBar {
                    RoachSectionHeader(
                        "Working Set",
                        title: "Keep the useful output close.",
                        detail: "Recent replies and pinned memory act like lightweight artifacts: readable, copyable, and ready to save without leaving the thread."
                    )
                } actions: {
                    HStack(spacing: 8) {
                        RoachTag("\(replies.count) replies", accent: RoachPalette.magenta)
                        RoachTag("\(memories.count) recalls", accent: RoachPalette.cyan)
                    }
                }

                if replies.isEmpty && memories.isEmpty {
                    Text("Ask once, then the pieces worth keeping start stacking here.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(replies) { line in
                                roachClawWorkingSetCard(
                                    eyebrow: "Reply artifact",
                                    title: String(line.text.prefix(58)),
                                    detail: line.text,
                                    accent: RoachPalette.magenta,
                                    actionTitle: "Copy"
                                ) {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(line.text, forType: .string)
                                    model.statusLine = "Copied a RoachClaw working-set reply."
                                }
                            }

                            ForEach(memories) { memory in
                                roachClawWorkingSetCard(
                                    eyebrow: memory.pinned ? "Pinned recall" : "Memory recall",
                                    title: memory.title,
                                    detail: memory.summary.isEmpty ? memory.body : memory.summary,
                                    accent: memory.pinned ? RoachPalette.green : RoachPalette.cyan,
                                    actionTitle: "Stage"
                                ) {
                                    model.promptDraft = "Use this RoachBrain memory as context and give me the next useful move:\n\n\(memory.title)\n\n\(memory.summary.isEmpty ? memory.body : memory.summary)"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func roachClawWorkingSetCard(
        eyebrow: String,
        title: String,
        detail: String,
        accent: Color,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .shadow(color: accent.opacity(0.35), radius: 8, x: 0, y: 0)
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(accent)
            }

            Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled output" : title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)

            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(4)

            Button(actionTitle) {
                action()
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }
        .padding(14)
        .frame(width: 240, alignment: .topLeading)
        .frame(minHeight: 172, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.82),
                            accent.opacity(0.08),
                            Color.black.opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.26), lineWidth: 1)
        )
    }

    private func roachClawStarterPromptDeck(_ prompts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start with the next sharp ask.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text("Drop a concrete prompt instead of letting the thread go soft.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
                Spacer(minLength: 8)
                RoachTag("Prompt deck", accent: RoachPalette.magenta)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 0), spacing: 10),
                    GridItem(.flexible(minimum: 0), spacing: 10),
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        model.promptDraft = prompt
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(RoachPalette.magenta.opacity(0.18))
                                        .frame(width: 34, height: 34)

                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(RoachPalette.magenta)
                                }

                                Text(prompt)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Text("Drop this into the composer")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(0.9)
                                .foregroundStyle(RoachPalette.muted)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            RoachPalette.panelRaised.opacity(0.88),
                                            RoachPalette.panel.opacity(0.74),
                                            Color.black.opacity(0.12),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(RoachCardButtonStyle())
                }
            }
        }
    }

    private func roachClawLatestReplySpotlight(
        _ reply: String,
        latestPrompt: String?,
        canSaveLatestReply: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            responsiveBar {
                RoachSectionHeader(
                    "Latest Reply",
                    title: "Keep the part worth keeping.",
                    detail: latestPrompt?.isEmpty == false
                        ? "This was the last useful turn. Pin it, play it back, or keep the next follow-up pointed at the same thread."
                        : "The last answer stays in view so you can decide if it belongs in RoachBrain."
                )
            } actions: {
                HStack(spacing: 8) {
                    if let latestPrompt, !latestPrompt.isEmpty {
                        RoachTag("Prompt saved", accent: RoachPalette.green)
                    }
                    RoachTag("Reply live", accent: RoachPalette.magenta)
                }
            }

            if let latestPrompt, !latestPrompt.isEmpty {
                Text(latestPrompt)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(2)
            }

            Text(reply)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Button(model.isSpeakingLatestReply ? "Stop Reply" : "Listen Back") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button(canSaveLatestReply ? "Save to RoachBrain" : "Await Reply") {
                        model.saveLatestRoachClawResponseToRoachBrain()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(!canSaveLatestReply)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button(model.isSpeakingLatestReply ? "Stop Reply" : "Listen Back") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button(canSaveLatestReply ? "Save to RoachBrain" : "Await Reply") {
                        model.saveLatestRoachClawResponseToRoachBrain()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(!canSaveLatestReply)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.92),
                            RoachPalette.panel.opacity(0.82),
                            Color.black.opacity(0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(RoachPalette.borderStrong, lineWidth: 1)
        )
    }

    private func roachClawActionDock(
        recommendedQuickstartModel: String,
        cloudModel: String?
    ) -> some View {
        let canSaveLatestReply = model.chatLines.contains(where: { $0.role == "RoachClaw" })
        let latestPrompt = model.chatLines.last(where: { $0.role == "User" })?.text
        let latestReply = model.latestRoachClawReply

        return RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                if let latestReply, !latestReply.isEmpty {
                    roachClawLatestReplySpotlight(
                        latestReply,
                        latestPrompt: latestPrompt,
                        canSaveLatestReply: canSaveLatestReply
                    )
                }

                RoachSectionHeader(
                    "Control Deck",
                    title: "Pick the lane that answers first.",
                    detail: "Route the prompt, arm voice, and keep the useful part without leaving the thread."
                )

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0), spacing: 10),
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    roachClawRouteCard(
                        kicker: "Local first",
                        title: recommendedQuickstartModel,
                        detail: "Keep the contained model lane in front until you deliberately step out to cloud.",
                        accent: RoachPalette.green,
                        isActive: model.selectedChatModel == recommendedQuickstartModel
                    ) {
                        model.config.roachClawDefaultModel = recommendedQuickstartModel
                        model.selectedChatModel = recommendedQuickstartModel
                        Task { await model.applyRoachClawDefaults() }
                    }

                    if let cloudModel {
                        roachClawRouteCard(
                            kicker: "Cloud when needed",
                            title: cloudModel,
                            detail: "Use the hosted lane when you need it, but keep the workbench and memory shelf in the same surface.",
                            accent: RoachPalette.cyan,
                            isActive: model.selectedChatModel == cloudModel
                        ) {
                            model.selectedChatModel = cloudModel
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Selected",
                        value: model.selectedChatModelLabel,
                        detail: "Current prompt route for this workbench.",
                        systemName: "brain.head.profile",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Voice",
                        value: model.isDictatingPrompt ? "Listening" : (model.isSpeakingLatestReply ? "Speaking" : "Standby"),
                        detail: model.speechStatusLine ?? "Mic and playback stay in the thread instead of hiding behind another surface.",
                        systemName: "waveform",
                        accent: model.isDictatingPrompt ? RoachPalette.green : RoachPalette.cyan
                    )
                    RoachDigestRow(
                        "RoachBrain",
                        value: canSaveLatestReply ? "Ready to save" : "Waiting",
                        detail: canSaveLatestReply ? "The latest assistant turn can be pinned into local recall." : "Run one good prompt and pin the part worth keeping.",
                        systemName: "shippingbox.fill",
                        accent: RoachPalette.bronze
                    )
                    RoachDigestRow(
                        "Context",
                        value: model.enabledRoachClawContextCount == 0 ? "Locked" : "\(model.enabledRoachClawContextCount) lanes armed",
                        detail: model.enabledRoachClawContextCount == 0
                            ? "Vault, captured web, and project context stay dark until you explicitly arm them."
                            : "RoachClaw can read only the lanes you explicitly opened for this workbench.",
                        systemName: "lock.shield.fill",
                        accent: model.enabledRoachClawContextCount == 0 ? RoachPalette.warning : RoachPalette.green
                    )
                }

                roachClawContextAccessDeck

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 10) {
                    Button(canSaveLatestReply ? "Save to RoachBrain" : "Await Reply") {
                        model.saveLatestRoachClawResponseToRoachBrain()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(!canSaveLatestReply)

                    Button(model.isSpeakingLatestReply ? "Stop Reply" : "Listen Back") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.latestRoachClawReply == nil)

                    Button(model.isDictatingPrompt ? "Stop Voice Prompt" : "Voice Prompt") {
                        Task { await model.togglePromptDictation() }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("Quickstart Local") {
                        model.config.roachClawDefaultModel = recommendedQuickstartModel
                        model.selectedChatModel = recommendedQuickstartModel
                        Task { await model.applyRoachClawDefaults() }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.isApplyingDefaults)

                    Button("Model Store") {
                        Task { await model.openRoute("/settings/models", title: "Model Store") }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
            }
        }
    }

    private var roachClawContextAccessDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoachSectionHeader(
                "Context Access",
                title: "Open only the lanes you want RoachClaw to read.",
                detail: "These permissions stay local to RoachNet. Open vault, captured web, or project context only when the thread actually needs more ground truth."
            )

            ForEach(RoachClawContextScope.allCases) { scope in
                let enabled = model.isRoachClawContextEnabled(scope)
                Button {
                    model.setRoachClawContext(scope, enabled: !enabled)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(scope.accent.opacity(enabled ? 0.18 : 0.10))
                                .frame(width: 34, height: 34)

                            Image(systemName: scope.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(scope.accent)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(scope.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(scope.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        RoachTag(enabled ? "Allowed" : "Locked", accent: enabled ? scope.accent : RoachPalette.warning)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(enabled ? 0.74 : 0.58))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(enabled ? scope.accent.opacity(0.24) : RoachPalette.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func roachClawRouteCard(
        kicker: String,
        title: String,
        detail: String,
        accent: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kicker.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 10)

                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(isActive ? accent : RoachPalette.muted)
                }

                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(isActive ? "Answering first" : "Promote this lane")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(isActive ? 0.16 : 0.08),
                                RoachPalette.panelRaised.opacity(0.86),
                                Color.black.opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? accent.opacity(0.55) : RoachPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(RoachCardButtonStyle())
    }

    private var roachClawComposerField: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Button {
                Task { await model.togglePromptDictation() }
            } label: {
                Image(systemName: model.isDictatingPrompt ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(model.isDictatingPrompt ? RoachPalette.green : RoachPalette.magenta)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)

                TextField("Ask RoachClaw something concrete", text: $model.promptDraft, axis: .vertical)
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
        }
    }

    private var roachClawSendButton: some View {
        Button(model.isSendingPrompt ? "Sending..." : "Send") {
            Task { await model.sendPrompt() }
        }
        .buttonStyle(RoachPrimaryButtonStyle())
        .disabled(model.isSendingPrompt || model.chatModelOptions.isEmpty)
    }

    private var maps: some View {
        let collections = model.snapshot?.mapCollections ?? []
        let activeMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" && $0.status != "failed" } ?? []
        let failedMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" && $0.status == "failed" } ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                        RoachSectionHeader("Atlas Shelf", title: "Offline regions live inside Vault now.", detail: "Download region packs, install the base atlas, and keep route references on the same shelf as notes, captures, and media.")
                    } actions: {
                        Button("Open Atlas View") {
                            Task { await model.openRoute("/maps", title: "Atlas Shelf") }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        Button(model.activeActions.contains("maps-base-assets") ? "Installing..." : "Install Atlas Base") {
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
                ForEach(collections) { collection in
                    let installedCount = collection.installed_count ?? 0
                    let totalCount = collection.total_count ?? collection.resources.count
                    let fullyInstalled = totalCount > 0 && installedCount >= totalCount
                    let actionKey = "map-\(collection.slug)"

                    Button {
                        if fullyInstalled {
                            Task { await model.openRoute("/maps", title: collection.name) }
                        } else {
                            Task { await model.downloadMapCollection(collection.slug) }
                        }
                    } label: {
                        VaultVirtualShelfCard(
                            title: collection.name,
                            detail: collection.description ?? "Offline regional map pack ready to live on the atlas shelf.",
                            pathLabel: "Vault / Atlas / \(collection.slug)",
                            kindLabel: "Atlas Pack",
                            actionLabel: fullyInstalled
                                ? "Open atlas"
                                : (model.activeActions.contains(actionKey) ? "Queueing..." : "Add to Vault"),
                            accent: RoachPalette.cyan,
                            fallbackSystemName: "map.fill",
                            extraTags: [
                                "\(installedCount) / \(totalCount) ready",
                                fullyInstalled ? "Ready on shelf" : "Download to Vault",
                            ]
                        )
                    }
                    .buttonStyle(RoachCardButtonStyle())
                    .disabled(model.activeActions.contains(actionKey))
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
                        RoachSectionHeader("Study Shelf", title: "Wikipedia and reference packs stay in the library.", detail: "Pick a Wikipedia bundle, queue recommended content tiers, and keep docs or setup close without splitting them into another lane.")
                    } actions: {
                        Button("Open Study View") {
                            Task { await model.openRoute("/docs/home", title: "Study Shelf") }
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

            if let wikipedia {
                LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 16) {
                    ForEach(wikipedia.options) { option in
                        let actionKey = "wikipedia-\(option.id)"
                        let isCurrentSelection = wikipedia.currentSelection?.optionId == option.id

                        Button {
                            if isCurrentSelection {
                                Task { await model.openRoute("/docs/home", title: option.name) }
                            } else {
                                model.selectedWikipediaOptionId = option.id
                                Task { await model.applyWikipediaSelection() }
                            }
                        } label: {
                            VaultVirtualShelfCard(
                                title: option.name,
                                detail: option.description ?? "Wikipedia bundle ready for the study shelf.",
                                pathLabel: "Vault / Wikipedia / \(option.id)",
                                kindLabel: "Wikipedia",
                                actionLabel: isCurrentSelection
                                    ? "Open study lane"
                                    : (model.activeActions.contains(actionKey) ? "Applying..." : "Bring to Vault"),
                                accent: isCurrentSelection ? RoachPalette.magenta : RoachPalette.cyan,
                                fallbackSystemName: "globe.americas.fill",
                                extraTags: [
                                    isCurrentSelection ? "Current selection" : "Available",
                                    "Study shelf",
                                ]
                            )
                        }
                        .buttonStyle(RoachCardButtonStyle())
                        .disabled(model.activeActions.contains(actionKey))
                    }
                }
            }

            LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 16) {
                ForEach(categories) { category in
                    let recommendedTier = category.tiers.first(where: { $0.recommended == true }) ?? category.tiers.first
                    let installedTier = category.tiers.first(where: { $0.slug == category.installedTierSlug })
                    let actionKey = "education-\(category.slug)-\(recommendedTier?.slug ?? "")"

                    Button {
                        if installedTier != nil {
                            Task { await model.openRoute("/docs/home", title: category.name) }
                        } else if let recommendedTier {
                            Task {
                                await model.downloadEducationTier(
                                    categorySlug: category.slug,
                                    tierSlug: recommendedTier.slug
                                )
                            }
                        }
                    } label: {
                        VaultVirtualShelfCard(
                            title: category.name,
                            detail: category.description ?? "Curated offline education pack ready for the study shelf.",
                            pathLabel: "Vault / Study / \(category.slug) / \((installedTier ?? recommendedTier)?.slug ?? "queue")",
                            kindLabel: "Study Shelf",
                            actionLabel: installedTier != nil
                                ? "Open study lane"
                                : (model.activeActions.contains(actionKey) ? "Queueing..." : "Download recommended"),
                            accent: RoachPalette.green,
                            fallbackSystemName: "books.vertical.fill",
                            extraTags: [
                                installedTier?.name ?? recommendedTier?.name ?? "Tiered",
                                installedTier != nil ? "Ready on shelf" : "Recommended tier",
                            ]
                        )
                    }
                    .buttonStyle(RoachCardButtonStyle())
                    .disabled(recommendedTier == nil || model.activeActions.contains(actionKey))
                }
            }
        }
    }

    private var knowledge: some View {
        let files = model.snapshot?.knowledgeFiles ?? []
        let archives = model.snapshot?.siteArchives ?? []
        let mapCollectionCount = model.snapshot?.mapCollections.count ?? 0
        let educationCategoryCount = model.snapshot?.educationCategories.count ?? 0
        let installedMapCollections = (model.snapshot?.mapCollections ?? []).filter { ($0.installed_count ?? 0) > 0 }
        let installedEducationCategories = (model.snapshot?.educationCategories ?? []).filter { category in
            guard let installedTierSlug = category.installedTierSlug else { return false }
            return category.tiers.contains(where: { $0.slug == installedTierSlug })
        }
        let installedWikipediaOption = model.snapshot?.wikipediaState.currentSelection?.optionId.flatMap { selectedID in
            model.snapshot?.wikipediaState.options.first(where: { $0.id == selectedID })
        }
        let installedModelNames = model.snapshot?.installedModels.map(\.name) ?? []
        let importedVaults = model.importedObsidianVaults
        let selectedImportedVault = importedVaults.first(where: { $0.id == model.selectedImportedVaultID }) ?? importedVaults.first
        let activeImportedVaultName = selectedImportedVault?.name ?? "No live markdown vault selected"
        let importedVaultNotes = selectedImportedVault.map { VaultWorkspaceStore.noteURLs(in: $0, limit: nil) } ?? []

        return VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                responsiveBar {
                    RoachSectionHeader(
                        "Vault",
                        title: "One shelf. Fewer dead ends.",
                        detail: "Notes, books, media, captures, and saved files stay close to the workspace and open inside RoachNet instead of bouncing you into another app."
                    )
                } actions: {
                    HStack(spacing: 8) {
                        Button("Import Obsidian Vault") {
                            model.importObsidianVault()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        RoachTag("EPUB ready", accent: RoachPalette.magenta)
                        RoachTag("Media preview", accent: RoachPalette.cyan)
                        RoachTag("Shelf view", accent: RoachPalette.green)
                        RoachTag("\(archives.count) captured sites", accent: RoachPalette.cyan)
                        RoachTag("\(mapCollectionCount) atlas packs", accent: RoachPalette.cyan)
                        RoachTag("\(educationCategoryCount) study shelves", accent: RoachPalette.green)
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    RoachSectionHeader(
                        "Shelf Pulse",
                        title: "The living library stays readable at a glance.",
                        detail: "See what is already on the shelf before you dive into notes, captures, atlases, study packs, or media."
                    )

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachMetricCard(
                            label: "Indexed",
                            value: "\(files.count)",
                            detail: files.isEmpty ? "No files on shelf yet" : "Files ready to open in place"
                        )
                        RoachMetricCard(
                            label: "Imported vaults",
                            value: "\(importedVaults.count)",
                            detail: importedVaults.isEmpty ? activeImportedVaultName : "\(activeImportedVaultName) is active"
                        )
                        RoachMetricCard(
                            label: "Captured web",
                            value: "\(archives.count)",
                            detail: archives.isEmpty ? "No mirrored sites yet" : "Offline site mirrors are shelved here"
                        )
                        RoachMetricCard(
                            label: "Installed packs",
                            value: "\(installedMapCollections.count + installedEducationCategories.count + (installedWikipediaOption == nil ? 0 : 1) + installedModelNames.count)",
                            detail: "Atlas, study, Wikipedia, and model packs stay inside Vault"
                        )
                    }
                }
            }

            if !archives.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Captured Web",
                                title: "Captured sites belong on the same shelf.",
                                detail: "The mirrored web lane is folded into Vault so saved sites, imported notes, and the rest of the library stop pretending they are separate products."
                            )
                        } actions: {
                            Button("Open Offline Web Apps") {
                                Task { await model.openRoute("/site-archives", title: "Offline Web Apps") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 12) {
                            ForEach(archives) { archive in
                                Button {
                                    Task { await model.openRoute("/site-archives", title: "Offline Web Apps") }
                                } label: {
                                    VaultVirtualShelfCard(
                                        title: archive.title ?? archive.slug,
                                        detail: archive.url ?? "Captured site mirror already staged in the contained web lane.",
                                        pathLabel: "Vault / Captured Web / \(archive.slug)",
                                        kindLabel: "Captured Site",
                                        actionLabel: "Open Offline Web Apps",
                                        accent: RoachPalette.cyan,
                                        fallbackSystemName: "globe.badge.chevron.backward",
                                        extraTags: ["Contained mirror", "Vault lane"]
                                    )
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }
                        }
                    }
                }
            }

            if !importedVaults.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Obsidian",
                                title: "Bring the notes home without copying them.",
                                detail: "Imported vaults stay where they already live on disk. RoachNet reads the same markdown, keeps the links live, and gives the notes their own shelf."
                            )
                        } actions: {
                            if let selectedImportedVault {
                                Button("Reveal \(selectedImportedVault.name)") {
                                    model.openImportedVaultInFinder(selectedImportedVault)
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }

                        LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 12) {
                            ForEach(importedVaults) { vault in
                                Button {
                                    model.selectedImportedVaultID = vault.id
                                } label: {
                                    VaultVirtualShelfCard(
                                        title: vault.name,
                                        detail: "RoachNet and Obsidian can point at the same markdown files without copying the vault into a second silo.",
                                        pathLabel: vault.path,
                                        kindLabel: VaultWorkspaceStore.isObsidianCompatible(vault: vault) ? "Obsidian live link" : "Markdown shelf",
                                        actionLabel: vault.id == selectedImportedVault?.id ? "Selected shelf" : "Browse notes",
                                        accent: VaultWorkspaceStore.isObsidianCompatible(vault: vault) ? RoachPalette.magenta : RoachPalette.cyan,
                                        fallbackSystemName: "books.vertical.fill",
                                        extraTags: {
                                            var tags = ["\(VaultWorkspaceStore.noteCount(in: vault)) notes", "Same markdown files"]
                                            if vault.id == selectedImportedVault?.id {
                                                tags.append("Selected")
                                            }
                                            return tags
                                        }()
                                    )
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }
                        }
                    }
                }
            }

            maps

            education

            if let selectedImportedVault, !importedVaultNotes.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Notes Lane",
                                title: "\(selectedImportedVault.name), inside RoachNet.",
                                detail: "Open notes from the imported vault in the built-in editor and keep the same markdown readable in Obsidian."
                            )
                        } actions: {
                            RoachTag("Shared with Obsidian", accent: RoachPalette.magenta)
                        }

                        LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 12) {
                            ForEach(importedVaultNotes, id: \.path) { noteURL in
                                Button {
                                    model.revealImportedVaultNote(noteURL)
                                } label: {
                                    VaultShelfCard(
                                        url: noteURL,
                                        title: noteURL.deletingPathExtension().lastPathComponent,
                                        detail: importedVaultNoteDetail(noteURL: noteURL, vault: selectedImportedVault),
                                        pathLabel: noteURL.path,
                                        kindLabel: "Note",
                                        actionLabel: "Open note",
                                        accent: RoachPalette.magenta,
                                        fallbackSystemName: "note.text",
                                        extraTags: ["Shared with Obsidian"]
                                    )
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }
                        }
                    }
                }
            }

            if !installedMapCollections.isEmpty || !installedEducationCategories.isEmpty || installedWikipediaOption != nil || !installedModelNames.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Installed Packs",
                                title: "App Store installs still land inside the library.",
                                detail: "Maps, study shelves, Wikipedia, and model packs stay grouped with the rest of the contained vault instead of disappearing into separate setup lanes."
                            )
                        } actions: {
                            RoachTag("Installed via Apps", accent: RoachPalette.magenta)
                        }

                        LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 12) {
                            ForEach(installedMapCollections) { collection in
                                Button {
                                    Task { await model.openRoute("/maps", title: collection.name) }
                                } label: {
                                    VaultVirtualShelfCard(
                                        title: collection.name,
                                        detail: collection.description ?? "Offline region pack already staged inside RoachNet.",
                                        pathLabel: "Vault / Atlas / \(collection.slug)",
                                        kindLabel: "Map Pack",
                                        actionLabel: "Open atlas",
                                        accent: RoachPalette.cyan,
                                        fallbackSystemName: "map.fill",
                                        extraTags: [
                                            "\(collection.installed_count ?? 0) / \(collection.total_count ?? collection.resources.count) ready",
                                            "Installed via Apps",
                                        ]
                                    )
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }

                            ForEach(installedEducationCategories) { category in
                                if let installedTier = category.tiers.first(where: { $0.slug == category.installedTierSlug }) {
                                    Button {
                                        Task { await model.openRoute("/docs/home", title: category.name) }
                                    } label: {
                                        VaultVirtualShelfCard(
                                            title: category.name,
                                            detail: installedTier.description ?? category.description ?? "Curated offline reference shelf already staged inside the vault.",
                                            pathLabel: "Vault / Study / \(category.slug) / \(installedTier.slug)",
                                            kindLabel: "Study Shelf",
                                            actionLabel: "Open study shelf",
                                            accent: RoachPalette.green,
                                            fallbackSystemName: "books.vertical.fill",
                                            extraTags: [installedTier.name, "Installed via Apps"]
                                        )
                                    }
                                    .buttonStyle(RoachCardButtonStyle())
                                }
                            }

                            if let installedWikipediaOption {
                                Button {
                                    Task { await model.openRoute("/docs/home", title: installedWikipediaOption.name) }
                                } label: {
                                    VaultVirtualShelfCard(
                                        title: installedWikipediaOption.name,
                                        detail: installedWikipediaOption.description ?? "The selected Wikipedia pack is staged in the contained study lane.",
                                        pathLabel: "Vault / Wikipedia / \(installedWikipediaOption.id)",
                                        kindLabel: "Wikipedia",
                                        actionLabel: "Open reference shelf",
                                        accent: RoachPalette.magenta,
                                        fallbackSystemName: "globe.americas.fill",
                                        extraTags: ["Current selection", "Installed via Apps"]
                                    )
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }

                            ForEach(installedModelNames, id: \.self) { modelName in
                                Button {
                                    model.selectedPane = .roachClaw
                                    model.selectedChatModel = modelName
                                } label: {
                                    VaultVirtualShelfCard(
                                        title: modelName,
                                        detail: "Contained RoachClaw model pack ready for local chat, coding, and assistant lanes.",
                                        pathLabel: "Vault / Models / \(modelName)",
                                        kindLabel: "Model Pack",
                                        actionLabel: "Open RoachClaw",
                                        accent: RoachPalette.magenta,
                                        fallbackSystemName: "brain.head.profile",
                                        extraTags: ["Installed via Apps", "Local model"]
                                    )
                                }
                                .buttonStyle(RoachCardButtonStyle())
                            }
                        }
                    }
                }
            }

            if files.isEmpty {
                RoachInsetPanel {
                    Text("No indexed files yet.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            } else {
                LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 12) {
                    ForEach(files, id: \.self) { file in
                        Button {
                            model.previewVaultFile(file)
                        } label: {
                            VaultShelfCard(
                                url: URL(fileURLWithPath: file),
                                title: URL(fileURLWithPath: file).lastPathComponent,
                                detail: vaultFilePreviewHint(for: file),
                                pathLabel: file,
                                kindLabel: vaultFileKindLabel(for: file),
                                actionLabel: vaultFileActionLabel(for: file),
                                accent: vaultFileAccent(for: file),
                                fallbackSystemName: vaultFileIcon(for: file),
                                extraTags: {
                                    let kind = VaultPreviewKind.resolve(for: URL(fileURLWithPath: file))
                                    switch kind {
                                    case .markdown:
                                        return ["Open in RoachNet", "Notes lane"]
                                    case .text:
                                        return ["Open in RoachNet", "Text deck"]
                                    case .image:
                                        return ["Open in RoachNet", "Lightbox"]
                                    default:
                                        return ["Open in RoachNet"]
                                    }
                                }()
                            )
                        }
                        .buttonStyle(RoachCardButtonStyle())
                    }
                }
            }
        }
    }

    private func vaultFileKindLabel(for file: String) -> String {
        switch VaultPreviewKind.resolve(for: URL(fileURLWithPath: file)) {
        case .book:
            return "Book"
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .markdown:
            return "Markdown"
        case .text:
            return "Text"
        case .image:
            return "Image"
        case .pdf:
            return "PDF"
        case .folder:
            return "Folder"
        default:
            return "Preview"
        }
    }

    private func vaultFileIcon(for file: String) -> String {
        switch VaultPreviewKind.resolve(for: URL(fileURLWithPath: file)) {
        case .book:
            return "books.vertical.fill"
        case .video:
            return "film.fill"
        case .audio:
            return "waveform"
        case .markdown:
            return "doc.text.fill"
        case .text:
            return "doc.plaintext.fill"
        case .image:
            return "photo.fill"
        case .pdf:
            return "doc.richtext.fill"
        case .folder:
            return "folder.fill"
        default:
            return "doc.fill"
        }
    }

    private func vaultFileAccent(for file: String) -> Color {
        switch VaultPreviewKind.resolve(for: URL(fileURLWithPath: file)) {
        case .book:
            return RoachPalette.magenta
        case .video:
            return RoachPalette.cyan
        case .audio:
            return RoachPalette.green
        case .markdown:
            return RoachPalette.magenta
        case .text:
            return RoachPalette.cyan
        case .image:
            return RoachPalette.magenta
        case .pdf:
            return RoachPalette.bronze
        case .folder:
            return RoachPalette.cyan
        default:
            return RoachPalette.cyan
        }
    }

    private func vaultFilePreviewHint(for file: String) -> String {
        switch VaultPreviewKind.resolve(for: URL(fileURLWithPath: file)) {
        case .book:
            return "Open the built-in reader surface and keep the book in your shelf."
        case .video:
            return "Open the video lane and keep the file in the same archive shell."
        case .audio:
            return "Play it in the built-in listening surface without leaving the vault."
        case .markdown:
            return "Preview the note in-place and keep the markdown lane close to the wider vault."
        case .text:
            return "Open the file in the built-in text deck and keep config, logs, and source on the same shelf."
        case .image:
            return "Open the file in the lightbox and keep the visual tied to the rest of the archive."
        case .pdf:
            return "Open the document in the built-in reader instead of bouncing out to Preview."
        case .folder:
            return "Open the folder in the expanded shelf view and keep drilling inward without dropping to Finder."
        default:
            return "Open the file inside RoachNet and keep the archive lane tidy."
        }
    }

    private func vaultFileActionLabel(for file: String) -> String {
        switch VaultPreviewKind.resolve(for: URL(fileURLWithPath: file)) {
        case .book, .pdf:
            return "Read"
        case .video:
            return "Watch"
        case .audio:
            return "Play"
        case .markdown:
            return "Open note"
        case .text:
            return "Open file"
        case .image:
            return "Open image"
        case .folder:
            return "Open folder"
        default:
            return "Preview"
        }
    }

    private func importedVaultNoteDetail(noteURL: URL, vault: ImportedObsidianVault) -> String {
        let vaultRoot = vault.url.standardizedFileURL.path + "/"
        let relativePath = noteURL.standardizedFileURL.path.replacingOccurrences(of: vaultRoot, with: "")
        return "Open \(relativePath) in the RoachNet notes lane while keeping the same file live for Obsidian."
    }

    private var runtime: some View {
        let system = model.snapshot?.systemInfo
        let serverInfo = model.snapshot?.serverInfo
        let roachTail = model.snapshot?.roachTail
        let roachSync = model.snapshot?.roachSync
        let failedDownloads = (model.snapshot?.downloads ?? []).filter { $0.status == "failed" }

        return VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.green) {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                RoachSectionHeader(
                    "Runtime",
                    title: "Contained, readable, recoverable.",
                    detail: "One local gateway in front, RoachTail and RoachSync behind it, and the runtime state you actually care about surfaced without a scavenger hunt."
                )
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

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            runtimeOverviewPanel(system: system, serverInfo: serverInfo, roachTail: roachTail, roachSync: roachSync)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            runtimeSignalDeck(
                                system: system,
                                serverInfo: serverInfo,
                                roachTail: roachTail,
                                roachSync: roachSync
                            )
                            .frame(width: 320)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            runtimeOverviewPanel(system: system, serverInfo: serverInfo, roachTail: roachTail, roachSync: roachSync)

                            runtimeSignalDeck(
                                system: system,
                                serverInfo: serverInfo,
                                roachTail: roachTail,
                                roachSync: roachSync
                            )
                        }
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

            if let account = model.snapshot?.account {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Account",
                                title: account.linked ? "Linked and ready." : "Local-only until you link it.",
                                detail: "Web chat, saved app picks, and future synced settings hang off the same contained account lane."
                            )
                        } actions: {
                            Button("Open Account") {
                                model.openPublicURL(account.portalUrl, title: "RoachNet Account")
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button(model.accountActionInFlight ? "Refreshing..." : "Refresh") {
                                Task { await model.affectAccount("refresh") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(model.accountActionInFlight)
                        }

                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                            RoachMetricCard(
                                label: "State",
                                value: account.status.capitalized,
                                detail: account.linked ? (account.displayName ?? account.email ?? "Account linked") : "No account stored in this install"
                            )
                            RoachMetricCard(
                                label: "Settings",
                                value: account.settingsSyncEnabled ? "Synced" : "Local",
                                detail: "Settings lane"
                            )
                            RoachMetricCard(
                                label: "Apps",
                                value: account.savedAppsSyncEnabled ? "Synced" : "Local",
                                detail: "Saved app picks"
                            )
                            RoachMetricCard(
                                label: "Hosted Chat",
                                value: account.hostedChatEnabled ? "Armed" : "Off",
                                detail: "RoachClaw web lane"
                            )
                        }

                        RoachStatusRow(title: "Alias Host", value: account.aliasHost, accent: RoachPalette.green)

                        if let bridgeURL = account.bridgeUrl, !bridgeURL.isEmpty {
                            RoachStatusRow(title: "Bridge URL", value: bridgeURL, accent: RoachPalette.green)
                        }

                        if let runtimeOrigin = account.runtimeOrigin, !runtimeOrigin.isEmpty {
                            RoachStatusRow(title: "Runtime Origin", value: runtimeOrigin, accent: RoachPalette.green)
                        }

                        if !account.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(account.notes.prefix(3), id: \.self) { note in
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

                        if let pairingPayload = roachTail.pairingPayload,
                           !pairingPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let qrCode = qrCodeImage(from: pairingPayload)
                        {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Phone Pairing")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)

                                HStack(alignment: .top, spacing: 16) {
                                    Image(nsImage: qrCode)
                                        .interpolation(.none)
                                        .resizable()
                                        .frame(width: 158, height: 158)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .fill(Color.white.opacity(0.96))
                                        )

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Scan this in RoachNetiOS to load the bridge URL and one-time join code.")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(RoachPalette.text)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if let expiresAt = roachTail.joinCodeExpiresAt, !expiresAt.isEmpty {
                                            Text("Code rotates at \(expiresAt).")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(RoachPalette.muted)
                                        }

                                        Text("The QR carries bridge and transport hints only. The phone still mints its own private peer token during pairing.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(RoachPalette.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let roachSync {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "RoachSync",
                                title: roachSync.enabled ? "Contained sync lane is armed." : "Contained sync lane is off.",
                                detail: "Keep the vault, settings, and future shared installs grouped under one private sync lane instead of loose host folders."
                            )
                        } actions: {
                            Toggle(
                                isOn: Binding(
                                    get: { model.snapshot?.roachSync.enabled ?? false },
                                    set: { nextValue in
                                        Task {
                                            await model.affectRoachSync(nextValue ? "enable" : "disable")
                                        }
                                    }
                                )
                            ) {
                                Text("Enabled")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                            }
                            .toggleStyle(.switch)
                            .disabled(model.roachSyncActionInFlight)
                            .labelsHidden()
                        }

                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                            RoachMetricCard(label: "Network", value: roachSync.networkName, detail: "Private sync lane")
                            RoachMetricCard(label: "Peers", value: "\(roachSync.peers.count)", detail: "Linked devices")
                            RoachMetricCard(label: "State", value: roachSync.status.capitalized, detail: "Current sync state")
                            RoachMetricCard(label: "Folder", value: roachSync.folderId, detail: "Contained sync target")
                        }

                        RoachStatusRow(
                            title: "Folder Path",
                            value: RuntimeSurfacePathLabel.displayValue(roachSync.folderPath, kind: .vaultFolder),
                            accent: RoachPalette.green
                        )

                        if let guiURL = roachSync.guiUrl, !guiURL.isEmpty {
                            RoachStatusRow(title: "Control URL", value: guiURL, accent: RoachPalette.green)
                        }

                        HStack(spacing: 12) {
                            Button(model.roachSyncActionInFlight ? "Refreshing..." : "Refresh Sync") {
                                Task { await model.affectRoachSync("refresh") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(model.roachSyncActionInFlight)

                            Button(model.roachSyncActionInFlight ? "Clearing..." : "Clear Peers") {
                                Task { await model.affectRoachSync("clear-peers") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(model.roachSyncActionInFlight || roachSync.peers.isEmpty)
                        }

                        if !roachSync.peers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("RoachSync Peers")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)

                                ForEach(roachSync.peers.prefix(4)) { peer in
                                    RoachStatusRow(
                                        title: peer.name,
                                        value: "\(peer.status.capitalized)\(peer.lastSeenAt.map { " · \($0)" } ?? "")",
                                        accent: RoachPalette.green
                                    )
                                }
                            }
                        }

                        if !roachSync.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(roachSync.notes.prefix(3), id: \.self) { note in
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

                    RoachStatusRow(
                        title: "Current Path",
                        value: RuntimeSurfacePathLabel.displayValue(model.storagePath, kind: .storageRoot),
                        accent: RoachPalette.green
                    )
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
        [GridItem(.adaptive(minimum: 212), spacing: 16, alignment: .top)]
    }

    private var vaultShelfColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .top)]
    }

    private var homeGridItems: [CommandGridItem] {
        [
            CommandGridItem(
                id: "maps",
                title: "Atlas Shelf",
                detail: "Open the vault atlas shelf and keep routes, packs, and offline regions close.",
                badge: "Vault",
                systemImage: "map.fill",
                routePath: "/maps",
                isInstalled: true
            ),
            CommandGridItem(
                id: "ai-control",
                title: "AI Control",
                detail: "See the model lane, the runtime, and what RoachClaw can actually see.",
                badge: "Runtime",
                systemImage: "cpu.fill",
                routePath: "/settings/ai",
                isInstalled: true
            ),
            CommandGridItem(
                id: "easy-setup",
                title: "Easy Setup",
                detail: "Fix the install, stage the runtime, and line up the first shelves.",
                badge: setupBadge,
                systemImage: "bolt.fill",
                routePath: "/easy-setup",
                isInstalled: true
            ),
            CommandGridItem(
                id: "offline-web",
                title: "Web Shelf",
                detail: "Keep captured sites readable from the vault instead of burying them in browser tabs.",
                badge: "Vault",
                systemImage: "globe.badge.chevron.backward",
                routePath: "/site-archives",
                isInstalled: true
            ),
            CommandGridItem(
                id: "install-apps",
                title: "Install Apps",
                detail: "Pull packs from the store and land them in the right shelf.",
                badge: "App Store",
                systemImage: "square.grid.2x2.fill",
                routePath: "/settings/apps",
                isInstalled: true
            ),
            CommandGridItem(
                id: "docs",
                title: "Study Shelf",
                detail: "Read guides, runtime notes, and offline references from the same vault shelf.",
                badge: "Vault",
                systemImage: "doc.text.fill",
                routePath: "/docs/home",
                isInstalled: true
            ),
            CommandGridItem(
                id: "settings",
                title: "Settings",
                detail: "Tune RoachNet, storage, providers, and the parts that keep it running.",
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
        let recommendedLocalModel = model.recommendedLocalModels.first ?? model.config.roachClawDefaultModel
        let cloudModel = model.chatModelOptions.first(where: { $0.localizedCaseInsensitiveContains(":cloud") })
        let storagePath = model.storagePath
        let installPath = model.installPath
        let projectsPath = RoachNetDeveloperPaths.projectsRoot(storagePath: storagePath)
        let importedVaults = model.importedObsidianVaults
        let selectedImportedVault = importedVaults.first(where: { $0.id == model.selectedImportedVaultID }) ?? importedVaults.first
        let importedVaultNotes = selectedImportedVault.map { VaultWorkspaceStore.noteURLs(in: $0, limit: 6) } ?? []
        let knowledgeFiles = Array((model.snapshot?.knowledgeFiles ?? []).prefix(8))
        let capturedSites = Array((model.snapshot?.siteArchives ?? []).prefix(4))
        let paneEntries = visiblePanes.map { pane in
            CommandPaletteEntry(
                id: "pane-\(pane.rawValue)",
                section: "Navigate",
                title: pane.rawValue,
                detail: pane.subtitle,
                systemImage: pane.icon,
                target: .pane(pane),
                badge: pane == activePane ? "Current" : nil,
                keywords: [pane.rawValue, pane.subtitle, "module", "pane"]
            )
        }

        let routeEntries = homeGridItems.map { item in
            CommandPaletteEntry(
                id: "route-\(item.id)",
                section: "Open",
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
                section: "Services",
                title: item.title,
                detail: item.detail,
                systemImage: item.systemImage,
                target: .service(serviceName: item.id),
                badge: item.isInstalled ? "Installed" : "Available",
                keywords: [item.title, item.detail, item.id, "service"]
            )
        }

        let importedVaultEntries = importedVaults.map { vault in
            CommandPaletteEntry(
                id: "vault-\(vault.id)",
                section: "Vault",
                title: "Open \(vault.name)",
                detail: "Open the imported vault in RoachNet's expanded shelf instead of bouncing out to Finder.",
                systemImage: "books.vertical.fill",
                target: .previewVaultFile(vault.path),
                badge: VaultWorkspaceStore.isObsidianCompatible(vault: vault) ? "Obsidian" : "Markdown",
                keywords: ["vault", "obsidian", "notes", vault.name, vault.path]
            )
        }

        let importedVaultNoteEntries = importedVaultNotes.map { noteURL in
            CommandPaletteEntry(
                id: "vault-note-\(noteURL.path)",
                section: "Vault",
                title: noteURL.deletingPathExtension().lastPathComponent,
                detail: "Open the note directly in the built-in notes lane and keep the same markdown live on disk.",
                systemImage: "note.text",
                target: .previewVaultFile(noteURL.path),
                badge: "Note",
                keywords: ["vault", "note", "markdown", noteURL.lastPathComponent, noteURL.path]
            )
        }

        let knowledgeFileEntries = knowledgeFiles.map { file in
            let fileURL = URL(fileURLWithPath: file)
            return CommandPaletteEntry(
                id: "vault-file-\(file)",
                section: "Vault",
                title: fileURL.lastPathComponent,
                detail: vaultFilePreviewHint(for: file),
                systemImage: vaultFileIcon(for: file),
                target: .previewVaultFile(file),
                badge: vaultFileKindLabel(for: file),
                keywords: ["vault", "file", fileURL.lastPathComponent, file]
            )
        }

        let capturedSiteEntries = capturedSites.map { archive in
            CommandPaletteEntry(
                id: "vault-captured-\(archive.slug)",
                section: "Vault",
                title: archive.title ?? archive.slug,
                detail: "Jump into the captured web shelf for \(archive.url ?? archive.slug) without leaving the launcher.",
                systemImage: "globe.badge.chevron.backward",
                target: .route(title: "Offline Web Apps", path: "/site-archives"),
                badge: "Captured",
                keywords: ["captured", "web", "archive", archive.slug, archive.url ?? ""]
            )
        }

        return paneEntries
            + routeEntries
            + serviceEntries
            + importedVaultEntries
            + importedVaultNoteEntries
            + knowledgeFileEntries
            + capturedSiteEntries
            + [
                CommandPaletteEntry(
                    id: "action-refresh-runtime",
                    section: "Runtime",
                    title: "Refresh Runtime",
                    detail: "Pull a fresh native snapshot and recheck the local services.",
                    systemImage: "arrow.clockwise",
                    target: .refreshRuntime,
                    shortcut: "⌘R",
                    keywords: ["health", "services", "reload", "snapshot"]
                ),
                CommandPaletteEntry(
                    id: "action-launch-guide",
                    section: "Open",
                    title: "Open Guided Tour",
                    detail: "Replay the first-launch walkthrough for the command deck.",
                    systemImage: "play.rectangle.fill",
                    target: .launchGuide,
                    keywords: ["guide", "tour", "help", "walkthrough"]
                ),
                CommandPaletteEntry(
                    id: "action-open-storage-root",
                    section: "Workspace",
                    title: "Open Storage Library",
                    detail: "Reveal the contained library root where vault files, installs, and local RoachNet state stay on disk.",
                    systemImage: "externaldrive.connected.to.line.below.fill",
                    target: .revealPath(storagePath),
                    badge: shortRuntimePath(storagePath),
                    keywords: ["storage", "library", "vault", "disk", "files", storagePath]
                ),
                CommandPaletteEntry(
                    id: "action-open-install-root",
                    section: "Workspace",
                    title: "Open Install Root",
                    detail: "Reveal the live RoachNet install root in Finder without leaving the launcher.",
                    systemImage: "folder.badge.gearshape",
                    target: .revealPath(installPath),
                    badge: shortRuntimePath(installPath),
                    keywords: ["install", "root", "app", "bundle", installPath]
                ),
                CommandPaletteEntry(
                    id: "action-open-projects-root",
                    section: "Workspace",
                    title: "Open Projects Root",
                    detail: "Jump straight into the contained developer workspace that Dev Studio is built around.",
                    systemImage: "folder.badge.person.crop",
                    target: .revealPath(projectsPath),
                    badge: shortRuntimePath(projectsPath),
                    keywords: ["projects", "workspace", "dev", "code", projectsPath]
                ),
                CommandPaletteEntry(
                    id: "action-import-obsidian-vault",
                    section: "Workspace",
                    title: "Import Obsidian Vault",
                    detail: "Bring an existing markdown vault into RoachNet without copying it into a second notes silo.",
                    systemImage: "square.stack.3d.up.badge.plus",
                    target: .importObsidianVault,
                    keywords: ["obsidian", "vault", "markdown", "notes", "import"]
                ),
                CommandPaletteEntry(
                    id: "action-open-model-store",
                    section: "RoachClaw",
                    title: "Open Model Store",
                    detail: "Jump straight into RoachClaw's local and cloud model shelf.",
                    systemImage: "shippingbox.fill",
                    target: .route(title: "Model Store", path: "/settings/models"),
                    badge: model.selectedChatModelLabel,
                    keywords: ["models", "ollama", "cloud", "store", "ai"]
                ),
                CommandPaletteEntry(
                    id: "action-open-roachclaw-anywhere",
                    section: "RoachClaw",
                    title: "Open RoachClaw Anywhere",
                    detail: "Float chat, voice, memory, and context controls over the current RoachNet surface.",
                    systemImage: "sparkles",
                    target: .openGlobalRoachClaw,
                    badge: "Global",
                    keywords: ["roachclaw", "assistant", "chat", "voice", "global", "anywhere"]
                ),
                CommandPaletteEntry(
                    id: "action-voice-prompt",
                    section: "RoachClaw",
                    title: model.isDictatingPrompt ? "Stop Voice Prompt" : "Start Voice Prompt",
                    detail: "Open the floating RoachClaw voice lane directly from the command bar.",
                    systemImage: model.isDictatingPrompt ? "waveform.circle.fill" : "mic.circle.fill",
                    target: .togglePromptDictation,
                    badge: model.isDictatingPrompt ? "Listening" : "Standby",
                    keywords: ["voice", "speech", "dictation", "prompt", "whisper", "global"]
                ),
                CommandPaletteEntry(
                    id: "action-latest-reply",
                    section: "RoachClaw",
                    title: model.isSpeakingLatestReply ? "Stop Reply Playback" : "Listen to Latest Reply",
                    detail: "Play back the most recent RoachClaw answer without leaving the current thread.",
                    systemImage: model.isSpeakingLatestReply ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    target: .toggleLatestReplySpeech,
                    badge: model.latestRoachClawReply == nil ? "No reply yet" : nil,
                    keywords: ["tts", "playback", "reply", "voice", "speech"]
                ),
                CommandPaletteEntry(
                    id: "action-copy-latest-reply",
                    section: "RoachClaw",
                    title: "Copy Latest Reply",
                    detail: "Put the most recent RoachClaw answer on the clipboard for handoff into any app.",
                    systemImage: "doc.on.doc.fill",
                    target: .copyLatestReply,
                    badge: model.latestRoachClawReply == nil ? "No reply yet" : "Ready",
                    keywords: ["copy", "reply", "clipboard", "pasteboard", "handoff"]
                ),
                CommandPaletteEntry(
                    id: "action-save-latest-reply",
                    section: "RoachClaw",
                    title: "Save Latest Reply to RoachBrain",
                    detail: "Pin the most recent assistant turn into local memory for reuse and retrieval.",
                    systemImage: "brain.head.profile",
                    target: .saveLatestReplyToRoachBrain,
                    keywords: ["save", "memory", "roachbrain", "pin", "recall"]
                ),
                CommandPaletteEntry(
                    id: "action-stage-next-useful-move",
                    section: "RoachClaw",
                    title: "Stage 'Next Useful Move'",
                    detail: "Load a first ask into the floating RoachClaw panel without leaving the current surface.",
                    systemImage: "arrowshape.turn.up.right.fill",
                    target: .stagePrompt("Give me the next useful move for this machine."),
                    keywords: ["prompt", "next", "useful", "move", "assistant"]
                ),
                CommandPaletteEntry(
                    id: "action-stage-runtime-summary",
                    section: "RoachClaw",
                    title: "Stage Runtime Summary Prompt",
                    detail: "Queue a concrete ask for the current RoachNet runtime inside the floating panel.",
                    systemImage: "waveform.path.ecg.rectangle.fill",
                    target: .stagePrompt("Summarize what RoachNet is running right now."),
                    keywords: ["prompt", "runtime", "summary", "services", "status"]
                ),
                CommandPaletteEntry(
                    id: "action-stage-clipboard",
                    section: "RoachClaw",
                    title: "Ask RoachClaw About Clipboard",
                    detail: "Turn the current clipboard into a focused RoachClaw prompt from the global command bar.",
                    systemImage: "doc.on.clipboard.fill",
                    target: .stagePromptFromClipboard("Read this clipboard content and give me the next useful action."),
                    badge: NSPasteboard.general.string(forType: .string)?.isEmpty == false ? "Clipboard" : "Empty",
                    keywords: ["clipboard", "pasteboard", "ask", "prompt", "raycast", "global"]
                ),
                CommandPaletteEntry(
                    id: "action-stage-dev-agent",
                    section: "Dev",
                    title: "Stage Dev Agent Prompt",
                    detail: "Load a task-runner ask that tells RoachClaw to inspect, act, verify, and record before claiming progress.",
                    systemImage: "terminal.fill",
                    target: .stagePrompt("Act as the RoachNet Dev agent for the current project: inspect the relevant files, propose the smallest safe patch, name the verification command, and do not claim anything ran unless it actually did."),
                    badge: "Agent",
                    keywords: ["dev", "agent", "ide", "cursor", "code", "verify"]
                ),
                CommandPaletteEntry(
                    id: "action-toggle-all-context",
                    section: "RoachClaw",
                    title: model.hasFullRoachClawContextAccess ? "Lock All Context" : "Allow Full Context",
                    detail: model.hasFullRoachClawContextAccess
                        ? "Close vault, captured web, project, and live RoachNet state back down."
                        : "Open the whole local workbench so RoachClaw can use the full vault, project, and app context.",
                    systemImage: model.hasFullRoachClawContextAccess ? "lock.fill" : "lock.open.fill",
                    target: .setAllContext(!model.hasFullRoachClawContextAccess),
                    badge: model.hasFullRoachClawContextAccess ? "Full access" : "Partial",
                    keywords: ["full", "context", "vault", "projects", "roachnet", "permissions"]
                ),
                CommandPaletteEntry(
                    id: "action-toggle-vault-context",
                    section: "RoachClaw",
                    title: model.isRoachClawContextEnabled(.vault) ? "Lock Vault Context" : "Allow Vault Context",
                    detail: "Let RoachClaw read the vault lane only when this thread needs file and note context.",
                    systemImage: "books.vertical.fill",
                    target: .toggleContextScope(.vault),
                    badge: model.isRoachClawContextEnabled(.vault) ? "Allowed" : "Locked",
                    keywords: ["vault", "notes", "files", "obsidian", "context"]
                ),
                CommandPaletteEntry(
                    id: "action-toggle-archive-context",
                    section: "RoachClaw",
                    title: model.isRoachClawContextEnabled(.archives) ? "Lock Captured Web Context" : "Allow Captured Web Context",
                    detail: "Let RoachClaw see the mirrored site shelf when the chat needs archived web context.",
                    systemImage: "globe.badge.chevron.backward",
                    target: .toggleContextScope(.archives),
                    badge: model.isRoachClawContextEnabled(.archives) ? "Allowed" : "Locked",
                    keywords: ["archive", "captured", "web", "offline", "context"]
                ),
                CommandPaletteEntry(
                    id: "action-toggle-project-context",
                    section: "RoachClaw",
                    title: model.isRoachClawContextEnabled(.projects) ? "Lock Project Context" : "Allow Project Context",
                    detail: "Let RoachClaw read the local project shelf so coding help starts from the real workspace.",
                    systemImage: "terminal.fill",
                    target: .toggleContextScope(.projects),
                    badge: model.isRoachClawContextEnabled(.projects) ? "Allowed" : "Locked",
                    keywords: ["project", "workspace", "dev", "code", "context"]
                ),
                CommandPaletteEntry(
                    id: "action-toggle-roachnet-context",
                    section: "RoachClaw",
                    title: model.isRoachClawContextEnabled(.roachnet) ? "Lock RoachNet Context" : "Allow RoachNet Context",
                    detail: "Let RoachClaw read the active pane, installed packs, model route, and live shell state when the thread actually needs it.",
                    systemImage: "square.stack.3d.up.fill",
                    target: .toggleContextScope(.roachnet),
                    badge: model.isRoachClawContextEnabled(.roachnet) ? "Allowed" : "Locked",
                    keywords: ["roachnet", "app", "runtime", "active pane", "context"]
                ),
                CommandPaletteEntry(
                    id: "action-promote-local-model",
                    section: "RoachClaw",
                    title: "Use Recommended Local Model",
                    detail: "Promote the contained model lane back to the front of the workbench.",
                    systemImage: "sparkles",
                    target: .promoteLocalModel(recommendedLocalModel),
                    badge: recommendedLocalModel,
                    keywords: ["local", "model", "ollama", "contained", recommendedLocalModel]
                ),
                CommandPaletteEntry(
                    id: "action-promote-cloud-model",
                    section: "RoachClaw",
                    title: cloudModel == nil ? "No Cloud Fallback Armed" : "Promote Cloud Fallback",
                    detail: cloudModel == nil
                        ? "Arm a hosted provider in AI Control before using the wider lane."
                        : "Promote the hosted lane when the local model is not the right first answer.",
                    systemImage: "cloud.fill",
                    target: .promoteCloudModel(cloudModel ?? "cloud-unavailable"),
                    badge: cloudModel.map(model.chatModelLabel(for:)) ?? "Unavailable",
                    keywords: ["cloud", "fallback", "hosted", "provider", "ai"]
                ),
                CommandPaletteEntry(
                    id: "action-open-apps-store",
                    section: "External",
                    title: "Open Apps Store",
                    detail: "Open apps.roachnet.org for direct install handoffs into the native app.",
                    systemImage: "square.grid.2x2",
                    target: .externalURL("https://apps.roachnet.org"),
                    keywords: ["apps", "catalog", "store", "install", "downloads"]
                ),
                CommandPaletteEntry(
                    id: "action-open-runtime-health",
                    section: "Runtime",
                    title: "Open Runtime Health",
                    detail: "Jump to the runtime settings and service-health lane.",
                    systemImage: "stethoscope",
                    target: .route(title: "Runtime Health", path: "/settings/system"),
                    keywords: ["runtime", "health", "services", "diagnostics"]
                ),
            ]
    }

    private var recentCommandPaletteEntries: [CommandPaletteEntry] {
        recentCommandPaletteIDs.compactMap { recentID in
            commandPaletteEntries.first(where: { $0.id == recentID })
        }
    }

    private var contextCommandPaletteEntries: [CommandPaletteEntry] {
        switch activePane {
        case .roachClaw:
            return commandPaletteEntries.filter {
                $0.section == "RoachClaw" || $0.id == "pane-RoachClaw" || $0.id == "action-open-model-store" || $0.id == "action-open-roachclaw-anywhere"
            }
        case .runtime:
            return commandPaletteEntries.filter { $0.section == "Runtime" || $0.id == "pane-Runtime" }
        case .knowledge:
            return commandPaletteEntries.filter {
                $0.id == "pane-Vault"
                    || $0.id == "action-open-storage-root"
                    || $0.id == "action-import-obsidian-vault"
                    || $0.section == "Vault"
            }
        case .dev:
            return commandPaletteEntries.filter {
                $0.id == "pane-Dev"
                    || $0.id == "action-open-model-store"
                    || $0.id == "action-refresh-runtime"
                    || $0.id == "action-open-projects-root"
                    || $0.id == "action-open-storage-root"
                    || $0.section == "Vault"
            }
        default:
            return commandPaletteEntries.filter { $0.section == "Open" || $0.section == "Navigate" }.prefix(4).map { $0 }
        }
    }

    private var featuredCommandPaletteEntries: [CommandPaletteEntry] {
        var ordered: [CommandPaletteEntry] = []
        let candidateGroups = [
            contextCommandPaletteEntries,
            recentCommandPaletteEntries,
            commandPaletteEntries.filter {
                $0.id == "action-refresh-runtime"
                    || $0.id == "action-open-roachclaw-anywhere"
                    || $0.id == "action-voice-prompt"
                    || $0.id == "action-open-model-store"
                    || $0.id == "action-open-apps-store"
                    || $0.id == "action-open-storage-root"
                    || $0.id == "action-stage-next-useful-move"
                    || $0.id == "action-stage-clipboard"
                    || $0.id == "action-stage-dev-agent"
                    || $0.section == "Vault"
            }
        ]

        for group in candidateGroups {
            for entry in group where !ordered.contains(where: { $0.id == entry.id }) {
                ordered.append(entry)
            }
        }

        return Array(ordered.prefix(8))
    }

    private func performCommand(_ entry: CommandPaletteEntry, fromDetachedPalette: Bool = false) {
        showCommandPalette = false
        recordRecentCommand(entry)

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
        case let .revealPath(path):
            model.revealPathInFinder(path)
        case let .previewVaultFile(file):
            model.previewVaultFile(file)
        case .importObsidianVault:
            model.selectedPane = .knowledge
            model.importObsidianVault()
        case .openGlobalRoachClaw:
            openGlobalRoachClaw()
        case let .stagePrompt(prompt):
            model.promptDraft = prompt
            openGlobalRoachClaw()
        case let .stagePromptFromClipboard(prefix):
            let clipboard = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            model.promptDraft = clipboard.isEmpty
                ? prefix
                : """
                \(prefix)

                Clipboard:
                \(String(clipboard.prefix(6000)))
                """
            openGlobalRoachClaw()
        case .togglePromptDictation:
            openGlobalRoachClaw()
            Task { await model.togglePromptDictation() }
        case .toggleLatestReplySpeech:
            model.toggleLatestReplySpeech()
        case .copyLatestReply:
            if let reply = model.latestRoachClawReply, !reply.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(reply, forType: .string)
                model.statusLine = "Copied the latest RoachClaw reply."
            } else {
                model.statusLine = "No RoachClaw reply is ready to copy yet."
            }
        case .saveLatestReplyToRoachBrain:
            model.saveLatestRoachClawResponseToRoachBrain()
        case let .toggleContextScope(scope):
            model.setRoachClawContext(scope, enabled: !model.isRoachClawContextEnabled(scope))
        case let .setAllContext(enabled):
            model.setAllRoachClawContext(enabled: enabled)
        case let .promoteLocalModel(modelName):
            model.config.roachClawDefaultModel = modelName
            model.selectedChatModel = modelName
            Task { await model.applyRoachClawDefaults() }
        case let .promoteCloudModel(modelName):
            guard modelName != "cloud-unavailable" else {
                Task { await model.openRoute("/settings/ai", title: "AI Control") }
                return
            }
            model.selectedChatModel = modelName
        case let .externalURL(urlString):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func recordRecentCommand(_ entry: CommandPaletteEntry) {
        var ids = recentCommandPaletteIDs.filter { $0 != entry.id }
        ids.insert(entry.id, at: 0)
        recentCommandPaletteIDsRaw = ids.prefix(10).joined(separator: "|")
    }

    private func presentDetachedCommandPalette() {
        showCommandPalette = false
        detachedPaletteCoordinator.present(entries: commandPaletteEntries, featuredEntries: featuredCommandPaletteEntries) { entry in
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
        WorkspacePane.allCases.filter { $0 != .suite && $0 != .maps && $0 != .education }
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
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: trimmed)
            let lastComponent = url.lastPathComponent

            if trimmed.localizedCaseInsensitiveContains("RoachNet") {
                return "RoachNet workspace"
            }

            if !lastComponent.isEmpty {
                return lastComponent
            }
        }

        return "RoachNet workspace"
    }

    private func runtimeTargetLabel(_ target: String?) -> String {
        if let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return target.capitalized
        }

        return model.snapshot == nil ? "Warming up" : "Native shell"
    }

    private func hostLabel(_ hostname: String?) -> String {
        if let hostname, !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if hostname.localizedCaseInsensitiveContains("roachnet") {
                return "RoachNet"
            }

            return "RoachNet host"
        }

        return model.snapshot == nil ? "Warming up" : "RoachNet host"
    }

    private func shortRuntimePath(_ path: String) -> String {
        RuntimeSurfacePathLabel.displayValue(path, kind: .storageRoot)
    }

    private func runtimeSignalDeck(
        system: SystemInfoResponse?,
        serverInfo: ManagedAppServerInfo?,
        roachTail: ManagedRoachTailStatusResponse?,
        roachSync: ManagedRoachSyncStatusResponse?
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Signal Board",
                    title: "Runtime, read fast.",
                    detail: "The parts that matter before you disappear into logs."
                )

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    RoachMetricCard(
                        label: "Route",
                        value: runtimeTargetLabel(serverInfo?.target),
                        detail: "Active local gateway"
                    )
                    RoachMetricCard(
                        label: "Host",
                        value: hostLabel(system?.os.hostname),
                        detail: runtimeCPUDetail(system)
                    )
                    RoachMetricCard(
                        label: "RoachTail",
                        value: roachTail?.enabled == true ? "\(roachTail?.peers.count ?? 0) peers" : "Off",
                        detail: roachTail?.enabled == true ? "Private bridge is armed." : "Private overlay disabled."
                    )
                    RoachMetricCard(
                        label: "RoachSync",
                        value: roachSync?.enabled == true ? "\(roachSync?.peers.count ?? 0) peers" : "Off",
                        detail: roachSync?.enabled == true ? "Sync lane is live." : "Contained sync is disabled."
                    )
                }
            }
        }
    }

    private func runtimeOverviewPanel(
        system: SystemInfoResponse?,
        serverInfo: ManagedAppServerInfo?,
        roachTail: ManagedRoachTailStatusResponse?,
        roachSync: ManagedRoachSyncStatusResponse?
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Runtime map",
                    title: "One contained path. No scavenger hunt.",
                    detail: "The root, the route, and the private lanes that matter when something feels off."
                )

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Install root",
                        value: RuntimeSurfacePathLabel.displayValue(model.installPath, kind: .installRoot),
                        detail: "The contained app root. No smear across the host when this lane is behaving.",
                        systemName: "shippingbox.fill",
                        accent: RoachPalette.green
                    )
                    RoachDigestRow(
                        "Storage root",
                        value: shortRuntimePath(model.storagePath),
                        detail: "Maps, vault content, archives, logs, and runtime cache stay grouped here.",
                        systemName: "externaldrive.fill",
                        accent: RoachPalette.cyan
                    )
                    RoachDigestRow(
                        "Server target",
                        value: runtimeTargetLabel(serverInfo?.target),
                        detail: "The active local route in front of the services.",
                        systemName: "network",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Private lanes",
                        value: "\(roachTail?.enabled == true ? "Tail" : "Tail off") · \(roachSync?.enabled == true ? "Sync" : "Sync off")",
                        detail: "RoachTail handles the private bridge. RoachSync keeps the shelf aligned.",
                        systemName: "point.3.connected.trianglepath.dotted",
                        accent: RoachPalette.bronze
                    )
                }
            }
        }
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

    private func qrCodeImage(from payload: String) -> NSImage? {
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(normalized.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: outputImage.extent.width, height: outputImage.extent.height)
        )
    }

    private func logPathValue(_ serverInfo: ManagedAppServerInfo?) -> String {
        if let logPath = serverInfo?.logPath?.trimmingCharacters(in: .whitespacesAndNewlines), !logPath.isEmpty {
            return RuntimeSurfacePathLabel.displayValue(logPath, kind: .logFile)
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
        roachWindowDebug("Application did finish launching.")
        clearSavedState()
        NSApp.setActivationPolicy(.regular)
        registerCommandPaletteHotKey()
        bringPrimaryWindowForward()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterCommandPaletteHotKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringPrimaryWindowForward()
        return true
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
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

    private func bringPrimaryWindowForward() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                roachWindowDebug("App delegate brought an existing window forward.")
            } else {
                roachWindowDebug("App delegate found no window to bring forward yet.")
            }
        }
    }

    private func clearSavedState() {
        let savedStatePath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("com.roachwares.roachnet.savedState", isDirectory: true)
            .path

        try? FileManager.default.removeItem(atPath: savedStatePath)
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
