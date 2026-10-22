import Foundation
import WebKit

enum RoachArcadeGameKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case rom
    case macOS
    case windows
    case pc
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rom: return "ROM"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .pc: return "PC"
        case .external: return "External"
        }
    }
}

enum RoachArcadeCompatibilityRunner: String, CaseIterable, Codable, Identifiable, Hashable {
    case native
    case gamePortingToolkit
    case crossover
    case wine
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Native"
        case .gamePortingToolkit: return "Game Porting Toolkit"
        case .crossover: return "CrossOver"
        case .wine: return "Wine"
        case .external: return "External"
        }
    }
}

enum RoachArcadeGameStatus: String, Codable, Hashable {
    case ready
    case missingFile
    case needsCore
    case needsRunner
    case tracked

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .missingFile: return "Missing file"
        case .needsCore: return "Needs core"
        case .needsRunner: return "Needs runner"
        case .tracked: return "Tracked"
        }
    }
}

enum RoachArcadeLibraryFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case ready
    case attention
    case favorites
    case roms
    case native
    case windows
    case modded
    case cheats
    case recent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .ready: return "Ready"
        case .attention: return "Needs work"
        case .favorites: return "Favorites"
        case .roms: return "ROMs"
        case .native: return "Native"
        case .windows: return "Windows"
        case .modded: return "Modded"
        case .cheats: return "Cheats"
        case .recent: return "Recent"
        }
    }
}

struct RoachArcadeGame: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var kind: RoachArcadeGameKind
    var system: String
    var source: String
    var status: RoachArcadeGameStatus
    var romPath: String?
    var executablePath: String?
    var installPath: String?
    var modDirectoryPath: String?
    var artworkPath: String?
    var storeURL: String?
    var emulatorCore: String?
    var compatibilityRunner: RoachArcadeCompatibilityRunner
    var runnerPath: String?
    var bottlePath: String?
    var notes: String
    var tags: [String]
    var favorite: Bool
    var cheats: [RoachArcadeCheat]
    var playCount: Int
    var lastPlayedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case system
        case source
        case status
        case romPath
        case executablePath
        case installPath
        case modDirectoryPath
        case artworkPath
        case storeURL
        case emulatorCore
        case compatibilityRunner
        case runnerPath
        case bottlePath
        case notes
        case tags
        case favorite
        case cheats
        case playCount
        case lastPlayedAt
        case createdAt
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String,
        kind: RoachArcadeGameKind,
        system: String,
        source: String,
        romPath: String? = nil,
        executablePath: String? = nil,
        installPath: String? = nil,
        modDirectoryPath: String? = nil,
        artworkPath: String? = nil,
        storeURL: String? = nil,
        emulatorCore: String? = nil,
        compatibilityRunner: RoachArcadeCompatibilityRunner? = nil,
        runnerPath: String? = nil,
        bottlePath: String? = nil,
        notes: String = "",
        tags: [String] = [],
        favorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.system = system
        self.source = source
        self.status = .tracked
        self.romPath = romPath
        self.executablePath = executablePath
        self.installPath = installPath
        self.modDirectoryPath = modDirectoryPath
        self.artworkPath = artworkPath
        self.storeURL = storeURL
        self.emulatorCore = emulatorCore
        self.compatibilityRunner = compatibilityRunner ?? (kind == .windows ? .gamePortingToolkit : .native)
        self.runnerPath = runnerPath
        self.bottlePath = bottlePath
        self.notes = notes
        self.tags = tags
        self.favorite = favorite
        self.cheats = []
        self.playCount = 0
        self.lastPlayedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try container.decodeIfPresent(RoachArcadeGameKind.self, forKey: .kind) ?? .external
        let now = Date()

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled game"
        kind = decodedKind
        system = try container.decodeIfPresent(String.self, forKey: .system) ?? decodedKind.label
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "Local library"
        status = try container.decodeIfPresent(RoachArcadeGameStatus.self, forKey: .status) ?? .tracked
        romPath = try container.decodeIfPresent(String.self, forKey: .romPath)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        installPath = try container.decodeIfPresent(String.self, forKey: .installPath)
        modDirectoryPath = try container.decodeIfPresent(String.self, forKey: .modDirectoryPath)
        artworkPath = try container.decodeIfPresent(String.self, forKey: .artworkPath)
        storeURL = try container.decodeIfPresent(String.self, forKey: .storeURL)
        emulatorCore = try container.decodeIfPresent(String.self, forKey: .emulatorCore)
        compatibilityRunner =
            try container.decodeIfPresent(RoachArcadeCompatibilityRunner.self, forKey: .compatibilityRunner)
            ?? (decodedKind == .windows ? .gamePortingToolkit : .native)
        runnerPath = try container.decodeIfPresent(String.self, forKey: .runnerPath)
        bottlePath = try container.decodeIfPresent(String.self, forKey: .bottlePath)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        cheats = try container.decodeIfPresent([RoachArcadeCheat].self, forKey: .cheats) ?? []
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
    }

    var launchPath: String? {
        switch kind {
        case .rom:
            return romPath
        case .macOS, .windows, .pc, .external:
            return executablePath ?? installPath
        }
    }

    var resolvedCore: String? {
        emulatorCore?.nilIfBlank ?? RoachArcadeCoreResolver.core(forSystem: system, path: romPath)
    }
}

struct RoachArcadeCheat: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var code: String
    var enabled: Bool
    var notes: String

    init(id: UUID = UUID(), name: String, code: String, enabled: Bool = true, notes: String = "") {
        self.id = id
        self.name = name
        self.code = code
        self.enabled = enabled
        self.notes = notes
    }
}

struct RoachArcadeModProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var gameID: UUID
    var name: String
    var enabled: Bool
    var mods: [RoachArcadeModEntry]
    var vortexCollectionURL: String?
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        gameID: UUID,
        name: String,
        enabled: Bool = true,
        mods: [RoachArcadeModEntry] = [],
        vortexCollectionURL: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.gameID = gameID
        self.name = name
        self.enabled = enabled
        self.mods = mods
        self.vortexCollectionURL = vortexCollectionURL
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

struct RoachArcadeModEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var sourcePath: String
    var enabled: Bool
    var loadOrder: Int
    var conflictGroup: String
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        sourcePath: String,
        enabled: Bool = true,
        loadOrder: Int = 0,
        conflictGroup: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.enabled = enabled
        self.loadOrder = loadOrder
        self.conflictGroup = conflictGroup
        self.notes = notes
    }
}

struct RoachArcadeVortexCollection: Identifiable, Codable, Hashable {
    var id: UUID
    var gameID: UUID
    var profileID: UUID?
    var title: String
    var sourceURL: String
    var localSourcePath: String?
    var status: String
    var importedAt: Date

    init(
        id: UUID = UUID(),
        gameID: UUID,
        profileID: UUID? = nil,
        title: String,
        sourceURL: String,
        localSourcePath: String?,
        status: String = "Imported"
    ) {
        self.id = id
        self.gameID = gameID
        self.profileID = profileID
        self.title = title
        self.sourceURL = sourceURL
        self.localSourcePath = localSourcePath
        self.status = status
        self.importedAt = Date()
    }
}

struct RoachArcadeLibrary: Codable {
    var version: Int
    var games: [RoachArcadeGame]
    var modProfiles: [RoachArcadeModProfile]
    var vortexCollections: [RoachArcadeVortexCollection]
    var emulatorJSDataPath: String
    var gamePortingToolkitRunnerPath: String
    var crossoverAppPath: String
    var wineRunnerPath: String

    private enum CodingKeys: String, CodingKey {
        case version
        case games
        case modProfiles
        case vortexCollections
        case emulatorJSDataPath
        case gamePortingToolkitRunnerPath
        case crossoverAppPath
        case wineRunnerPath
    }

    static var empty: RoachArcadeLibrary {
        RoachArcadeLibrary(
            version: 1,
            games: [],
            modProfiles: [],
            vortexCollections: [],
            emulatorJSDataPath: "https://cdn.emulatorjs.org/stable/data/",
            gamePortingToolkitRunnerPath: "",
            crossoverAppPath: "/Applications/CrossOver.app",
            wineRunnerPath: ""
        )
    }

    init(
        version: Int,
        games: [RoachArcadeGame],
        modProfiles: [RoachArcadeModProfile],
        vortexCollections: [RoachArcadeVortexCollection],
        emulatorJSDataPath: String,
        gamePortingToolkitRunnerPath: String,
        crossoverAppPath: String,
        wineRunnerPath: String
    ) {
        self.version = version
        self.games = games
        self.modProfiles = modProfiles
        self.vortexCollections = vortexCollections
        self.emulatorJSDataPath = emulatorJSDataPath
        self.gamePortingToolkitRunnerPath = gamePortingToolkitRunnerPath
        self.crossoverAppPath = crossoverAppPath
        self.wineRunnerPath = wineRunnerPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        games = try container.decodeIfPresent([RoachArcadeGame].self, forKey: .games) ?? []
        modProfiles = try container.decodeIfPresent([RoachArcadeModProfile].self, forKey: .modProfiles) ?? []
        vortexCollections =
            try container.decodeIfPresent([RoachArcadeVortexCollection].self, forKey: .vortexCollections) ?? []
        emulatorJSDataPath =
            try container.decodeIfPresent(String.self, forKey: .emulatorJSDataPath)
            ?? "https://cdn.emulatorjs.org/stable/data/"
        gamePortingToolkitRunnerPath =
            try container.decodeIfPresent(String.self, forKey: .gamePortingToolkitRunnerPath) ?? ""
        crossoverAppPath =
            try container.decodeIfPresent(String.self, forKey: .crossoverAppPath) ?? "/Applications/CrossOver.app"
        wineRunnerPath = try container.decodeIfPresent(String.self, forKey: .wineRunnerPath) ?? ""
    }
}

@MainActor
final class RoachArcadePlayerSession: ObservableObject, Identifiable {
    let id: UUID
    let gameID: UUID
    let title: String
    let htmlURL: URL
    let readAccessURL: URL
    let webView: WKWebView

    init(id: UUID = UUID(), gameID: UUID, title: String, htmlURL: URL, readAccessURL: URL) {
        self.id = id
        self.gameID = gameID
        self.title = title
        self.htmlURL = htmlURL
        self.readAccessURL = readAccessURL

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessURL)
        self.webView = webView
    }
}

enum RoachArcadeCoreResolver {
    static func core(forSystem system: String, path: String?) -> String? {
        let haystack = [system, path ?? ""].joined(separator: " ").lowercased()
        let extensionValue = path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""

        if haystack.contains("game boy advance") || extensionValue == "gba" { return "gba" }
        if haystack.contains("game boy color") || extensionValue == "gbc" { return "gb" }
        if haystack.contains("game boy") || extensionValue == "gb" { return "gb" }
        if haystack.contains("super nintendo") || haystack.contains("snes") || ["sfc", "smc"].contains(extensionValue) {
            return "snes"
        }
        if haystack.contains("nintendo 64") || ["n64", "z64", "v64"].contains(extensionValue) { return "n64" }
        if haystack.contains("nintendo ds") || extensionValue == "nds" { return "nds" }
        if haystack.contains("nes") || extensionValue == "nes" { return "nes" }
        if haystack.contains("virtual boy") || extensionValue == "vb" { return "vb" }
        if haystack.contains("playstation portable") || haystack.contains("psp") || ["cso"].contains(extensionValue) {
            return "psp"
        }
        if haystack.contains("saturn") { return "saturn" }
        if haystack.contains("3do") { return "3do" }
        if haystack.contains("playstation") || ["cue", "chd", "iso", "bin"].contains(extensionValue) { return "psx" }
        if haystack.contains("sega cd") || haystack.contains("mega cd") { return "segaCD" }
        if haystack.contains("32x") || extensionValue == "32x" { return "sega32x" }
        if haystack.contains("genesis") || haystack.contains("mega drive")
            || ["md", "gen", "smd"].contains(extensionValue)
        {
            return "segaMD"
        }
        if haystack.contains("master system") || extensionValue == "sms" { return "segaMS" }
        if haystack.contains("game gear") || extensionValue == "gg" { return "segaGG" }
        if haystack.contains("pc engine") || haystack.contains("turbografx") || ["pce", "sgx"].contains(extensionValue)
        {
            return "pce"
        }
        if haystack.contains("neo geo pocket") || ["ngp", "ngc"].contains(extensionValue) { return "ngp" }
        if haystack.contains("wonder") || ["ws", "wsc"].contains(extensionValue) { return "ws" }
        if haystack.contains("atari 2600") || extensionValue == "a26" { return "atari2600" }
        if haystack.contains("atari 7800") || extensionValue == "a78" { return "atari7800" }
        if haystack.contains("lynx") || extensionValue == "lnx" { return "lynx" }
        if haystack.contains("jaguar") || ["j64", "jag"].contains(extensionValue) { return "jaguar" }
        if haystack.contains("arcade") || haystack.contains("mame") { return "arcade" }
        return nil
    }

    static func system(forROM url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gba": return "Game Boy Advance"
        case "gb": return "Game Boy"
        case "gbc": return "Game Boy Color"
        case "sfc", "smc": return "Super Nintendo"
        case "n64", "z64", "v64": return "Nintendo 64"
        case "nds": return "Nintendo DS"
        case "nes": return "NES"
        case "vb": return "Virtual Boy"
        case "md", "gen", "smd": return "Sega Genesis"
        case "32x": return "Sega 32X"
        case "sms": return "Sega Master System"
        case "gg": return "Sega Game Gear"
        case "pce", "sgx": return "PC Engine"
        case "ngp", "ngc": return "Neo Geo Pocket"
        case "ws", "wsc": return "WonderSwan"
        case "a26": return "Atari 2600"
        case "a78": return "Atari 7800"
        case "lnx": return "Atari Lynx"
        case "j64", "jag": return "Atari Jaguar"
        case "cue", "chd", "iso", "bin", "img", "ccd", "pbp", "cso", "m3u": return "Disc Image"
        case "zip", "7z": return "Arcade / Compressed"
        default: return "Unknown System"
        }
    }

    static var supportedROMExtensions: Set<String> {
        [
            "nes", "sfc", "smc", "gb", "gbc", "gba", "n64", "z64", "v64", "nds",
            "iso", "cue", "chd", "bin", "img", "ccd", "sub", "toc", "pbp", "cso", "m3u",
            "md", "gen", "smd", "sms", "gg", "32x", "pce", "sgx", "ngp", "ngc", "ws", "wsc",
            "a26", "a78", "lnx", "j64", "jag", "vb", "zip", "7z",
        ]
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
