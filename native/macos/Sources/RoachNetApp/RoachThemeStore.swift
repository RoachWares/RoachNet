import AppKit
import Combine
import Foundation
import RoachNetCore
import RoachNetDesign
import SwiftUI

/// A theme the person can pick, and where it came from.
struct RoachThemeEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case builtIn
        case user
        case pack(id: String, name: String)
    }

    let document: RoachThemeDocument
    let source: Source
    /// The theme file, for user and pack themes.
    let file: URL?
    let issues: [RoachThemeIssue]

    var id: String { document.id }
    var baseURL: URL? { file?.deletingLastPathComponent() }
    var isUserTheme: Bool { source == .user }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }

    var sourceLabel: String {
        switch source {
        case .builtIn: return "Built in"
        case .user: return "Your themes"
        case .pack(_, let name): return name
        }
    }
}

struct RoachSnippetEntry: Identifiable, Equatable {
    let document: RoachThemeSnippetDocument
    let source: RoachThemeEntry.Source
    let file: URL?
    let issues: [RoachThemeIssue]

    var id: String { document.id }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }
}

/// Finds themes and snippets (built in, in `<storage>/themes`, and in enabled
/// packs), keeps the person's appearance settings, and applies the result to
/// `RoachThemeRuntime`, AppKit, and `<storage>/themes/active-theme.json` (read
/// by the runtime for the iOS companion).
@MainActor
final class RoachThemeStore: ObservableObject {
    static let shared = RoachThemeStore()

    @Published private(set) var themes: [RoachThemeEntry] = []
    @Published private(set) var snippets: [RoachSnippetEntry] = []
    @Published private(set) var settings = RoachThemeSettings()
    @Published private(set) var active: RoachResolvedTheme = RoachThemeRuntime.shared.untrackedTheme
    @Published private(set) var problems: [String] = []
    @Published var lastMessage: String?

    private(set) var storageRoot: URL
    private var revision = 0
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var appearanceObserver: NSObjectProtocol?
    private var bootstrapped = false

    init(storageRoot: URL? = nil) {
        self.storageRoot = storageRoot ?? Self.defaultStorageRoot()
    }

    static func defaultStorageRoot() -> URL {
        let config = RoachNetRepositoryLocator.readConfig()
        let installPath = config.installPath.isEmpty ? RoachNetRepositoryLocator.defaultInstallPath() : config.installPath
        let storagePath = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath)
            : config.storagePath
        return URL(fileURLWithPath: storagePath, isDirectory: true)
    }

    var themesFolder: URL { storageRoot.appendingPathComponent("themes", isDirectory: true) }
    var snippetsFolder: URL { themesFolder.appendingPathComponent("snippets", isDirectory: true) }
    var packsFolder: URL { storageRoot.appendingPathComponent("packs", isDirectory: true) }
    private var settingsURL: URL { themesFolder.appendingPathComponent("settings.json") }
    var exportURL: URL { themesFolder.appendingPathComponent("active-theme.json") }

    var activeEntry: RoachThemeEntry? { themes.first { $0.id == settings.themeID } }
    var enabledSnippets: [RoachSnippetEntry] {
        settings.snippets.compactMap { id in snippets.first { $0.id == id && !$0.hasErrors } }
    }

    // MARK: Lifecycle

    /// Reads settings and theme files and applies the theme. Safe to call more
    /// than once; a new storage root (after setup moves storage) rescans.
    func bootstrap(storageRoot newRoot: URL? = nil) {
        if let newRoot, newRoot.standardizedFileURL != storageRoot.standardizedFileURL {
            storageRoot = newRoot
            stopWatching()
            bootstrapped = false
        }
        guard !bootstrapped else { return }
        bootstrapped = true
        settings = loadSettings()
        scan()
        apply()
        startWatching()
        observeSystemAppearance()
    }

    func reload() {
        scan()
        apply()
    }

    // MARK: Settings

    func update(_ change: (inout RoachThemeSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        saveSettingsSoon()
        apply()
    }

    /// Sliders change settings many times a second; write the file once they settle.
    private func saveSettingsSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingSave = nil
                self?.saveSettings()
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func select(_ entry: RoachThemeEntry) {
        update { settings in
            settings.themeID = entry.id
            // A light-only or dark-only theme flips the mode so the pick shows.
            if entry.document.light == nil, settings.appearance == .light { settings.appearance = .dark }
            if entry.document.dark == nil, settings.appearance == .dark { settings.appearance = .light }
        }
    }

    func setSnippet(_ id: String, enabled: Bool) {
        update { settings in
            settings.snippets.removeAll { $0 == id }
            if enabled { settings.snippets.append(id) }
        }
    }

    func moveSnippet(_ id: String, by offset: Int) {
        update { settings in
            guard let index = settings.snippets.firstIndex(of: id) else { return }
            let target = min(max(0, index + offset), settings.snippets.count - 1)
            settings.snippets.swapAt(index, target)
        }
    }

    func resetOverrides() {
        update { settings in
            let keep = (settings.themeID, settings.appearance, settings.snippets)
            settings = RoachThemeSettings(themeID: keep.0, appearance: keep.1)
            settings.snippets = keep.2
        }
    }

    // MARK: Previews

    /// A theme resolved for a gallery card: the person's mode, none of their overrides.
    func preview(_ entry: RoachThemeEntry, dark: Bool? = nil) -> RoachResolvedTheme {
        let systemIsDark = Self.systemIsDark()
        var previewSettings = RoachThemeSettings(themeID: entry.id, appearance: settings.appearance)
        if let dark { previewSettings.appearance = dark ? .dark : .light }
        return RoachThemeResolver.resolve(
            document: entry.document,
            settings: previewSettings,
            systemIsDark: systemIsDark,
            baseURL: entry.baseURL
        )
    }

    // MARK: Files

    /// Copies a theme or snippet file (and a background picture it names) into
    /// the themes folder. Refuses files with errors.
    @discardableResult
    func importFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: themesFolder, withIntermediateDirectories: true)

        if let snippet = try? decoder.decode(RoachThemeSnippetDocument.self, from: data), snippet.schema == RoachThemeSnippetDocument.schemaID {
            let issues = RoachThemeValidator.validate(snippet)
            if let error = issues.first(where: { $0.severity == .error }) { throw Self.error(error.message) }
            var document = snippet
            if RoachBuiltInThemes.snippet(id: document.id) != nil { document.id = "user." + document.id }
            try FileManager.default.createDirectory(at: snippetsFolder, withIntermediateDirectories: true)
            try write(document, to: snippetsFolder.appendingPathComponent(document.id + RoachThemeSnippetDocument.fileSuffix))
            reload()
            lastMessage = "Imported the snippet \(document.name)."
            return document.id
        }

        let theme: RoachThemeDocument
        do {
            theme = try decoder.decode(RoachThemeDocument.self, from: data)
        } catch {
            throw Self.error("That file is not a RoachNet theme or snippet: \(error.localizedDescription)")
        }
        let sourceFolder = url.deletingLastPathComponent()
        let issues = RoachThemeValidator.validate(theme, baseURL: sourceFolder)
        if let error = issues.first(where: { $0.severity == .error }) { throw Self.error(error.message) }

        var document = theme
        if RoachBuiltInThemes.theme(id: document.id) != nil || themes.contains(where: { $0.id == document.id && !$0.isUserTheme }) {
            document.id = "user." + document.id
        }
        let destination = themesFolder.appendingPathComponent(document.id, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for mode in [document.dark, document.light] {
            guard let name = mode?.background?.image else { continue }
            let source = sourceFolder.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        }
        try write(document, to: destination.appendingPathComponent(document.id + RoachThemeDocument.fileSuffix))
        reload()
        lastMessage = "Imported \(document.name)."
        return document.id
    }

    func export(_ entry: RoachThemeEntry, to url: URL) throws {
        try write(entry.document, to: url)
    }

    /// Makes an editable copy of a theme in the themes folder.
    @discardableResult
    func duplicate(_ entry: RoachThemeEntry, name: String? = nil) throws -> RoachThemeEntry {
        var document = entry.document
        let baseName = name ?? "\(entry.document.name) (custom)"
        document.name = baseName
        document.author = NSFullUserName().isEmpty ? "You" : NSFullUserName()
        document.version = "1.0.0"
        document.tags = Array(Set((document.tags ?? []) + ["custom"])).sorted()
        document.id = uniqueUserID(for: baseName)
        try saveUserTheme(document, assetsFrom: entry.baseURL)
        guard let saved = themes.first(where: { $0.id == document.id }) else { throw Self.error("The copy did not load.") }
        return saved
    }

    /// Writes a user theme and reloads. Pass `assetsFrom` to carry a
    /// background picture along.
    func saveUserTheme(_ document: RoachThemeDocument, assetsFrom source: URL? = nil) throws {
        let issues = RoachThemeValidator.validate(document, baseURL: source)
        if let error = issues.first(where: { $0.severity == .error && !$0.message.contains("image background") }) {
            throw Self.error(error.message)
        }
        let folder = themesFolder.appendingPathComponent(document.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let source {
            for mode in [document.dark, document.light] {
                guard let name = mode?.background?.image else { continue }
                let from = source.appendingPathComponent(name)
                let to = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: from, to: to)
                }
            }
        }
        try write(document, to: folder.appendingPathComponent(document.id + RoachThemeDocument.fileSuffix))
        reload()
    }

    /// Moves a user theme to the Trash (so it can be put back).
    func trash(_ entry: RoachThemeEntry) throws {
        guard entry.isUserTheme, let file = entry.file else { return }
        let folder = file.deletingLastPathComponent()
        let target = folder.standardizedFileURL == themesFolder.standardizedFileURL ? file : folder
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        if settings.themeID == entry.id {
            settings.themeID = RoachThemeSettings.defaultThemeID
            saveSettings()
        }
        reload()
        lastMessage = "Moved \(entry.document.name) to the Trash."
    }

    func revealThemesFolder() {
        try? FileManager.default.createDirectory(at: snippetsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([themesFolder])
    }

    private func uniqueUserID(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let stem = "user." + (slug.isEmpty ? "theme" : String(slug.prefix(40)))
        var candidate = stem
        var counter = 2
        while themes.contains(where: { $0.id == candidate }) || RoachBuiltInThemes.theme(id: candidate) != nil {
            candidate = "\(stem)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private func write<Document: Encodable>(_ document: Document, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "RoachNetThemes", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Scanning, applying, watching

extension RoachThemeStore {
    private struct PackStateFile: Decodable {
        struct State: Decodable {
            var enabled: Bool
            var installedVersion: String?
        }

        var packs: [String: State]
    }

    private struct InstalledPackManifest: Decodable {
        var name: String?
    }

    /// Enabled packs and the folder each one installed into.
    private func enabledPackFolders() -> [(id: String, name: String, folder: URL)] {
        let stateURL = packsFolder.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PackStateFile.self, from: data) else { return [] }
        return state.packs.sorted { $0.key < $1.key }.compactMap { id, pack in
            guard pack.enabled, let version = pack.installedVersion else { return nil }
            let folder = packsFolder.appendingPathComponent("installed", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            let name = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode(InstalledPackManifest.self, from: $0) }?.name
            return (id, name ?? id, folder)
        }
    }

    /// Files under `folder` ending in `suffix`, at most `depth` levels down.
    private func files(in folder: URL, suffix: String, depth: Int, skipping skipped: Set<String> = []) -> [URL] {
        guard depth >= 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        var found: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if !skipped.contains(entry.lastPathComponent) {
                    found += files(in: entry, suffix: suffix, depth: depth - 1, skipping: skipped)
                }
            } else if entry.lastPathComponent.hasSuffix(suffix) {
                found.append(entry)
            }
        }
        return found
    }

    func scan() {
        let decoder = JSONDecoder()
        var themeEntries = RoachBuiltInThemes.themes.map {
            RoachThemeEntry(document: $0, source: .builtIn, file: nil, issues: [])
        }
        var snippetEntries = RoachBuiltInThemes.snippets.map {
            RoachSnippetEntry(document: $0, source: .builtIn, file: nil, issues: [])
        }
        var scanProblems: [String] = []
        var seenThemes = Set(themeEntries.map(\.id))
        var seenSnippets = Set(snippetEntries.map(\.id))

        func addTheme(_ url: URL, source: RoachThemeEntry.Source) {
            do {
                let document = try decoder.decode(RoachThemeDocument.self, from: Data(contentsOf: url))
                guard !seenThemes.contains(document.id) else {
                    scanProblems.append("\(url.lastPathComponent): another theme already uses the id \(document.id).")
                    return
                }
                seenThemes.insert(document.id)
                let issues = RoachThemeValidator.validate(document, baseURL: url.deletingLastPathComponent())
                themeEntries.append(RoachThemeEntry(document: document, source: source, file: url, issues: issues))
            } catch {
                scanProblems.append("\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
            }
        }

        func addSnippet(_ url: URL, source: RoachThemeEntry.Source) {
            do {
                let document = try decoder.decode(RoachThemeSnippetDocument.self, from: Data(contentsOf: url))
                guard !seenSnippets.contains(document.id) else {
                    scanProblems.append("\(url.lastPathComponent): another snippet already uses the id \(document.id).")
                    return
                }
                seenSnippets.insert(document.id)
                snippetEntries.append(RoachSnippetEntry(document: document, source: source, file: url, issues: RoachThemeValidator.validate(document)))
            } catch {
                scanProblems.append("\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
            }
        }

        for url in files(in: themesFolder, suffix: RoachThemeDocument.fileSuffix, depth: 2, skipping: ["snippets"]) {
            addTheme(url, source: .user)
        }
        for url in files(in: snippetsFolder, suffix: RoachThemeSnippetDocument.fileSuffix, depth: 1) {
            addSnippet(url, source: .user)
        }
        for pack in enabledPackFolders() {
            let source = RoachThemeEntry.Source.pack(id: pack.id, name: pack.name)
            for url in files(in: pack.folder, suffix: RoachThemeDocument.fileSuffix, depth: 3) {
                addTheme(url, source: source)
            }
            for url in files(in: pack.folder, suffix: RoachThemeSnippetDocument.fileSuffix, depth: 3) {
                addSnippet(url, source: source)
            }
        }

        if RoachBuiltInThemes.undecodableSourceCount > 0 {
            scanProblems.append("\(RoachBuiltInThemes.undecodableSourceCount) built-in theme files did not load.")
        }
        themes = themeEntries
        snippets = snippetEntries
        problems = scanProblems
    }

    func apply() {
        let entry = activeEntry.flatMap { $0.hasErrors ? nil : $0 }
            ?? themes.first { $0.id == RoachThemeSettings.defaultThemeID }
        let document = entry?.document ?? RoachBuiltInThemes.defaultTheme
        revision += 1
        let resolved = RoachThemeResolver.resolve(
            document: document,
            snippets: enabledSnippets.map(\.document),
            settings: settings,
            systemIsDark: Self.systemIsDark(),
            baseURL: entry?.baseURL,
            revision: revision
        )
        RoachThemeRuntime.shared.apply(resolved)
        active = resolved
        NSApplication.shared.appearance = NSAppearance(named: resolved.appearanceName)
        writeActiveTheme(resolved)
    }

    private func writeActiveTheme(_ theme: RoachResolvedTheme) {
        do {
            try FileManager.default.createDirectory(at: themesFolder, withIntermediateDirectories: true)
            try theme.exportJSON().write(to: exportURL, options: .atomic)
        } catch {
            problems.append("Could not write active-theme.json: \(error.localizedDescription)")
        }
    }

    func loadSettings() -> RoachThemeSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(RoachThemeSettings.self, from: data) else {
            return RoachThemeSettings()
        }
        return decoded
    }

    func saveSettings() {
        do {
            try FileManager.default.createDirectory(at: themesFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch {
            lastMessage = "Could not save appearance settings: \(error.localizedDescription)"
        }
    }

    static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    func observeSystemAppearance() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.appearance == .system else { return }
                self.apply()
            }
        }
    }

    /// Watches the themes, snippets and packs folders so a theme saved in a
    /// text editor (or a pack switched on) shows up without a restart.
    func startWatching() {
        stopWatching()
        try? FileManager.default.createDirectory(at: snippetsFolder, withIntermediateDirectories: true)
        var folders = [themesFolder, snippetsFolder, packsFolder]
        folders += (try? FileManager.default.contentsOfDirectory(at: themesFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "snippets" } ?? []
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // settings.json edited outside the app (a sync tool, a gate
                // script) wins, unless this app has a save of its own pending.
                if self.pendingSave == nil {
                    let onDisk = self.loadSettings()
                    if onDisk != self.settings { self.settings = onDisk }
                }
                self.reload()
                // New theme folders need their own watcher.
                self.startWatching()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
