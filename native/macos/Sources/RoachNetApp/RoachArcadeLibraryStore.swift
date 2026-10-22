import AppKit
import Foundation
import GameController
import WebKit

private struct RoachArcadeESDEGame {
    var title: String
    var system: String
    var romPath: String
    var artworkPath: String?
    var notes: String
}

private final class RoachArcadeESDEGameListParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private let system: String
    private var currentElement = ""
    private var currentValues: [String: String] = [:]
    private var currentText = ""
    private var insideGame = false

    private(set) var games: [RoachArcadeESDEGame] = []

    init(baseURL: URL, system: String) {
        self.baseURL = baseURL
        self.system = system
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "game" {
            insideGame = true
            currentValues = [:]
            currentText = ""
            currentElement = ""
            return
        }

        guard insideGame else { return }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideGame, !currentElement.isEmpty else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard insideGame else { return }

        if elementName == "game" {
            if let game = buildGame() {
                games.append(game)
            }
            insideGame = false
            currentElement = ""
            currentValues = [:]
            currentText = ""
            return
        }

        if elementName == currentElement {
            currentValues[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            currentElement = ""
            currentText = ""
        }
    }

    private func buildGame() -> RoachArcadeESDEGame? {
        guard let rawPath = currentValues["path"], !rawPath.isEmpty else { return nil }

        let romPath = resolveESDEPath(rawPath, baseURL: baseURL)
        let title =
            currentValues["name"]?.nilIfBlank
            ?? URL(fileURLWithPath: romPath).deletingPathExtension().lastPathComponent
        let artworkPath = currentValues["image"].flatMap { value in
            value.nilIfBlank.map { resolveESDEPath($0, baseURL: baseURL) }
        }
        let notes = currentValues["desc"]?.nilIfBlank ?? ""

        return RoachArcadeESDEGame(
            title: title,
            system: system,
            romPath: romPath,
            artworkPath: artworkPath,
            notes: notes
        )
    }

    private func resolveESDEPath(_ rawValue: String, baseURL: URL) -> String {
        let expanded = NSString(string: rawValue).expandingTildeInPath
        if let url = URL(string: expanded), url.isFileURL {
            return url.path
        }
        if expanded.hasPrefix("/") {
            return expanded
        }

        let trimmed = expanded.hasPrefix("./") ? String(expanded.dropFirst(2)) : expanded
        return baseURL.appendingPathComponent(trimmed).standardizedFileURL.path
    }
}

struct RoachArcadeRunnerDiagnostic: Identifiable, Hashable {
    var id: String
    var label: String
    var value: String
    var detail: String
    var isReady: Bool
}

struct RoachArcadeSystemSummary: Identifiable, Hashable {
    var id: String { system }
    var system: String
    var count: Int
    var playable: Int
    var core: String?

    var readinessLabel: String {
        "\(playable)/\(count) ready"
    }
}

enum RoachArcadeHTMLSanitizer {
    static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return scriptSafeJavaScriptLiteral(literal)
    }

    static func javaScriptLiteral(jsonData: Data) -> String {
        let literal = String(data: jsonData, encoding: .utf8) ?? "null"
        return scriptSafeJavaScriptLiteral(literal)
    }

    static func htmlAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;", options: .literal)
            .replacingOccurrences(of: "\"", with: "&quot;", options: .literal)
            .replacingOccurrences(of: "'", with: "&#39;", options: .literal)
            .replacingOccurrences(of: "<", with: "&lt;", options: .literal)
            .replacingOccurrences(of: ">", with: "&gt;", options: .literal)
    }

    private static func scriptSafeJavaScriptLiteral(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: "&", with: "\\u0026", options: .literal)
            .replacingOccurrences(of: "<", with: "\\u003C", options: .literal)
            .replacingOccurrences(of: ">", with: "\\u003E", options: .literal)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028", options: .literal)
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029", options: .literal)
    }
}

@MainActor
final class RoachArcadeLibraryStore: ObservableObject {
    @Published private(set) var library: RoachArcadeLibrary = .empty
    @Published var selectedGameID: UUID?
    @Published var activePlayerSession: RoachArcadePlayerSession?
    @Published var statusLine = "RoachArcade ready."
    @Published var errorLine: String?
    @Published var searchText = ""
    @Published var libraryFilter: RoachArcadeLibraryFilter = .all
    @Published private(set) var connectedControllers: [String] = []

    private var storageRoot: URL?
    private let fileManager = FileManager.default
    private var controllerObservers: [NSObjectProtocol] = []

    init() {
        startControllerMonitoring()
    }

    var games: [RoachArcadeGame] {
        library.games.map(refreshStatus).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var selectedGame: RoachArcadeGame? {
        guard let selectedGameID else { return games.first }
        return games.first { $0.id == selectedGameID } ?? games.first
    }

    var filteredGames: [RoachArcadeGame] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return games.filter { game in
            matchesFilter(game)
                && (needle.isEmpty
                    || [
                        game.title,
                        game.system,
                        game.source,
                        game.tags.joined(separator: " "),
                        game.notes,
                    ]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(needle))
        }
    }

    var profilesForSelectedGame: [RoachArcadeModProfile] {
        guard let gameID = selectedGame?.id else { return [] }
        return library.modProfiles
            .filter { $0.gameID == gameID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var collectionsForSelectedGame: [RoachArcadeVortexCollection] {
        guard let gameID = selectedGame?.id else { return [] }
        return library.vortexCollections
            .filter { $0.gameID == gameID }
            .sorted { $0.importedAt > $1.importedAt }
    }

    var connectedControllerSummary: String {
        connectedControllers.isEmpty ? "None" : connectedControllers.joined(separator: ", ")
    }

    var stats:
        (
            games: Int, roms: Int, native: Int, windows: Int, profiles: Int, cheats: Int, playable: Int, attention: Int,
            favorites: Int, recent: Int
        )
    {
        let refreshed = games
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        return (
            games: refreshed.count,
            roms: refreshed.filter { $0.kind == .rom }.count,
            native: refreshed.filter { $0.kind == .macOS || $0.kind == .pc }.count,
            windows: refreshed.filter { $0.kind == .windows }.count,
            profiles: library.modProfiles.count,
            cheats: refreshed.reduce(0) { $0 + $1.cheats.count },
            playable: refreshed.filter { $0.status == .ready }.count,
            attention: refreshed.filter { $0.status != .ready && $0.status != .tracked }.count,
            favorites: refreshed.filter(\.favorite).count,
            recent: refreshed.filter { ($0.lastPlayedAt ?? .distantPast) >= recentCutoff }.count
        )
    }

    var systemShelf: [RoachArcadeSystemSummary] {
        let grouped = Dictionary(grouping: games) { game in
            let trimmed = game.system.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? game.kind.label : trimmed
        }

        return grouped.map { system, games in
            RoachArcadeSystemSummary(
                system: system,
                count: games.count,
                playable: games.filter { $0.status == .ready }.count,
                core: games.first?.resolvedCore
            )
        }
        .sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            return $0.system.localizedCaseInsensitiveCompare($1.system) == .orderedAscending
        }
    }

    var runnerDiagnostics: [RoachArcadeRunnerDiagnostic] {
        let emulatorPath = library.emulatorJSDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let emulatorReady =
            emulatorPath.isEmpty
            || emulatorPath.hasPrefix("http://")
            || emulatorPath.hasPrefix("https://")
            || firstExistingPath([emulatorPath]) != nil
        let gamePortingPath = firstExistingPath([
            library.gamePortingToolkitRunnerPath,
            "/opt/homebrew/bin/gameportingtoolkit",
            "/usr/local/bin/gameportingtoolkit",
        ])
        let crossoverPath = firstExistingPath([
            library.crossoverAppPath,
            "/Applications/CrossOver.app",
        ])
        let winePath = firstExistingPath([
            library.wineRunnerPath,
            "/opt/homebrew/bin/wine64",
            "/usr/local/bin/wine64",
            "/opt/homebrew/bin/wine",
            "/usr/local/bin/wine",
        ])

        return [
            RoachArcadeRunnerDiagnostic(
                id: "emulatorjs",
                label: "EmulatorJS",
                value: emulatorReady ? "Ready" : "Missing",
                detail: emulatorPath.isEmpty ? "Loads from a CDN until you set a local loader path." : emulatorPath,
                isReady: emulatorReady
            ),
            RoachArcadeRunnerDiagnostic(
                id: "gptk",
                label: "Game Porting Toolkit",
                value: gamePortingPath == nil ? "Missing" : "Ready",
                detail: gamePortingPath ?? "Set a runner path for Windows games.",
                isReady: gamePortingPath != nil
            ),
            RoachArcadeRunnerDiagnostic(
                id: "crossover",
                label: "CrossOver",
                value: crossoverPath == nil ? "Missing" : "Ready",
                detail: crossoverPath ?? "Install CrossOver or point RoachNet at the app.",
                isReady: crossoverPath != nil
            ),
            RoachArcadeRunnerDiagnostic(
                id: "wine",
                label: "Wine",
                value: winePath == nil ? "Missing" : "Ready",
                detail: winePath ?? "Install wine64 with Homebrew or set a custom path.",
                isReady: winePath != nil
            ),
            RoachArcadeRunnerDiagnostic(
                id: "controllers",
                label: "Controllers",
                value: connectedControllers.isEmpty ? "None" : "\(connectedControllers.count)",
                detail: connectedControllerSummary,
                isReady: !connectedControllers.isEmpty
            ),
        ]
    }

    func configure(storagePath: String) {
        let root = URL(fileURLWithPath: storagePath, isDirectory: true)
            .appendingPathComponent("RoachArcade", isDirectory: true)
        guard root != storageRoot else { return }

        storageRoot = root
        load()
    }

    func load() {
        guard let storageRoot else { return }
        do {
            try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let libraryURL = storageRoot.appendingPathComponent("library.json")
            guard fileManager.fileExists(atPath: libraryURL.path) else {
                library = .empty
                try save()
                return
            }

            let data = try Data(contentsOf: libraryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            library = try decoder.decode(RoachArcadeLibrary.self, from: data)
            statusLine = "Loaded \(library.games.count) game\(library.games.count == 1 ? "" : "s")."
        } catch {
            errorLine =
                "RoachArcade couldn't load the game library. Your game files on disk aren't affected. \(error.localizedDescription)"
        }
    }

    func save() throws {
        guard let storageRoot else { return }
        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let libraryURL = storageRoot.appendingPathComponent("library.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: libraryURL, options: .atomic)
    }

    func addGame(_ game: RoachArcadeGame) {
        upsert(game)
        statusLine = "Added \(game.title)."
    }

    func importROMFolder(_ folderURL: URL) {
        do {
            let candidates = try scanROMs(in: folderURL)
            var imported = 0
            var existingROMPaths = Set(library.games.compactMap(\.romPath))
            for romURL in candidates {
                if !existingROMPaths.insert(romURL.path).inserted {
                    continue
                }
                let title = romURL.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let system = RoachArcadeCoreResolver.system(forROM: romURL)
                appendImportedGame(
                    RoachArcadeGame(
                        title: title,
                        kind: .rom,
                        system: system,
                        source: "Local ROM folder",
                        romPath: romURL.path,
                        emulatorCore: RoachArcadeCoreResolver.core(forSystem: system, path: romURL.path),
                        tags: ["rom", system]
                    )
                )
                imported += 1
            }
            persistAfterMutation(
                "Imported \(imported) ROM\(imported == 1 ? "" : "s") from \(folderURL.lastPathComponent).")
        } catch {
            errorLine = "RoachArcade couldn't scan that ROM folder. \(error.localizedDescription)"
        }
    }

    func importESDELibrary(_ folderURL: URL) {
        do {
            let entries = try scanESDEGameLists(in: folderURL)
            guard !entries.isEmpty else {
                importROMFolder(folderURL)
                return
            }

            var imported = 0
            var existingROMPaths = Set(library.games.compactMap(\.romPath))
            for entry in entries {
                if !existingROMPaths.insert(entry.romPath).inserted {
                    continue
                }
                appendImportedGame(
                    RoachArcadeGame(
                        title: entry.title,
                        kind: .rom,
                        system: entry.system,
                        source: "ES-DE",
                        romPath: entry.romPath,
                        artworkPath: entry.artworkPath,
                        emulatorCore: RoachArcadeCoreResolver.core(forSystem: entry.system, path: entry.romPath),
                        notes: entry.notes,
                        tags: ["es-de", "rom", entry.system]
                    )
                )
                imported += 1
            }

            persistAfterMutation("Imported \(imported) of \(entries.count) ES-DE game\(entries.count == 1 ? "" : "s").")
        } catch {
            errorLine = "RoachArcade couldn't import that ES-DE library. \(error.localizedDescription)"
        }
    }

    func importMacGame(_ appURL: URL) {
        let title = appURL.deletingPathExtension().lastPathComponent
        upsert(
            RoachArcadeGame(
                title: title,
                kind: .macOS,
                system: "macOS",
                source: appURL.path.hasPrefix("/Applications") ? "Applications" : "Local install",
                executablePath: appURL.path,
                installPath: appURL.deletingLastPathComponent().path,
                tags: ["macOS"]
            )
        )
        statusLine = "Added \(title)."
    }

    func importInstalledMacGames(from folderURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        do {
            let apps = try scanApplications(in: folderURL)
            var imported = 0
            for appURL in apps {
                if library.games.contains(where: { $0.executablePath == appURL.path }) {
                    continue
                }
                let title = appURL.deletingPathExtension().lastPathComponent
                if mergeGame(
                    RoachArcadeGame(
                        title: title,
                        kind: .macOS,
                        system: "macOS",
                        source: folderURL.path == "/Applications" ? "Applications scan" : folderURL.lastPathComponent,
                        executablePath: appURL.path,
                        installPath: appURL.deletingLastPathComponent().path,
                        tags: ["macOS", "scanned"]
                    )
                ) {
                    imported += 1
                }
            }
            persistAfterMutation("Scanned \(apps.count) app\(apps.count == 1 ? "" : "s"); imported \(imported).")
        } catch {
            errorLine = "RoachArcade couldn't scan that folder for apps. \(error.localizedDescription)"
        }
    }

    func importWindowsGame(_ executableURL: URL, runner: RoachArcadeCompatibilityRunner = .gamePortingToolkit) {
        let title = executableURL.deletingPathExtension().lastPathComponent
        upsert(
            RoachArcadeGame(
                title: title,
                kind: .windows,
                system: "Windows",
                source: "Local Windows game",
                executablePath: executableURL.path,
                installPath: executableURL.deletingLastPathComponent().path,
                compatibilityRunner: runner,
                tags: ["windows", runner.label]
            )
        )
        statusLine = "Added \(title). Runner: \(runner.label)."
    }

    func toggleFavorite(_ gameID: UUID) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        library.games[index].favorite.toggle()
        library.games[index].updatedAt = Date()
        persistAfterMutation(
            library.games[index].favorite
                ? "Pinned \(library.games[index].title) to favorites." : "Removed from favorites.")
    }

    func updateGameMetadata(
        gameID: UUID,
        notes: String,
        tagsText: String,
        artworkPath: String,
        storeURL: String,
        runnerPath: String,
        bottlePath: String
    ) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        library.games[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        library.games[index].tags =
            tagsText
            .split { $0 == "," || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
        library.games[index].artworkPath = artworkPath.nilIfBlank
        library.games[index].storeURL = storeURL.nilIfBlank
        library.games[index].runnerPath = runnerPath.nilIfBlank
        library.games[index].bottlePath = bottlePath.nilIfBlank
        library.games[index].updatedAt = Date()
        persistAfterMutation("Updated \(library.games[index].title).")
    }

    func setCompatibilityRunner(_ runner: RoachArcadeCompatibilityRunner, for gameID: UUID) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        library.games[index].compatibilityRunner = runner
        library.games[index].updatedAt = Date()
        persistAfterMutation("Updated runner for \(library.games[index].title).")
    }

    func addCheat(to gameID: UUID, name: String, code: String) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedCode.isEmpty else {
            errorLine = "Add a cheat name and code first."
            return
        }

        library.games[index].cheats.append(RoachArcadeCheat(name: trimmedName, code: trimmedCode))
        library.games[index].updatedAt = Date()
        persistAfterMutation("Added cheat to \(library.games[index].title).")
    }

    func deleteCheat(_ cheatID: UUID, from gameID: UUID) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        library.games[index].cheats.removeAll { $0.id == cheatID }
        library.games[index].updatedAt = Date()
        persistAfterMutation("Removed cheat.")
    }

    func toggleCheat(_ cheatID: UUID, for gameID: UUID) {
        guard
            let gameIndex = library.games.firstIndex(where: { $0.id == gameID }),
            let cheatIndex = library.games[gameIndex].cheats.firstIndex(where: { $0.id == cheatID })
        else {
            return
        }

        library.games[gameIndex].cheats[cheatIndex].enabled.toggle()
        library.games[gameIndex].updatedAt = Date()
        persistAfterMutation("Updated cheat state.")
    }

    func setModDirectory(_ folderURL: URL, for gameID: UUID) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        library.games[index].modDirectoryPath = folderURL.path
        library.games[index].updatedAt = Date()
        persistAfterMutation("Set the mod folder for \(library.games[index].title).")
    }

    func setEmulatorDataPath(_ path: String) {
        library.emulatorJSDataPath = path
        persistAfterMutation("Updated emulator loader path.")
    }

    func setGamePortingToolkitRunnerPath(_ path: String) {
        library.gamePortingToolkitRunnerPath = path
        persistAfterMutation("Updated Game Porting Toolkit runner.")
    }

    func setCrossoverAppPath(_ path: String) {
        library.crossoverAppPath = path
        persistAfterMutation("Updated CrossOver app path.")
    }

    func setWineRunnerPath(_ path: String) {
        library.wineRunnerPath = path
        persistAfterMutation("Updated Wine runner.")
    }

    func createProfile(for gameID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorLine = "Name the mod profile first."
            return
        }
        library.modProfiles.append(RoachArcadeModProfile(gameID: gameID, name: trimmed))
        persistAfterMutation("Created \(trimmed).")
    }

    func importModFolder(_ folderURL: URL, for profileID: UUID) {
        guard let profileIndex = library.modProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        let entry = RoachArcadeModEntry(
            name: folderURL.lastPathComponent,
            sourcePath: folderURL.path,
            loadOrder: library.modProfiles[profileIndex].mods.count + 1
        )
        library.modProfiles[profileIndex].mods.append(entry)
        library.modProfiles[profileIndex].updatedAt = Date()
        persistAfterMutation("Imported \(entry.name) into \(library.modProfiles[profileIndex].name).")
    }

    func setModEnabled(_ enabled: Bool, modID: UUID, profileID: UUID) {
        guard
            let profileIndex = library.modProfiles.firstIndex(where: { $0.id == profileID }),
            let modIndex = library.modProfiles[profileIndex].mods.firstIndex(where: { $0.id == modID })
        else {
            return
        }

        library.modProfiles[profileIndex].mods[modIndex].enabled = enabled
        library.modProfiles[profileIndex].updatedAt = Date()
        persistAfterMutation(enabled ? "Enabled mod." : "Disabled mod.")
    }

    func moveMod(_ modID: UUID, profileID: UUID, direction: Int) {
        guard
            direction != 0,
            let profileIndex = library.modProfiles.firstIndex(where: { $0.id == profileID }),
            let currentIndex = library.modProfiles[profileIndex].mods.firstIndex(where: { $0.id == modID })
        else {
            return
        }

        let targetIndex = max(0, min(library.modProfiles[profileIndex].mods.count - 1, currentIndex + direction))
        guard targetIndex != currentIndex else { return }

        library.modProfiles[profileIndex].mods.swapAt(currentIndex, targetIndex)
        for index in library.modProfiles[profileIndex].mods.indices {
            library.modProfiles[profileIndex].mods[index].loadOrder = index + 1
        }
        library.modProfiles[profileIndex].updatedAt = Date()
        persistAfterMutation("Updated mod load order.")
    }

    func removeMod(_ modID: UUID, profileID: UUID) {
        guard let profileIndex = library.modProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        library.modProfiles[profileIndex].mods.removeAll { $0.id == modID }
        for index in library.modProfiles[profileIndex].mods.indices {
            library.modProfiles[profileIndex].mods[index].loadOrder = index + 1
        }
        library.modProfiles[profileIndex].updatedAt = Date()
        persistAfterMutation("Removed mod.")
    }

    func deleteProfile(_ profileID: UUID) {
        library.modProfiles.removeAll { $0.id == profileID }
        library.vortexCollections.removeAll { $0.profileID == profileID }
        persistAfterMutation("Deleted mod profile.")
    }

    func importVortexCollection(
        gameID: UUID,
        title: String,
        sourceURL: String,
        localFolderURL: URL?
    ) {
        let profileName =
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vortex collection"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var mods: [RoachArcadeModEntry] = []

        if let localFolderURL {
            mods = parseVortexManifest(in: localFolderURL, profileName: profileName)
            if mods.isEmpty {
                mods = scanModFolders(in: localFolderURL, profileName: profileName)
            }
        }

        let profile = RoachArcadeModProfile(
            gameID: gameID,
            name: profileName,
            mods: mods,
            vortexCollectionURL: sourceURL.nilIfBlank,
            notes: "Imported from an extracted Vortex collection."
        )
        library.modProfiles.append(profile)
        library.vortexCollections.append(
            RoachArcadeVortexCollection(
                gameID: gameID,
                profileID: profile.id,
                title: profileName,
                sourceURL: sourceURL,
                localSourcePath: localFolderURL?.path,
                status: mods.isEmpty ? "Tracked" : "Imported \(mods.count) mod\(mods.count == 1 ? "" : "s")"
            )
        )
        persistAfterMutation("Imported Vortex collection \(profileName).")
    }

    func deployProfile(_ profile: RoachArcadeModProfile, for game: RoachArcadeGame) {
        guard let modDirectoryPath = game.modDirectoryPath?.nilIfBlank else {
            errorLine = "Set this game's mod folder before deploying a profile."
            return
        }

        let destinationRoot = URL(fileURLWithPath: modDirectoryPath, isDirectory: true)
            .appendingPathComponent("RoachArcade-\(profile.name.safeFileComponent)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            for mod in profile.mods where mod.enabled {
                let sourceURL = URL(fileURLWithPath: mod.sourcePath)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let destinationURL =
                    destinationRoot
                    .appendingPathComponent("\(String(format: "%03d", mod.loadOrder))-\(sourceURL.lastPathComponent)")
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                do {
                    try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
                } catch {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                }
            }
            statusLine = "Deployed \(profile.name) to \(destinationRoot.lastPathComponent)."
        } catch {
            errorLine =
                "RoachArcade couldn't deploy the mod profile. Check that the game's mod folder exists and try again. \(error.localizedDescription)"
        }
    }

    func play(_ game: RoachArcadeGame) {
        let refreshed = refreshStatus(game)
        guard refreshed.status == .ready else {
            errorLine = "\(game.title) isn't ready to launch. Check its file, core or runner."
            return
        }

        switch refreshed.kind {
        case .rom:
            do {
                activePlayerSession = try prepareEmbeddedSession(for: refreshed)
                incrementPlayCount(for: refreshed.id)
            } catch {
                errorLine =
                    "RoachArcade couldn't open \(game.title) in the built-in player. \(error.localizedDescription)"
            }
        case .windows:
            launchWindowsGame(refreshed)
        case .macOS, .pc, .external:
            launchNativeGame(refreshed)
        }
    }

    func reveal(_ path: String?) {
        guard let path = path?.nilIfBlank else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealLibraryFolder() {
        guard let storageRoot else { return }
        NSWorkspace.shared.open(storageRoot)
    }

    func remove(_ game: RoachArcadeGame) {
        library.games.removeAll { $0.id == game.id }
        library.modProfiles.removeAll { $0.gameID == game.id }
        library.vortexCollections.removeAll { $0.gameID == game.id }
        if selectedGameID == game.id {
            selectedGameID = games.first?.id
        }
        persistAfterMutation("Removed \(game.title) from the library.")
    }

    private func upsert(_ game: RoachArcadeGame) {
        _ = mergeGame(game)
        persistAfterMutation(nil)
    }

    @discardableResult
    private func mergeGame(_ game: RoachArcadeGame) -> Bool {
        var next = refreshStatus(game)
        next.updatedAt = Date()

        if let existingIndex = library.games.firstIndex(where: { existing in
            let existingPaths = [existing.romPath, existing.executablePath, existing.installPath].compactMap(\.self)
            let nextPaths = [next.romPath, next.executablePath, next.installPath].compactMap(\.self)
            return existing.id == next.id || existingPaths.contains(where: nextPaths.contains)
        }) {
            let existing = library.games[existingIndex]
            next.id = existing.id
            next.cheats = existing.cheats
            next.playCount = existing.playCount
            next.lastPlayedAt = existing.lastPlayedAt
            next.createdAt = existing.createdAt
            library.games[existingIndex] = next
            return false
        } else {
            library.games.append(next)
            selectedGameID = next.id
            return true
        }
    }

    private func appendImportedGame(_ game: RoachArcadeGame) {
        var next = refreshStatus(game)
        next.updatedAt = Date()
        library.games.append(next)
        selectedGameID = next.id
    }

    private func persistAfterMutation(_ message: String?) {
        do {
            try save()
            if let message {
                statusLine = message
            }
        } catch {
            errorLine = "RoachArcade couldn't save the game library. \(error.localizedDescription)"
        }
    }

    private func matchesFilter(_ game: RoachArcadeGame) -> Bool {
        switch libraryFilter {
        case .all:
            return true
        case .ready:
            return game.status == .ready
        case .attention:
            return game.status != .ready && game.status != .tracked
        case .favorites:
            return game.favorite
        case .roms:
            return game.kind == .rom
        case .native:
            return game.kind == .macOS || game.kind == .pc
        case .windows:
            return game.kind == .windows
        case .modded:
            return library.modProfiles.contains { $0.gameID == game.id && !$0.mods.isEmpty }
        case .cheats:
            return !game.cheats.isEmpty
        case .recent:
            let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
            return (game.lastPlayedAt ?? .distantPast) >= cutoff
        }
    }

    private func refreshStatus(_ game: RoachArcadeGame) -> RoachArcadeGame {
        var copy = game
        let path = game.launchPath?.nilIfBlank

        if let path, fileManager.fileExists(atPath: path) {
            if game.kind == .rom, game.resolvedCore == nil {
                copy.status = .needsCore
            } else if game.kind == .windows, !canResolveCompatibilityRunner(for: game) {
                copy.status = .needsRunner
            } else {
                copy.status = .ready
            }
        } else if path == nil {
            copy.status = .tracked
        } else {
            copy.status = .missingFile
        }

        return copy
    }

    private func scanApplications(in folderURL: URL) throws -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isPackageKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            urls.append(url)
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func scanROMs(in folderURL: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if RoachArcadeCoreResolver.supportedROMExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func scanESDEGameLists(in folderURL: URL) throws -> [RoachArcadeESDEGame] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var entries: [RoachArcadeESDEGame] = []
        for case let url as URL in enumerator where url.lastPathComponent.lowercased() == "gamelist.xml" {
            let system = url.deletingLastPathComponent().lastPathComponent
            let parserDelegate = RoachArcadeESDEGameListParser(
                baseURL: url.deletingLastPathComponent(),
                system: system.isEmpty ? "ES-DE" : system
            )
            guard let parser = XMLParser(contentsOf: url) else { continue }
            parser.delegate = parserDelegate
            if parser.parse() {
                entries.append(contentsOf: parserDelegate.games)
            }
        }

        return entries
    }

    private func scanModFolders(in folderURL: URL, profileName: String) -> [RoachArcadeModEntry] {
        let folders =
            (try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        var mods: [RoachArcadeModEntry] = []
        for folder in folders {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                mods.append(
                    RoachArcadeModEntry(
                        name: folder.lastPathComponent,
                        sourcePath: folder.path,
                        loadOrder: mods.count + 1,
                        conflictGroup: profileName
                    )
                )
            }
        }
        return mods
    }

    private func parseVortexManifest(in folderURL: URL, profileName: String) -> [RoachArcadeModEntry] {
        let manifestNames = ["collection.json", "manifest.json", "mods.json", "vortex.collection.json"]
        guard
            let manifestURL =
                manifestNames
                .map({ folderURL.appendingPathComponent($0) })
                .first(where: { fileManager.fileExists(atPath: $0.path) }),
            let data = try? Data(contentsOf: manifestURL),
            let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }

        let objects: [[String: Any]]
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let dictionary = root as? [String: Any] {
            objects =
                (dictionary["mods"] as? [[String: Any]]
                    ?? dictionary["files"] as? [[String: Any]]
                    ?? dictionary["items"] as? [[String: Any]]
                    ?? dictionary["downloads"] as? [[String: Any]]
                    ?? [])
        } else {
            objects = []
        }

        return objects.enumerated().compactMap { offset, object in
            let name =
                object.stringValue(for: ["name", "title", "displayName", "fileName", "modName"])
                ?? "Mod \(offset + 1)"
            let rawPath = object.stringValue(for: [
                "path", "sourcePath", "source_path", "filePath", "file_name", "fileName",
            ])
            let sourcePath =
                rawPath
                .map { resolveCollectionPath($0, relativeTo: folderURL).path }
                ?? folderURL.appendingPathComponent(name.safeFileComponent).path
            let loadOrder = object.intValue(for: ["loadOrder", "load_order", "priority", "index"]) ?? offset + 1
            let enabled = object.boolValue(for: ["enabled", "isEnabled", "installed"]) ?? true

            return RoachArcadeModEntry(
                name: name,
                sourcePath: sourcePath,
                enabled: enabled,
                loadOrder: loadOrder,
                conflictGroup: object.stringValue(for: ["group", "conflictGroup", "conflict_group"]) ?? profileName,
                notes: object.stringValue(for: ["notes", "description", "summary"]) ?? ""
            )
        }
        .sorted { lhs, rhs in
            if lhs.loadOrder != rhs.loadOrder {
                return lhs.loadOrder < rhs.loadOrder
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .enumerated()
        .map { offset, mod in
            var copy = mod
            copy.loadOrder = offset + 1
            return copy
        }
    }

    private func resolveCollectionPath(_ rawValue: String, relativeTo folderURL: URL) -> URL {
        let expanded = NSString(string: rawValue).expandingTildeInPath
        if let url = URL(string: expanded), url.isFileURL {
            return url
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return folderURL.appendingPathComponent(expanded).standardizedFileURL
    }

    private func prepareEmbeddedSession(for game: RoachArcadeGame) throws -> RoachArcadePlayerSession {
        guard let storageRoot else {
            throw NSError(
                domain: "RoachArcade", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage is not configured."])
        }
        guard let romPath = game.romPath?.nilIfBlank else {
            throw NSError(
                domain: "RoachArcade", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "This game does not have a ROM path."])
        }
        guard let core = game.resolvedCore else {
            throw NSError(
                domain: "RoachArcade", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "There's no emulator core for \(game.system)."])
        }

        let romURL = URL(fileURLWithPath: romPath)
        let playersRoot = storageRoot.appendingPathComponent("Players", isDirectory: true)
        try fileManager.createDirectory(at: playersRoot, withIntermediateDirectories: true)
        let htmlURL = playersRoot.appendingPathComponent("\(game.id.uuidString).html")
        let dataPath = normalizedEmulatorDataPath()
        let cheats = game.cheats
            .filter(\.enabled)
            .map { [$0.name, $0.code] }
        let cheatsJSONData = try JSONSerialization.data(withJSONObject: cheats, options: [])
        let cheatsJSON = RoachArcadeHTMLSanitizer.javaScriptLiteral(jsonData: cheatsJSONData)
        let titleLiteral = RoachArcadeHTMLSanitizer.javaScriptStringLiteral(game.title)
        let gameURLLiteral = RoachArcadeHTMLSanitizer.javaScriptStringLiteral(romURL.absoluteString)
        let coreLiteral = RoachArcadeHTMLSanitizer.javaScriptStringLiteral(core)
        let dataPathLiteral = RoachArcadeHTMLSanitizer.javaScriptStringLiteral(dataPath)
        let loaderScriptURL = RoachArcadeHTMLSanitizer.htmlAttributeValue("\(dataPath)loader.js")
        let html = """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <style>
                html, body, #game { width: 100%; height: 100%; margin: 0; background: #050706; overflow: hidden; }
              </style>
            </head>
            <body>
              <div id="game"></div>
              <script>
                window.EJS_player = "#game";
                window.EJS_gameName = \(titleLiteral);
                window.EJS_gameUrl = \(gameURLLiteral);
                window.EJS_core = \(coreLiteral);
                window.EJS_pathtodata = \(dataPathLiteral);
                window.EJS_color = "#00ff66";
                window.EJS_startOnLoaded = true;
                window.EJS_disableDatabases = false;
                window.EJS_gamepad = true;
                window.EJS_cheats = \(cheatsJSON);
              </script>
              <script src="\(loaderScriptURL)"></script>
            </body>
            </html>
            """
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return RoachArcadePlayerSession(
            id: UUID(),
            gameID: game.id,
            title: game.title,
            htmlURL: htmlURL,
            readAccessURL: romURL.deletingLastPathComponent()
        )
    }

    private func normalizedEmulatorDataPath() -> String {
        let raw = library.emulatorJSDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "https://cdn.emulatorjs.org/stable/data/"
        guard !raw.isEmpty else { return fallback }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw.hasSuffix("/") ? raw : raw + "/"
        }
        let url = URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
        return url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
    }

    private func launchNativeGame(_ game: RoachArcadeGame) {
        guard let path = game.launchPath?.nilIfBlank else {
            errorLine = "No launch path is set for \(game.title)."
            return
        }
        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.errorLine = "RoachArcade couldn't launch that game. \(error.localizedDescription)"
                } else {
                    self?.incrementPlayCount(for: game.id)
                }
            }
        }
    }

    private func launchWindowsGame(_ game: RoachArcadeGame) {
        guard let path = game.launchPath?.nilIfBlank else {
            errorLine = "No Windows executable is set for \(game.title)."
            return
        }

        let executableURL = URL(fileURLWithPath: path)
        switch game.compatibilityRunner {
        case .crossover:
            guard let crossoverPath = resolvedCompatibilityRunnerPath(for: game) else {
                errorLine = "Set a valid CrossOver.app path before launching \(game.title)."
                return
            }
            let appURL = URL(fileURLWithPath: crossoverPath)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([executableURL], withApplicationAt: appURL, configuration: configuration) {
                [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.errorLine =
                            "RoachArcade couldn't start the game through CrossOver. \(error.localizedDescription)"
                    } else {
                        self?.incrementPlayCount(for: game.id)
                    }
                }
            }
        case .gamePortingToolkit:
            guard let runnerPath = resolvedCompatibilityRunnerPath(for: game) else {
                errorLine = "Set a Game Porting Toolkit runner path in Settings before launching \(game.title)."
                return
            }
            launchCompatibilityProcess(
                runnerPath: runnerPath,
                arguments: compatibilityArguments(for: game, executableURL: executableURL),
                game: game,
                label: "Game Porting Toolkit"
            )
        case .wine:
            guard let runnerPath = resolvedCompatibilityRunnerPath(for: game) else {
                errorLine = "Set a Wine runner path in Settings before launching \(game.title)."
                return
            }
            launchCompatibilityProcess(
                runnerPath: runnerPath,
                arguments: compatibilityArguments(for: game, executableURL: executableURL),
                game: game,
                label: "Wine"
            )
        case .external:
            guard let runnerPath = resolvedCompatibilityRunnerPath(for: game) else {
                errorLine = "Set an external runner for \(game.title)."
                return
            }
            launchCompatibilityProcess(
                runnerPath: runnerPath,
                arguments: compatibilityArguments(for: game, executableURL: executableURL),
                game: game,
                label: "External runner"
            )
        case .native:
            NSWorkspace.shared.open(executableURL)
            incrementPlayCount(for: game.id)
        }
    }

    private func canResolveCompatibilityRunner(for game: RoachArcadeGame) -> Bool {
        game.compatibilityRunner == .native || resolvedCompatibilityRunnerPath(for: game) != nil
    }

    private func resolvedCompatibilityRunnerPath(for game: RoachArcadeGame) -> String? {
        switch game.compatibilityRunner {
        case .native:
            return game.launchPath?.nilIfBlank.map { NSString(string: $0).expandingTildeInPath }
        case .crossover:
            return firstExistingPath([
                game.runnerPath,
                library.crossoverAppPath,
                "/Applications/CrossOver.app",
            ])
        case .gamePortingToolkit:
            return firstExistingPath([
                game.runnerPath,
                library.gamePortingToolkitRunnerPath,
                "/opt/homebrew/bin/gameportingtoolkit",
                "/usr/local/bin/gameportingtoolkit",
            ])
        case .wine:
            return firstExistingPath([
                game.runnerPath,
                library.wineRunnerPath,
                "/opt/homebrew/bin/wine64",
                "/usr/local/bin/wine64",
                "/opt/homebrew/bin/wine",
                "/usr/local/bin/wine",
            ])
        case .external:
            return firstExistingPath([game.runnerPath])
        }
    }

    private func firstExistingPath(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let raw = candidate?.nilIfBlank else { continue }
            let expanded = NSString(string: raw).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    private func compatibilityArguments(for game: RoachArcadeGame, executableURL: URL) -> [String] {
        if let bottlePath = game.bottlePath?.nilIfBlank {
            return [NSString(string: bottlePath).expandingTildeInPath, executableURL.path]
        }
        return [executableURL.path]
    }

    private func launchCompatibilityProcess(
        runnerPath: String,
        arguments: [String],
        game: RoachArcadeGame,
        label: String
    ) {
        let expandedRunner = NSString(string: runnerPath).expandingTildeInPath
        guard fileManager.fileExists(atPath: expandedRunner) else {
            errorLine = "RoachArcade couldn't find \(label) at \(expandedRunner). Check the runner path."
            return
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: expandedRunner)
            process.arguments = arguments
            try process.run()
            incrementPlayCount(for: game.id)
        } catch {
            errorLine = "RoachArcade couldn't launch the game with \(label). \(error.localizedDescription)"
        }
    }

    private func incrementPlayCount(for gameID: UUID) {
        guard let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        library.games[index].playCount += 1
        library.games[index].lastPlayedAt = Date()
        library.games[index].updatedAt = Date()
        persistAfterMutation("Opened \(library.games[index].title).")
    }

    private func startControllerMonitoring() {
        refreshConnectedControllers()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)

        let center = NotificationCenter.default
        controllerObservers.append(
            center.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshConnectedControllers() }
            }
        )
        controllerObservers.append(
            center.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshConnectedControllers() }
            }
        )
    }

    private func refreshConnectedControllers() {
        connectedControllers = GCController.controllers()
            .map { controller in
                let name = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let category = controller.productCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                return name?.isEmpty == false ? name! : (category.isEmpty ? "Game controller" : category)
            }
            .uniqued()
            .sorted()
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate var safeFileComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce("") { $0 + String($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Dictionary where Key == String, Value == Any {
    fileprivate func stringValue(for keys: [String]) -> String? {
        for key in keys {
            if let string = self[key] as? String, let value = string.nilIfBlank {
                return value
            }
            if let number = self[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    fileprivate func intValue(for keys: [String]) -> Int? {
        for key in keys {
            if let intValue = self[key] as? Int {
                return intValue
            }
            if let number = self[key] as? NSNumber {
                return number.intValue
            }
            if let string = self[key] as? String,
                let intValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return intValue
            }
        }
        return nil
    }

    fileprivate func boolValue(for keys: [String]) -> Bool? {
        for key in keys {
            if let boolValue = self[key] as? Bool {
                return boolValue
            }
            if let number = self[key] as? NSNumber {
                return number.boolValue
            }
            if let string = self[key] as? String {
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1", "enabled":
                    return true
                case "false", "no", "0", "disabled":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
