import SwiftUI
import AppKit
import AVKit
import Carbon
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import WebKit
import RoachNetCore
import RoachNetDesign

enum WorkspacePane: String, CaseIterable, Identifiable {
    case suite = "Suite"
    case home = "Home"
    case dev = "Dev"
    case roachClaw = "RoachClaw"
    case arcade = "RoachArcade"
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
        case .arcade: return "gamecontroller.fill"
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
        case .home: return "Command deck"
        case .dev: return "IDE workspace"
        case .roachClaw: return "AI workbench"
        case .arcade: return "Game library"
        case .maps: return "Native atlas"
        case .education: return "Course packs"
        case .knowledge: return "Vault shelf"
        case .runtime: return "Console"
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
                return "RoachNet storage"
            case .vaultFolder:
                return "Contained vault"
            case .logFile:
                return "Runtime log"
            }
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        let lastPathComponent = url.lastPathComponent
        let parentPathComponent = url.deletingLastPathComponent().lastPathComponent

        switch kind {
        case .installRoot:
            return "Contained app"
        case .storageRoot:
            return storageRootLabel(lastPathComponent: lastPathComponent, parentPathComponent: parentPathComponent)
        case .vaultFolder:
            return "Contained vault"
        case .logFile:
            return lastPathComponent.isEmpty ? "Runtime log" : lastPathComponent
        }
    }

    static func displayDetail(_ path: String?, kind: RuntimeSurfacePathKind) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            switch kind {
            case .installRoot:
                return "Install root not set"
            case .storageRoot:
                return "Content root not set"
            case .vaultFolder:
                return "Vault folder not set"
            case .logFile:
                return "Runtime log not set"
            }
        }

        let home = NSHomeDirectory()
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~/" + trimmed.dropFirst(home.count + 1)
        }
        return trimmed
    }

    private static func storageRootLabel(lastPathComponent: String, parentPathComponent: String) -> String {
        guard !lastPathComponent.isEmpty else { return "RoachNet storage" }

        let normalizedLeaf = lastPathComponent.lowercased()
        let normalizedParent = parentPathComponent.lowercased()
        if normalizedLeaf == "storage" {
            if normalizedParent.contains("roachnet") {
                return "RoachNet storage"
            }
            if !parentPathComponent.isEmpty {
                return "\(parentPathComponent)/storage"
            }
            return "storage"
        }

        return lastPathComponent
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
    let pane: WorkspacePane?

    init(
        id: String,
        title: String,
        detail: String,
        badge: String?,
        systemImage: String,
        routePath: String,
        isInstalled: Bool,
        pane: WorkspacePane? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.badge = badge
        self.systemImage = systemImage
        self.routePath = routePath
        self.isInstalled = isInstalled
        self.pane = pane
    }
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
    let section: String
    let primaryAction: String
    let quickHint: String
    let commandHint: String
    let accent: Color
    let tags: [String]
}

private struct LaunchGuideStep: Identifiable {
    let id: String
    let number: String
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color
}

private struct LaunchGuideQuickAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color
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

private enum HomeNextMoveTarget: Hashable {
    case pane(WorkspacePane)
    case route(title: String, path: String)
    case prompt(String)
    case commandBar
    case refreshRuntime
    case importVault
}

private struct HomeNextMove: Identifiable {
    let id: String
    let title: String
    let detail: String
    let badge: String
    let systemImage: String
    let accent: Color
    let target: HomeNextMoveTarget
}

enum RoachClawContextScope: String, CaseIterable, Identifiable, Hashable {
    case vault
    case arcade
    case archives
    case projects
    case roachnet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vault:
            return "Vault"
        case .arcade:
            return "RoachArcade"
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
            return "Vault files and notes."
        case .arcade:
            return "Active game context."
        case .archives:
            return "Captured web shelf."
        case .projects:
            return "Project shelf."
        case .roachnet:
            return "Live app state."
        }
    }

    var systemImage: String {
        switch self {
        case .vault:
            return "books.vertical.fill"
        case .arcade:
            return "gamecontroller.fill"
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
        case .arcade:
            return RoachPalette.magenta
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
    var arcade = true
    var archives = true
    var projects = true
    var roachnet = true

    private enum CodingKeys: String, CodingKey {
        case vault
        case arcade
        case archives
        case projects
        case roachnet
    }

    init(vault: Bool = true, arcade: Bool = true, archives: Bool = true, projects: Bool = true, roachnet: Bool = true) {
        self.vault = vault
        self.arcade = arcade
        self.archives = archives
        self.projects = projects
        self.roachnet = roachnet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vault = try container.decodeIfPresent(Bool.self, forKey: .vault) ?? true
        arcade = try container.decodeIfPresent(Bool.self, forKey: .arcade) ?? true
        archives = try container.decodeIfPresent(Bool.self, forKey: .archives) ?? true
        projects = try container.decodeIfPresent(Bool.self, forKey: .projects) ?? true
        roachnet = try container.decodeIfPresent(Bool.self, forKey: .roachnet) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vault, forKey: .vault)
        try container.encode(arcade, forKey: .arcade)
        try container.encode(archives, forKey: .archives)
        try container.encode(projects, forKey: .projects)
        try container.encode(roachnet, forKey: .roachnet)
    }

    func isEnabled(_ scope: RoachClawContextScope) -> Bool {
        switch scope {
        case .vault:
            return vault
        case .arcade:
            return arcade
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
        case .arcade:
            arcade = enabled
        case .archives:
            archives = enabled
        case .projects:
            projects = enabled
        case .roachnet:
            roachnet = enabled
        }
    }
}

enum CommandPaletteTarget: Hashable {
    case pane(WorkspacePane)
    case route(title: String, path: String)
    case service(serviceName: String)
    case refreshRuntime
    case launchGuide
    case revealPath(String)
    case previewVaultFile(String)
    case importObsidianVault
    case openNativeSettings
    case openAbout
    case checkForUpdates
    case requestSystemUpdate
    case copyDiagnostics
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
    case commandDeck = "Deck"
    case installedModules = "Installed"
    case availableModules = "Staged"

    var id: String { rawValue }
}

struct CommandPaletteEntry: Identifiable, Hashable {
    let id: String
    let section: String
    let title: String
    let detail: String
    let systemImage: String
    let target: CommandPaletteTarget
    let badge: String?
    let shortcut: String?
    let keywords: [String]
    let aliases: [String]
    let previewNote: String?

    init(
        id: String,
        section: String,
        title: String,
        detail: String,
        systemImage: String,
        target: CommandPaletteTarget,
        badge: String? = nil,
        shortcut: String? = nil,
        keywords: [String] = [],
        aliases: [String] = [],
        previewNote: String? = nil
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
        self.aliases = aliases
        self.previewNote = previewNote
    }
}

private extension Notification.Name {
    static let roachNetOpenCommandPalette = Notification.Name("roachnet.open-command-palette")
    static let roachNetOpenDetachedCommandPalette = Notification.Name("roachnet.open-detached-command-palette")
    static let roachNetOpenGlobalRoachClaw = Notification.Name("roachnet.open-global-roachclaw")
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

enum RoachNetGlobalHotKey {
    static let commandPaletteID: UInt32 = 1
    static let keyCode: UInt32 = UInt32(kVK_ANSI_R)
    static let modifiers: UInt32 = UInt32(cmdKey) | UInt32(controlKey)
    static let hint = "Ctrl-Cmd-R"
}

private func roachNetFourCharCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { partial, byte in
        (partial << 8) + OSType(byte)
    }
}

func filteredCommandPaletteEntries(
    from entries: [CommandPaletteEntry],
    query: String
) -> [CommandPaletteEntry] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
        return entries
    }

    let queryTokens = commandPaletteTokens(from: trimmedQuery)

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

func commandPaletteScore(for entry: CommandPaletteEntry, queryTokens: [String]) -> Int {
    let title = entry.title.lowercased()
    let detail = entry.detail.lowercased()
    let section = entry.section.lowercased()
    let badge = entry.badge?.lowercased() ?? ""
    let shortcut = entry.shortcut?.lowercased() ?? ""
    let aliases = entry.aliases.map { $0.lowercased() }
    let keywords = entry.keywords.map { $0.lowercased() }
    let searchFields = [title, detail, section, badge, shortcut] + aliases + keywords
    let titleAcronym = commandPaletteAcronym(title)
    let sectionAcronym = commandPaletteAcronym(section)

    var score = 0
    for token in queryTokens {
        let shouldUseLooseFuzzy = token.count >= 3
        if title == token {
            score += 520
        } else if title.hasPrefix(token) {
            score += 360
        } else if title.contains(token) {
            score += 230
        } else if titleAcronym.hasPrefix(token) {
            score += 210
        } else if shouldUseLooseFuzzy, commandPaletteCharacters(in: token, appearInOrderInside: title) {
            score += 120
        }

        if aliases.contains(where: { $0 == token }) {
            score += 340
        } else if aliases.contains(where: { $0.hasPrefix(token) }) {
            score += 240
        } else if aliases.contains(where: { $0.contains(token) }) {
            score += 150
        }

        if keywords.contains(where: { $0 == token }) {
            score += 180
        } else if keywords.contains(where: { $0.hasPrefix(token) }) {
            score += 135
        } else if keywords.contains(where: { $0.contains(token) }) {
            score += 95
        }

        if section == token {
            score += 120
        } else if section.hasPrefix(token) || sectionAcronym.hasPrefix(token) {
            score += 80
        }

        if detail.hasPrefix(token) {
            score += 58
        } else if detail.contains(token) {
            score += 46
        }

        if badge == token || shortcut == token {
            score += 90
        }

        if shouldUseLooseFuzzy,
           searchFields.contains(where: { commandPaletteCharacters(in: token, appearInOrderInside: $0) }) {
            score += 24
        }
    }

    return score
}

func commandPaletteTokens(from query: String) -> [String] {
    query
        .lowercased()
        .split { character in
            character.isWhitespace || character == "/" || character == "-" || character == "_" || character == "."
        }
        .map(String.init)
        .filter { !$0.isEmpty }
}

func commandPaletteVisibleEntries(
    entries: [CommandPaletteEntry],
    recentEntries: [CommandPaletteEntry],
    query: String
) -> [CommandPaletteEntry] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = filteredCommandPaletteEntries(from: entries, query: query)
    guard trimmedQuery.isEmpty, !recentEntries.isEmpty else {
        return filtered
    }

    let validRecentEntries = recentEntries.filter { recent in
        entries.contains(where: { $0.id == recent.id })
    }
    let recentIDs = Set(validRecentEntries.map(\.id))
    return validRecentEntries + filtered.filter { !recentIDs.contains($0.id) }
}

private func commandPaletteAcronym(_ value: String) -> String {
    value
        .split { !$0.isLetter && !$0.isNumber }
        .compactMap(\.first)
        .map { String($0).lowercased() }
        .joined()
}

private func commandPaletteCharacters(in needle: String, appearInOrderInside haystack: String) -> Bool {
    guard !needle.isEmpty else { return true }
    var remaining = Array(needle)
    for character in haystack {
        guard let next = remaining.first, next == character else { continue }
        remaining.removeFirst()
        if remaining.isEmpty {
            return true
        }
    }
    return false
}

private func commandPaletteNumberIndex(for keyCode: UInt16) -> Int? {
    switch Int(keyCode) {
    case kVK_ANSI_1: return 0
    case kVK_ANSI_2: return 1
    case kVK_ANSI_3: return 2
    case kVK_ANSI_4: return 3
    case kVK_ANSI_5: return 4
    case kVK_ANSI_6: return 5
    case kVK_ANSI_7: return 6
    case kVK_ANSI_8: return 7
    case kVK_ANSI_9: return 8
    default: return nil
    }
}

private func groupedCommandPaletteEntries(
    _ entries: [CommandPaletteEntry],
    recentIDs: Set<String> = []
) -> [(String, [CommandPaletteEntry])] {
    var orderedSections: [String] = []
    var grouped: [String: [CommandPaletteEntry]] = [:]

    for entry in entries {
        let section = recentIDs.contains(entry.id) ? "Recent" : entry.section
        if grouped[section] == nil {
            orderedSections.append(section)
        }
        grouped[section, default: []].append(entry)
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
        case .pane, .route, .service, .refreshRuntime, .launchGuide, .revealPath, .previewVaultFile, .importObsidianVault, .openNativeSettings, .openAbout, .checkForUpdates, .requestSystemUpdate, .copyDiagnostics, .openGlobalRoachClaw, .stagePrompt, .stagePromptFromClipboard, .togglePromptDictation, .toggleLatestReplySpeech, .copyLatestReply, .saveLatestReplyToRoachBrain, .toggleContextScope, .setAllContext, .promoteLocalModel, .promoteCloudModel:
            return true
        }
    }

    var actionLabel: String {
        switch self {
        case .pane, .route, .openNativeSettings, .openAbout:
            return "Open"
        case .service:
            return "Launch"
        case .refreshRuntime, .checkForUpdates:
            return "Check"
        case .requestSystemUpdate:
            return "Install"
        case .launchGuide, .openGlobalRoachClaw:
            return "Show"
        case .revealPath:
            return "Reveal"
        case .previewVaultFile:
            return "Preview"
        case .importObsidianVault:
            return "Import"
        case .stagePrompt, .stagePromptFromClipboard:
            return "Stage"
        case .togglePromptDictation, .toggleLatestReplySpeech, .toggleContextScope, .setAllContext:
            return "Toggle"
        case .copyLatestReply, .copyDiagnostics:
            return "Copy"
        case .saveLatestReplyToRoachBrain:
            return "Save"
        case .promoteLocalModel, .promoteCloudModel:
            return "Use"
        case .externalURL:
            return "Visit"
        }
    }
}

private extension CommandPaletteEntry {
    var accent: Color {
        switch section {
        case "Navigate":
            return RoachPalette.green
        case "Open":
            return RoachPalette.cyan
        case "RoachClaw":
            return RoachPalette.magenta
        case "Runtime":
            return RoachPalette.bronze
        case "Vault":
            return RoachPalette.cyan
        case "Dev":
            return RoachPalette.green
        case "Workspace":
            return RoachPalette.bronze
        case "Services":
            return RoachPalette.green
        case "External":
            return RoachPalette.magenta
        default:
            return RoachPalette.green
        }
    }

    var actionLabel: String {
        target.actionLabel
    }

    var copyTargetPayload: String {
        switch target {
        case let .pane(pane):
            return pane.rawValue
        case let .route(title, path):
            return "\(title) \(path)"
        case let .service(serviceName):
            return serviceName
        case .refreshRuntime:
            return "Refresh Runtime"
        case .launchGuide:
            return "Open Guided Tour"
        case let .revealPath(path), let .previewVaultFile(path):
            return path
        case .importObsidianVault:
            return "Import Obsidian Vault"
        case .openNativeSettings:
            return "Open RoachNet Settings"
        case .openAbout:
            return "About RoachNet"
        case .checkForUpdates:
            return "Check for RoachNet updates"
        case .requestSystemUpdate:
            return "Install available RoachNet update"
        case .copyDiagnostics:
            return "Copy RoachNet diagnostics"
        case .openGlobalRoachClaw:
            return "Open RoachClaw Anywhere"
        case let .stagePrompt(prompt), let .stagePromptFromClipboard(prompt):
            return prompt
        case .togglePromptDictation:
            return "Toggle voice prompt"
        case .toggleLatestReplySpeech:
            return "Toggle latest reply playback"
        case .copyLatestReply:
            return "Copy latest RoachClaw reply"
        case .saveLatestReplyToRoachBrain:
            return "Save latest RoachClaw reply to RoachBrain"
        case let .toggleContextScope(scope):
            return "Toggle \(scope.title) context"
        case let .setAllContext(enabled):
            return enabled ? "Allow full RoachClaw context" : "Lock full RoachClaw context"
        case let .promoteLocalModel(modelName), let .promoteCloudModel(modelName):
            return modelName
        case let .externalURL(urlString):
            return urlString
        }
    }

    var secondaryActionLabel: String {
        switch target {
        case .revealPath, .previewVaultFile:
            return "Copy path"
        case .externalURL:
            return "Copy URL"
        case .route:
            return "Copy route"
        case .stagePrompt, .stagePromptFromClipboard:
            return "Copy prompt"
        default:
            return "Copy target"
        }
    }

    var compactSectionLabel: String {
        section.uppercased()
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
    let index: Int?

    init(entry: CommandPaletteEntry, isSelected: Bool, index: Int? = nil) {
        self.entry = entry
        self.isSelected = isSelected
        self.index = index
    }

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isSelected ? entry.accent : Color.clear)
                .frame(width: 3, height: 34)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? entry.accent.opacity(0.18) : Color.white.opacity(0.055))

                Image(systemName: entry.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.text : entry.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                    if let badge = entry.badge {
                        RoachTag(badge, accent: isSelected ? entry.accent : RoachPalette.cyan)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                Text(entry.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let index, index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? RoachPalette.text : RoachPalette.muted)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(RoachPalette.panelGlass.opacity(isSelected ? 1 : 0.72))
                        )
                        .accessibilityHidden(true)
                }

                Text(isSelected ? "Return" : (entry.shortcut ?? entry.actionLabel))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? RoachPalette.text : RoachPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill((isSelected ? entry.accent.opacity(0.18) : RoachPalette.panelGlass).opacity(0.92))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.075) : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? entry.accent.opacity(0.46) : Color.white.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: isSelected ? entry.accent.opacity(0.11) : .clear, radius: 16, y: 9)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isSelected)
    }
}

private struct CommandPalettePreview: View {
    let entry: CommandPaletteEntry?
    let showActionPanel: Bool
    let onSelect: (CommandPaletteEntry) -> Void
    let onCopyTarget: (CommandPaletteEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let entry {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(entry.accent)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(entry.accent.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.compactSectionLabel)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(entry.accent)
                        Text(entry.title)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        Text(entry.detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        onSelect(entry)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .bold))
                            Text(entry.actionLabel)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                    }
                    .buttonStyle(RoachUtilityButtonStyle(tint: entry.accent))
                    .help("Run selected command")

                    Button {
                        onCopyTarget(entry)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .bold))
                            Text(entry.secondaryActionLabel)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.muted))
                    .help("Copy the selected command target")
                }

                if let previewNote = entry.previewNote {
                    Text(previewNote)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.text.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(entry.accent.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(entry.accent.opacity(0.14), lineWidth: 1)
                        )
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                if let badge = entry.badge {
                    HStack(spacing: 8) {
                        RoachTag("State", accent: entry.accent)
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }
                }

                if showActionPanel {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Actions")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(entry.accent)

                        VStack(alignment: .leading, spacing: 8) {
                            CommandPaletteActionLine(key: "Return", label: "\(entry.actionLabel) now")
                            CommandPaletteActionLine(key: "⌥↵", label: entry.secondaryActionLabel)
                            CommandPaletteActionLine(key: "⌘1-9", label: "Open by index")
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.58))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(RoachPalette.border.opacity(0.75), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Command Bar")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                    Text("Type a lane, file, model, or task. Return runs it; Option-Return copies where it points.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 1)
        )
    }
}

private struct CommandPaletteActionLine: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 9) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .frame(width: 48, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RoachPalette.panelGlass)
                )

            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct CommandPaletteFeaturedRail: View {
    let entries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Suggested moves")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)

                Spacer(minLength: 8)

                Text("\(entries.count) ready")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.green)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.systemImage)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(entry.accent)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(entry.accent.opacity(0.12))
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.compactSectionLabel)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundStyle(RoachPalette.muted)
                                    Text(entry.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .frame(width: 218, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                entry.accent.opacity(0.10),
                                                RoachPalette.panelRaised.opacity(0.76),
                                                Color.black.opacity(0.16),
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(entry.accent.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(RoachCardButtonStyle())
                    }
                }
            }
        }
    }
}

private struct CommandPaletteKeyHintStrip: View {
    let selectedAction: String
    let actionPanelVisible: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                hint("Return", selectedAction)
                hint("⌘K", actionPanelVisible ? "Hide panel" : "Actions")
                hint("⌥↵", "Copy")
            }

            HStack(spacing: 7) {
                hint("Return", selectedAction)
                hint("⌘K", "Actions")
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(RoachPalette.panelGlass)
                )
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct CommandPaletteSectionHeader: View {
    let title: String
    let count: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(accent)

            Rectangle()
                .fill(accent.opacity(0.18))
                .frame(height: 1)

            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
        }
    }
}

private struct CommandPaletteEmptyState: View {
    let hasQuery: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: hasQuery ? "magnifyingglass" : "command.circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(RoachPalette.green)

            Text(hasQuery ? "Nothing crawled out." : "Command index is empty.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RoachPalette.text)

            Text(hasQuery ? "Try vault, dev, update, logs, model, or anything with a real file behind it." : "Refresh the runtime and try again.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
    }
}

private struct CommandPaletteSheet: View {
    let entries: [CommandPaletteEntry]
    let featuredEntries: [CommandPaletteEntry]
    let recentEntries: [CommandPaletteEntry]
    let leadingReservedWidth: CGFloat
    let onSelect: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedEntryID: String?
    @State private var appeared = false
    @State private var showActionPanel = false
    @State private var keyMonitor: Any?
    @FocusState private var queryFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEntries: [CommandPaletteEntry] {
        Array(commandPaletteVisibleEntries(
            entries: entries,
            recentEntries: recentEntries,
            query: query
        ).prefix(32))
    }

    private var groupedEntries: [(String, [CommandPaletteEntry])] {
        groupedCommandPaletteEntries(
            filteredEntries,
            recentIDs: trimmedQuery.isEmpty ? Set(recentEntries.map(\.id)) : []
        )
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
            let isTight = proxy.size.width < 920 || proxy.size.height < 640
            let reservedWidth = min(max(leadingReservedWidth, 0), proxy.size.width * 0.38)
            let usableWidth = max(380, proxy.size.width - reservedWidth)
            let panelWidth = min(usableWidth - 30, isTight ? 820 : 940)
            let panelHeight = min(proxy.size.height - 34, isTight ? 570 : 620)

            ZStack {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .onTapGesture {
                        onDismiss()
                    }

                VStack(alignment: .leading, spacing: isTight ? 10 : 11) {
                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "command")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(RoachPalette.green)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(RoachPalette.green.opacity(0.12))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Command Bar")
                                    .font(.system(size: isTight ? 18 : 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                Text(trimmedQuery.isEmpty ? "Search the whole machine room." : "\(filteredEntries.count) matches")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                            }
                        }

                        Spacer()

                        Button {
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.muted))
                        .help("Close command bar")
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(selectedEntry?.accent ?? RoachPalette.green)
                            .font(.system(size: 15, weight: .semibold))

                        TextField("Search RoachNet", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .focused($queryFocused)
                            .onSubmit {
                                activateSelection()
                            }

                        Spacer(minLength: 8)

                        if !trimmedQuery.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RoachPalette.muted)
                            .help("Clear search")
                        }

                        CommandPaletteKeyHintStrip(
                            selectedAction: selectedEntry?.actionLabel ?? "Open",
                            actionPanelVisible: showActionPanel
                        )
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        RoachPalette.panelRaised.opacity(0.82),
                                        Color.black.opacity(0.24),
                                        (selectedEntry?.accent ?? RoachPalette.green).opacity(0.07),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke((selectedEntry?.accent ?? RoachPalette.green).opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: (selectedEntry?.accent ?? RoachPalette.green).opacity(0.10), radius: 18, y: 10)

                    if isTight {
                        paletteResultsList
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            paletteResultsList
                                .frame(width: min(max(panelWidth * 0.52, 390), 500), alignment: .leading)
                            CommandPalettePreview(
                                entry: selectedEntry,
                                showActionPanel: showActionPanel,
                                onSelect: onSelect,
                                onCopyTarget: copyCommandTarget
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(isTight ? 14 : 16)
                .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.94),
                                    RoachPalette.panel.opacity(0.98),
                                    Color.black.opacity(0.88),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.clear,
                                    RoachPalette.green.opacity(0.035),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    (selectedEntry?.accent ?? RoachPalette.green).opacity(0.20),
                                    Color.white.opacity(0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: RoachPalette.shadow.opacity(0.62), radius: 44, x: 0, y: 24)
                .shadow(color: (selectedEntry?.accent ?? RoachPalette.green).opacity(0.09), radius: 54, x: 0, y: 28)
                .padding(17)
                .padding(.leading, reservedWidth)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: reservedWidth > 0 ? .topLeading : .center
                )
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.965, anchor: .top)
                .offset(y: appeared ? 0 : -10)
            }
        }
        .onAppear {
            selectedEntryID = filteredEntries.first?.id
            installKeyMonitor()
            requestQueryFocus()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                appeared = true
            }
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            selectedEntryID = filteredEntries.first?.id
            showActionPanel = false
        }
        .onChange(of: filteredEntries) { _, entries in
            guard !entries.isEmpty else {
                selectedEntryID = nil
                return
            }
            if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
                return
            }
            selectedEntryID = entries.first?.id
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
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedEntryID)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: trimmedQuery)
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: showActionPanel)
    }

    private var paletteResultsList: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedEntries, id: \.0) { section, items in
                        VStack(alignment: .leading, spacing: 7) {
                            CommandPaletteSectionHeader(
                                title: section,
                                count: items.count,
                                accent: items.first?.accent ?? RoachPalette.green
                            )

                            ForEach(items) { entry in
                                Button {
                                    onSelect(entry)
                                } label: {
                                    CommandPaletteRow(
                                        entry: entry,
                                        isSelected: selectedEntry?.id == entry.id,
                                        index: filteredEntries.firstIndex(of: entry)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                                .onHover { hovering in
                                    guard hovering else { return }
                                    selectedEntryID = entry.id
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }
                        }
                    }

                    if filteredEntries.isEmpty {
                        CommandPaletteEmptyState(hasQuery: !trimmedQuery.isEmpty)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .onChange(of: selectedEntryID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                    reader.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func moveSelection(delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let currentIndex = filteredEntries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
        let nextIndex = (currentIndex + delta + filteredEntries.count) % filteredEntries.count
        selectedEntryID = filteredEntries[nextIndex].id
    }

    private func activateSelection() {
        if let selectedEntry {
            onSelect(selectedEntry)
        }
    }

    private func copySelectedTarget() {
        guard let selectedEntry else { return }
        copyCommandTarget(selectedEntry)
    }

    private func copyCommandTarget(_ entry: CommandPaletteEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.copyTargetPayload, forType: .string)
    }

    private func activateEntry(at index: Int) {
        guard filteredEntries.indices.contains(index) else { return }
        onSelect(filteredEntries[index])
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags.contains(.command), event.keyCode == 40 {
                showActionPanel.toggle()
                return nil
            }

            if flags.contains(.command), let index = commandPaletteNumberIndex(for: event.keyCode) {
                activateEntry(at: index)
                return nil
            }

            switch event.keyCode {
            case 125:
                moveSelection(delta: 1)
                return nil
            case 126:
                moveSelection(delta: -1)
                return nil
            case 36, 76:
                if flags.contains(.option) {
                    copySelectedTarget()
                    return nil
                }
                activateSelection()
                return nil
            case 53:
                onDismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func requestQueryFocus() {
        queryFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            queryFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            queryFocused = true
        }
    }
}

private struct DetachedCommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let featuredEntries: [CommandPaletteEntry]
    let recentEntries: [CommandPaletteEntry]
    let onSelect: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedEntryID: String?
    @State private var appeared = false
    @State private var showActionPanel = false
    @State private var keyMonitor: Any?
    @FocusState private var queryFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEntries: [CommandPaletteEntry] {
        Array(commandPaletteVisibleEntries(
            entries: entries,
            recentEntries: recentEntries,
            query: query
        ).prefix(32))
    }

    private var groupedEntries: [(String, [CommandPaletteEntry])] {
        groupedCommandPaletteEntries(
            filteredEntries,
            recentIDs: trimmedQuery.isEmpty ? Set(recentEntries.map(\.id)) : []
        )
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
            let isWide = proxy.size.width > 760
            let panelWidth = min(proxy.size.width - 32, isWide ? 850 : 740)
            let panelHeight = min(proxy.size.height - 40, isWide ? 570 : 540)

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "command")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(RoachPalette.green)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(RoachPalette.green.opacity(0.12))
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Command Bar")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                Text(trimmedQuery.isEmpty ? "Search the whole machine room." : "\(filteredEntries.count) matches")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                            }

                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selectedEntry?.accent ?? RoachPalette.green)

                            TextField("Search RoachNet", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(RoachPalette.text)
                                .focused($queryFocused)
                                .onSubmit {
                                    activateSelection()
                                }

                            if !trimmedQuery.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(RoachPalette.muted)
                                .help("Clear search")
                            }

                            CommandPaletteKeyHintStrip(
                                selectedAction: selectedEntry?.actionLabel ?? "Open",
                                actionPanelVisible: showActionPanel
                            )
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.82))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke((selectedEntry?.accent ?? RoachPalette.green).opacity(0.18), lineWidth: 1)
                        )

                        if isWide {
                            HStack(alignment: .top, spacing: 16) {
                                paletteResultsList
                                    .frame(width: min(max(panelWidth * 0.50, 340), 430), alignment: .leading)
                                CommandPalettePreview(
                                    entry: selectedEntry,
                                    showActionPanel: showActionPanel,
                                    onSelect: onSelect,
                                    onCopyTarget: copyCommandTarget
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            paletteResultsList
                        }
                }
                .padding(14)
                .frame(
                    width: panelWidth,
                    height: panelHeight
                )
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.94),
                                    RoachPalette.panel.opacity(0.98),
                                    Color.black.opacity(0.88),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    (selectedEntry?.accent ?? RoachPalette.green).opacity(0.20),
                                    Color.white.opacity(0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: RoachPalette.shadow.opacity(0.62), radius: 44, x: 0, y: 24)
                .shadow(color: (selectedEntry?.accent ?? RoachPalette.green).opacity(0.09), radius: 54, x: 0, y: 28)
                .padding(.top, 22)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.965, anchor: .top)
                .offset(y: appeared ? 0 : -10)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
        }
        .onAppear {
            selectedEntryID = filteredEntries.first?.id
            installKeyMonitor()
            requestQueryFocus()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                appeared = true
            }
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            selectedEntryID = filteredEntries.first?.id
            showActionPanel = false
        }
        .onChange(of: filteredEntries) { _, entries in
            guard !entries.isEmpty else {
                selectedEntryID = nil
                return
            }
            if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
                return
            }
            selectedEntryID = entries.first?.id
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
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedEntryID)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: trimmedQuery)
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: showActionPanel)
    }

    private func moveSelection(delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let currentIndex = filteredEntries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
        let nextIndex = (currentIndex + delta + filteredEntries.count) % filteredEntries.count
        selectedEntryID = filteredEntries[nextIndex].id
    }

    private func activateSelection() {
        if let selectedEntry {
            onSelect(selectedEntry)
        }
    }

    private func copySelectedTarget() {
        guard let selectedEntry else { return }
        copyCommandTarget(selectedEntry)
    }

    private func copyCommandTarget(_ entry: CommandPaletteEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.copyTargetPayload, forType: .string)
    }

    private func activateEntry(at index: Int) {
        guard filteredEntries.indices.contains(index) else { return }
        onSelect(filteredEntries[index])
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags.contains(.command), event.keyCode == 40 {
                showActionPanel.toggle()
                return nil
            }

            if flags.contains(.command), let index = commandPaletteNumberIndex(for: event.keyCode) {
                activateEntry(at: index)
                return nil
            }

            switch event.keyCode {
            case 125:
                moveSelection(delta: 1)
                return nil
            case 126:
                moveSelection(delta: -1)
                return nil
            case 36, 76:
                if flags.contains(.option) {
                    copySelectedTarget()
                    return nil
                }
                activateSelection()
                return nil
            case 53:
                onDismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func requestQueryFocus() {
        queryFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            queryFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            queryFocused = true
        }
    }

    private var paletteResultsList: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedEntries, id: \.0) { section, items in
                        VStack(alignment: .leading, spacing: 7) {
                            CommandPaletteSectionHeader(
                                title: section,
                                count: items.count,
                                accent: items.first?.accent ?? RoachPalette.green
                            )

                            ForEach(items) { entry in
                                Button {
                                    onSelect(entry)
                                } label: {
                                    CommandPaletteRow(
                                        entry: entry,
                                        isSelected: selectedEntry?.id == entry.id,
                                        index: filteredEntries.firstIndex(of: entry)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                                .onHover { hovering in
                                    guard hovering else { return }
                                    selectedEntryID = entry.id
                                }
                            }
                        }
                    }

                    if filteredEntries.isEmpty {
                        CommandPaletteEmptyState(hasQuery: !trimmedQuery.isEmpty)
                    }
                }
            }
            .onChange(of: selectedEntryID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                    reader.scrollTo(id, anchor: .center)
                }
            }
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
        recentEntries: [CommandPaletteEntry],
        onSelect: @escaping (CommandPaletteEntry) -> Void
    ) {
        dismiss()

        let controller = DetachedCommandPaletteWindowController(
            entries: entries,
            featuredEntries: featuredEntries,
            recentEntries: recentEntries
        ) { [weak self] entry in
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
        recentEntries: [CommandPaletteEntry],
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
        // AppKit rejects combining `.canJoinAllSpaces` with `.moveToActiveSpace`
        // on this borderless non-activating panel. Keep the global palette stable
        // across Spaces and position it explicitly in `showPalette()`.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .utilityWindow
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let rootView = DetachedCommandPaletteView(
            entries: entries,
            featuredEntries: featuredEntries,
            recentEntries: recentEntries,
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
private final class VaultDropImportBatch: @unchecked Sendable {
    let expectedCount: Int
    var importedURLs: [URL] = []
    var failureMessages: [String] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    var isComplete: Bool {
        importedURLs.count + failureMessages.count == expectedCount
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    private static let roachClawContextPermissionsKey = "roachnet.roachclaw.context-permissions"
    private static let roachClawContextBudgetKey = "roachnet.roachclaw.context-character-budget"

    @Published var selectedPane: WorkspacePane? = .home
    @Published var config: RoachNetInstallerConfig = RoachNetRepositoryLocator.readConfig()
    @Published var snapshot: ManagedAppSnapshot?
    @Published var isLoading = false
    @Published var errorLine: String?
    @Published var statusLine: String = "Native shell ready."
    @Published var chatLines: [ChatLine] = [
        .init(role: "System", text: "RoachNet is up."),
        .init(role: "RoachClaw", text: "Local lane ready."),
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
    @Published var roachClawContextCharacterBudget = WorkspaceModel.loadRoachClawContextBudget() {
        didSet { persistRoachClawContextBudget() }
    }
    @Published var presentedWebSurface: PresentedWebSurface?
    @Published var presentedVaultAsset: PresentedVaultAsset?
    @Published var importedObsidianVaults: [ImportedObsidianVault] = []
    @Published var selectedImportedVaultID: String?
    @Published var roachArcadeStore = RoachArcadeLibraryStore()
    @Published var roachArchiveStore = RoachArchiveStore()
    @Published var latestVersionInfo: RoachNetLatestVersionResponse?
    @Published var systemUpdateStatus: RoachNetSystemUpdateStatusResponse?
    @Published var benchmarkStatus: RoachNetBenchmarkStatusResponse?
    @Published var isCheckingForUpdates = false
    @Published var isRequestingUpdate = false
    @Published var isRunningBenchmark = false
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
        let installURL = URL(fileURLWithPath: installPath)
        let hasNativeLauncher = fileManager.fileExists(atPath: installURL.appendingPathComponent("scripts/run-roachnet-native-api.mjs").path)
        let hasLegacyLauncher = fileManager.fileExists(atPath: installURL.appendingPathComponent("scripts/run-roachnet.mjs").path)
        return (hasNativeLauncher || hasLegacyLauncher)
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
    var speechCapabilitySnapshot: RoachSpeechCapabilitySnapshot {
        speechController.capabilitySnapshot
    }
    var enabledRoachClawContextCount: Int {
        RoachClawContextScope.allCases.filter { roachClawContextPermissions.isEnabled($0) }.count
    }
    var hasFullRoachClawContextAccess: Bool {
        enabledRoachClawContextCount == RoachClawContextScope.allCases.count
    }
    var latestVersionLabel: String {
        guard let latestVersionInfo else { return "Not checked" }
        return latestVersionInfo.updateAvailable ? latestVersionInfo.latestVersion : "Current"
    }
    var latestVersionDetail: String {
        guard let latestVersionInfo else { return "Manual check available" }
        return latestVersionInfo.message ?? "\(latestVersionInfo.currentVersion) -> \(latestVersionInfo.latestVersion)"
    }
    var systemUpdateStageLabel: String {
        systemUpdateStatus?.stage.capitalized ?? "Idle"
    }
    var systemUpdateDetail: String {
        systemUpdateStatus?.message ?? "No update in progress"
    }
    var canRequestSystemUpdate: Bool {
        guard let latestVersionInfo else { return false }
        let stage = systemUpdateStatus?.stage.lowercased() ?? "idle"
        return latestVersionInfo.updateAvailable && ["idle", "complete", "error"].contains(stage)
    }
    var benchmarkStatusLabel: String {
        benchmarkStatus?.status.capitalized ?? "Idle"
    }
    var benchmarkDetail: String {
        if let benchmarkId = benchmarkStatus?.benchmarkId, !benchmarkId.isEmpty {
            return benchmarkId
        }
        return isRunningBenchmark ? "Running locally" : "Ready to run"
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

    func setRoachClawContextBudget(_ value: Int) {
        roachClawContextCharacterBudget = min(max(value, 3_000), 40_000)
        statusLine = "Updated RoachClaw context budget."
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

    private static func loadRoachClawContextBudget() -> Int {
        let stored = UserDefaults.standard.integer(forKey: roachClawContextBudgetKey)
        guard stored > 0 else { return 12_000 }
        return min(max(stored, 3_000), 40_000)
    }

    private func persistRoachClawContextPermissions() {
        guard let data = try? JSONEncoder().encode(roachClawContextPermissions) else { return }
        UserDefaults.standard.set(data, forKey: Self.roachClawContextPermissionsKey)
    }

    private func persistRoachClawContextBudget() {
        UserDefaults.standard.set(roachClawContextCharacterBudget, forKey: Self.roachClawContextBudgetKey)
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
        speechStatusLine = "\(speechCapabilitySnapshot.engineName) listening. \(speechCapabilitySnapshot.sttModeLabel), no server detour."

        do {
            try await speechController.startTranscription { [weak self] transcript in
                self?.applyDictationTranscript(transcript)
            } onFinish: { [weak self] transcript in
                self?.finishDictation(transcript)
            }
            isDictatingPrompt = true
            statusLine = "RoachSpeech voice lane is live."
        } catch {
            isDictatingPrompt = false
            speechStatusLine = nil
            errorLine = error.localizedDescription
            statusLine = "RoachSpeech lane unavailable."
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
        speechStatusLine = "\(speechCapabilitySnapshot.engineName) reading back the latest reply."
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

    @discardableResult
    func importDroppedVaultProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            errorLine = "Drop files or folders from Finder. RoachNet cannot stash that payload."
            return false
        }

        statusLine = "Dragging loot into the vault."
        errorLine = nil

        let batch = VaultDropImportBatch(expectedCount: fileProviders.count)

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                let errorMessage = error?.localizedDescription
                let sourceURL = Self.fileURL(fromDroppedItem: item)

                Task { @MainActor in
                    guard let self else { return }

                    if let errorMessage {
                        batch.failureMessages.append(errorMessage)
                    } else if let sourceURL {
                        do {
                            let importedURL = try self.importVaultItem(from: sourceURL)
                            batch.importedURLs.append(importedURL)
                        } catch {
                            batch.failureMessages.append(error.localizedDescription)
                        }
                    } else {
                        batch.failureMessages.append("Finder did not hand RoachNet a usable file URL.")
                    }

                    guard batch.isComplete else { return }
                    self.finishDroppedVaultImport(importedURLs: batch.importedURLs, failures: batch.failureMessages)
                }
            }
        }

        return true
    }

    nonisolated private static func fileURL(fromDroppedItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL {
            return url
        }
        if let url = item as? NSURL, (url as URL).isFileURL {
            return url as URL
        }
        if let data = item as? Data,
           let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?,
           url.isFileURL {
            return url
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }
            let fileURL = URL(fileURLWithPath: NSString(string: string).expandingTildeInPath)
            return fileURL.isFileURL ? fileURL : nil
        }
        return nil
    }

    private func importVaultItem(from sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let vaultRoot = VaultDropImportSupport.vaultRootURL(storagePath: storagePath)
        try fileManager.createDirectory(at: vaultRoot, withIntermediateDirectories: true)

        let source = sourceURL.standardizedFileURL
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: source.path) else {
            throw NSError(
                domain: "RoachNetVaultDrop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(source.lastPathComponent) is not available anymore."]
            )
        }

        if VaultDropImportSupport.isInsideVault(source, vaultRootURL: vaultRoot) {
            return source
        }

        let destination = VaultDropImportSupport.destinationURL(for: source, in: vaultRoot, fileManager: fileManager)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    private func finishDroppedVaultImport(importedURLs: [URL], failures: [String]) {
        if let firstURL = importedURLs.first {
            previewVaultURL(firstURL, subtitle: firstURL.path)
        }

        if importedURLs.isEmpty {
            errorLine = failures.first ?? "Vault drop failed."
            statusLine = "Vault drop failed."
        } else {
            statusLine = "Vault swallowed \(importedURLs.count) item\(importedURLs.count == 1 ? "" : "s")."
            errorLine = failures.isEmpty ? nil : "\(failures.count) item\(failures.count == 1 ? "" : "s") failed to import."
            Task { await refreshRuntimeState(silently: true) }
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
            storageURL.appendingPathComponent("RoachArchive", isDirectory: true),
            storageURL.appendingPathComponent("RoachArchive", isDirectory: true).appendingPathComponent("Books", isDirectory: true),
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
                action: trimmedAction,
                relayHost: config.companionAdvertisedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : config.companionAdvertisedURL
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

    func downloadRoachSpeechPack(url: String, packID: String, kind: String) async {
        await runAction("roachspeech-\(packID)", status: "Queueing RoachSpeech pack.") {
            _ = try await ManagedAppRuntimeBridge.shared.downloadRoachSpeechPack(
                using: self.config,
                url: url,
                packID: packID,
                kind: kind
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
            let archiveRecords = roachArchiveStore.vaultRecords.prefix(4).map { record in
                "\(record.result.title) [\(record.status)]"
            }
            var lines: [String] = []
            lines.append("Vault lane:")
            lines.append("- Indexed files: \(snapshot?.knowledgeFiles.count ?? 0)")
            lines.append("- Roach's Archive records: \(roachArchiveStore.vaultRecords.count)")
            lines.append("- Roach's Archive search results: \(roachArchiveStore.results.count)")
            lines.append("- Roach's Archive metadata torrents: \(roachArchiveStore.metadataTorrentCount)")
            if !files.isEmpty {
                lines.append("- File samples: \(files.joined(separator: ", "))")
            }
            if let selectedImportedVault = importedObsidianVaults.first(where: { $0.id == selectedImportedVaultID }) ?? importedObsidianVaults.first {
                lines.append("- Active imported vault: \(selectedImportedVault.name)")
            }
            if !importedVaults.isEmpty {
                lines.append("- Imported vaults: \(importedVaults.joined(separator: " · "))")
            }
            if !archiveRecords.isEmpty {
                lines.append("- Added books: \(archiveRecords.joined(separator: " · "))")
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

        if roachClawContextPermissions.arcade {
            let games = roachArcadeStore.games
            let selectedGame = roachArcadeStore.selectedGame
            var lines: [String] = []
            lines.append("RoachArcade lane:")
            lines.append("- Library games: \(games.count)")
            lines.append("- Playable games: \(games.filter { $0.status == .ready }.count)")
            lines.append("- Connected controllers: \(roachArcadeStore.connectedControllerSummary)")
            if let session = roachArcadeStore.activePlayerSession {
                lines.append("- Active game session: \(session.title)")
            }
            if let selectedGame {
                lines.append("- Selected game: \(selectedGame.title) [\(selectedGame.system), \(selectedGame.kind.label), \(selectedGame.status.label)]")
                lines.append("- Runner: \(selectedGame.compatibilityRunner.label)")
                if selectedGame.cheats.isEmpty {
                    lines.append("- Cheats: none stored")
                } else {
                    let enabledCheats = selectedGame.cheats.filter(\.enabled).map(\.name)
                    lines.append("- Enabled cheats: \(enabledCheats.isEmpty ? "none" : enabledCheats.joined(separator: ", "))")
                }
                let profiles = roachArcadeStore.profilesForSelectedGame.map { profile in
                    "\(profile.name) (\(profile.mods.count) mods)"
                }
                if !profiles.isEmpty {
                    lines.append("- Mod profiles: \(profiles.joined(separator: " · "))")
                }
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

        let contextBody = sections.joined(separator: "\n\n")
        let budgetedContextBody = RoachClawContextSupport.normalizedExcerpt(
            contextBody,
            maxCharacters: roachClawContextCharacterBudget
        ) ?? contextBody

        return """
        Explicitly permitted local app context:
        \(budgetedContextBody)

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
        case "roachspeech-pack", "roachvoice-pack":
            guard
                let remoteURL = queryValue("url", in: components),
                let packID = queryValue("pack", in: components) ?? queryValue("packID", in: components)
            else {
                errorLine = "RoachNet couldn't tell which RoachSpeech pack to install."
                statusLine = "Install link incomplete."
                return
            }
            let kind = queryValue("kind", in: components) ?? "roachVoice"
            selectedPane = .roachClaw
            await downloadRoachSpeechPack(url: remoteURL, packID: packID, kind: kind)
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

        let ollamaService = snapshot.services.first { $0.service_name == "roachnet_ollama" }
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

    func requestSettingsPane(_ pane: RoachNetSettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: RoachNetSettingsPane.requestedPaneUserDefaultsKey)
    }

    func checkForRoachNetUpdates(force: Bool = false) async {
        guard setupCompleted, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        errorLine = nil
        statusLine = "Checking release lane."

        do {
            latestVersionInfo = try await ManagedAppRuntimeBridge.shared.checkLatestVersion(
                using: config,
                force: force
            )
            statusLine = latestVersionInfo?.updateAvailable == true ? "Update available." : "RoachNet is current."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Update check failed."
        }

        isCheckingForUpdates = false
    }

    func refreshUpdateStatusIfNeeded() async {
        guard setupCompleted, systemUpdateStatus == nil else { return }
        await refreshSystemUpdateStatus()
    }

    func refreshSystemUpdateStatus() async {
        guard setupCompleted else { return }

        do {
            systemUpdateStatus = try await ManagedAppRuntimeBridge.shared.getSystemUpdateStatus(using: config)
        } catch {
            if errorLine == nil {
                errorLine = error.localizedDescription
            }
        }
    }

    func requestRoachNetUpdate() async {
        guard setupCompleted, canRequestSystemUpdate, !isRequestingUpdate else { return }
        isRequestingUpdate = true
        errorLine = nil
        statusLine = "Requesting update."

        do {
            let result = try await ManagedAppRuntimeBridge.shared.requestSystemUpdate(using: config)
            statusLine = result.message ?? result.note ?? "Update requested."
            await refreshSystemUpdateStatus()
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Update request failed."
        }

        isRequestingUpdate = false
    }

    func refreshBenchmarkStatusIfNeeded() async {
        guard setupCompleted, benchmarkStatus == nil else { return }
        await refreshBenchmarkStatus()
    }

    func refreshBenchmarkStatus() async {
        guard setupCompleted else { return }

        do {
            benchmarkStatus = try await ManagedAppRuntimeBridge.shared.getBenchmarkStatus(using: config)
        } catch {
            if errorLine == nil {
                errorLine = error.localizedDescription
            }
        }
    }

    func runRoachNetBenchmark(type: String) async {
        guard setupCompleted, !isRunningBenchmark else { return }
        isRunningBenchmark = true
        errorLine = nil
        statusLine = "Starting \(type) benchmark."

        do {
            let result = try await ManagedAppRuntimeBridge.shared.runBenchmark(
                using: config,
                type: type,
                synchronous: false
            )
            statusLine = result.message ?? "Benchmark queued."
            benchmarkStatus = RoachNetBenchmarkStatusResponse(
                status: "starting",
                benchmarkId: result.benchmark_id ?? result.job_id
            )
            try? await Task.sleep(for: .milliseconds(400))
            await refreshBenchmarkStatus()
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Benchmark failed to start."
        }

        isRunningBenchmark = false
    }

    func saveSettingsFromPreferences() async {
        errorLine = nil
        statusLine = "Saving settings."

        var updatedConfig = config
        updatedConfig.storagePath = updatedConfig.storagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedConfig.roachClawDefaultModel = updatedConfig.roachClawDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedConfig.exoBaseUrl = updatedConfig.exoBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedConfig.exoModelId = updatedConfig.exoModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedConfig.releaseChannel = updatedConfig.releaseChannel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "stable"
            : updatedConfig.releaseChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedConfig.companionAdvertisedURL = updatedConfig.companionAdvertisedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedConfig.companionPort = min(max(updatedConfig.companionPort, 1_024), 65_535)

        if updatedConfig.roachClawDefaultModel.isEmpty {
            updatedConfig.roachClawDefaultModel = recommendedLocalModels.first ?? "qwen2.5-coder:1.5b"
        }

        if updatedConfig.storagePath.isEmpty {
            updatedConfig.storagePath = RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath)
        }

        do {
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
            config = updatedConfig
            roachArcadeStore.configure(storagePath: storagePath)
            roachArchiveStore.configure(storagePath: storagePath)
            synchronizeSelectedChatModel()
            await refreshRuntimeState(silently: true)
            statusLine = "Settings saved."
        } catch {
            errorLine = error.localizedDescription
            statusLine = "Settings save failed."
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

private struct HomeMascotDialogBubble: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(3)
            .minimumScaleFactor(0.78)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 18,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 18,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.16),
                            RoachPalette.panelRaised.opacity(0.82),
                            Color.black.opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 18,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 18,
                    style: .continuous
                )
                .stroke(accent.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: accent.opacity(0.10), radius: 18, y: 10)
    }
}

private struct RoachHomeMascotView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isThinking: Bool
    let isListening: Bool
    let nudge: Bool
    let accent: Color

    @State private var isHovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                drawMascot(context: &context, size: size, time: time)
            }
        }
        .scaleEffect(isHovering ? 1.035 : (nudge ? 1.02 : 1.0))
        .animation(.spring(response: 0.30, dampingFraction: 0.64), value: isHovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: nudge)
        .onHover { isHovering = $0 }
    }

    private func drawMascot(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let scale = min(width / 260, height / 210)
        let center = CGPoint(x: width * 0.50, y: height * 0.56)
        let sway = CGFloat(sin(time * 2.1)) * 4 * scale
        let breathe = CGFloat(0.5 + 0.5 * sin(time * 2.8))
        let antenna = CGFloat(sin(time * (isListening ? 8.0 : 3.2))) * 7 * scale
        let thinkingPulse = isThinking ? CGFloat(0.5 + 0.5 * sin(time * 6.0)) : 0

        let shadowRect = CGRect(
            x: center.x - 82 * scale,
            y: center.y + 58 * scale,
            width: 164 * scale,
            height: 18 * scale
        )
        context.fill(
            Path(ellipseIn: shadowRect),
            with: .color(Color.black.opacity(0.32))
        )

        drawDitherHalo(context: &context, size: size, time: time, center: center, scale: scale)

        let shellRect = CGRect(
            x: center.x - 58 * scale + sway,
            y: center.y - 70 * scale - breathe * 3 * scale,
            width: 116 * scale,
            height: 142 * scale
        )
        let shell = Path(roundedRect: shellRect, cornerRadius: 48 * scale)
        context.fill(shell, with: .color(RoachPalette.backgroundRaised.opacity(0.92)))
        context.fill(
            shell,
            with: .linearGradient(
                Gradient(colors: [
                    accent.opacity(0.26 + thinkingPulse * 0.10),
                    RoachPalette.panelRaised.opacity(0.92),
                    RoachPalette.magenta.opacity(isThinking ? 0.22 : 0.08),
                ]),
                startPoint: CGPoint(x: shellRect.minX, y: shellRect.minY),
                endPoint: CGPoint(x: shellRect.maxX, y: shellRect.maxY)
            )
        )
        context.stroke(shell, with: .color(accent.opacity(0.72)), lineWidth: 2 * scale)

        let headRect = CGRect(
            x: center.x - 39 * scale + sway,
            y: center.y - 103 * scale - breathe * 2 * scale,
            width: 78 * scale,
            height: 56 * scale
        )
        let head = Path(roundedRect: headRect, cornerRadius: 28 * scale)
        context.fill(head, with: .color(RoachPalette.background.opacity(0.96)))
        context.stroke(head, with: .color(accent.opacity(0.66)), lineWidth: 1.7 * scale)

        drawWingLines(context: &context, center: center, scale: scale, sway: sway, breathe: breathe)
        drawLegs(context: &context, center: center, scale: scale, time: time, sway: sway)
        drawAntennae(context: &context, center: center, scale: scale, sway: sway, antenna: antenna)
        drawFace(context: &context, center: center, scale: scale, sway: sway, time: time)
    }

    private func drawDitherHalo(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        center: CGPoint,
        scale: CGFloat
    ) {
        let cell: CGFloat = max(4, 6 * scale)
        let columns = Int(ceil(size.width / cell))
        let rows = Int(ceil(size.height / cell))

        for row in 0...rows {
            for column in 0...columns {
                let point = CGPoint(x: CGFloat(column) * cell, y: CGFloat(row) * cell)
                let dx = (point.x - center.x) / max(1, 120 * scale)
                let dy = (point.y - center.y) / max(1, 92 * scale)
                let radius = sqrt(dx * dx + dy * dy)
                let ring = max(0, 1.0 - abs(Double(radius) - 0.70) * 2.9)
                let sweep = 0.5 + 0.5 * sin(Double(column) * 0.33 + Double(row) * 0.19 + time * 2.0)
                let threshold = ((Double((row & 3) * 4 + (column & 3)) / 16.0) * 0.45)
                let intensity = ring * (0.34 + 0.22 * sweep)

                guard intensity > threshold else { continue }

                let rect = CGRect(x: point.x, y: point.y, width: max(1, cell - 2), height: max(1, cell - 2))
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.2 * scale),
                    with: .color(accent.opacity(min(0.20, intensity - threshold + 0.035)))
                )
            }
        }
    }

    private func drawWingLines(context: inout GraphicsContext, center: CGPoint, scale: CGFloat, sway: CGFloat, breathe: CGFloat) {
        for offset in [-24, 0, 24] {
            var line = Path()
            line.move(to: CGPoint(x: center.x + CGFloat(offset) * scale + sway * 0.28, y: center.y - 54 * scale))
            line.addQuadCurve(
                to: CGPoint(x: center.x + CGFloat(offset) * 0.45 * scale + sway * 0.16, y: center.y + 54 * scale),
                control: CGPoint(x: center.x + CGFloat(offset) * 0.82 * scale + sway, y: center.y + CGFloat(breathe) * 5 * scale)
            )
            context.stroke(line, with: .color(accent.opacity(offset == 0 ? 0.38 : 0.24)), lineWidth: offset == 0 ? 1.4 * scale : 1.0 * scale)
        }
    }

    private func drawLegs(context: inout GraphicsContext, center: CGPoint, scale: CGFloat, time: TimeInterval, sway: CGFloat) {
        for index in 0..<3 {
            let y = center.y + CGFloat(index * 29 - 32) * scale
            let kick = CGFloat(sin(time * 3.0 + Double(index))) * 7 * scale
            drawLeg(
                context: &context,
                start: CGPoint(x: center.x - 42 * scale + sway, y: y),
                mid: CGPoint(x: center.x - (76 + CGFloat(index * 8)) * scale - kick, y: y + (index == 1 ? 5 : -6) * scale),
                end: CGPoint(x: center.x - (106 + CGFloat(index * 10)) * scale - kick, y: y + (index == 2 ? 22 : -20) * scale),
                scale: scale
            )
            drawLeg(
                context: &context,
                start: CGPoint(x: center.x + 42 * scale + sway, y: y),
                mid: CGPoint(x: center.x + (76 + CGFloat(index * 8)) * scale + kick, y: y + (index == 1 ? 5 : -6) * scale),
                end: CGPoint(x: center.x + (106 + CGFloat(index * 10)) * scale + kick, y: y + (index == 2 ? 22 : -20) * scale),
                scale: scale
            )
        }
    }

    private func drawLeg(context: inout GraphicsContext, start: CGPoint, mid: CGPoint, end: CGPoint, scale: CGFloat) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: mid)
        path.addLine(to: end)
        context.stroke(path, with: .color(accent.opacity(0.76)), lineWidth: 1.9 * scale)
    }

    private func drawAntennae(context: inout GraphicsContext, center: CGPoint, scale: CGFloat, sway: CGFloat, antenna: CGFloat) {
        for side: CGFloat in [-1, 1] {
            var path = Path()
            let start = CGPoint(x: center.x + side * 25 * scale + sway, y: center.y - 93 * scale)
            path.move(to: start)
            path.addQuadCurve(
                to: CGPoint(x: center.x + side * (90 * scale + antenna), y: center.y - 132 * scale + antenna * 0.22),
                control: CGPoint(x: center.x + side * (50 * scale + antenna * 0.40), y: center.y - 140 * scale)
            )
            context.stroke(path, with: .color(accent.opacity(0.82)), lineWidth: 1.8 * scale)
        }
    }

    private func drawFace(context: inout GraphicsContext, center: CGPoint, scale: CGFloat, sway: CGFloat, time: TimeInterval) {
        let blink = sin(time * 1.6) > 0.94
        for side: CGFloat in [-1, 1] {
            let eyeRect = CGRect(
                x: center.x + side * 17 * scale - 4 * scale + sway,
                y: center.y - 84 * scale,
                width: 8 * scale,
                height: blink ? 2 * scale : 10 * scale
            )
            context.fill(Path(ellipseIn: eyeRect), with: .color(RoachPalette.text.opacity(0.92)))
        }

        var smile = Path()
        smile.move(to: CGPoint(x: center.x - 12 * scale + sway, y: center.y - 66 * scale))
        smile.addQuadCurve(
            to: CGPoint(x: center.x + 12 * scale + sway, y: center.y - 66 * scale),
            control: CGPoint(x: center.x + sway, y: center.y - 58 * scale)
        )
        context.stroke(smile, with: .color(accent.opacity(0.74)), lineWidth: 1.4 * scale)
    }
}

private struct GlobalRoachClawPanel: View {
    @ObservedObject var model: WorkspaceModel
    let onDismiss: () -> Void

    @State private var appeared = false
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
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                RoachTag(model.selectedChatModelLabel, accent: RoachPalette.magenta)
                                RoachTag(model.speechCapabilitySnapshot.engineName, accent: RoachPalette.cyan)
                                RoachTag(model.isDictatingPrompt ? "Listening" : model.speechCapabilitySnapshot.sttModeLabel, accent: model.isDictatingPrompt ? RoachPalette.green : RoachPalette.cyan)
                                RoachTag(model.enabledRoachClawContextCount == 0 ? "Context locked" : "\(model.enabledRoachClawContextCount) lanes", accent: model.enabledRoachClawContextCount == 0 ? RoachPalette.warning : RoachPalette.green)
                            }
                        }
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
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.985, anchor: .topTrailing)
        .onAppear {
            promptFocused = true
            withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                appeared = true
            }
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
                        RoachKicker("RoachClaw")
                        Text("Ask anywhere.")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
            }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button("Workbench") {
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

                        Button(model.isSendingPrompt ? "Sending..." : "Send") {
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

                        Button(model.isSendingPrompt ? "Sending..." : "Send") {
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
                    title: "Permissions.",
                    detail: nil
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

                Text(RoachNetGlobalHotKey.hint)
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

                Text(RoachNetGlobalHotKey.hint)
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
    let pathwaySteps: [LaunchGuideStep]
    @Binding var selectedFeatureID: String
    let onDismiss: () -> Void

    private var selectedFeature: GuideFeature? {
        featureRows.first { $0.id == selectedFeatureID } ?? featureRows.first
    }

    private var selectedFeatureIndex: Int {
        featureRows.firstIndex { $0.id == selectedFeatureID } ?? 0
    }

    var body: some View {
        RoachSpotlightPanel(accent: selectedFeature?.accent ?? RoachPalette.magenta) {
            VStack(alignment: .leading, spacing: 16) {
                LaunchGuideHero(
                    feature: selectedFeature,
                    progressText: "\(selectedFeatureIndex + 1)/\(max(featureRows.count, 1))"
                )

                LaunchGuidePathway(steps: pathwaySteps)

                LaunchGuideFeatureWorkbench(
                    featureRows: featureRows,
                    selectedFeatureID: $selectedFeatureID,
                    selectedFeature: selectedFeature
                )

                ViewThatFits(in: .horizontal) {
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

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Enter RoachNet") {
                            onDismiss()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button("Skip Intro") {
                            onDismiss()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
                .padding(.top, 2)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selectedFeatureID)
        }
        .frame(minWidth: 300, idealWidth: 720, maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct LaunchGuideHero: View {
    let feature: GuideFeature?
    let progressText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                LaunchGuidePulseMark(accent: feature?.accent ?? RoachPalette.green)
                    .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        RoachKicker("Native Guide")
                        RoachTag(RoachNetGlobalHotKey.hint, accent: RoachPalette.cyan)
                    }

                    Text("Your local command bunker.")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)

                    Text("The fast route through Home, command search, RoachClaw, RoachSpeech, Dev, RoachArcade, Maps, Vault, and the runtime bits that keep the machine honest.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    LaunchGuideSignalGrid()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let feature {
                LaunchGuideNowReading(feature: feature, progressText: progressText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LaunchGuidePulseMark: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.18),
                            RoachPalette.panelGlass,
                            Color.black.opacity(0.28),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(accent.opacity(0.32), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(accent.opacity(pulse ? 0.12 : 0.34), lineWidth: 2)
                .scaleEffect(pulse ? 1.08 : 0.94)

            RoachOrbitMark()
                .padding(12)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct LaunchGuideSignalGrid: View {
    private let columns = [
        GridItem(.adaptive(minimum: 106, maximum: 150), spacing: 8, alignment: .leading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            LaunchGuideSignalPill(value: "Local-first", detail: "default", accent: RoachPalette.green)
            LaunchGuideSignalPill(value: "Core ML", detail: "speech", accent: RoachPalette.magenta)
            LaunchGuideSignalPill(value: "ES-DE", detail: "arcade", accent: RoachPalette.cyan)
            LaunchGuideSignalPill(value: "Vault", detail: "drop zone", accent: RoachPalette.bronze)
        }
    }
}

private struct LaunchGuideSignalPill: View {
    let value: String
    let detail: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Text(detail)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct LaunchGuideNowReading: View {
    let feature: GuideFeature
    let progressText: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(progressText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(feature.accent)
                .frame(width: 44, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(feature.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Label("Reading: \(feature.title)", systemImage: feature.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                Text(feature.commandHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RoachPalette.panelGlass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(feature.accent.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct LaunchGuidePathway: View {
    let steps: [LaunchGuideStep]

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 238), spacing: 8, alignment: .topLeading),
    ]

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("First ten minutes", systemImage: "checklist.checked")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    RoachTag("best path", accent: RoachPalette.green)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        LaunchGuideStepTile(step: step)
                    }
                }
            }
        }
    }
}

private struct LaunchGuideStepTile: View {
    let step: LaunchGuideStep

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(step.accent.opacity(0.14))
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(step.accent)
                }
                .frame(width: 24, height: 24)

                Text(step.number)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(step.accent)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Label(step.title, systemImage: step.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(step.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            step.accent.opacity(0.08),
                            RoachPalette.panelGlass,
                            Color.black.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(step.accent.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct LaunchGuideFeatureWorkbench: View {
    let featureRows: [GuideFeature]
    @Binding var selectedFeatureID: String
    let selectedFeature: GuideFeature?

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Feature map", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Pick a lane. Get the useful move.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        LaunchGuideFeaturePicker(
                            featureRows: featureRows,
                            selectedFeatureID: $selectedFeatureID,
                            isCompact: false
                        )
                        .frame(width: 228)

                        if let selectedFeature {
                            LaunchGuideFeatureDetail(feature: selectedFeature)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        LaunchGuideFeaturePicker(
                            featureRows: featureRows,
                            selectedFeatureID: $selectedFeatureID,
                            isCompact: true
                        )

                        if let selectedFeature {
                            LaunchGuideFeatureDetail(feature: selectedFeature)
                        }
                    }
                }
            }
        }
    }
}

private struct LaunchGuideFeaturePicker: View {
    let featureRows: [GuideFeature]
    @Binding var selectedFeatureID: String
    let isCompact: Bool

    var body: some View {
        Group {
            if isCompact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(featureRows) { feature in
                            LaunchGuideFeatureButton(
                                feature: feature,
                                isSelected: selectedFeatureID == feature.id,
                                isCompact: true
                            ) {
                                selectedFeatureID = feature.id
                            }
                            .frame(width: 154)
                        }
                    }
                    .padding(.vertical, 1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(featureRows) { feature in
                        LaunchGuideFeatureButton(
                            feature: feature,
                            isSelected: selectedFeatureID == feature.id,
                            isCompact: false
                        ) {
                            selectedFeatureID = feature.id
                        }
                    }
                }
            }
        }
    }
}

private struct LaunchGuideFeatureButton: View {
    let feature: GuideFeature
    let isSelected: Bool
    let isCompact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? feature.accent : Color.clear)
                    .frame(width: 3, height: isCompact ? 28 : 38)

                Image(systemName: feature.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? feature.accent : RoachPalette.muted)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? feature.accent.opacity(0.16) : RoachPalette.panelGlass)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? RoachPalette.text : RoachPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(feature.section)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(feature.accent.opacity(isSelected ? 0.92 : 0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 52 : 50, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? feature.accent.opacity(0.13) : RoachPalette.panelRaised.opacity(0.44))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? feature.accent.opacity(0.42) : RoachPalette.border.opacity(0.78), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct LaunchGuideFeatureDetail: View {
    let feature: GuideFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(feature.accent)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(feature.accent.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 6) {
                    LaunchGuideTagCloud(tags: [feature.section] + feature.tags, accent: feature.accent)

                    Text(feature.title)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)

                    Text(feature.detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LaunchGuideHintRow(
                    title: "Do first",
                    detail: feature.primaryAction,
                    systemImage: "cursorarrow.click.2",
                    accent: feature.accent
                )
                LaunchGuideHintRow(
                    title: "Command search",
                    detail: feature.commandHint,
                    systemImage: "command.circle.fill",
                    accent: RoachPalette.cyan
                )
                LaunchGuideHintRow(
                    title: "Fast hint",
                    detail: feature.quickHint,
                    systemImage: "bolt.fill",
                    accent: RoachPalette.green
                )
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            feature.accent.opacity(0.10),
                            RoachPalette.panelGlass,
                            Color.black.opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(feature.accent.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct LaunchGuideTagCloud: View {
    let tags: [String]
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(tags.prefix(4)), id: \.self) { tag in
                    RoachTag(tag, accent: tag == (tags.first ?? "") ? accent : RoachPalette.cyan)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct LaunchGuideHintRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.text.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LaunchGuideVideoColumn: View {
    @ObservedObject var playbackController: LaunchGuidePlaybackController
    let quickActions: [LaunchGuideQuickAction]
    let onDismiss: () -> Void

    var body: some View {
        RoachSpotlightPanel(accent: RoachPalette.cyan) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        RoachKicker("Launch Controls")
                        Text("Watch, search, or just drive.")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.76)
                        Text("The guide is useful without the video. The command bar is the real map.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    RoachTag("no maze", accent: RoachPalette.green)
                }

                LaunchGuideReelCard(playbackController: playbackController)

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Quick actions", systemImage: "wand.and.stars")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Spacer(minLength: 8)
                            RoachTag("search these", accent: RoachPalette.magenta)
                        }

                        LaunchGuideQuickActionGrid(actions: quickActions)
                    }
                }

                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Access stays put", systemImage: "pin.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)

                        LaunchGuideHintRow(
                            title: "Sidebar",
                            detail: "Guide button stays in the shell utilities.",
                            systemImage: "sidebar.leading",
                            accent: RoachPalette.green
                        )
                        LaunchGuideHintRow(
                            title: "Command",
                            detail: "`Open Guided Tour` replays this sheet without resetting setup.",
                            systemImage: "command.circle.fill",
                            accent: RoachPalette.cyan
                        )
                        LaunchGuideHintRow(
                            title: "First launch",
                            detail: "The intro sheet still appears after setup, then gets out of the way.",
                            systemImage: "sparkle.magnifyingglass",
                            accent: RoachPalette.magenta
                        )
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Button(playbackController.isPresentingWindow ? "Replay Reel" : "Open Reel") {
                            playbackController.presentVideoWindow()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(!playbackController.hasVideo)

                        Spacer(minLength: 0)

                        Button("Enter RoachNet") {
                            onDismiss()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Enter RoachNet") {
                            onDismiss()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button(playbackController.isPresentingWindow ? "Replay Reel" : "Open Reel") {
                            playbackController.presentVideoWindow()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(!playbackController.hasVideo)
                    }
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 440, maxWidth: 500, alignment: .topLeading)
    }
}

private struct LaunchGuideReelCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playbackController: LaunchGuidePlaybackController

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.cyan.opacity(0.16),
                            RoachPalette.magenta.opacity(0.08),
                            Color.black.opacity(0.26),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 16.0, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    let stripeHeight: CGFloat = 8
                    let rowCount = Int(ceil(size.height / stripeHeight))

                    for row in 0...rowCount where row.isMultiple(of: 2) {
                        let y = CGFloat(row) * stripeHeight
                        let alpha = 0.020 + 0.016 * abs(sin(time + Double(row) * 0.41))
                        context.fill(
                            Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                            with: .color(Color.white.opacity(alpha))
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: playbackController.hasVideo ? "play.rectangle.fill" : "play.slash.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(playbackController.hasVideo ? RoachPalette.cyan : RoachPalette.muted)
                        .frame(width: 46, height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(playbackController.hasVideo ? "Native launch reel" : "Written guide mode")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.76)

                        Text(playbackController.hasVideo ? "Home, command search, local AI, voice packs, games, maps, vault shelves, settings, updates." : "Video asset is missing; the field guide still carries the release path.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                LaunchGuideTagCloud(
                    tags: ["Home", "RoachClaw", "RoachSpeech", "RoachArcade", "Maps/GPS", "Vault", "Updates"],
                    accent: RoachPalette.cyan
                )

                Text(playbackController.isPresentingWindow ? "Reel window is open." : playbackController.hasVideo ? "Reel is ready." : "Rebuild `roachnet-launch-guide.mp4` when capture refresh lands.")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(playbackController.hasVideo ? RoachPalette.green : RoachPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RoachPalette.cyan.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct LaunchGuideQuickActionGrid: View {
    let actions: [LaunchGuideQuickAction]

    private let columns = [
        GridItem(.adaptive(minimum: 176, maximum: 240), spacing: 8, alignment: .topLeading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(actions) { action in
                LaunchGuideQuickActionTile(action: action)
            }
        }
    }
}

private struct LaunchGuideQuickActionTile: View {
    let action: LaunchGuideQuickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(action.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(action.accent.opacity(0.12))
                    )

                Text(action.title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(action.accent)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            Text(action.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.text.opacity(0.86))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(action.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(action.accent.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct LaunchGuideSheet: View {
    let onDismiss: () -> Void
    @StateObject private var playbackController = LaunchGuidePlaybackController()
    @State private var selectedFeatureID = "home"

    private let featureRows: [GuideFeature] = [
        .init(
            id: "home",
            title: "Home",
            detail: "The command deck shows what is installed, what is stale, and where to jump next.",
            systemImage: "square.grid.2x2.fill",
            section: "Start",
            primaryAction: "Check Home after setup. It is the release dashboard without the dashboard swamp.",
            quickHint: "Use the Guide button or \(RoachNetGlobalHotKey.hint) when you lose the thread.",
            commandHint: "Search `home`, `runtime`, or `updates` when you want the machine status fast.",
            accent: RoachPalette.green,
            tags: ["Status", "Next move", "Native"]
        ),
        .init(
            id: "command",
            title: "Command Bar",
            detail: "One search lane for panes, files, settings, updates, diagnostics, and the weird little chores.",
            systemImage: "command.circle.fill",
            section: "Shortcut",
            primaryAction: "Hit \(RoachNetGlobalHotKey.hint), type what you mean, and let the shell route it.",
            quickHint: "Search works with aliases. `maps gps`, `voice pack`, and `open guide` all count.",
            commandHint: "Search `open guide`, `voice prompt`, `copy diagnostics`, or any pane name.",
            accent: RoachPalette.cyan,
            tags: ["Search", "Aliases", "Global"]
        ),
        .init(
            id: "roachclaw",
            title: "RoachClaw",
            detail: "The RoachNet-owned AI workbench reads permitted local context before anything leaves the box.",
            systemImage: "sparkles",
            section: "Local AI",
            primaryAction: "Open RoachClaw, choose the context scopes, then ask against the real vault/app state.",
            quickHint: "Start local. Cloud fallback is a choice, not the default landlord.",
            commandHint: "Search `RoachClaw`, `allow vault context`, or `stage next useful move`.",
            accent: RoachPalette.magenta,
            tags: ["RoachBrain", "Context", "Local"]
        ),
        .init(
            id: "roachspeech",
            title: "RoachSpeech",
            detail: "Core ML speech lanes handle dictation, reply reading, model packs, and optional voice cloning.",
            systemImage: "waveform.and.mic",
            section: "Voice",
            primaryAction: "Install the base Whisper/Kokoro packs first; add Chatterbox only when cloning is needed.",
            quickHint: "Model packs live under RoachNet storage and validate before they swap in.",
            commandHint: "Search `voice prompt`, `listen to latest reply`, or `model store`.",
            accent: RoachPalette.green,
            tags: ["Core ML", "Model packs", "Voice"]
        ),
        .init(
            id: "dev",
            title: "Dev Studio",
            detail: "A native IDE-style surface with editor, terminal transcript handling, and inline RoachClaw assist.",
            systemImage: "terminal.fill",
            section: "Build",
            primaryAction: "Open Dev when the task needs files, shell output, and AI help in the same lane.",
            quickHint: "Paths are redacted where needed; terminal traces stay useful without getting sloppy.",
            commandHint: "Search `Dev`, `stage dev agent prompt`, or `open projects root`.",
            accent: RoachPalette.cyan,
            tags: ["Editor", "Terminal", "Assist"]
        ),
        .init(
            id: "arcade",
            title: "RoachArcade",
            detail: "ES-DE imports, ROM metadata, Mac games, mods, cheats, Vortex manifests, and runner readiness.",
            systemImage: "gamecontroller.fill",
            section: "Games",
            primaryAction: "Import an ES-DE library or ROM folder, then let the shelf show what can actually run.",
            quickHint: "Windows titles say `Needs Runner` until GPTK/CrossOver/Wine is real.",
            commandHint: "Search `RoachArcade`, `apps store`, or `open storage library`.",
            accent: RoachPalette.magenta,
            tags: ["ES-DE", "ROMs", "Mods"]
        ),
        .init(
            id: "maps",
            title: "Maps/GPS",
            detail: "Native map packs, offline source profiles, live phone GPS packets, and stale/live fix labels.",
            systemImage: "map.fill",
            section: "Atlas",
            primaryAction: "Load curated map packs, then pair RoachPhone when live position matters.",
            quickHint: "Offline maps stay useful when web maps start acting like toll booths.",
            commandHint: "Search `Maps`, `gps`, or `open runtime health` if packets look stale.",
            accent: RoachPalette.cyan,
            tags: ["Offline", "GPS", "Packs"]
        ),
        .init(
            id: "vault",
            title: "Vault",
            detail: "Drag/drop files, books, media, archive metadata, transcripts, lyrics, previews, and local search.",
            systemImage: "books.vertical.fill",
            section: "Library",
            primaryAction: "Drop files into Vault first; books, media, and sidecars become something you can use.",
            quickHint: "Keep transcripts beside the source instead of making a mystery folder shrine.",
            commandHint: "Search `Vault`, `import Obsidian vault`, or a file name after import.",
            accent: RoachPalette.bronze,
            tags: ["Books", "Media", "Transcripts"]
        ),
        .init(
            id: "runtime",
            title: "Runtime/Settings/Updates",
            detail: "Inspect contained services, logs, paths, diagnostics, native settings, and update requests.",
            systemImage: "server.rack",
            section: "Maintain",
            primaryAction: "Check Runtime before blaming the app. Check Settings before blaming yourself.",
            quickHint: "Copy diagnostics from the command bar when a bug report needs clean evidence.",
            commandHint: "Search `refresh runtime`, `check for updates`, `open runtime log`, or `settings`.",
            accent: RoachPalette.cyan,
            tags: ["Logs", "Settings", "Updates"]
        ),
    ]

    private let pathwaySteps: [LaunchGuideStep] = [
        .init(
            id: "deck",
            number: "01",
            title: "Open the deck",
            detail: "Home tells you what is installed, alive, stale, or waiting.",
            systemImage: "square.grid.2x2.fill",
            accent: RoachPalette.green
        ),
        .init(
            id: "content",
            number: "02",
            title: "Load your stuff",
            detail: "Drop vault files, books, media, ROMs, maps, and packs into their lanes.",
            systemImage: "tray.and.arrow.down.fill",
            accent: RoachPalette.bronze
        ),
        .init(
            id: "ai",
            number: "03",
            title: "Pick a brain",
            detail: "Use RoachClaw and RoachSpeech with explicit local context.",
            systemImage: "sparkles",
            accent: RoachPalette.magenta
        ),
        .init(
            id: "maintain",
            number: "04",
            title: "Keep it clean",
            detail: "Runtime, Settings, Updates, and diagnostics keep the bolts visible.",
            systemImage: "wrench.and.screwdriver.fill",
            accent: RoachPalette.cyan
        ),
    ]

    private let quickActions: [LaunchGuideQuickAction] = [
        .init(
            id: "command",
            title: "Command",
            detail: "\(RoachNetGlobalHotKey.hint) opens the command bar from anywhere in the shell.",
            systemImage: "command.circle.fill",
            accent: RoachPalette.cyan
        ),
        .init(
            id: "drop",
            title: "Drop",
            detail: "Vault accepts files, books, media, metadata, and sidecars without ceremony.",
            systemImage: "tray.and.arrow.down.fill",
            accent: RoachPalette.bronze
        ),
        .init(
            id: "packs",
            title: "Packs",
            detail: "RoachSpeech model packs install, validate, then swap into local storage.",
            systemImage: "shippingbox.fill",
            accent: RoachPalette.green
        ),
        .init(
            id: "diagnose",
            title: "Diagnose",
            detail: "Runtime logs, diagnostics, Settings, and Updates stay one search away.",
            systemImage: "stethoscope",
            accent: RoachPalette.magenta
        ),
    ]

    var body: some View {
        ZStack {
            RoachBackground()
                .overlay(Color.black.opacity(0.64))
                .ignoresSafeArea()

            GeometryReader { proxy in
                let isCompact = proxy.size.width < 1120
                let contentWidth = max(300, min(proxy.size.width - 32, 1180))

                ScrollView(showsIndicators: false) {
                    Group {
                        if isCompact {
                            VStack(spacing: 16) {
                                LaunchGuideFeatureColumn(
                                    featureRows: featureRows,
                                    pathwaySteps: pathwaySteps,
                                    selectedFeatureID: $selectedFeatureID,
                                    onDismiss: onDismiss
                                )
                                LaunchGuideVideoColumn(
                                    playbackController: playbackController,
                                    quickActions: quickActions,
                                    onDismiss: onDismiss
                                )
                            }
                        } else {
                            HStack(alignment: .top, spacing: 18) {
                                LaunchGuideFeatureColumn(
                                    featureRows: featureRows,
                                    pathwaySteps: pathwaySteps,
                                    selectedFeatureID: $selectedFeatureID,
                                    onDismiss: onDismiss
                                )
                                LaunchGuideVideoColumn(
                                    playbackController: playbackController,
                                    quickActions: quickActions,
                                    onDismiss: onDismiss
                                )
                            }
                        }
                    }
                    .frame(
                        maxWidth: contentWidth,
                        alignment: .center
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaPadding(.top, 8)
                .safeAreaPadding(.bottom, 8)
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
    @StateObject private var model: WorkspaceModel

    @MainActor
    init() {
        let model = WorkspaceModel()
        _model = StateObject(wrappedValue: model)
        RoachNetMacAppDelegate.bootstrapModel = model
    }

    var body: some Scene {
        WindowGroup("RoachNet", id: "main") {
            RootWorkspaceView(model: model)
                .background(MainWindowConfigurator())
                .frame(minWidth: 760, idealWidth: 1360, minHeight: 580, idealHeight: 860)
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
        .commands {
            RoachNetAppCommands(model: model)
        }

        Settings {
            RoachNetSettingsView(model: model)
                .frame(minWidth: 760, idealWidth: 900, maxWidth: 1040, minHeight: 560, idealHeight: 680)
                .onAppear {
                    appDelegate.model = model
                }
        }

    }
}

@MainActor
private final class RoachNetAboutWindowPresenter {
    static let shared = RoachNetAboutWindowPresenter()

    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: RoachNetAboutView())
        let aboutWindow = NSWindow(contentViewController: host)
        aboutWindow.title = "About RoachNet"
        aboutWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        aboutWindow.titleVisibility = .hidden
        aboutWindow.titlebarAppearsTransparent = true
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.setContentSize(NSSize(width: 940, height: 680))
        aboutWindow.minSize = NSSize(width: 520, height: 480)
        aboutWindow.center()

        window = aboutWindow
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow.makeKeyAndOrderFront(nil)
        aboutWindow.orderFrontRegardless()
    }
}

private struct RoachNetAppCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About RoachNet") {
                RoachNetAboutWindowPresenter.shared.present()
            }
        }

        CommandMenu("RoachNet") {
            Button {
                NotificationCenter.default.post(name: .roachNetOpenCommandPalette, object: nil)
            } label: {
                Label("Command Bar", systemImage: "command")
            }
            .keyboardShortcut("r", modifiers: [.command, .control])

            Button {
                NotificationCenter.default.post(name: .roachNetOpenGlobalRoachClaw, object: nil)
            } label: {
                Label("RoachClaw Overlay", systemImage: "sparkles")
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            Button {
                Task { await model.refreshRuntimeState() }
            } label: {
                Label("Refresh Runtime", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button {
                model.openStorageInFinder()
            } label: {
                Label("Reveal Storage", systemImage: "externaldrive.fill")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button {
                Task { await model.shutdownRuntime() }
            } label: {
                Label("Stop Runtime", systemImage: "stop.circle")
            }
            .disabled(!model.setupCompleted)

            SettingsLink {
                Label("Settings...", systemImage: "gearshape")
            }
        }

        CommandMenu("Sections") {
            Button("Home") {
                model.selectedPane = .home
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Dev") {
                model.selectedPane = .dev
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("RoachClaw") {
                model.selectedPane = .roachClaw
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("RoachArcade") {
                model.selectedPane = .arcade
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button("Vault") {
                model.selectedPane = .knowledge
            }
            .keyboardShortcut("5", modifiers: [.command])

            Button("Runtime") {
                model.selectedPane = .runtime
            }
            .keyboardShortcut("6", modifiers: [.command])
        }
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

            let minimumSize = NSSize(width: 900, height: 640)
            let preferredSize = NSSize(width: 1400, height: 900)
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
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasSeenLaunchGuide") private var hasSeenLaunchGuide = false
    @AppStorage("recentCommandPaletteIDs") private var recentCommandPaletteIDsRaw = ""
    @Namespace private var sidebarMotion
    @StateObject private var detachedPaletteCoordinator = DetachedCommandPaletteCoordinator()
    @StateObject private var phoneLocationBridge = RoachPhoneLocationBridge()
    @State private var showLaunchGuide = false
    @State private var showCommandPalette = false
    @State private var showGlobalRoachClaw = false
    @State private var sidebarCollapsed = false
    @State private var homeMenuSection: HomeMenuSection = .commandDeck
    @State private var homeMascotNudge = false
    @State private var homeMascotLineIndex = 0
    @State private var selectedMapCollectionSlug: String?
    @State private var mapViewerMode: RoachMapViewerMode = .drive
    @State private var mapZoomLevel = 0.72
    @State private var manualPhoneGPSPayload = RoachPhoneLocationFix.samplePayload
    @State private var isVaultDropTarget = false
    @State private var didScheduleInitialRefresh = false
    @State private var scheduledStoreConfigurationPath: String?
    @FocusState private var homePromptFocused: Bool
    private let topTitlebarInset: CGFloat = 56
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
            return "Installed surfaces and staged modules."
        case .home:
            return "Home is where the Roach is!"
        case .dev:
            return "Editor, terminal, local AI."
        case .roachClaw:
            return "Chat, voice, context. No rented brain."
        case .arcade:
            return "ROMs, Mac games, mods, cheats."
        case .maps:
            return "Maps, packs, phone GPS."
        case .education:
            return "Reference packs."
        case .knowledge:
            return "Notes, books, captures, media."
        case .runtime:
            return "Services, paths, logs, trapdoors."
        }
    }

    private func accent(for pane: WorkspacePane) -> Color {
        switch pane {
        case .suite, .home:
            return RoachPalette.green
        case .dev:
            return RoachPalette.cyan
        case .roachClaw:
            return RoachPalette.magenta
        case .arcade:
            return RoachPalette.magenta
        case .maps:
            return RoachPalette.cyan
        case .education, .knowledge:
            return RoachPalette.bronze
        case .runtime:
            return RoachPalette.green
        }
    }

    private var paneAccent: Color {
        accent(for: activePane)
    }

    private var shellStatusSummary: String {
        let readiness = model.setupCompleted ? "Ready" : "Setup"
        let runtime = model.snapshot == nil ? "Waiting" : "Live"
        let account = model.snapshot?.account.linked == true ? "Linked" : "Local"
        return "\(readiness)  ·  \(runtime)  ·  \(account)"
    }

    private var shellHintSummary: String {
        switch activePane {
        case .home:
            return "Pulse · Goodies · Loose bolts"
        case .dev:
            return "Editor · Terminal · Local AI"
        case .roachClaw:
            return "Thread · Context · No landlord"
        case .arcade:
            return "Library · Player · Mods"
        case .maps:
            return "Atlas · GPS · Offline Packs"
        case .knowledge:
            return "Shelf · Reader · Archive"
        case .runtime:
            return "Health · Logs · Wires"
        case .suite, .education:
            return "Global tools in the rail."
        }
    }

    private func displayedPane(for pane: WorkspacePane?) -> WorkspacePane {
        switch pane {
        case .education?:
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

    private var shouldShowShellHeader: Bool {
        !model.setupCompleted
    }

    private func scheduleLocalStoreConfiguration() {
        let storagePath = model.storagePath
        guard scheduledStoreConfigurationPath != storagePath else { return }
        scheduledStoreConfigurationPath = storagePath

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard scheduledStoreConfigurationPath == storagePath else { return }
            model.roachArcadeStore.configure(storagePath: storagePath)
            model.roachArchiveStore.configure(storagePath: storagePath)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactShell = proxy.size.width < 900
            let isTightShell = proxy.size.width < 1180 || proxy.size.height < 760
            let isVeryTightShell = proxy.size.width < 900 || proxy.size.height < 680
            let autoCollapsed = proxy.size.width < 1080
            let effectiveSidebarCollapsed = sidebarCollapsed || autoCollapsed
            let shellPadding = isVeryTightShell ? 5.0 : (isTightShell ? 7.0 : surfacePadding)
            let verticalInset = isVeryTightShell ? 50.0 : (isTightShell ? 52.0 : topTitlebarInset)
            let sidebarWidth = effectiveSidebarCollapsed ? (isVeryTightShell ? 60.0 : 66.0) : (isTightShell ? 248.0 : 276.0)
            let shellSpacing = effectiveSidebarCollapsed ? 7.0 : (isTightShell ? 10.0 : 14.0)

            ZStack {
                RoachBackground()

                Group {
                    if isCompactShell {
                        VStack(alignment: .leading, spacing: 10) {
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

                topWindowChrome(isCompact: isCompactShell, isTight: isTightShell, isVeryTight: isVeryTightShell)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, shellPadding + 2)
                    .padding(.top, isVeryTightShell ? 7 : 9)
                    .zIndex(12)

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
                        recentEntries: recentCommandPaletteEntries,
                        leadingReservedWidth: isCompactShell ? 0 : sidebarWidth + shellSpacing + shellPadding,
                        onSelect: { entry in
                            performCommand(entry)
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
                                showCommandPalette = false
                            }
                        }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.985, anchor: .top).combined(with: .opacity)
                        )
                    )
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

                if let arcadeSession = model.roachArcadeStore.activePlayerSession, activePane != .arcade {
                    RoachArcadeFloatingPlayer(
                        session: arcadeSession,
                        onOpenArcade: {
                            model.selectedPane = .arcade
                        },
                        onClose: {
                            model.roachArcadeStore.activePlayerSession = nil
                        }
                    )
                    .frame(
                        width: max(360, min(proxy.size.width - 30, 620)),
                        height: max(300, min(proxy.size.height - 40, 470))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, isCompactShell ? 14 : 24)
                    .padding(.bottom, isCompactShell ? 14 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(14)
                }
            }
        }
        .task {
            scheduleLocalStoreConfiguration()

            if model.selectedPane == .education {
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
        .onAppear {
            scheduleLocalStoreConfiguration()
        }
        .onChange(of: model.storagePath) { _, storagePath in
            model.roachArcadeStore.configure(storagePath: storagePath)
            model.roachArchiveStore.configure(storagePath: storagePath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .roachNetOpenCommandPalette)) { _ in
            detachedPaletteCoordinator.dismiss()
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                showCommandPalette = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .roachNetOpenDetachedCommandPalette)) { _ in
            presentDetachedCommandPalette()
        }
        .onReceive(NotificationCenter.default.publisher(for: .roachNetOpenGlobalRoachClaw)) { _ in
            openGlobalRoachClaw()
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

    private func topWindowChrome(isCompact: Bool, isTight: Bool, isVeryTight: Bool) -> some View {
        HStack(spacing: isTight ? 8 : 10) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(paneAccent.opacity(0.13))
                    RoachModuleMark(
                        systemName: activePane.icon,
                        assetName: activePane.assetName,
                        size: activePane.assetName == nil ? 15 : 18,
                        isSelected: true
                    )
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(activePane.rawValue)
                        .font(.system(size: isTight ? 12 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    if !isVeryTight {
                        Text(shellHintSummary)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
            }

            Spacer(minLength: 6)

            if !isVeryTight {
                HStack(spacing: 6) {
                    RoachTag(model.snapshot == nil ? "warming" : "live", accent: model.snapshot == nil ? RoachPalette.warning : RoachPalette.green)
                    RoachTag(model.snapshot?.account.linked == true ? "linked" : "local", accent: RoachPalette.cyan)
                }
            }

            Button {
                showCommandPalette = true
            } label: {
                if isVeryTight {
                    Image(systemName: "magnifyingglass")
                } else {
                    Label("Command", systemImage: "magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .keyboardShortcut("k", modifiers: [.command])
            .help("Open command bar")

            Button {
                openGlobalRoachClaw()
            } label: {
                if isVeryTight {
                    Image(systemName: "sparkles")
                } else {
                    Label("Claw", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .help("Open RoachClaw anywhere")

            Button {
                openNativeSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.bronze))
            .help("Open settings")
        }
        .padding(.horizontal, isTight ? 9 : 11)
        .padding(.vertical, isTight ? 7 : 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.82),
                            RoachPalette.panel.opacity(0.88),
                            Color.black.opacity(0.64),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(paneAccent.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 10)
        .shadow(color: paneAccent.opacity(0.05), radius: 24, x: 0, y: 12)
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

    private func openNativeSettings(_ pane: RoachNetSettingsPane? = nil) {
        if let pane {
            model.requestSettingsPane(pane)
        }
        showCommandPalette = false
        showGlobalRoachClaw = false
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func openNativeSettings(forInternalPath path: String) -> Bool {
        guard let pane = settingsPane(forInternalPath: path) else { return false }
        openNativeSettings(pane)
        return true
    }

    private func settingsPane(forInternalPath path: String) -> RoachNetSettingsPane? {
        let normalizedPath = path
            .components(separatedBy: "?")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedPath {
        case "/settings", "/settings/system":
            return .runtime
        case "/settings/ai":
            return .roachClaw
        case "/settings/apps":
            return .apps
        case "/settings/maps":
            return .atlas
        case "/settings/models":
            return .models
        case "/settings/update":
            return .updates
        case "/settings/benchmark":
            return .benchmark
        case "/settings/support":
            return .support
        case "/settings/legal":
            return .legal
        case "/settings/zim", "/settings/zim/remote-explorer":
            return .vault
        default:
            return nil
        }
    }

    private func sidebar(isCollapsed: Bool, isTight: Bool, isVeryTight: Bool) -> some View {
        RoachPanel {
            ZStack(alignment: .top) {
                if isCollapsed {
                    VStack(alignment: .center, spacing: 12) {
                        RoachOrbitMark()
                            .matchedGeometryEffect(id: "sidebar-mark", in: sidebarMotion)
                            .frame(width: isVeryTight ? 52 : 60, height: isVeryTight ? 52 : 60)
                            .padding(.top, 2)

                        sidebarToggleButton(isCollapsed: true)
                            .matchedGeometryEffect(id: "sidebar-toggle", in: sidebarMotion)

                        shellUtilityDock(isCompact: true, isVeryTight: isVeryTight)

                        VStack(spacing: 8) {
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

                        Circle()
                            .fill(model.snapshot == nil ? RoachPalette.warning : RoachPalette.green)
                            .frame(width: 8, height: 8)
                            .shadow(color: (model.snapshot == nil ? RoachPalette.warning : RoachPalette.green).opacity(0.30), radius: 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .leading)),
                            removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.88, anchor: .leading))
                        )
                    )
                } else {
                    VStack(alignment: .leading, spacing: isTight ? 12 : 16) {
                        HStack(spacing: 10) {
                            RoachOrbitMark()
                                .matchedGeometryEffect(id: "sidebar-mark", in: sidebarMotion)
                                .frame(width: isTight ? 54 : 62, height: isTight ? 54 : 62)

                            VStack(alignment: .leading, spacing: 6) {
                                RoachKicker("Welcome to")
                                Text("RoachNet")
                                    .font(.system(size: isTight ? 19 : 22, weight: .bold))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.74)
                                Text("Offline on purpose.")
                                    .font(.system(size: isTight ? 11 : 12, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

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
                            VStack(alignment: .leading, spacing: 12) {
                                shellUtilityDock(isCompact: false, isVeryTight: isVeryTight)

                                if !isVeryTight {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.06))
                                        .frame(height: 1)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(RoachNetGlobalHotKey.hint)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(RoachPalette.text.opacity(0.92))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("Search. Claw. Settings.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(RoachPalette.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
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
        }
        .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.text))
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    @ViewBuilder
    private func shellUtilityDock(isCompact: Bool, isVeryTight: Bool) -> some View {
        if isCompact {
            VStack(spacing: isVeryTight ? 6 : 8) {
                shellCompactUtilityButton("Command Bar", systemImage: "magnifyingglass", tint: RoachPalette.green) {
                    showCommandPalette = true
                }
                shellCompactUtilityButton("RoachClaw Anywhere", systemImage: "sparkles", tint: RoachPalette.magenta) {
                    openGlobalRoachClaw()
                }
                shellCompactUtilityButton("Guide", systemImage: "play.rectangle", tint: RoachPalette.cyan) {
                    showLaunchGuide = true
                }
                shellCompactUtilityButton("Settings", systemImage: "gearshape", tint: RoachPalette.bronze) {
                    openNativeSettings()
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    shellExpandedUtilityButton("Command", systemImage: "magnifyingglass") {
                        showCommandPalette = true
                    }
                    shellExpandedUtilityButton("Claw", systemImage: "sparkles") {
                        openGlobalRoachClaw()
                    }
                    shellExpandedUtilityButton("Guide", systemImage: "play.rectangle") {
                        showLaunchGuide = true
                    }
                    shellExpandedUtilityButton("Settings", systemImage: "gearshape") {
                        openNativeSettings()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    shellExpandedUtilityButton("Command", systemImage: "magnifyingglass") {
                        showCommandPalette = true
                    }
                    shellExpandedUtilityButton("Claw", systemImage: "sparkles") {
                        openGlobalRoachClaw()
                    }
                    shellExpandedUtilityButton("Guide", systemImage: "play.rectangle") {
                        showLaunchGuide = true
                    }
                    shellExpandedUtilityButton("Settings", systemImage: "gearshape") {
                        openNativeSettings()
                    }
                }
            }
        }
    }

    private func shellCompactUtilityButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(RoachUtilityButtonStyle(tint: tint))
        .help(title)
    }

    private func shellExpandedUtilityButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private func compactShellHeader(isTight: Bool) -> some View {
        return RoachPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    RoachOrbitMark()
                        .frame(width: isTight ? 52 : 62, height: isTight ? 52 : 62)

                    VStack(alignment: .leading, spacing: 6) {
                        RoachKicker("Welcome to")
                        Text("RoachNet")
                            .font(.system(size: isTight ? 22 : 26, weight: .bold))
                            .foregroundStyle(RoachPalette.text)
                        Text("Offline on purpose.")
                            .font(.system(size: isTight ? 12 : 13, weight: .medium))
                            .foregroundStyle(paneAccent)
                    }

                    Spacer(minLength: 0)

                    shellUtilityDock(isCompact: true, isVeryTight: false)
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
                            Text(activePane.rawValue)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                        }

                        Spacer(minLength: 12)

                        RoachTag(activePane.rawValue, accent: RoachPalette.green)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        RoachKicker("Surfaces")
                        Text(activePane.rawValue)
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
                        .frame(minHeight: max(0, proxy.size.height - 28), alignment: .topLeading)
                } else {
                    ScrollView(showsIndicators: false) {
                        detailPaneStack(isTight: isTight)
                    }
                    .id("shell-scroll-\(activePane.rawValue)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func detailPaneStack(isTight: Bool) -> some View {
        VStack(alignment: .leading, spacing: isTight ? 16 : 18) {
            if shouldShowShellHeader {
                headerBar(isTight: isTight)
            }

            if let errorLine = model.errorLine {
                RoachNotice(title: "Runtime notice", detail: errorLine)
            }

            detailPaneSurface
        }
        .padding(.top, shouldShowShellHeader ? (isTight ? 4 : 6) : (isTight ? 10 : 12))
        .padding(.bottom, isTight ? 22 : 28)
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
                case .arcade:
                    RoachArcadeView(model: model, store: model.roachArcadeStore)
                case .maps:
                    maps
                case .education:
                    knowledge
                case .knowledge:
                    knowledge
                case .runtime:
                    runtime
                }
            }
            .id(activePane.rawValue)
            .transition(
                .opacity
                    .combined(with: .move(edge: .bottom))
                    .combined(with: .scale(scale: 0.985, anchor: .top))
            )
        } else {
            lockedState
                .id("locked")
                .transition(
                    .opacity
                        .combined(with: .move(edge: .bottom))
                        .combined(with: .scale(scale: 0.985, anchor: .top))
                )
        }
    }

    private func headerBar(isTight: Bool) -> some View {
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
                            .font(.system(size: isTight ? 13 : 14, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }
            } actions: {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(shellStatusSummary)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(model.setupCompleted ? paneAccent.opacity(0.92) : RoachPalette.warning)
                        .multilineTextAlignment(.trailing)
                    Text(shellHintSummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    ? "Search lanes and actions."
                    : "Search lanes, files, actions, and RoachClaw.",
                keys: RoachNetGlobalHotKey.hint
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
                    RoachSectionHeader("Suite", title: "Installed surfaces.", detail: "Open local lanes and stage the next module.")

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 16) {
                        suiteCard(title: "Home", detail: "Status, command bar, launch deck.", value: "Runtime and next moves", pane: .home)
                        suiteCard(title: "Dev", detail: "Editor, shell, secrets, AI.", value: "Projects and assist", pane: .dev)
                        suiteCard(title: "RoachArcade", detail: "ROMs, macOS games, mods, and cheats on disk.", value: "Built-in player and Vortex bridge", pane: .arcade)
                        suiteCard(
                            title: "RoachAtlas",
                            detail: "Offline map packs, phone GPS, and route prep.",
                            value: "\(model.snapshot?.mapCollections.count ?? 0) map packs · \(phoneLocationBridge.routeSamples.count) trace samples",
                            pane: .maps
                        )
                        suiteCard(
                            title: "Vault",
                            detail: "Files, books, notes, media, packs.",
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
                    detail: "RoachNet modules can be installed directly from the native shell.",
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
                    detail: "Install work stays in setup."
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

        return VStack(alignment: .leading, spacing: 12) {
            homeLandingSurface(
                hardware: hardware,
                roachClaw: roachClaw,
                installedServices: installedServices.count,
                availableServices: availableServices.count
            )

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Lanes",
                        title: "All the Goodies",
                        detail: nil
                    )

                    homeMenuStrip(
                        installedCount: installedServices.count,
                        availableCount: availableServices.count
                    )

                    if homeMenuSection == .commandDeck {
                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                            ForEach(homeGridItems) { item in
                                Button {
                                    if let pane = item.pane {
                                        model.selectedPane = pane
                                    } else if openNativeSettings(forInternalPath: item.routePath) {
                                        return
                                    } else {
                                        Task { await model.openRoute(item.routePath, title: item.title) }
                                    }
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
                                detail: "Stage what you need from Available."
                            )
                        } else {
                            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                                ForEach(installedServices) { service in
                                    serviceModuleCard(service)
                                }
                            }
                        }
                    } else {
                        if availableServices.isEmpty {
                            emptyHomeMenuState(
                                title: "Nothing left to stage.",
                                detail: "All available modules are installed."
                            )
                        } else {
                            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
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
                    VStack(alignment: .leading, spacing: 12) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Next Up",
                                title: "Loose bolts.",
                                detail: nil
                            )
                        } actions: {
                            Button("Easy Setup") {
                                Task { await model.openRoute("/easy-setup", title: "Easy Setup") }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
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
        .padding(.bottom, 24)
    }

    private func homeLandingSurface(
        hardware: SystemInfoResponse.HardwareProfile?,
        roachClaw: RoachClawStatusResponse?,
        installedServices: Int,
        availableServices: Int
    ) -> some View {
        RoachSpotlightPanel(accent: RoachPalette.green) {
            VStack(alignment: .center, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        homeLandingCopy(hardware: hardware, roachClaw: roachClaw)
                            .frame(minWidth: 260, idealWidth: 310, maxWidth: 360, alignment: .leading)

                        homeMascotStage
                            .frame(minWidth: 250, idealWidth: 360, maxWidth: 430)
                            .frame(maxWidth: .infinity)

                        homeLandingSignals(
                            hardware: hardware,
                            roachClaw: roachClaw,
                            installedServices: installedServices,
                            availableServices: availableServices
                        )
                        .frame(minWidth: 240, idealWidth: 284, maxWidth: 320, alignment: .leading)
                    }

                    VStack(alignment: .center, spacing: 14) {
                        homeLandingCopy(hardware: hardware, roachClaw: roachClaw)
                        homeMascotStage
                            .frame(maxWidth: 440)
                        homeLandingSignals(
                            hardware: hardware,
                            roachClaw: roachClaw,
                            installedServices: installedServices,
                            availableServices: availableServices
                        )
                    }
                }

                homeRoachClawComposer
                    .frame(maxWidth: 780)
                    .padding(.top, 2)

                homeNextMovesDeck
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func homeLandingCopy(
        hardware: SystemInfoResponse.HardwareProfile?,
        roachClaw: RoachClawStatusResponse?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoachModuleMark(
                    systemName: WorkspacePane.home.icon,
                    size: 26,
                    isSelected: true,
                    glow: true
                )

                RoachTag(model.setupCompleted ? "Local shell live" : "Setup needed", accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning)
            }

            VStack(alignment: .leading, spacing: 8) {
                RoachKicker("Home")
                Text("Home is where the Roach is!")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)

                Text(homeMascotLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            homeHeroCommandWell

            Text(hardware == nil ? "Apple Silicon lane warming up." : "\(hardware?.platformLabel ?? "Apple Silicon") · \(hardware?.recommendedModelClass ?? "local")")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RoachPalette.green.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homeHeroCommandWell: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    showCommandPalette = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "command.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Command")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                        Text(RoachNetGlobalHotKey.hint)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(RoachPalette.green.opacity(0.86))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(RoachPalette.green)
                }
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.green.opacity(0.16),
                                    RoachPalette.panelRaised.opacity(0.72),
                                    Color.black.opacity(0.20),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(RoachPalette.green.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(RoachCardButtonStyle())
            .help("Open the Raycast-style command bar.")

            Button {
                homePromptFocused = true
            } label: {
                Image(systemName: "text.cursor")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(RoachPalette.magenta)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(RoachPalette.magenta.opacity(0.11))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(RoachPalette.magenta.opacity(0.18), lineWidth: 1)
                    )
            }
            .buttonStyle(RoachCardButtonStyle())
            .help("Focus the Home RoachClaw chat bar.")
        }
    }

    private var homeMascotStage: some View {
        VStack(spacing: 8) {
            HomeMascotDialogBubble(
                text: homeMascotDialog,
                accent: model.isSendingPrompt ? RoachPalette.magenta : RoachPalette.green
            )
            .frame(maxWidth: 360)
            .id(homeMascotDialog)
            .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))

            RoachHomeMascotView(
                isThinking: model.isSendingPrompt,
                isListening: model.isDictatingPrompt,
                nudge: homeMascotNudge,
                accent: RoachPalette.green
            )
            .frame(width: 230, height: 190)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                    homeMascotLineIndex = (homeMascotLineIndex + 1) % homeMascotLines.count
                    homeMascotNudge.toggle()
                }
            }
            .help("Tap the roach for another local hint.")
        }
        .frame(maxWidth: .infinity)
    }

    private func homeLandingSignals(
        hardware: SystemInfoResponse.HardwareProfile?,
        roachClaw: RoachClawStatusResponse?,
        installedServices: Int,
        availableServices: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            homeSignalPill(
                title: "Runtime",
                value: model.snapshot == nil ? "Waking" : "Live",
                detail: model.snapshot?.internetConnected == true ? "Network present" : "Offline fine",
                systemImage: "server.rack",
                accent: model.snapshot == nil ? RoachPalette.warning : RoachPalette.green
            )
            homeSignalPill(
                title: "RoachClaw",
                value: roachClaw?.ready == true ? "Ready" : "Staging",
                detail: model.selectedChatModelLabel,
                systemImage: "sparkles",
                accent: roachClaw?.ready == true ? RoachPalette.green : RoachPalette.magenta
            )
            homeSignalPill(
                title: "Vault",
                value: "\(model.snapshot?.knowledgeFiles.count ?? 0) files",
                detail: model.importedObsidianVaults.isEmpty ? "No live note vault" : "\(model.importedObsidianVaults.count) vaults",
                systemImage: "books.vertical.fill",
                accent: RoachPalette.cyan
            )
            homeSignalPill(
                title: "Goodies",
                value: "\(installedServices) / \(availableServices)",
                detail: "Installed / waiting",
                systemImage: "square.grid.2x2.fill",
                accent: RoachPalette.bronze
            )
        }
    }

    private func homeSignalPill(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        accent: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.text.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        )
    }

    private var homeRoachClawComposer: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    RoachKicker("RoachClaw")
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                            showCommandPalette = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "command")
                                .font(.system(size: 10, weight: .bold))
                            Text(RoachNetGlobalHotKey.hint)
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                        }
                        .foregroundStyle(RoachPalette.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(RoachPalette.green.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open command bar")
                }

                HStack(alignment: .center, spacing: 10) {
                    Button {
                        Task { await model.togglePromptDictation() }
                    } label: {
                        Image(systemName: model.isDictatingPrompt ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(model.isDictatingPrompt ? RoachPalette.green : RoachPalette.magenta)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .help(model.isDictatingPrompt ? "Stop voice prompt" : "Start voice prompt")

                    TextField("Ask RoachClaw what to do next.", text: $model.promptDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1...3)
                        .focused($homePromptFocused)
                        .onSubmit {
                            sendHomePrompt()
                        }

                    Button {
                        sendHomePrompt()
                    } label: {
                        Image(systemName: model.isSendingPrompt ? "hourglass" : "arrow.up.circle.fill")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(homeCanSendPrompt ? RoachPalette.green : RoachPalette.muted)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .disabled(!homeCanSendPrompt)
                    .help("Send to RoachClaw")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(homePromptChips, id: \.self) { prompt in
                            Button(prompt) {
                                stageHomePrompt(prompt)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var homeNextMovesDeck: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RoachKicker("RoachClaw Picks")
                Spacer(minLength: 8)
                Text("\(homeNextMoves.count) next moves")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(homeNextMoves) { move in
                    homeNextMoveCard(move)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func homeNextMoveCard(_ move: HomeNextMove) -> some View {
        Button {
            performHomeMove(move)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: move.systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(move.accent)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(move.accent.opacity(0.13))
                        )

                    Spacer(minLength: 8)

                    Text(move.badge.uppercased())
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(move.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(move.title)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(move.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                move.accent.opacity(0.13),
                                RoachPalette.panelRaised.opacity(0.68),
                                Color.black.opacity(0.18),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(move.accent.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(RoachCardButtonStyle())
    }

    private var homeMascotLines: [String] {
        [
            "Pick a lane. I’ll keep the wires from chewing each other.",
            "The good stuff lives on disk. The rented stuff can wait outside.",
            "Ask RoachClaw from here, then jump into the lane it points at.",
            "Small machine. Big bunker. Fewer excuses.",
        ]
    }

    private var homeMascotLine: String {
        let lines = homeMascotLines
        guard !lines.isEmpty else { return "Local shell ready." }
        return lines[homeMascotLineIndex % lines.count]
    }

    private var homeMascotDialog: String {
        let draft = model.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isSendingPrompt {
            return "RoachClaw is chewing on it."
        }
        if model.isDictatingPrompt {
            return "Listening locally. No rented ears."
        }
        if !draft.isEmpty {
            return "That ask is staged. Send it when you’re ready."
        }
        if let latestReply = model.latestRoachClawReply, !latestReply.isEmpty {
            return String(latestReply.prefix(96))
        }
        return homeMascotLine
    }

    private var homePromptChips: [String] {
        [
            "What should I do next?",
            "Check this setup for loose bolts.",
            "Find useful vault context for today.",
            "Help me start a dev session.",
        ]
    }

    private var homeCanSendPrompt: Bool {
        model.setupCompleted
            && !model.isSendingPrompt
            && !model.chatModelOptions.isEmpty
            && !model.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var homeNextMoves: [HomeNextMove] {
        var moves: [HomeNextMove] = []
        let snapshot = model.snapshot
        let roachClawReady = snapshot?.roachClaw.ready == true
        let providerReady = snapshot?.roachClaw.ollama.available == true || snapshot?.roachClaw.openclaw.available == true
        let vaultFileCount = snapshot?.knowledgeFiles.count ?? 0
        let hasImportedVaults = !model.importedObsidianVaults.isEmpty
        let arcadeStats = model.roachArcadeStore.stats
        let hasUserChat = model.chatLines.contains { $0.role == "User" }
        let failedDownloads = snapshot?.downloads.filter { $0.status == "failed" }.count ?? 0

        if !model.setupCompleted {
            moves.append(
                HomeNextMove(
                    id: "setup",
                    title: "Finish the bunker",
                    detail: "Run Easy Setup so the native shell has a real install to drive.",
                    badge: "Setup",
                    systemImage: "bolt.fill",
                    accent: RoachPalette.warning,
                    target: .route(title: "Easy Setup", path: "/easy-setup")
                )
            )
        }

        if snapshot == nil {
            moves.append(
                HomeNextMove(
                    id: "runtime-refresh",
                    title: "Wake the runtime",
                    detail: "Pull a fresh local snapshot before guessing what is alive.",
                    badge: "Pulse",
                    systemImage: "arrow.clockwise",
                    accent: RoachPalette.green,
                    target: .refreshRuntime
                )
            )
        }

        if !roachClawReady || !providerReady {
            moves.append(
                HomeNextMove(
                    id: "ai-lane",
                    title: "Warm RoachClaw",
                    detail: "Stage the local model lane so Home, Dev, and Vault can ask better questions.",
                    badge: "AI",
                    systemImage: "sparkles",
                    accent: RoachPalette.magenta,
                    target: .route(title: "AI Control", path: "/settings/ai")
                )
            )
        }

        if vaultFileCount == 0 {
            moves.append(
                HomeNextMove(
                    id: "vault-feed",
                    title: "Feed the vault",
                    detail: "Drop in notes, books, captures, or media. Empty shelves make bad bunkers.",
                    badge: "Vault",
                    systemImage: "books.vertical.fill",
                    accent: RoachPalette.cyan,
                    target: .pane(.knowledge)
                )
            )
        } else if !hasImportedVaults {
            moves.append(
                HomeNextMove(
                    id: "obsidian-import",
                    title: "Point at your notes",
                    detail: "Import an Obsidian vault without copying it into another note jail.",
                    badge: "Notes",
                    systemImage: "square.stack.3d.up.badge.plus",
                    accent: RoachPalette.cyan,
                    target: .importVault
                )
            )
        }

        if arcadeStats.games == 0 {
            moves.append(
                HomeNextMove(
                    id: "arcade-import",
                    title: "Load the game shelf",
                    detail: "Import ES-DE, ROMs, Mac games, runners, and mods. One shelf, fewer launcher ghosts.",
                    badge: "Arcade",
                    systemImage: "gamecontroller.fill",
                    accent: RoachPalette.magenta,
                    target: .pane(.arcade)
                )
            )
        }

        if !hasUserChat {
            moves.append(
                HomeNextMove(
                    id: "first-ask",
                    title: "Ask for the first move",
                    detail: "Let RoachClaw read the machine before it starts pretending.",
                    badge: "Ask",
                    systemImage: "bubble.left.and.bubble.right.fill",
                    accent: RoachPalette.green,
                    target: .prompt("Read the current RoachNet setup and give me the next three useful moves. Keep it concrete.")
                )
            )
        }

        if failedDownloads > 0 {
            moves.append(
                HomeNextMove(
                    id: "failed-downloads",
                    title: "Clear failed pulls",
                    detail: "\(failedDownloads) download\(failedDownloads == 1 ? "" : "s") failed. Clean the lane before it lies to you.",
                    badge: "Fix",
                    systemImage: "exclamationmark.triangle.fill",
                    accent: RoachPalette.warning,
                    target: .route(title: "Runtime", path: "/settings/system")
                )
            )
        }

        moves.append(
            HomeNextMove(
                id: "dev-session",
                title: "Open the workbench",
                detail: "Editor, terminal, inline assist, and project state. One bench, no tab graveyard.",
                badge: "Dev",
                systemImage: "terminal.fill",
                accent: RoachPalette.cyan,
                target: .pane(.dev)
            )
        )

        moves.append(
            HomeNextMove(
                id: "command",
                title: "Search the whole stack",
                detail: "Open the command bar. Faster than hunting menus like it’s 2009.",
                badge: RoachNetGlobalHotKey.hint,
                systemImage: "command.circle.fill",
                accent: RoachPalette.green,
                target: .commandBar
            )
        )

        var seen = Set<String>()
        return moves.filter { seen.insert($0.id).inserted }.prefix(4).map { $0 }
    }

    private func sendHomePrompt() {
        guard homeCanSendPrompt else { return }
        Task { await model.sendPrompt() }
    }

    private func stageHomePrompt(_ prompt: String) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            model.promptDraft = prompt
            homePromptFocused = true
        }
    }

    private func performHomeMove(_ move: HomeNextMove) {
        switch move.target {
        case let .pane(pane):
            withAnimation(shellSpring) {
                model.selectedPane = pane
            }
        case let .route(title, path):
            if openNativeSettings(forInternalPath: path) {
                return
            }
            Task { await model.openRoute(path, title: title) }
        case let .prompt(prompt):
            stageHomePrompt(prompt)
        case .commandBar:
            withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                showCommandPalette = true
            }
        case .refreshRuntime:
            Task { await model.refreshRuntimeState() }
        case .importVault:
            model.importObsidianVault()
        }
    }

    private var homeHeroLaunchDeck: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            homeHeroActionCard(
                title: "Command Bar",
                detail: RoachNetGlobalHotKey.hint,
                systemImage: "magnifyingglass",
                accent: RoachPalette.green
            ) {
                showCommandPalette = true
            }

            homeHeroActionCard(
                title: "RoachClaw",
                detail: "Local AI.",
                systemImage: "sparkles",
                accent: RoachPalette.magenta
            ) {
                openGlobalRoachClaw()
            }

            homeHeroActionCard(
                title: "Dev Desk",
                detail: "IDE shell.",
                systemImage: "terminal.fill",
                accent: RoachPalette.cyan
            ) {
                model.selectedPane = .dev
            }

            homeHeroActionCard(
                title: "Arcade",
                detail: "Game shelf.",
                systemImage: "gamecontroller.fill",
                accent: RoachPalette.magenta
            ) {
                model.selectedPane = .arcade
            }

            homeHeroActionCard(
                title: "Vault",
                detail: "Books, notes.",
                systemImage: "books.vertical.fill",
                accent: RoachPalette.cyan
            ) {
                model.selectedPane = .knowledge
            }

            homeHeroActionCard(
                title: "RoachAtlas",
                detail: "Offline maps.",
                systemImage: "map.fill",
                accent: RoachPalette.bronze
            ) {
                model.selectedPane = .maps
            }
        }
    }

    private func homeHeroActionCard(
        title: String,
        detail: String,
        systemImage: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.14))
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.10),
                                RoachPalette.panelRaised.opacity(0.82),
                                Color.black.opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accent.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(RoachCardButtonStyle())
    }

    private func homeSignalDeck(
        hardware: SystemInfoResponse.HardwareProfile?,
        installedServices: Int,
        availableServices: Int
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Status",
                    title: "Pulse check.",
                    detail: nil
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    RoachMetricCard(
                        label: "Runtime",
                        value: model.snapshot == nil ? "Waiting" : "Live",
                        detail: model.snapshot?.internetConnected == true ? "Online" : "Offline"
                    )
                    RoachMetricCard(
                        label: "Account",
                        value: model.snapshot?.account.linked == true ? "Linked" : "Local",
                        detail: model.snapshot?.account.linked == true ? "Sync" : "This Mac"
                    )
                    RoachMetricCard(
                        label: "Modules",
                        value: "\(installedServices) live / \(availableServices) staged",
                        detail: "Installed / staged"
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
                    "Overview",
                    title: "Stack on disk.",
                    detail: nil
                )

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Runtime",
                        value: roachClaw?.preferredMode ?? hardware?.recommendedRuntime ?? "native_local",
                        detail: model.snapshot?.internetConnected == true
                            ? "Live"
                            : "Offline",
                        systemName: "server.rack",
                        accent: RoachPalette.green
                    )
                    RoachDigestRow(
                        "AI lane",
                        value: model.displayedRoachClawDefaultModel,
                        detail: roachClaw?.ollama.available == true
                            ? "Ready"
                            : "Needs model",
                        systemName: "sparkles",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Vault",
                        value: "\(model.snapshot?.knowledgeFiles.count ?? 0) local files",
                        detail: "Shelf",
                        systemName: "books.vertical.fill",
                        accent: RoachPalette.cyan
                    )
                }
            }
        }
    }

    private var roachClaw: some View {
        let chatModels = model.chatModelOptions
        let recommendedQuickstartModel = model.recommendedLocalModels.first ?? model.config.roachClawDefaultModel
        let cloudModels = chatModels.filter { $0.localizedCaseInsensitiveContains(":cloud") }
        let activeModelDownloads = model.snapshot?.downloads.filter { $0.filetype == "model" && $0.status != "failed" } ?? []

        return VStack(alignment: .leading, spacing: 14) {
            roachClawControlStrip(
                cloudModels: cloudModels.count,
                activeModelDownloads: activeModelDownloads.count
            )

            roachClawConversationAndActionDeck(
                roachClaw: model.snapshot?.roachClaw,
                recommendedQuickstartModel: recommendedQuickstartModel,
                cloudModel: cloudModels.first,
                activeModelDownloads: activeModelDownloads.count,
                cloudModels: cloudModels.count
            )

            roachClawWorkingSetDock
        }
    }

    private func roachClawControlStrip(
        cloudModels: Int,
        activeModelDownloads: Int
    ) -> some View {
        RoachSpotlightPanel(accent: RoachPalette.magenta) {
            VStack(alignment: .leading, spacing: 12) {
                responsiveBar {
                    HStack(alignment: .center, spacing: 14) {
                        RoachModuleMark(
                            systemName: WorkspacePane.roachClaw.icon,
                            assetName: WorkspacePane.roachClaw.assetName,
                            size: 32,
                            isSelected: true,
                            glow: true
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("RoachClaw")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(RoachPalette.text)
                            Text("Local first.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                } actions: {
                    roachClawTopActions(chatModels: model.chatModelOptions)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        RoachTag(model.selectedChatModelLabel, accent: RoachPalette.green)
                        RoachTag("\(model.roachBrainPinnedCount) pinned", accent: RoachPalette.magenta)
                        RoachTag("\(model.enabledRoachClawContextCount) lanes", accent: RoachPalette.cyan)
                        RoachTag(cloudModels == 0 ? "no cloud rent" : "\(cloudModels) escape routes", accent: RoachPalette.bronze)
                        if activeModelDownloads > 0 {
                            RoachTag("\(activeModelDownloads) model pulls", accent: RoachPalette.warning)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func roachClawTopActions(chatModels: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button(model.isDictatingPrompt ? "Stop Voice" : "Voice") {
                    Task { await model.togglePromptDictation() }
                }
                .buttonStyle(RoachSecondaryButtonStyle())

                Menu {
                    ForEach(chatModels, id: \.self) { modelName in
                        Button(model.chatModelLabel(for: modelName)) {
                            model.selectedChatModel = modelName
                        }
                    }

                    Divider()

                    Button("Model Store") {
                        openNativeSettings(.models)
                    }
                } label: {
                    Label("Model", systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }

            Menu {
                Button(model.isDictatingPrompt ? "Stop Voice" : "Voice") {
                    Task { await model.togglePromptDictation() }
                }

                Divider()

                ForEach(chatModels, id: \.self) { modelName in
                    Button(model.chatModelLabel(for: modelName)) {
                        model.selectedChatModel = modelName
                    }
                }

                Divider()

                Button("Model Store") {
                    openNativeSettings(.models)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(RoachPalette.panelRaised.opacity(0.74)))
                    .overlay(Circle().stroke(RoachPalette.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func roachClawHeroStrip(
        recommendedQuickstartModel: String,
        cloudModels: Int
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
            RoachInfoPill(title: "Selected Model", value: model.selectedChatModelLabel)
            RoachInfoPill(title: "Quickstart", value: recommendedQuickstartModel)
            RoachInfoPill(title: "Memory", value: "\(model.roachBrainPinnedCount) pinned")
            RoachInfoPill(
                title: "Command Bar",
                value: RoachNetGlobalHotKey.hint
            )
            RoachInfoPill(
                title: "Fallback",
                value: cloudModels == 0 ? "Local only" : "\(cloudModels) cloud routes"
            )
            RoachInfoPill(
                title: "Context",
                value: "\(model.enabledRoachClawContextCount) lanes armed"
            )
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
                    "Status",
                    title: "AI lane.",
                    detail: nil
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

                if let lanes = roachClaw?.playbook?.lanes, !lanes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachSectionHeader(
                            "Playbook",
                            title: "Cookbook, research, compare.",
                            detail: "RoachClaw-native moves for model fit, research, blind comparison, and RoachBrain cleanup."
                        )

                        if let capabilities = roachClaw?.playbook?.capabilities, !capabilities.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(capabilities.prefix(6), id: \.self) { capability in
                                        RoachTag(
                                            roachClawCapabilityLabel(capability),
                                            accent: capability.contains("voice") ? RoachPalette.cyan : RoachPalette.green
                                        )
                                    }
                                }
                                .padding(.horizontal, 1)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            ForEach(lanes.prefix(4)) { lane in
                                RoachDigestRow(
                                    lane.title,
                                    value: roachClawPlaybookStatus(lane.status),
                                    detail: lane.summary,
                                    systemName: roachClawPlaybookIcon(lane.icon),
                                    accent: roachClawPlaybookAccent(lane.accent)
                                )
                            }
                        }
                    }
                }

                if let featureGroups = roachClaw?.playbook?.featureGroups, !featureGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachSectionHeader(
                            "Native parity map",
                            title: "Every self-hosted AI lane gets a RoachNet home.",
                            detail: "Chat, agents, docs, memory, mail, calendar, media, voice, security, and iOS are tracked as native RoachNet surfaces."
                        )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                            ForEach(featureGroups) { feature in
                                RoachDigestRow(
                                    feature.title,
                                    value: roachClawPlaybookStatus(feature.status),
                                    detail: feature.nativeSurface.map { "\($0): \(feature.summary)" } ?? feature.summary,
                                    systemName: roachClawFeatureGroupIcon(feature.id),
                                    accent: roachClawFeatureGroupAccent(feature.status, id: feature.id)
                                )
                                .accessibilityLabel("\(feature.title), \(roachClawPlaybookStatus(feature.status)). \(feature.summary)")
                            }
                        }
                    }
                }

                if let operations = roachClaw?.operations {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachSectionHeader(
                            "Operations",
                            title: "Diagnostics, hooks, jobs, and reports are real state now.",
                            detail: "The planned-native lanes expose local payloads so macOS and iOS can inspect what is armed, idle, queued, or ready."
                        )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                            if let commandDeck = operations.commandDeck {
                                RoachDigestRow(
                                    "Command Deck",
                                    value: "\(commandDeck.count ?? 0) actions",
                                    detail: commandDeck.detail ?? "Fast command launch with local previews and approval boundaries.",
                                    systemName: "command.circle",
                                    accent: RoachPalette.magenta,
                                    metadata: roachClawShellSurfaceMetadata(commandDeck)
                                )
                            }

                            if let contextRail = operations.contextRail {
                                RoachDigestRow(
                                    "Context Rail",
                                    value: "\(contextRail.count ?? 0) crumbs",
                                    detail: contextRail.detail ?? "Visible context, compactions, search crumbs, and drafts.",
                                    systemName: "sidebar.trailing",
                                    accent: RoachPalette.cyan,
                                    metadata: roachClawShellSurfaceMetadata(contextRail)
                                )
                            }

                            if let vaultNavigator = operations.vaultNavigator {
                                RoachDigestRow(
                                    "Vault Navigator",
                                    value: "\(vaultNavigator.count ?? 0) local",
                                    detail: vaultNavigator.detail ?? "Finder-like vault browsing with previews and real paths.",
                                    systemName: "folder.badge.gearshape",
                                    accent: RoachPalette.green,
                                    metadata: roachClawShellSurfaceMetadata(vaultNavigator)
                                )
                            }

                            if let agentMonitor = operations.agentMonitor {
                                RoachDigestRow(
                                    "Agent Monitor",
                                    value: "\(agentMonitor.active ?? 0) live",
                                    detail: agentMonitor.detail ?? "Run history, replay crumbs, stops, retries, and event pressure.",
                                    systemName: "waveform.path.ecg.rectangle",
                                    accent: (agentMonitor.stalled ?? 0) > 0 ? RoachPalette.bronze : RoachPalette.green,
                                    metadata: roachClawShellSurfaceMetadata(agentMonitor)
                                )
                            }

                            if let orchestration = operations.orchestrationDashboard {
                                RoachDigestRow(
                                    "Orchestration",
                                    value: "\(orchestration.open ?? 0) handoffs",
                                    detail: orchestration.detail ?? "Local agent roles, context budgets, handoffs, and outcomes.",
                                    systemName: "rectangle.3.group",
                                    accent: RoachPalette.cyan,
                                    metadata: roachClawShellSurfaceMetadata(orchestration)
                                )
                            }

                            if let workspace = operations.workspaceBrowser {
                                RoachDigestRow(
                                    "Workspace Browser",
                                    value: roachClawPlaybookStatus(workspace.status),
                                    detail: workspace.detail ?? "Folder context for Dev and RoachClaw, kept native and local.",
                                    systemName: "folder.badge.gearshape",
                                    accent: RoachPalette.cyan,
                                    metadata: roachClawShellSurfaceMetadata(workspace)
                                )
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            if let diagnostics = operations.diagnostics {
                                RoachDigestRow(
                                    "Diagnostics",
                                    value: roachClawPlaybookStatus(diagnostics.status),
                                    detail: diagnostics.warnings?.first ?? "\(diagnostics.probes.count) runtime probes available.",
                                    systemName: "stethoscope",
                                    accent: diagnostics.warnings?.isEmpty == false ? RoachPalette.bronze : RoachPalette.green
                                )
                            }

                            if let serviceHealth = operations.serviceHealth {
                                RoachDigestRow(
                                    "Service Health",
                                    value: roachClawPlaybookStatus(serviceHealth.status),
                                    detail: serviceHealth.detail ?? "Secret-safe health report for native runtime lanes.",
                                    systemName: "waveform.path.ecg.rectangle",
                                    accent: serviceHealth.status == "ok" ? RoachPalette.green : RoachPalette.bronze,
                                    metadata: roachClawShellSurfaceMetadata(serviceHealth)
                                )
                            }

                            if let hooks = operations.hooks {
                                RoachDigestRow(
                                    "Hooks",
                                    value: roachClawPlaybookStatus(hooks.status),
                                    detail: "\(hooks.endpoints.count) local endpoints, secrets \(hooks.secretsPolicy ?? "redacted").",
                                    systemName: "point.3.connected.trianglepath.dotted",
                                    accent: RoachPalette.cyan
                                )
                            }

                            if let jobs = operations.jobs {
                                RoachDigestRow(
                                    "Jobs",
                                    value: jobs.scheduler.pending == 0 ? "Idle" : "\(jobs.scheduler.pending) queued",
                                    detail: "\(jobs.downloads.count) downloads tracked by the local scheduler.",
                                    systemName: "clock.arrow.circlepath",
                                    accent: jobs.status == "idle" ? RoachPalette.muted : RoachPalette.green
                                )
                            }

                            if let cookbookServe = operations.cookbookServeLifecycle {
                                RoachDigestRow(
                                    "Cookbook Serve",
                                    value: "\(cookbookServe.active ?? 0) active",
                                    detail: cookbookServe.detail ?? "Model serve schedules with explicit stop windows.",
                                    systemName: "timer",
                                    accent: (cookbookServe.active ?? 0) > 0 ? RoachPalette.green : RoachPalette.muted,
                                    metadata: roachClawShellSurfaceMetadata(cookbookServe)
                                )
                            }

                            if let scopedTools = operations.scopedToolBridge {
                                RoachDigestRow(
                                    "Scoped Tools",
                                    value: "\(scopedTools.count ?? 0) scopes",
                                    detail: scopedTools.detail ?? "Local tool bridge with explicit scopes and approvals.",
                                    systemName: "wrench.adjustable",
                                    accent: RoachPalette.magenta,
                                    metadata: roachClawShellSurfaceMetadata(scopedTools)
                                )
                            }

                            if let userTime = operations.userTime {
                                RoachDigestRow(
                                    "Time Context",
                                    value: roachClawPlaybookStatus(userTime.status),
                                    detail: userTime.detail ?? "Timezone and local clock context for schedulers and prompts.",
                                    systemName: "clock.badge.checkmark",
                                    accent: RoachPalette.bronze,
                                    metadata: roachClawShellSurfaceMetadata(userTime)
                                )
                            }

                            if let tls = operations.tlsOverrides {
                                RoachDigestRow(
                                    "Provider TLS",
                                    value: roachClawPlaybookStatus(tls.status),
                                    detail: tls.detail ?? "Extra CA bundle metadata without disabling verification.",
                                    systemName: "lock.shield",
                                    accent: tls.status == "invalid-path" ? RoachPalette.bronze : RoachPalette.cyan,
                                    metadata: roachClawShellSurfaceMetadata(tls)
                                )
                            }

                            if let uploadLimits = operations.uploadLimits {
                                RoachDigestRow(
                                    "Intake Policy",
                                    value: roachClawPlaybookStatus(uploadLimits.status),
                                    detail: uploadLimits.detail ?? "Bounded chat, vault, media, speech, calendar, and installer intake.",
                                    systemName: "tray.and.arrow.down.fill",
                                    accent: RoachPalette.green,
                                    metadata: roachClawShellSurfaceMetadata(uploadLimits)
                                )
                            }

                            if let memoryProvider = operations.memoryProvider {
                                RoachDigestRow(
                                    "Memory Provider",
                                    value: "\(memoryProvider.active ?? 0) active",
                                    detail: memoryProvider.detail ?? "RoachBrain native memory plus opt-in external providers.",
                                    systemName: "brain.head.profile",
                                    accent: RoachPalette.bronze,
                                    metadata: roachClawShellSurfaceMetadata(memoryProvider)
                                )
                            }

                            if let providerOAuth = operations.providerOAuth {
                                RoachDigestRow(
                                    "Provider OAuth",
                                    value: roachClawPlaybookStatus(providerOAuth.status),
                                    detail: providerOAuth.detail ?? "User-owned remote tool auth metadata.",
                                    systemName: "person.badge.key",
                                    accent: providerOAuth.status == "needs-user-action" ? RoachPalette.bronze : RoachPalette.muted,
                                    metadata: roachClawShellSurfaceMetadata(providerOAuth)
                                )
                            }

                            if let embeddingLanes = operations.embeddingLanes {
                                RoachDigestRow(
                                    "Embedding Lanes",
                                    value: "\(embeddingLanes.active ?? embeddingLanes.count ?? 0) active",
                                    detail: embeddingLanes.detail ?? "Separate local and custom vector lanes with safe reset metadata.",
                                    systemName: "point.3.filled.connected.trianglepath.dotted",
                                    accent: embeddingLanes.status == "healthy" ? RoachPalette.green : RoachPalette.bronze,
                                    metadata: roachClawShellSurfaceMetadata(embeddingLanes)
                                )
                            }

                            if let toolPolicy = operations.toolPolicy {
                                RoachDigestRow(
                                    "Tool Policy",
                                    value: roachClawPlaybookStatus(toolPolicy.status),
                                    detail: toolPolicy.detail ?? "Guide-only and disabled-tool state for the local tool lane.",
                                    systemName: "shield.lefthalf.filled",
                                    accent: toolPolicy.status == "guide-only" ? RoachPalette.bronze : RoachPalette.cyan,
                                    metadata: roachClawShellSurfaceMetadata(toolPolicy)
                                )
                            }

                            if let contacts = operations.contacts {
                                RoachDigestRow(
                                    "Contacts",
                                    value: "\(contacts.recordCount ?? 0) local",
                                    detail: contacts.scopes.prefix(2).joined(separator: " · "),
                                    systemName: "person.2.wave.2",
                                    accent: RoachPalette.cyan
                                )
                            }

                            if let tasks = operations.notesTasks {
                                RoachDigestRow(
                                    "Tasks",
                                    value: "\(tasks.open ?? tasks.count ?? 0) open",
                                    detail: "Stored in the local RoachClaw queue.",
                                    systemName: "checklist",
                                    accent: RoachPalette.green
                                )
                            }

                            if let calendar = operations.calendar {
                                RoachDigestRow(
                                    "Calendar",
                                    value: "\(calendar.count ?? 0) events",
                                    detail: "Planning data stays in the local workspace.",
                                    systemName: "calendar.badge.clock",
                                    accent: RoachPalette.bronze
                                )
                            }

                            if let reports = operations.reports {
                                RoachDigestRow(
                                    "Reports",
                                    value: "\(reports.count ?? 0) saved",
                                    detail: reports.formats.joined(separator: ", "),
                                    systemName: "chart.bar.doc.horizontal",
                                    accent: RoachPalette.green
                                )
                            }

                            if let memories = operations.memories {
                                RoachDigestRow(
                                    "Memories",
                                    value: "\(memories.count ?? 0) saved",
                                    detail: "Durable RoachBrain notes for context that should survive the session.",
                                    systemName: "brain.head.profile",
                                    accent: RoachPalette.bronze
                                )
                            }

                            if let skills = operations.skills {
                                RoachDigestRow(
                                    "Skills",
                                    value: "\(skills.count ?? 0) procedures",
                                    detail: "Reusable instructions RoachClaw can keep close without calling home.",
                                    systemName: "sparkles.square.filled.on.square",
                                    accent: RoachPalette.green
                                )
                            }

                            if let drafts = operations.editorDrafts {
                                RoachDigestRow(
                                    "Drafts",
                                    value: "\(drafts.open ?? drafts.count ?? 0) open",
                                    detail: "Native editor drafts staged for Vault, Dev, and RoachClaw handoff.",
                                    systemName: "doc.text",
                                    accent: RoachPalette.cyan
                                )
                            }

                            if let migrationTools = operations.migrationDocumentTools {
                                RoachDigestRow(
                                    "Migration Tools",
                                    value: roachClawPlaybookStatus(migrationTools.status),
                                    detail: migrationTools.detail ?? "Office imports, active docs, migration previews, validators, and output tails stay native.",
                                    systemName: "doc.badge.gearshape",
                                    accent: RoachPalette.cyan,
                                    metadata: roachClawShellSurfaceMetadata(migrationTools)
                                )
                            }

                            if let searchCache = operations.searchCache {
                                RoachDigestRow(
                                    "Search Cache",
                                    value: "\(searchCache.count ?? 0) entries",
                                    detail: "Cached source lookups and ranked crumbs for local research.",
                                    systemName: "magnifyingglass.circle",
                                    accent: RoachPalette.magenta
                                )
                            }

                            if let gallery = operations.gallery {
                                RoachDigestRow(
                                    "Gallery",
                                    value: "\(gallery.count ?? 0) assets",
                                    detail: "Vault media index for reports and context.",
                                    systemName: "photo.on.rectangle.angled",
                                    accent: RoachPalette.magenta
                                )
                            }

                            if let webhooks = operations.webhooks {
                                RoachDigestRow(
                                    "Webhooks",
                                    value: "\(webhooks.active ?? 0) armed",
                                    detail: "Inbound hooks store only secret digests, never raw signing keys.",
                                    systemName: "point.3.connected.trianglepath.dotted",
                                    accent: RoachPalette.cyan
                                )
                            }

                            if let runs = operations.agentRuns {
                                RoachDigestRow(
                                    "Agent Runs",
                                    value: "\(runs.active ?? 0) live",
                                    detail: "Detached RoachClaw run metadata and replay crumbs stay local.",
                                    systemName: "bolt.badge.clock",
                                    accent: RoachPalette.green
                                )
                            }

                            if let compactions = operations.contextCompactions {
                                RoachDigestRow(
                                    "Compactions",
                                    value: "\(compactions.count ?? 0) saved",
                                    detail: "Dense summaries preserve goals, paths, and decisions when context gets fat.",
                                    systemName: "text.badge.checkmark",
                                    accent: RoachPalette.bronze
                                )
                            }

                            if let toolIndex = operations.toolIndex {
                                RoachDigestRow(
                                    "Tool Index",
                                    value: "\(toolIndex.active ?? toolIndex.count ?? 0) armed",
                                    detail: "Local tool cards keep RoachClaw from stuffing every trick into every prompt.",
                                    systemName: "wrench.and.screwdriver",
                                    accent: RoachPalette.magenta
                                )
                            }

                            if let events = operations.events {
                                RoachDigestRow(
                                    "Events",
                                    value: "\(events.count ?? 0) counters",
                                    detail: "Local event counters gate reminders and agent follow-through.",
                                    systemName: "dot.radiowaves.left.and.right",
                                    accent: RoachPalette.cyan
                                )
                            }

                            if let mail = operations.mail {
                                RoachDigestRow(
                                    "RoachMail",
                                    value: "\(mail.messages ?? 0) msg · \(mail.drafts ?? 0) drafts",
                                    detail: "Local inbox and draft state without a WebUI mail bridge.",
                                    systemName: "envelope.badge",
                                    accent: RoachPalette.cyan
                                )
                            }

                            if let presets = operations.presets {
                                RoachDigestRow(
                                    "Presets",
                                    value: "\(presets.count ?? 0) saved",
                                    detail: "Reusable RoachClaw prompt setups live in the local vault.",
                                    systemName: "slider.horizontal.3",
                                    accent: RoachPalette.green
                                )
                            }

                            if let signatures = operations.signatures {
                                RoachDigestRow(
                                    "Signatures",
                                    value: "\(signatures.count ?? 0) saved",
                                    detail: "Local signature payloads for docs, mail, and vault notes.",
                                    systemName: "signature",
                                    accent: RoachPalette.bronze
                                )
                            }

                            if let tokens = operations.apiTokens {
                                RoachDigestRow(
                                    "API Tokens",
                                    value: "\(tokens.active ?? 0) active",
                                    detail: "Scoped local keys; plaintext is only shown once.",
                                    systemName: "key.horizontal",
                                    accent: RoachPalette.magenta
                                )
                            }

                            if let backups = operations.backups {
                                RoachDigestRow(
                                    "Backups",
                                    value: "\(backups.count ?? 0) snapshots",
                                    detail: "Exportable RoachClaw state for moving or restoring the lane.",
                                    systemName: "externaldrive.badge.timemachine",
                                    accent: RoachPalette.cyan
                                )
                            }
                        }
                    }
                }

                if let referenceInventory = roachClaw?.playbook?.referenceInventory {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachSectionHeader(
                            "GitHub upstream inventory",
                            title: "\(referenceInventory.functionalFileCount) functional files tracked.",
                            detail: "\(referenceInventory.observedFileCount) files observed at GitHub HEAD. The Python/WebUI stack is reference material; RoachNet owns native rewrites."
                        )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            ForEach(referenceInventory.coverageGroups) { group in
                                RoachDigestRow(
                                    group.label,
                                    value: "\(group.fileCount) files",
                                    detail: "\(group.nativeSurface): \(group.prefix)",
                                    systemName: roachClawInventoryGroupIcon(group.id),
                                    accent: RoachPalette.green
                                )
                                .accessibilityLabel("\(group.label), \(group.fileCount) files, \(group.nativeSurface)")
                            }
                        }
                    }
                }

                if let referenceModules = roachClaw?.playbook?.referenceModules, !referenceModules.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachSectionHeader(
                            "Coverage ledger",
                            title: "\(referenceModules.count) upstream modules tracked.",
                            detail: "Routes, helpers, UI modules, services, and tests are mapped into RoachNet-native owners so nothing hides in a vague backlog."
                        )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            ForEach(referenceModules.prefix(12)) { module in
                                RoachDigestRow(
                                    roachClawModuleName(module.source),
                                    value: module.nativeSurface,
                                    detail: "\(module.category.capitalized): \(roachClawPlaybookStatus(module.status))",
                                    systemName: roachClawModuleIcon(module.category),
                                    accent: roachClawFeatureGroupAccent(module.status, id: module.id)
                                )
                                .accessibilityLabel("\(module.source), \(module.nativeSurface), \(roachClawPlaybookStatus(module.status))")
                            }

                            if referenceModules.count > 12 {
                                RoachDigestRow(
                                    "Remaining modules",
                                    value: "+\(referenceModules.count - 12)",
                                    detail: "Kept in the native playbook payload and parity map for implementation tracking.",
                                    systemName: "square.stack.3d.up.fill",
                                    accent: RoachPalette.bronze
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func roachClawCapabilityLabel(_ capability: String) -> String {
        switch capability {
        case "roachclaw-cookbook":
            return "Cookbook"
        case "roachclaw-quant-aware-fit":
            return "Quant Fit"
        case "roachclaw-deep-research":
            return "Research"
        case "roachclaw-model-compare":
            return "Compare"
        case "roachbrain-memory-skills-audit":
            return "RoachBrain"
        case "vault-document-assist":
            return "Vault Docs"
        case "roachspeech-voice-lane":
            return "Voice"
        case "roachclaw-upload-limits":
            return "Intake Policy"
        case "roachclaw-service-health":
            return "Service Health"
        default:
            return capability
                .replacingOccurrences(of: "roachclaw-", with: "")
                .replacingOccurrences(of: "roachbrain-", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    private func roachClawPlaybookStatus(_ status: String) -> String {
        status
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }

    private func roachClawShellSurfaceMetadata(_ lane: RoachClawOperationsResponse.CollectionLane) -> [String] {
        var metadata: [String] = []

        if let priority = lane.priority, !priority.isEmpty {
            metadata.append(roachClawPlaybookStatus(priority))
        }

        if let hotkey = lane.hotkey, !hotkey.isEmpty {
            metadata.append(hotkey)
        }

        if let firstSummary = lane.summaryItems?.first, !firstSummary.isEmpty {
            metadata.append(firstSummary)
        } else if let route = lane.route, !route.isEmpty {
            metadata.append(route.replacingOccurrences(of: "roachnet://", with: ""))
        }

        return metadata
    }

    private func roachClawPlaybookIcon(_ icon: String?) -> String {
        switch icon {
        case "rectangle.stack.badge.person.crop":
            return "rectangle.stack.badge.person.crop"
        case "slider.horizontal.below.rectangle":
            return "slider.horizontal.below.rectangle"
        case "cpu":
            return "cpu.fill"
        case "doc.text.magnifyingglass":
            return "doc.text.magnifyingglass"
        case "rectangle.split.2x1":
            return "rectangle.split.2x1.fill"
        case "brain.head.profile":
            return "brain.head.profile"
        case "doc.richtext":
            return "doc.richtext.fill"
        case "doc.badge.gearshape":
            return "doc.badge.gearshape"
        case "waveform":
            return "waveform"
        case "paintpalette":
            return "paintpalette.fill"
        case "stethoscope":
            return "wrench.and.screwdriver.fill"
        case "waveform.path.ecg.rectangle":
            return "waveform.path.ecg.rectangle.fill"
        case "person.2.wave.2":
            return "person.2.fill"
        case "chart.bar.doc.horizontal":
            return "chart.bar.fill"
        case "person.3.sequence":
            return "person.3.sequence.fill"
        case "externaldrive.badge.timemachine":
            return "externaldrive.badge.timemachine"
        case "rectangle.3.group":
            return "rectangle.3.group.fill"
        case "bolt.badge.clock":
            return "bolt.badge.clock.fill"
        default:
            return "sparkles"
        }
    }

    private func roachClawFeatureGroupIcon(_ id: String) -> String {
        switch id {
        case "chat":
            return "bubble.left.and.bubble.right.fill"
        case "session-board":
            return "rectangle.stack.badge.person.crop.fill"
        case "agent-tools":
            return "hammer.fill"
        case "cookbook":
            return "cpu.fill"
        case "deep-research":
            return "doc.text.magnifyingglass"
        case "compare":
            return "rectangle.split.2x1.fill"
        case "model-bench":
            return "slider.horizontal.below.rectangle"
        case "documents":
            return "doc.richtext.fill"
        case "migration-document-tools":
            return "doc.badge.gearshape"
        case "memory-skills":
            return "brain.head.profile"
        case "email":
            return "envelope.fill"
        case "notes-tasks":
            return "checklist"
        case "calendar":
            return "calendar"
        case "search-rag":
            return "magnifyingglass.circle.fill"
        case "voice":
            return "waveform"
        case "gallery-editor":
            return "photo.on.rectangle"
        case "security":
            return "lock.shield.fill"
        case "mobile":
            return "iphone"
        case "contacts":
            return "person.crop.circle.badge.checkmark"
        case "diagnostics":
            return "wrench.and.screwdriver.fill"
        case "preferences":
            return "slider.horizontal.3"
        case "session-history":
            return "clock.arrow.circlepath"
        case "model-providers":
            return "network"
        case "assistant-crew":
            return "person.3.sequence.fill"
        case "orchestration":
            return "rectangle.3.group.fill"
        case "signatures":
            return "signature"
        case "backup-restore":
            return "externaldrive.badge.timemachine"
        case "local-api-keys":
            return "key.horizontal.fill"
        case "font-emoji-assets":
            return "textformat.alt"
        case "housekeeping":
            return "sparkles.rectangle.stack.fill"
        case "theme-studio":
            return "paintpalette.fill"
        case "uploads-personal-docs":
            return "tray.and.arrow.down.fill"
        case "webhooks-integrations":
            return "point.3.connected.trianglepath.dotted"
        case "background-jobs":
            return "clock.arrow.circlepath"
        case "visual-reports":
            return "chart.bar.doc.horizontal"
        case "admin-recovery":
            return "lock.rotation"
        default:
            return "square.grid.2x2.fill"
        }
    }

    private func roachClawPlaybookAccent(_ accent: String?) -> Color {
        switch accent {
        case "cyan":
            return RoachPalette.cyan
        case "magenta":
            return RoachPalette.magenta
        case "bronze":
            return RoachPalette.bronze
        default:
            return RoachPalette.green
        }
    }

    private func roachClawFeatureGroupAccent(_ status: String, id: String) -> Color {
        if status.contains("planned") { return RoachPalette.bronze }
        if status.contains("warmup") || status.contains("needs") { return RoachPalette.magenta }
        if id == "voice" || id == "search-rag" || id == "calendar" { return RoachPalette.cyan }
        return RoachPalette.green
    }

    private func roachClawModuleName(_ source: String) -> String {
        source.split(separator: "/").last.map(String.init) ?? source
    }

    private func roachClawModuleIcon(_ category: String) -> String {
        switch category {
        case "route":
            return "arrow.triangle.branch"
        case "web":
            return "globe"
        case "source":
            return "curlybraces"
        default:
            return "shippingbox.fill"
        }
    }

    private func roachClawInventoryGroupIcon(_ id: String) -> String {
        switch id {
        case "routes":
            return "arrow.triangle.branch"
        case "core":
            return "cpu.fill"
        case "source":
            return "curlybraces"
        case "services":
            return "server.rack"
        case "mcp-servers":
            return "point.3.connected.trianglepath.dotted"
        case "scripts":
            return "terminal.fill"
        case "companion":
            return "iphone.gen3"
        case "static-js":
            return "rectangle.3.group.bubble.left"
        default:
            return "square.stack.3d.up.fill"
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
            RoachMetricCard(
                label: "Context",
                value: "\(model.roachClawContextCharacterBudget / 1_000)k chars",
                detail: "\(model.enabledRoachClawContextCount) permissioned lanes"
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
                }
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 360, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 14) {
                roachClawConversationDock
                VStack(alignment: .leading, spacing: 14) {
                    roachClawActionDock(
                        recommendedQuickstartModel: recommendedQuickstartModel,
                        cloudModel: cloudModel
                    )
                }
            }
        }
    }

    private var roachClawStarterPrompts: [String] {
        [
            "Run a Cookbook check: what model fits this Mac and why?",
            "Plan a deep research pass and save the useful brief.",
            "Compare two model routes on the same prompt without model-label bias.",
            "Audit memory and skills for stale, duplicated, or useful context.",
        ]
    }

    private var roachClawConversationDock: some View {
        let threadLines = Array(model.chatLines.suffix(24))
        let hasMessages = !threadLines.isEmpty
        let latestPrompt = model.chatLines.last(where: { $0.role == "User" })?.text
        let threadTitle = latestPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? latestPrompt!
            : "Fresh thread"
        let laneTitle = model.hasCloudChatFallback ? "Web lane" : "Local first"

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
                                        Text(hasMessages ? "Thread" : "New chat")
                                            .font(.system(size: 20, weight: .bold, design: .rounded))
                                            .foregroundStyle(RoachPalette.text)
                                    }
                                }
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 8) {
                                RoachTag(laneTitle, accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                RoachTag("\(threadLines.count) turns", accent: RoachPalette.magenta)
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
                                    Text(hasMessages ? "Thread" : "New chat")
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                }
                            }

                            HStack(spacing: 8) {
                                RoachTag(laneTitle, accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                RoachTag("\(threadLines.count) turns", accent: RoachPalette.magenta)
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
                                        .truncationMode(.middle)
                                        .minimumScaleFactor(0.76)
                                }

                                Spacer(minLength: 12)

                                HStack(spacing: 8) {
                                    RoachTag(model.hasCloudChatFallback ? "Web lane" : "Private lane", accent: model.hasCloudChatFallback ? RoachPalette.cyan : RoachPalette.green)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(threadTitle)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .minimumScaleFactor(0.76)
                                HStack(spacing: 8) {
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
                        .frame(minHeight: 360, idealHeight: 430, maxHeight: 520)
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
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(RoachPalette.cyan.opacity(0.14))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "message.badge.waveform.fill")
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(RoachPalette.cyan)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Start a thread.")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
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
                        title: "Recent output.",
                        detail: nil
                    )
                } actions: {
                    HStack(spacing: 8) {
                        RoachTag("\(replies.count) replies", accent: RoachPalette.magenta)
                        RoachTag("\(memories.count) recalls", accent: RoachPalette.cyan)
                    }
                }

                if replies.isEmpty && memories.isEmpty {
                    Text("No saved output yet.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], alignment: .leading, spacing: 12) {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                Text("Prompts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Spacer(minLength: 8)
                RoachTag(RoachNetGlobalHotKey.hint, accent: RoachPalette.magenta)
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
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(RoachPalette.magenta)
                                    .frame(width: 24, height: 24)

                                Text(prompt)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
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
                    title: "Last answer.",
                    detail: nil
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
                    Button(model.isSpeakingLatestReply ? "Stop" : "Listen") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button(canSaveLatestReply ? "Save" : "Await Reply") {
                        model.saveLatestRoachClawResponseToRoachBrain()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(!canSaveLatestReply)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button(model.isSpeakingLatestReply ? "Stop" : "Listen") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button(canSaveLatestReply ? "Save" : "Await Reply") {
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
                    "Controls",
                    title: "Route and context.",
                    detail: nil
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
                        detail: "Contained model",
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
                            detail: "Hosted route",
                            accent: RoachPalette.cyan,
                            isActive: model.selectedChatModel == cloudModel
                        ) {
                            model.selectedChatModel = cloudModel
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                    RoachInfoPill(title: "STT", value: model.isDictatingPrompt ? "Listening" : model.speechCapabilitySnapshot.sttModeLabel)
                    RoachInfoPill(title: "TTS", value: model.isSpeakingLatestReply ? "Speaking" : model.speechCapabilitySnapshot.ttsModeLabel)
                    RoachInfoPill(title: "Memory", value: canSaveLatestReply ? "Save ready" : "\(model.roachBrainMemories.count) saved")
                    RoachInfoPill(title: "Context", value: model.enabledRoachClawContextCount == 0 ? "Locked" : "\(model.enabledRoachClawContextCount) lanes")
                }

                roachClawContextAccessDeck

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                    Button(canSaveLatestReply ? "Save" : "Await Reply") {
                        model.saveLatestRoachClawResponseToRoachBrain()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(!canSaveLatestReply)

                    Button(model.isSpeakingLatestReply ? "Stop" : "Listen") {
                        model.toggleLatestReplySpeech()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.latestRoachClawReply == nil)

                    Button(model.isDictatingPrompt ? "Stop Voice" : "Voice") {
                        Task { await model.togglePromptDictation() }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("Local") {
                        model.config.roachClawDefaultModel = recommendedQuickstartModel
                        model.selectedChatModel = recommendedQuickstartModel
                        Task { await model.applyRoachClawDefaults() }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.isApplyingDefaults)

                    Button("Models") {
                        openNativeSettings(.models)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
            }
        }
    }

    private var roachClawContextAccessDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoachSectionHeader(
                "Context",
                title: "Context.",
                detail: nil
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
                                .lineLimit(1)
                                .truncationMode(.tail)
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

                Text(isActive ? "Active" : "Use")
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

                TextField("Ask RoachClaw", text: $model.promptDraft, axis: .vertical)
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
        let collections = mapDisplayCollections(from: model.snapshot?.mapCollections ?? [])
        let selectedCollection = selectedMapCollection(in: collections)
        let activeMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" && $0.status != "failed" } ?? []
        let failedMapDownloads = model.snapshot?.downloads.filter { $0.filetype == "map" && $0.status == "failed" } ?? []
        let installedCount = collections.filter(\.isReady).count
        let totalResources = collections.reduce(0) { $0 + $1.totalCount }
        let readyResources = collections.reduce(0) { $0 + $1.installedCount }
        let selectedActionKey = selectedCollection.map { "map-\($0.slug)" }

        return VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.cyan) {
                VStack(alignment: .leading, spacing: 16) {
                    responsiveBar {
                        RoachSectionHeader(
                            "RoachAtlas",
                            title: "Atlas.",
                            detail: nil
                        )
                    } actions: {
                        Button {
                            Task { await model.downloadBaseMapAssets() }
                        } label: {
                            Label(model.activeActions.contains("maps-base-assets") ? "Installing" : "Install Base", systemImage: "square.and.arrow.down.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.activeActions.contains("maps-base-assets"))

                        Button {
                            model.selectedPane = .maps
                        } label: {
                            Label("Native Atlas", systemImage: "map.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    Picker("Map mode", selection: $mapViewerMode) {
                        ForEach(RoachMapViewerMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                        RoachMetricCard(label: "Packs", value: "\(installedCount) / \(collections.count)", detail: "Installed")
                        RoachMetricCard(label: "Resources", value: "\(readyResources) / \(totalResources)", detail: "Ready")
                        RoachMetricCard(label: "Phone", value: phoneLocationBridge.statusLabel, detail: phoneLocationBridge.latestFix?.coordinateLabel ?? "No fix")
                        RoachMetricCard(label: "Trace", value: "\(phoneLocationBridge.routeSamples.count)", detail: phoneLocationBridge.routeSamples.isEmpty ? "No samples" : "Samples")
                    }

                    if !activeMapDownloads.isEmpty {
                        downloadsPanel(title: "Map Downloads", jobs: activeMapDownloads)
                    }

                    if !failedMapDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            RoachNotice(
                                title: "Map downloads need another pass",
                                detail: "\(failedMapDownloads.count) failed jobs.",
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

            RoachNativeMapViewer(
                collection: selectedCollection,
                mode: mapViewerMode,
                zoomLevel: $mapZoomLevel,
                latestFix: phoneLocationBridge.latestFix,
                routeSamples: phoneLocationBridge.routeSamples,
                installBusy: selectedActionKey.map { model.activeActions.contains($0) } ?? false,
                onInstallSelected: {
                    guard let selectedCollection else { return }
                    Task { await model.downloadMapCollection(selectedCollection.slug) }
                },
                onOpenWebAtlas: {
                    model.selectedPane = .maps
                }
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    RoachPhoneTrackingPanel(
                        bridge: phoneLocationBridge,
                        manualPayload: $manualPhoneGPSPayload
                    )
                    .frame(minWidth: 360, idealWidth: 440, maxWidth: 520)

                    RoachMapSourceReadinessPanel(
                        sources: RoachOpenMapSource.defaults,
                        selectedCollection: selectedCollection,
                        routeSamples: phoneLocationBridge.routeSamples
                    )
                }

                VStack(alignment: .leading, spacing: 16) {
                    RoachPhoneTrackingPanel(
                        bridge: phoneLocationBridge,
                        manualPayload: $manualPhoneGPSPayload
                    )

                    RoachMapSourceReadinessPanel(
                        sources: RoachOpenMapSource.defaults,
                        selectedCollection: selectedCollection,
                        routeSamples: phoneLocationBridge.routeSamples
                    )
                }
            }

            RoachMapPackShelf(
                collections: collections,
                selectedSlug: $selectedMapCollectionSlug,
                activeActionIDs: model.activeActions
            )
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
        let installedPackCount = installedMapCollections.count
            + installedEducationCategories.count
            + (installedWikipediaOption == nil ? 0 : 1)
            + installedModelNames.count

        return VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.bronze) {
                VStack(alignment: .leading, spacing: 10) {
                    responsiveBar {
                        RoachSectionHeader(
                            "Vault",
                            title: "Vault.",
                            detail: nil
                        )
                    } actions: {
                        Button("Import Vault") {
                            model.importObsidianVault()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button("Open Storage") {
                            model.openStorageInFinder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            }

            RoachArchiveVaultPanel(model: model, store: model.roachArchiveStore)
                .layoutPriority(2)

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Vault Lanes",
                        title: "Fast shelves.",
                        detail: nil
                    )

                    knowledgeHeroLaunchDeck(
                        archivesCount: archives.count,
                        mapCollectionCount: mapCollectionCount,
                        educationCategoryCount: educationCategoryCount,
                        installedModelCount: installedModelNames.count
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    knowledgeOverviewPanel(
                        activeImportedVaultName: activeImportedVaultName,
                        importedVaultCount: importedVaults.count,
                        filesCount: files.count,
                        archivesCount: archives.count,
                        installedPackCount: installedPackCount,
                        installedModelCount: installedModelNames.count
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    knowledgeSignalDeck(
                        filesCount: files.count,
                        importedVaultCount: importedVaults.count,
                        archivesCount: archives.count,
                        installedPackCount: installedPackCount
                    )
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                }

                VStack(alignment: .leading, spacing: 14) {
                    knowledgeOverviewPanel(
                        activeImportedVaultName: activeImportedVaultName,
                        importedVaultCount: importedVaults.count,
                        filesCount: files.count,
                        archivesCount: archives.count,
                        installedPackCount: installedPackCount,
                        installedModelCount: installedModelNames.count
                    )

                    knowledgeSignalDeck(
                        filesCount: files.count,
                        importedVaultCount: importedVaults.count,
                        archivesCount: archives.count,
                        installedPackCount: installedPackCount
                    )
                }
            }

            if !archives.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Captured Web",
                                title: "Captured sites.",
                                detail: nil
                            )
                        } actions: {
                            Button("Open Captures") {
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
                                        actionLabel: "Open capture",
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
                                title: "Shared markdown vaults.",
                                detail: nil
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
                                        detail: "Same markdown files.",
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

            if let selectedImportedVault, !importedVaultNotes.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        responsiveBar {
                            RoachSectionHeader(
                                "Notes Lane",
                                title: selectedImportedVault.name,
                                detail: nil
                            )
                        } actions: {
                            Button("Reveal Vault") {
                                model.openImportedVaultInFinder(selectedImportedVault)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
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
                                title: "Installed packs.",
                                detail: nil
                            )
                        } actions: {
                            Button("Open Apps") {
                                openNativeSettings(.apps)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        LazyVGrid(columns: vaultShelfColumns, alignment: .leading, spacing: 12) {
                            ForEach(installedMapCollections) { collection in
                                Button {
                                    Task { await model.openRoute("/maps", title: collection.name) }
                                } label: {
                                    VaultVirtualShelfCard(
                                        title: collection.name,
                                        detail: collection.description ?? "Offline region pack.",
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
                                            detail: installedTier.description ?? category.description ?? "Offline reference shelf.",
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
                                        detail: installedWikipediaOption.description ?? "Selected Wikipedia pack.",
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
                                        detail: "Local model pack.",
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
                    VStack(alignment: .leading, spacing: 14) {
                        RoachNotice(
                            title: "Vault shelf is empty",
                            detail: "Import a vault or drop files into storage.",
                            accent: RoachPalette.cyan,
                            systemName: "books.vertical.fill"
                        )

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Button {
                                    model.importObsidianVault()
                                } label: {
                                    Label("Import Vault", systemImage: "square.stack.3d.up.badge.plus")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())

                                Button {
                                    model.openStorageInFinder()
                                } label: {
                                    Label("Open Storage", systemImage: "externaldrive.fill")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    model.importObsidianVault()
                                } label: {
                                    Label("Import Vault", systemImage: "square.stack.3d.up.badge.plus")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())

                                Button {
                                    model.openStorageInFinder()
                                } label: {
                                    Label("Open Storage", systemImage: "externaldrive.fill")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }
                    }
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
                                    case .archive:
                                        return ["Open in RoachNet", "Archive"]
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isVaultDropTarget) { providers in
            model.importDroppedVaultProviders(providers)
        }
        .overlay(alignment: .topTrailing) {
            if isVaultDropTarget {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 16, weight: .bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop into Vault")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Text("Files and folders get copied. No rental shelf involved.")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(RoachPalette.text)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RoachPalette.green.opacity(0.72), lineWidth: 1)
                )
                .shadow(color: RoachPalette.green.opacity(0.22), radius: 18, x: 0, y: 8)
                .padding(14)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: isVaultDropTarget)
    }

    private func knowledgeHeroLaunchDeck(
        archivesCount: Int,
        mapCollectionCount: Int,
        educationCategoryCount: Int,
        installedModelCount: Int
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
            homeHeroActionCard(
                title: "Captured Web",
                detail: archivesCount == 0 ? "Open or start the capture shelf." : "\(archivesCount) mirrors on shelf.",
                systemImage: "globe.badge.chevron.backward",
                accent: RoachPalette.cyan
            ) {
                Task { await model.openRoute("/site-archives", title: "Offline Web Apps") }
            }

            homeHeroActionCard(
                title: "RoachAtlas",
                detail: mapCollectionCount == 0 ? "Open the atlas lane." : "\(mapCollectionCount) atlas packs ready.",
                systemImage: "map.fill",
                accent: RoachPalette.cyan
            ) {
                model.selectedPane = .maps
            }

            homeHeroActionCard(
                title: "Study Shelf",
                detail: educationCategoryCount == 0 ? "Open docs and reference lanes." : "\(educationCategoryCount) study shelves staged.",
                systemImage: "graduationcap.fill",
                accent: RoachPalette.green
            ) {
                Task { await model.openRoute("/docs/home", title: "Study Shelf") }
            }

            homeHeroActionCard(
                title: "Model Shelf",
                detail: installedModelCount == 0 ? "Open the model store." : "\(installedModelCount) local models on disk.",
                systemImage: "brain.head.profile",
                accent: RoachPalette.magenta
            ) {
                openNativeSettings(.models)
            }
        }
    }

    private func knowledgeOverviewPanel(
        activeImportedVaultName: String,
        importedVaultCount: Int,
        filesCount: Int,
        archivesCount: Int,
        installedPackCount: Int,
        installedModelCount: Int
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Index",
                    title: "Local inventory.",
                    detail: nil
                )

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Active vault",
                        value: importedVaultCount == 0 ? "No live vault" : activeImportedVaultName,
                        detail: importedVaultCount == 0 ? "Bring a markdown shelf in." : "\(importedVaultCount) linked vaults",
                        systemName: "books.vertical.fill",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Captured web",
                        value: "\(archivesCount)",
                        detail: archivesCount == 0 ? "No captures yet" : "Mirrors on the shelf",
                        systemName: "globe.badge.chevron.backward",
                        accent: RoachPalette.cyan
                    )
                    RoachDigestRow(
                        "Files",
                        value: "\(filesCount)",
                        detail: filesCount == 0 ? "Shelf still empty" : "Open inside RoachNet",
                        systemName: "doc.fill",
                        accent: RoachPalette.green
                    )
                    RoachDigestRow(
                        "Installed packs",
                        value: "\(installedPackCount)",
                        detail: installedModelCount == 0 ? "Atlas, study, and wiki" : "\(installedModelCount) model packs included",
                        systemName: "shippingbox.fill",
                        accent: RoachPalette.bronze
                    )
                }
            }
        }
    }

    private func knowledgeSignalDeck(
        filesCount: Int,
        importedVaultCount: Int,
        archivesCount: Int,
        installedPackCount: Int
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Counts",
                    title: "Vault totals.",
                    detail: nil
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    RoachMetricCard(
                        label: "Files",
                        value: "\(filesCount)",
                        detail: filesCount == 0 ? "No files yet" : "Ready to open"
                    )
                    RoachMetricCard(
                        label: "Vaults",
                        value: "\(importedVaultCount)",
                        detail: importedVaultCount == 0 ? "Nothing linked" : "Markdown shelves linked"
                    )
                    RoachMetricCard(
                        label: "Captures",
                        value: "\(archivesCount)",
                        detail: archivesCount == 0 ? "No mirrors yet" : "Stored offline"
                    )
                    RoachMetricCard(
                        label: "Packs",
                        value: "\(installedPackCount)",
                        detail: installedPackCount == 0 ? "Nothing staged" : "Atlas, study, wiki, and models"
                    )
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
        case .archive:
            return "Archive"
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
        case .archive:
            return "archivebox.fill"
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
        case .archive:
            return RoachPalette.cyan
        case .folder:
            return RoachPalette.cyan
        default:
            return RoachPalette.cyan
        }
    }

    private func vaultFilePreviewHint(for file: String) -> String {
        switch VaultPreviewKind.resolve(for: URL(fileURLWithPath: file)) {
        case .book:
            return "Open in the built-in reader."
        case .video:
            return "Open in the video lane."
        case .audio:
            return "Play in the listening surface."
        case .markdown:
            return "Preview the note in place."
        case .text:
            return "Open in the text deck."
        case .image:
            return "Open in the lightbox."
        case .pdf:
            return "Open in the built-in reader."
        case .archive:
            return "Inspect the compressed package."
        case .folder:
            return "Open the folder in Vault."
        default:
            return "Open inside RoachNet."
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
        case .archive:
            return "Inspect"
        default:
            return "Preview"
        }
    }

    private func importedVaultNoteDetail(noteURL: URL, vault: ImportedObsidianVault) -> String {
        let vaultRoot = vault.url.standardizedFileURL.path + "/"
        let relativePath = noteURL.standardizedFileURL.path.replacingOccurrences(of: vaultRoot, with: "")
        return "Open \(relativePath) from the linked vault."
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
                            title: "Runtime console.",
                            detail: nil
                        )
                    } actions: {
                        Button(model.isLoading ? "Refreshing..." : "Refresh Runtime") {
                            Task { await model.refreshRuntimeState() }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(model.isLoading)
                        Button("Settings") {
                            openNativeSettings()
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
                            .frame(minWidth: 340, idealWidth: 380, maxWidth: 430)
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
                                detail: "\(failedDownloads.count) failed jobs in queue history.",
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
                                title: account.linked ? "Linked." : "Local account.",
                                detail: nil
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
                                title: roachTail.enabled ? "Device bridge on." : "Device bridge off.",
                                detail: nil
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

                        if let controlPlane = roachTail.controlPlane {
                            let policy = controlPlane.policyMode ?? "local-owner"
                            let approval = controlPlane.routeApproval ?? "owner-local"
                            RoachStatusRow(
                                title: "Control Plane",
                                value: "\(controlPlane.provider) · \(policy) · routes \(approval)",
                                accent: RoachPalette.green
                            )

                            if let dnsName = controlPlane.dnsName, !dnsName.isEmpty {
                                RoachStatusRow(title: "RoachTail DNS", value: dnsName, accent: RoachPalette.green)
                            }
                        }

                        if let bridgeURL = roachTail.advertisedUrl, !bridgeURL.isEmpty {
                            RoachStatusRow(title: "Bridge URL", value: bridgeURL, accent: RoachPalette.green)
                        } else if let companionURL = serverInfo?.companionAdvertisedUrl ?? serverInfo?.companionUrl {
                            RoachStatusRow(title: "Bridge URL", value: companionURL, accent: RoachPalette.green)
                        }

                        if let relayMode = roachTail.derpMap?.mode, !relayMode.isEmpty {
                            let relayHost = roachTail.derpMap?.regions?.first?.host ?? roachTail.relayHost ?? "local bridge"
                            RoachStatusRow(
                                title: "Relay Map",
                                value: "\(relayMode.replacingOccurrences(of: "-", with: " ")) · \(relayHost)",
                                accent: relayMode == "custom-relay" ? RoachPalette.magenta : RoachPalette.green
                            )
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

                        if let keys = roachTail.preAuthKeys, !keys.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Join Keys")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)

                                ForEach(keys.prefix(3)) { key in
                                    RoachStatusRow(
                                        title: key.used == true ? "Spent key" : "Active key",
                                        value: key.expiresAt.map { "Expires \($0)" } ?? "No expiry reported",
                                        accent: key.used == true ? RoachPalette.muted : RoachPalette.green
                                    )
                                }
                            }
                        }

                        if let routes = roachTail.routes, !routes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Approved Routes")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)

                                ForEach(routes.prefix(4)) { route in
                                    RoachStatusRow(
                                        title: route.id.replacingOccurrences(of: "-", with: " ").capitalized,
                                        value: "\(route.type ?? "route") · \(route.target ?? "pending")",
                                        accent: route.advertised == true ? RoachPalette.green : RoachPalette.muted
                                    )
                                }
                            }
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

                                        Text("The phone mints its peer token during pairing.")
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
                                title: roachSync.enabled ? "Sync on." : "Sync off.",
                                detail: nil
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
                        RoachSectionHeader("Storage", title: "Content root.", detail: nil)
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
                    Text(RuntimeSurfacePathLabel.displayDetail(model.storagePath, kind: .storageRoot))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Maps, Wikipedia packages, archives, and logs use this root.")
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
                    detail: "Ollama / OpenClaw"
                )
            }
        }
    }

    private var summaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)]
    }

    private var vaultShelfColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)]
    }

    private func mapDisplayCollections(from collections: [MapCuratedCollection]) -> [RoachMapCollectionDisplay] {
        collections.map { collection in
            let resourceTitles = collection.resources.map(\.title)
            let installedCount = max(0, collection.installed_count ?? 0)
            let totalCount = max(collection.total_count ?? collection.resources.count, collection.resources.count)
            return RoachMapCollectionDisplay(
                slug: collection.slug,
                name: collection.name,
                detail: collection.description ?? "Offline region pack.",
                installedCount: installedCount,
                totalCount: totalCount,
                resourceCount: collection.resources.count,
                resourceTitles: resourceTitles
            )
        }
    }

    private func selectedMapCollection(in collections: [RoachMapCollectionDisplay]) -> RoachMapCollectionDisplay? {
        if let selectedMapCollectionSlug,
           let selected = collections.first(where: { $0.slug == selectedMapCollectionSlug }) {
            return selected
        }

        return collections.first(where: \.isReady) ?? collections.first
    }

    private var homeGridItems: [CommandGridItem] {
        [
            CommandGridItem(
                id: "maps",
                title: "RoachAtlas",
                detail: "Native maps, phone GPS, offline regions.",
                badge: "Native",
                systemImage: "map.fill",
                routePath: "",
                isInstalled: true,
                pane: .maps
            ),
            CommandGridItem(
                id: "roacharcade",
                title: "RoachArcade",
                detail: "ROMs, Mac games, mods, cheats.",
                badge: "Native",
                systemImage: "gamecontroller.fill",
                routePath: "",
                isInstalled: true,
                pane: .arcade
            ),
            CommandGridItem(
                id: "ai-control",
                title: "AI Control",
                detail: "Local models, memory, no server landlord.",
                badge: "Runtime",
                systemImage: "cpu.fill",
                routePath: "/settings/ai",
                isInstalled: true
            ),
            CommandGridItem(
                id: "easy-setup",
                title: "Easy Setup",
                detail: "Install once. Quit babysitting it.",
                badge: setupBadge,
                systemImage: "bolt.fill",
                routePath: "/easy-setup",
                isInstalled: true
            ),
            CommandGridItem(
                id: "offline-web",
                title: "Web Shelf",
                detail: "Saved pages. Fewer dead-tab fossils.",
                badge: "Vault",
                systemImage: "globe.badge.chevron.backward",
                routePath: "/site-archives",
                isInstalled: true
            ),
            CommandGridItem(
                id: "install-apps",
                title: "Install Apps",
                detail: "Packs worth dragging home.",
                badge: "App Store",
                systemImage: "square.grid.2x2.fill",
                routePath: "/settings/apps",
                isInstalled: true
            ),
            CommandGridItem(
                id: "docs",
                title: "Study Shelf",
                detail: "Docs with a pulse.",
                badge: "Vault",
                systemImage: "doc.text.fill",
                routePath: "/docs/home",
                isInstalled: true
            ),
            CommandGridItem(
                id: "settings",
                title: "Settings",
                detail: "Knobs, paths, escape hatches.",
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
        let runtimeLogPath = model.snapshot?.serverInfo.logPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveRuntimeLogPath = runtimeLogPath.flatMap { $0.isEmpty ? nil : $0 }
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
                keywords: [pane.rawValue, pane.subtitle, "module", "pane"],
                aliases: [pane.rawValue.lowercased(), pane.icon]
            )
        }

        let routeEntries = homeGridItems.map { item in
            let target: CommandPaletteTarget = item.id == "settings"
                ? .openNativeSettings
                : item.pane.map { .pane($0) } ?? .route(title: item.title, path: item.routePath)

            return CommandPaletteEntry(
                id: "route-\(item.id)",
                section: "Open",
                title: item.title,
                detail: item.detail,
                systemImage: item.systemImage,
                target: target,
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
                    keywords: ["health", "services", "reload", "snapshot"],
                    aliases: ["restart status", "pulse check"],
                    previewNote: "No ceremony. It asks the local runtime what is alive right now."
                ),
                CommandPaletteEntry(
                    id: "action-check-updates",
                    section: "Runtime",
                    title: "Check for Updates",
                    detail: "Ask the local release lane if a newer RoachNet build is ready.",
                    systemImage: "arrow.down.circle.fill",
                    target: .checkForUpdates,
                    badge: model.latestVersionLabel,
                    keywords: ["update", "updates", "release", "latest", "download", "installer"],
                    aliases: ["upgrade", "new version", "release lane"],
                    previewNote: "Checks the public release lane. Your files stay where they are."
                ),
                CommandPaletteEntry(
                    id: "action-request-system-update",
                    section: "Runtime",
                    title: model.canRequestSystemUpdate ? "Install Available Update" : "Open Update Lane",
                    detail: model.canRequestSystemUpdate
                        ? "Hand the update to the contained runtime and replace the current build cleanly."
                        : model.latestVersionDetail,
                    systemImage: model.canRequestSystemUpdate ? "arrow.down.app.fill" : "gearshape.arrow.triangle.2.circlepath",
                    target: model.canRequestSystemUpdate
                        ? .requestSystemUpdate
                        : .route(title: "Updates", path: "/settings/update"),
                    badge: model.systemUpdateStageLabel,
                    keywords: ["update", "install", "upgrade", "release", "latest", "settings"],
                    aliases: ["upgrade roachnet", "install update"],
                    previewNote: model.canRequestSystemUpdate
                        ? "Hands the update to the contained installer instead of making you hunt for the bits."
                        : "Opens the update lane so the current machine can tell you what it knows."
                ),
                CommandPaletteEntry(
                    id: "action-copy-diagnostics",
                    section: "Runtime",
                    title: "Copy System Snapshot",
                    detail: "Copy version, paths, services, model route, and update state. No vault contents.",
                    systemImage: "doc.text.magnifyingglass",
                    target: .copyDiagnostics,
                    badge: model.snapshot == nil ? "No snapshot" : "Ready",
                    keywords: ["diagnostics", "debug", "support", "status", "snapshot", "bug"],
                    aliases: ["copy debug", "support bundle", "bug report"],
                    previewNote: "A clean handoff for bug reports and release checks. The vault stays out of it."
                ),
                CommandPaletteEntry(
                    id: "action-open-runtime-log",
                    section: "Runtime",
                    title: "Open Runtime Log",
                    detail: liveRuntimeLogPath != nil
                        ? "Open the local runtime log. The machine leaves tracks."
                        : "Runtime has not reported a log path yet.",
                    systemImage: "doc.text.fill",
                    target: .revealPath(liveRuntimeLogPath ?? storagePath),
                    badge: liveRuntimeLogPath.map { RuntimeSurfacePathLabel.displayValue($0, kind: .logFile) } ?? "Waiting",
                    keywords: ["log", "logs", "runtime", "debug", "server", "stderr", "stdout"],
                    aliases: ["open logs", "show log", "tail"],
                    previewNote: "Useful when the polite UI stops being useful."
                ),
                CommandPaletteEntry(
                    id: "action-launch-guide",
                    section: "Open",
                    title: "Open Guided Tour",
                    detail: "Open the native field guide for lanes, packs, vault, games, maps, and updates.",
                    systemImage: "play.rectangle.fill",
                    target: .launchGuide,
                    keywords: ["guide", "tour", "help", "walkthrough", "field", "v105", "model", "packs", "updates"],
                    aliases: ["getting started", "intro", "first run", "launch guide"],
                    previewNote: "Replays the polished guide without resetting the install."
                ),
                CommandPaletteEntry(
                    id: "action-open-about",
                    section: "Open",
                    title: "About RoachNet",
                    detail: "Open the native credits, links, version, and local-first notes.",
                    systemImage: "info.circle.fill",
                    target: .openAbout,
                    badge: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Local",
                    keywords: ["about", "credits", "version", "paypal", "donate", "github", "roachwares"],
                    aliases: ["credits", "version info", "company"],
                    previewNote: "Credits, build details, and the small print. The part people read after something breaks."
                ),
                CommandPaletteEntry(
                    id: "action-open-storage-root",
                    section: "Workspace",
                    title: "Open Storage Library",
                    detail: "Reveal the contained library root where vault files, installs, and local RoachNet state stay on disk.",
                    systemImage: "externaldrive.connected.to.line.below.fill",
                    target: .revealPath(storagePath),
                    badge: shortRuntimePath(storagePath),
                    keywords: ["storage", "library", "vault", "disk", "files", storagePath],
                    aliases: ["open files", "reveal storage", "show vault root"],
                    previewNote: "Opens the actual folder. Not a dashboard pretending to be custody."
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
                    keywords: ["obsidian", "vault", "markdown", "notes", "import"],
                    aliases: ["import notes", "markdown vault"],
                    previewNote: "Points RoachNet at the vault you already own. No new note format gets invented."
                ),
                CommandPaletteEntry(
                    id: "action-open-model-store",
                    section: "RoachClaw",
                    title: "Open Model Store",
                    detail: "Jump straight into RoachClaw's local and cloud model shelf.",
                    systemImage: "shippingbox.fill",
                    target: .route(title: "Model Store", path: "/settings/models"),
                    badge: model.selectedChatModelLabel,
                    keywords: ["models", "ollama", "cloud", "store", "ai"],
                    aliases: ["llm", "local ai", "weights"],
                    previewNote: "Model weights belong on disk first. Cloud can wait outside."
                ),
                CommandPaletteEntry(
                    id: "action-stage-cookbook-check",
                    section: "RoachClaw",
                    title: "Stage Cookbook Check",
                    detail: "Ask RoachClaw to scan the machine, pick a model lane, and explain the fit without hardware theater.",
                    systemImage: "cpu.fill",
                    target: .stagePrompt("Run a RoachClaw Cookbook check for this machine. Use the current hardware, installed models, and runtime state. Recommend the best local model lane, explain the tradeoffs briefly, and name the next install if one is missing."),
                    badge: "Fit",
                    keywords: ["cookbook", "model fit", "hardware", "recommend", "roachclaw", "local model"],
                    aliases: ["model recommendation", "hardware scan", "fit check"],
                    previewNote: "RoachNet-native model fit, contained in the local runtime."
                ),
                CommandPaletteEntry(
                    id: "action-stage-deep-research",
                    section: "RoachClaw",
                    title: "Stage Deep Research Brief",
                    detail: "Queue a research plan that gathers sources, reads them, and saves the answer instead of spraying tabs.",
                    systemImage: "doc.text.magnifyingglass",
                    target: .stagePrompt("Plan a RoachClaw Deep Research run. Start with the question, identify the source types to gather, define how you will verify them, then produce a concise brief I can save to the vault."),
                    badge: "Research",
                    keywords: ["deep research", "research", "sources", "brief", "summarize"],
                    aliases: ["source brief", "research plan", "investigate"],
                    previewNote: "Designed for local notes and captured web context first."
                ),
                CommandPaletteEntry(
                    id: "action-stage-model-compare",
                    section: "RoachClaw",
                    title: "Stage Model Compare",
                    detail: "Set up a blind model comparison so the loudest answer does not win by default.",
                    systemImage: "rectangle.split.2x1.fill",
                    target: .stagePrompt("Compare two RoachClaw model routes on the same task. Hide the model labels until after scoring, judge accuracy, speed, clarity, and local suitability, then recommend the route I should keep."),
                    badge: "A/B",
                    keywords: ["compare", "models", "blind", "benchmark", "route"],
                    aliases: ["model a b", "blind compare", "route compare"],
                    previewNote: "Useful when one model sounds confident and the other may actually be right."
                ),
                CommandPaletteEntry(
                    id: "action-stage-memory-skills-audit",
                    section: "RoachClaw",
                    title: "Stage Memory and Skills Audit",
                    detail: "Ask RoachClaw to find useful context, stale habits, and saved procedures worth keeping.",
                    systemImage: "brain.head.profile",
                    target: .stagePrompt("Audit the current RoachBrain memories and skills. Identify stale or duplicated context, name the useful procedures worth keeping, and suggest one cleanup action that will make future prompts sharper."),
                    badge: "Memory",
                    keywords: ["memory", "skills", "roachbrain", "audit", "context"],
                    aliases: ["skill audit", "memory cleanup", "context audit"],
                    previewNote: "Keeps the agent useful without letting the memory shelf become a junk drawer."
                ),
                CommandPaletteEntry(
                    id: "action-stage-agent-monitor",
                    section: "RoachClaw",
                    title: "Stage Agent Monitor Review",
                    detail: "Review live runs, replay crumbs, tool cards, and event counters from the local RoachClaw lane.",
                    systemImage: "bolt.badge.clock.fill",
                    target: .stagePrompt("Review the RoachClaw Agent Monitor lane. Summarize active runs, replay crumbs, tool-index coverage, local event counters, and anything that looks noisy or stuck. Keep it practical and name the next safe action."),
                    badge: "Monitor",
                    keywords: ["agent", "monitor", "runs", "activity", "events", "tool index", "orchestration"],
                    aliases: ["activity monitor", "run history", "agent runs", "local agents"],
                    previewNote: "Activity Monitor energy, but for local RoachClaw work instead of random processes."
                ),
                CommandPaletteEntry(
                    id: "action-stage-context-compaction",
                    section: "RoachClaw",
                    title: "Stage Context Compaction",
                    detail: "Compress the thread into goals, decisions, files, blockers, and next moves before the context gets bloated.",
                    systemImage: "text.badge.checkmark",
                    target: .stagePrompt("Create a RoachClaw context compaction. Preserve the user goal, files touched, decisions, blockers, validation evidence, and the next move. Remove chatter and keep only what future work needs."),
                    badge: "Context",
                    keywords: ["context", "compaction", "summary", "memory", "thread", "cursor", "side panel"],
                    aliases: ["summarize context", "compact thread", "context rail"],
                    previewNote: "The contextual side panel should remember the useful bits, not every sentence."
                ),
                CommandPaletteEntry(
                    id: "action-stage-tool-index",
                    section: "RoachClaw",
                    title: "Stage Tool Index Entry",
                    detail: "Turn a native action into a searchable RoachClaw tool card with scope and safety boundaries.",
                    systemImage: "wrench.and.screwdriver.fill",
                    target: .stagePrompt("Design a RoachClaw tool-index entry for the current task. Include name, category, trigger hints, what it can touch, what it must never touch, and when it should be suggested by the command bar."),
                    badge: "Tools",
                    keywords: ["tool", "index", "mcp", "actions", "raycast", "command bar"],
                    aliases: ["tool card", "action index", "command index"],
                    previewNote: "A Raycast-style index is only useful if the actions are scoped and easy to find."
                ),
                CommandPaletteEntry(
                    id: "action-stage-orchestration",
                    section: "RoachClaw",
                    title: "Stage Multi-Agent Orchestration",
                    detail: "Assign local agents roles, context budgets, handoffs, and finish lines before they start making noise.",
                    systemImage: "rectangle.3.group.fill",
                    target: .stagePrompt("Plan a RoachClaw multi-agent orchestration pass. Define each agent role, allowed context, tool boundaries, handoff format, success evidence, and stop condition. Keep it local-first and RoachNet branded."),
                    badge: "Orchestrate",
                    keywords: ["orchestration", "multi agent", "monet", "agents", "handoff", "roles"],
                    aliases: ["agent team", "multi-agent", "orchestrate"],
                    previewNote: "Multi-agent work should look managed, not like a pile of tabs arguing."
                ),
                CommandPaletteEntry(
                    id: "action-open-roachclaw-anywhere",
                    section: "RoachClaw",
                    title: "Open RoachClaw Anywhere",
                    detail: "Float chat, voice, memory, and context controls over the current RoachNet surface.",
                    systemImage: "sparkles",
                    target: .openGlobalRoachClaw,
                    badge: "Global",
                    keywords: ["roachclaw", "assistant", "chat", "voice", "global", "anywhere"],
                    aliases: ["ai overlay", "ask ai", "chat anywhere"],
                    previewNote: "Opens RoachClaw over the current surface so the app can stay in context."
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
                    target: .openNativeSettings,
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
            return commandPaletteEntries.filter {
                $0.section == "Runtime"
                    || $0.id == "pane-Runtime"
                    || $0.id == "action-check-updates"
                    || $0.id == "action-request-system-update"
                    || $0.id == "action-copy-diagnostics"
                    || $0.id == "action-open-runtime-log"
            }
        case .maps:
            return commandPaletteEntries.filter {
                $0.id == "pane-Maps"
                    || $0.id == "route-maps"
                    || $0.id == "action-refresh-runtime"
                    || $0.id == "action-open-storage-root"
            }
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
                    || $0.id == "action-copy-diagnostics"
                    || $0.id == "action-open-runtime-log"
                    || $0.id == "action-check-updates"
                    || $0.id == "action-open-roachclaw-anywhere"
                    || $0.id == "action-voice-prompt"
                    || $0.id == "action-open-model-store"
                    || $0.id == "action-open-about"
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
            if !openNativeSettings(forInternalPath: path) {
                Task { await model.openRoute(path, title: title) }
            }
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
        case .openNativeSettings:
            openNativeSettings()
        case .openAbout:
            RoachNetAboutWindowPresenter.shared.present()
        case .checkForUpdates:
            openNativeSettings(.updates)
            Task { await model.checkForRoachNetUpdates(force: true) }
        case .requestSystemUpdate:
            openNativeSettings(.updates)
            if model.canRequestSystemUpdate {
                Task { await model.requestRoachNetUpdate() }
            }
        case .copyDiagnostics:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(commandPaletteDiagnosticsSnapshot(), forType: .string)
            model.statusLine = "Copied RoachNet diagnostics."
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
                openNativeSettings(.roachClaw)
                return
            }
            model.selectedChatModel = modelName
        case let .externalURL(urlString):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func commandPaletteDiagnosticsSnapshot() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "local"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        let runtimeState = model.snapshot == nil ? "waiting" : "live"
        let accountState = model.snapshot?.account.linked == true ? "linked" : "local"
        let serviceCount = model.snapshot?.services.count ?? 0
        let installedServiceCount = model.snapshot?.services.filter { $0.installed ?? false }.count ?? 0
        let roachClawState = model.snapshot?.roachClaw.ready == true ? "ready" : "staging"
        let logPath = model.snapshot?.serverInfo.logPath ?? "not reported"

        return """
        RoachNet diagnostics
        Version: \(version) (\(build))
        Setup: \(model.setupCompleted ? "complete" : "incomplete")
        Runtime: \(runtimeState)
        Account: \(accountState)
        Active pane: \(activePane.rawValue)
        Install: \(model.installPath)
        Storage: \(model.storagePath)
        Log: \(logPath)
        Services: \(installedServiceCount)/\(serviceCount) installed
        RoachClaw: \(roachClawState)
        Model: \(model.selectedChatModelLabel)
        Latest release: \(model.latestVersionLabel)
        Update lane: \(model.systemUpdateStageLabel)
        """
    }

    private func recordRecentCommand(_ entry: CommandPaletteEntry) {
        var ids = recentCommandPaletteIDs.filter { $0 != entry.id }
        ids.insert(entry.id, at: 0)
        recentCommandPaletteIDsRaw = ids.prefix(10).joined(separator: "|")
    }

    private func presentDetachedCommandPalette() {
        showCommandPalette = false
        detachedPaletteCoordinator.present(
            entries: commandPaletteEntries,
            featuredEntries: featuredCommandPaletteEntries,
            recentEntries: recentCommandPaletteEntries
        ) { entry in
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
        WorkspacePane.allCases.filter { $0 != .suite && $0 != .education }
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
                    "Status",
                    title: "Service state.",
                    detail: nil
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
                        detail: roachTail?.enabled == true ? "Private bridge" : "Bridge disabled"
                    )
                    RoachMetricCard(
                        label: "RoachSync",
                        value: roachSync?.enabled == true ? "\(roachSync?.peers.count ?? 0) peers" : "Off",
                        detail: roachSync?.enabled == true ? "Sync live" : "Sync disabled"
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
                    "Paths",
                    title: "Runtime roots.",
                    detail: nil
                )

                VStack(alignment: .leading, spacing: 10) {
                    RoachDigestRow(
                        "Install root",
                        value: RuntimeSurfacePathLabel.displayValue(model.installPath, kind: .installRoot),
                        detail: "App bundle root",
                        systemName: "shippingbox.fill",
                        accent: RoachPalette.green
                    )
                    RoachDigestRow(
                        "Storage root",
                        value: shortRuntimePath(model.storagePath),
                        detail: "Content and cache",
                        systemName: "externaldrive.fill",
                        accent: RoachPalette.cyan
                    )
                    RoachDigestRow(
                        "Server target",
                        value: runtimeTargetLabel(serverInfo?.target),
                        detail: "Active route",
                        systemName: "network",
                        accent: RoachPalette.magenta
                    )
                    RoachDigestRow(
                        "Private lanes",
                        value: "\(roachTail?.enabled == true ? "Tail" : "Tail off") · \(roachSync?.enabled == true ? "Sync" : "Sync off")",
                        detail: "Device bridge and sync",
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
        let accent = accent(for: pane)

        return Button {
            model.selectedPane = pane
        } label: {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(accent.opacity(0.14))

                            RoachModuleMark(
                                systemName: pane.icon,
                                assetName: pane.assetName,
                                size: 18,
                                isSelected: activePane == pane
                            )
                        }
                        .frame(width: 44, height: 44)

                        Spacer(minLength: 8)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(value)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                        Text(detail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Open lane")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            }
        }
        .buttonStyle(RoachCardButtonStyle())
    }

    private func homeMenuStrip(installedCount: Int, availableCount: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(HomeMenuSection.allCases) { section in
                    homeMenuButton(section, installedCount: installedCount, availableCount: availableCount)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(HomeMenuSection.allCases) { section in
                    homeMenuButton(section, installedCount: installedCount, availableCount: availableCount)
                }
            }
        }
    }

    private func homeMenuButton(
        _ section: HomeMenuSection,
        installedCount: Int,
        availableCount: Int
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                homeMenuSection = section
            }
        } label: {
            HStack(spacing: 10) {
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(homeMenuSection == section ? RoachPalette.text : RoachPalette.muted)
                Spacer(minLength: 10)
                Text(homeMenuCount(for: section, installedCount: installedCount, availableCount: availableCount))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(homeMenuSection == section ? paneAccent : RoachPalette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        homeMenuSection == section
                            ? paneAccent.opacity(0.14)
                            : RoachPalette.panelRaised.opacity(0.54)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        homeMenuSection == section ? paneAccent.opacity(0.22) : RoachPalette.border,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func homeMenuCount(
        for section: HomeMenuSection,
        installedCount: Int,
        availableCount: Int
    ) -> String {
        switch section {
        case .commandDeck:
            return "\(homeGridItems.count)"
        case .installedModules:
            return "\(installedCount)"
        case .availableModules:
            return "\(availableCount)"
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
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader("Modules", title: title, detail: detail)

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: descriptor.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isInstalled ? RoachPalette.green : RoachPalette.warning)
                        .frame(width: 38, height: 38)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(3)
                        .minimumScaleFactor(0.84)
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
            .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
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
        case "roachnet_kiwix_server":
            return (
                title: "RoachNet Library",
                detail: "Open offline encyclopedias, survival references, and field manuals without leaving the native shell.",
                badge: defaultBadge,
                systemImage: "books.vertical.fill"
            )
        case "roachnet_ollama":
            return (
                title: "RoachNet Chat",
                detail: "Run local AI chat and tooling with the model lane RoachNet is already managing.",
                badge: defaultBadge,
                systemImage: "sparkles"
            )
        case "roachnet_kolibri":
            return (
                title: "RoachNet Academy",
                detail: "Launch structured education content and offline coursework from the same command grid.",
                badge: defaultBadge,
                systemImage: "graduationcap.fill"
            )
        case "roachnet_flatnotes":
            return (
                title: "RoachNet Notes",
                detail: "Keep quick notes, fragments, and working references local to the machine.",
                badge: defaultBadge,
                systemImage: "note.text"
            )
        case "roachnet_cyberchef":
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(RoachPalette.green)
                        .frame(width: 40, height: 40)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                        .minimumScaleFactor(0.82)
                    Text(item.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(3)
                        .minimumScaleFactor(0.84)
                }

                HStack {
                    Text(item.isInstalled ? "Open" : "Install")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.isInstalled ? RoachPalette.green : RoachPalette.warning)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(step.accent)
                        .frame(width: 38, height: 38)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(3)
                        .minimumScaleFactor(0.84)
                }

                if let routePath = step.routePath {
                    if step.isReady {
                        Button("Review") {
                            if !openNativeSettings(forInternalPath: routePath) {
                                Task { await model.openRoute(routePath, title: step.title) }
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    } else {
                        Button("Fix This") {
                            if !openNativeSettings(forInternalPath: routePath) {
                                Task { await model.openRoute(routePath, title: step.title) }
                            }
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        }
    }

    private func footerAction(title: String, path: String) -> some View {
        Button(title) {
            if !openNativeSettings(forInternalPath: path) {
                Task { await model.openRoute(path, title: title) }
            }
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
@MainActor
final class RoachNetMacAppDelegate: NSObject, NSApplicationDelegate {
    static var bootstrapModel: WorkspaceModel?

    weak var model: WorkspaceModel? {
        didSet {
            flushPendingURLsIfNeeded()
        }
    }
    private var isHandlingTermination = false
    private var pendingURLs: [URL] = []
    private var commandPaletteHotKeyRef: EventHotKeyRef?
    private var commandPaletteHotKeyHandler: EventHandlerRef?
    private var fallbackWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        roachWindowDebug("Application did finish launching.")
        clearSavedState()
        NSApp.setActivationPolicy(.regular)
        registerCommandPaletteHotKey()
        bringPrimaryWindowForward()
        scheduleFallbackWindowIfNeeded()
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

    private func scheduleFallbackWindowIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            guard let self else { return }

            if NSApp.windows.contains(where: { $0.canBecomeKey || $0.isVisible }) {
                self.bringPrimaryWindowForward()
                return
            }

            guard let model = self.model ?? Self.bootstrapModel else {
                roachWindowDebug("Fallback window skipped because no workspace model is available.")
                return
            }

            let host = NSHostingController(
                rootView: RootWorkspaceView(model: model)
                    .background(MainWindowConfigurator())
                    .frame(minWidth: 760, idealWidth: 1360, minHeight: 580, idealHeight: 860)
            )
            let window = NSWindow(contentViewController: host)
            window.title = "RoachNet"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isRestorable = false
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 900, height: 640)
            window.setContentSize(NSSize(width: 1400, height: 900))
            window.center()

            let controller = NSWindowController(window: window)
            fallbackWindowController = controller
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            roachWindowDebug("Fallback main window created.")
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
