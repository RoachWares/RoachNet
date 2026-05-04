import AppKit
import Foundation
import GameController
import WebKit

@MainActor
final class RoachArcadeLibraryStore: ObservableObject {
    @Published private(set) var library: RoachArcadeLibrary = .empty
    @Published var selectedGameID: UUID?
    @Published var activePlayerSession: RoachArcadePlayerSession?
    @Published var statusLine = "RoachArcade ready."
    @Published var errorLine: String?
    @Published var searchText = ""
    @Published private(set) var connectedControllers: [String] = []

    private var storageRoot: URL?
    private let fileManager = FileManager.default
    private var controllerObservers: [NSObjectProtocol] = []

    init() {
        startControllerMonitoring()
    }

    var games: [RoachArcadeGame] {
        library.games.map(refreshStatus).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var selectedGame: RoachArcadeGame? {
        guard let selectedGameID else { return games.first }
        return games.first { $0.id == selectedGameID } ?? games.first
    }

    var filteredGames: [RoachArcadeGame] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return games }
        return games.filter { game in
            [
                game.title,
                game.system,
                game.source,
                game.tags.joined(separator: " "),
                game.notes,
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
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

    var stats: (games: Int, roms: Int, native: Int, windows: Int, profiles: Int, cheats: Int, playable: Int) {
        let refreshed = games
        return (
            games: refreshed.count,
            roms: refreshed.filter { $0.kind == .rom }.count,
            native: refreshed.filter { $0.kind == .macOS || $0.kind == .pc }.count,
            windows: refreshed.filter { $0.kind == .windows }.count,
            profiles: library.modProfiles.count,
            cheats: refreshed.reduce(0) { $0 + $1.cheats.count },
            playable: refreshed.filter { $0.status == .ready }.count
        )
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
            errorLine = "RoachArcade could not load the library: \(error.localizedDescription)"
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
            for romURL in candidates {
                if library.games.contains(where: { $0.romPath == romURL.path }) {
                    continue
                }
                let title = romURL.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let system = RoachArcadeCoreResolver.system(forROM: romURL)
                upsert(
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
            statusLine = "Imported \(imported) ROM\(imported == 1 ? "" : "s") from \(folderURL.lastPathComponent)."
        } catch {
            errorLine = "ROM scan failed: \(error.localizedDescription)"
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
        statusLine = "Added \(title) for \(runner.label)."
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
        persistAfterMutation("Set mod directory for \(library.games[index].title).")
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

    func importVortexCollection(
        gameID: UUID,
        title: String,
        sourceURL: String,
        localFolderURL: URL?
    ) {
        let profileName = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vortex Collection"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var mods: [RoachArcadeModEntry] = []

        if let localFolderURL {
            let folders = (try? fileManager.contentsOfDirectory(
                at: localFolderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

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
        }

        let profile = RoachArcadeModProfile(
            gameID: gameID,
            name: profileName,
            mods: mods,
            vortexCollectionURL: sourceURL.nilIfBlank,
            notes: "Imported through RoachArcade's native Vortex collection bridge."
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
            errorLine = "Set this game's mod directory before deploying a profile."
            return
        }

        let destinationRoot = URL(fileURLWithPath: modDirectoryPath, isDirectory: true)
            .appendingPathComponent("RoachArcade-\(profile.name.safeFileComponent)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            for mod in profile.mods where mod.enabled {
                let sourceURL = URL(fileURLWithPath: mod.sourcePath)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let destinationURL = destinationRoot
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
            errorLine = "Mod deployment failed: \(error.localizedDescription)"
        }
    }

    func play(_ game: RoachArcadeGame) {
        let refreshed = refreshStatus(game)
        guard refreshed.status == .ready else {
            errorLine = "\(game.title) is not ready to launch."
            return
        }

        switch refreshed.kind {
        case .rom:
            do {
                activePlayerSession = try prepareEmbeddedSession(for: refreshed)
                incrementPlayCount(for: refreshed.id)
            } catch {
                errorLine = "Could not open \(game.title) inside RoachArcade: \(error.localizedDescription)"
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

    func remove(_ game: RoachArcadeGame) {
        library.games.removeAll { $0.id == game.id }
        library.modProfiles.removeAll { $0.gameID == game.id }
        library.vortexCollections.removeAll { $0.gameID == game.id }
        if selectedGameID == game.id {
            selectedGameID = games.first?.id
        }
        persistAfterMutation("Removed \(game.title).")
    }

    private func upsert(_ game: RoachArcadeGame) {
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
        } else {
            library.games.append(next)
            selectedGameID = next.id
        }

        persistAfterMutation(nil)
    }

    private func persistAfterMutation(_ message: String?) {
        do {
            try save()
            if let message {
                statusLine = message
            }
        } catch {
            errorLine = "RoachArcade could not save: \(error.localizedDescription)"
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

    private func scanROMs(in folderURL: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if RoachArcadeCoreResolver.supportedROMExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return Array(urls.prefix(1_500))
    }

    private func prepareEmbeddedSession(for game: RoachArcadeGame) throws -> RoachArcadePlayerSession {
        guard let storageRoot else {
            throw NSError(domain: "RoachArcade", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage is not configured."])
        }
        guard let romPath = game.romPath?.nilIfBlank else {
            throw NSError(domain: "RoachArcade", code: 2, userInfo: [NSLocalizedDescriptionKey: "This game does not have a ROM path."])
        }
        guard let core = game.resolvedCore else {
            throw NSError(domain: "RoachArcade", code: 3, userInfo: [NSLocalizedDescriptionKey: "No browser core is mapped for \(game.system)."])
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
        let cheatsJSON = String(data: cheatsJSONData, encoding: .utf8) ?? "[]"
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
            window.EJS_gameName = "\(game.title.javaScriptEscaped)";
            window.EJS_gameUrl = "\(romURL.absoluteString.javaScriptEscaped)";
            window.EJS_core = "\(core.javaScriptEscaped)";
            window.EJS_pathtodata = "\(dataPath.javaScriptEscaped)";
            window.EJS_color = "#00ff66";
            window.EJS_startOnLoaded = true;
            window.EJS_disableDatabases = false;
            window.EJS_gamepad = true;
            window.EJS_cheats = \(cheatsJSON);
          </script>
          <script src="\(dataPath.javaScriptEscaped)loader.js"></script>
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
                    self?.errorLine = "Launch failed: \(error.localizedDescription)"
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
            NSWorkspace.shared.open([executableURL], withApplicationAt: appURL, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.errorLine = "CrossOver launch failed: \(error.localizedDescription)"
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
            errorLine = "\(label) runner was not found at \(expandedRunner)."
            return
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: expandedRunner)
            process.arguments = arguments
            try process.run()
            incrementPlayCount(for: game.id)
        } catch {
            errorLine = "\(label) launch failed: \(error.localizedDescription)"
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
                return name?.isEmpty == false ? name! : (category.isEmpty ? "Game Controller" : category)
            }
            .uniqued()
            .sorted()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var safeFileComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce("") { $0 + String($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var javaScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
