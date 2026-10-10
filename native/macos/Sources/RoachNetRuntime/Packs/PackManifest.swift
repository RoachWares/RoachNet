import Foundation

/// A feature pack is the unit RoachNet installs, enables, updates and removes
/// independently of the core app. Capability packs are code that ships inside
/// the app and is switched on or off; resource packs are downloadable files
/// (models, speech packs, map collections, themes) verified by digest before
/// they are swapped into place. The manifest is declarative JSON — nothing in
/// it is executed.
public struct PackManifest: Codable, Equatable {
    public static let schema = "org.roachnet.pack.v1"

    public var schema: String
    public var id: String
    public var version: String
    public var kind: PackKind
    public var name: String
    public var summary: String
    public var publisher: String
    public var requires: PackRequirements
    public var dependencies: [PackDependency]
    public var capabilities: [PackCapability]
    public var resources: [PackResource]
    public var dataRoots: [PackDataRoot]
    /// How the pack lands once downloaded. Absent means the generic installer
    /// (verify, extract into `packs/installed/<id>/<version>`). `roachspeech-pack`
    /// hands the archive to the RoachSpeech shelf installer, which already
    /// validates `RoachSpeechPack.json` and swaps the pack in atomically.
    public var install: PackInstallHandler?
    public var signature: PackSignature?

    public init(
        id: String, version: String, kind: PackKind, name: String, summary: String = "", publisher: String = "RoachWares LLC",
        requires: PackRequirements = PackRequirements(), dependencies: [PackDependency] = [], capabilities: [PackCapability] = [],
        resources: [PackResource] = [], dataRoots: [PackDataRoot] = [], install: PackInstallHandler? = nil, signature: PackSignature? = nil
    ) {
        self.schema = Self.schema
        self.id = id
        self.version = version
        self.kind = kind
        self.name = name
        self.summary = summary
        self.publisher = publisher
        self.requires = requires
        self.dependencies = dependencies
        self.capabilities = capabilities
        self.resources = resources
        self.dataRoots = dataRoots
        self.install = install
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? Self.schema
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        kind = try c.decode(PackKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher) ?? ""
        requires = try c.decodeIfPresent(PackRequirements.self, forKey: .requires) ?? PackRequirements()
        dependencies = try c.decodeIfPresent([PackDependency].self, forKey: .dependencies) ?? []
        capabilities = try c.decodeIfPresent([PackCapability].self, forKey: .capabilities) ?? []
        resources = try c.decodeIfPresent([PackResource].self, forKey: .resources) ?? []
        dataRoots = try c.decodeIfPresent([PackDataRoot].self, forKey: .dataRoots) ?? []
        install = try c.decodeIfPresent(PackInstallHandler.self, forKey: .install)
        signature = try c.decodeIfPresent(PackSignature.self, forKey: .signature)
    }

    /// Total bytes the pack's resources occupy once installed (archives count
    /// their download size; extraction can be larger).
    public var downloadBytes: Int { resources.reduce(0) { $0 + $1.bytes } }

    public static func decode(_ data: Data) throws -> PackManifest {
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        } catch {
            throw PackError.invalidManifest("Manifest is not valid pack JSON: \(error)")
        }
        try manifest.validate()
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Structural validation. Anything that fails here is rejected before any
    /// file is written.
    public func validate() throws {
        guard schema == Self.schema else { throw PackError.invalidManifest("Unsupported pack schema \(schema).") }
        guard Self.isValidID(id) else { throw PackError.invalidManifest("Pack id \"\(id)\" must be 2–64 lowercase letters, digits, dots or dashes.") }
        guard SemanticVersion(version) != nil else { throw PackError.invalidManifest("Pack \(id) has a non-semantic version \"\(version)\".") }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw PackError.invalidManifest("Pack \(id) has no name.") }
        if let minimum = requires.roachnet, SemanticVersion(minimum) == nil {
            throw PackError.invalidManifest("Pack \(id) names a non-semantic minimum RoachNet version \"\(minimum)\".")
        }
        var seenDependencies = Set<String>()
        for dependency in dependencies {
            guard Self.isValidID(dependency.id) else { throw PackError.invalidManifest("Pack \(id) depends on an invalid id \"\(dependency.id)\".") }
            guard dependency.id != id else { throw PackError.invalidManifest("Pack \(id) depends on itself.") }
            guard seenDependencies.insert(dependency.id).inserted else { throw PackError.invalidManifest("Pack \(id) lists \(dependency.id) twice.") }
            if let minimum = dependency.minimumVersion, SemanticVersion(minimum) == nil {
                throw PackError.invalidManifest("Pack \(id) requires \(dependency.id) \"\(minimum)\", which is not a version.")
            }
        }
        var seenPaths = Set<String>()
        for resource in resources {
            guard Self.isSafeRelativePath(resource.path) else { throw PackError.invalidManifest("Pack \(id) resource path \"\(resource.path)\" escapes the pack folder.") }
            guard seenPaths.insert(resource.path).inserted else { throw PackError.invalidManifest("Pack \(id) lists resource \"\(resource.path)\" twice.") }
            guard JS.matches("^[a-f0-9]{64}$", resource.sha256) else { throw PackError.invalidManifest("Pack \(id) resource \"\(resource.path)\" has no SHA-256.") }
            guard resource.bytes > 0 else { throw PackError.invalidManifest("Pack \(id) resource \"\(resource.path)\" has no byte size.") }
            if let url = resource.url {
                guard let parsed = WebURL(url), parsed.scheme == "https" || (parsed.scheme == "http" && CompanionProxy.isLoopback(parsed.bareHostname)) else {
                    throw PackError.invalidManifest("Pack \(id) resource \"\(resource.path)\" must download over https.")
                }
            }
        }
        for root in dataRoots {
            guard Self.isSafeRelativePath(root.path) else { throw PackError.invalidManifest("Pack \(id) data root \"\(root.path)\" escapes the storage root.") }
        }
        if kind == .capability, !resources.isEmpty {
            throw PackError.invalidManifest("Capability pack \(id) cannot carry downloadable resources; code ships with the app.")
        }
        if let install {
            guard PackInstallHandler.knownHandlers.contains(install.handler) else {
                throw PackError.invalidManifest("Pack \(id) names an unknown install handler \"\(install.handler)\".")
            }
            if install.handler == PackInstallHandler.roachSpeechPack {
                guard resources.count == 1, resources[0].archive == "zip" else {
                    throw PackError.invalidManifest("Pack \(id) uses the RoachSpeech installer, which takes exactly one zip resource.")
                }
                guard let kind = install.kind, ["roachVoice", "roachWhisper"].contains(kind) else {
                    throw PackError.invalidManifest("Pack \(id) must say whether it is a roachVoice or roachWhisper pack.")
                }
            }
        }
    }

    public static func isValidID(_ value: String) -> Bool {
        JS.matches("^[a-z0-9][a-z0-9.-]{1,63}$", value)
    }

    /// Relative, no traversal, no absolute path, no hidden segments.
    public static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else { return false }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum PackKind: String, Codable, CaseIterable {
    /// Code that ships inside the app and is switched on or off (Org, Dev, Vault …).
    case capability
    /// Downloaded files: models, speech packs, map collections, knowledge bundles.
    case resource
    /// Declarative appearance packages consumed by the theme engine.
    case theme
    case animation
    case background
}

public struct PackRequirements: Codable, Equatable {
    /// Minimum RoachNet version (semantic).
    public var roachnet: String?
    /// Platforms the pack supports; empty means all.
    public var platforms: [String]

    public init(roachnet: String? = nil, platforms: [String] = []) {
        self.roachnet = roachnet
        self.platforms = platforms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roachnet = try c.decodeIfPresent(String.self, forKey: .roachnet)
        platforms = try c.decodeIfPresent([String].self, forKey: .platforms) ?? []
    }
}

public struct PackDependency: Codable, Equatable {
    public var id: String
    /// Minimum acceptable version of the dependency; nil accepts any.
    public var minimumVersion: String?

    public init(id: String, minimumVersion: String? = nil) {
        self.id = id
        self.minimumVersion = minimumVersion
    }
}

/// What a pack is allowed to do. Capability packs declare these so the Pack
/// Manager can show them, and so the runtime can refuse a resource pack that
/// asks for more than files.
public enum PackCapability: String, Codable, CaseIterable {
    case networkPublic = "network.public"
    case networkLocal = "network.local"
    case filesystemStorage = "filesystem.storage"
    case filesystemUser = "filesystem.user"
    case processSpawn = "process.spawn"
    case inference = "inference"
    case microphone = "microphone"
    case speaker = "speaker"
    case bluetooth = "bluetooth"
    case location = "location"
    case companionBridge = "companion.bridge"
}

public struct PackResource: Codable, Equatable {
    /// Where the file lands inside the pack's install folder.
    public var path: String
    /// Download source; nil for packs installed from a local package.
    public var url: String?
    public var sha256: String
    public var bytes: Int
    /// `zip` or `tar.gz` archives are extracted next to `path` after verification.
    public var archive: String?

    public init(path: String, url: String? = nil, sha256: String, bytes: Int, archive: String? = nil) {
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.archive = archive
    }
}

/// User-owned data a pack reads or writes, relative to the storage root. It is
/// never deleted by an uninstall unless the person asks for it explicitly.
public struct PackInstallHandler: Codable, Equatable {
    public static let roachSpeechPack = "roachspeech-pack"
    public static let knownHandlers: Set<String> = [roachSpeechPack]

    public var handler: String
    /// For `roachspeech-pack`: `roachVoice` or `roachWhisper`.
    public var kind: String?

    public init(handler: String, kind: String? = nil) {
        self.handler = handler
        self.kind = kind
    }
}

public struct PackDataRoot: Codable, Equatable {
    public var path: String
    public var description: String

    public init(path: String, description: String) {
        self.path = path
        self.description = description
    }
}

public struct PackSignature: Codable, Equatable {
    public var algorithm: String
    public var publicKeyId: String
    public var value: String

    public init(algorithm: String, publicKeyId: String, value: String) {
        self.algorithm = algorithm
        self.publicKeyId = publicKeyId
        self.value = value
    }
}

public enum PackError: Error, CustomStringConvertible, Equatable {
    case invalidManifest(String)
    case unknownPack(String)
    case incompatible(String)
    case dependencyMissing(String)
    case dependencyCycle(String)
    case dependentsEnabled(String)
    case integrity(String)
    case installFailed(String)

    public var description: String {
        switch self {
        case .invalidManifest(let m), .unknownPack(let m), .incompatible(let m), .dependencyMissing(let m),
             .dependencyCycle(let m), .dependentsEnabled(let m), .integrity(let m), .installFailed(let m):
            return m
        }
    }
}

/// Minimal semantic version: major.minor.patch with optional pre-release tag.
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preRelease: String?

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let split = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard let core = split.first else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = parts[0]!
        minor = parts[1]!
        patch = parts[2]!
        preRelease = split.count > 1 ? String(split[1]) : nil
    }

    public var description: String { "\(major).\(minor).\(patch)" + (preRelease.map { "-\($0)" } ?? "") }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil): return false
        case (nil, _): return false // release > pre-release
        case (_, nil): return true
        case (let a?, let b?): return a < b
        }
    }
}
