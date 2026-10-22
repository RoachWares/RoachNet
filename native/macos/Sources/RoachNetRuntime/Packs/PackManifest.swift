import Foundation

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
    public var install: PackInstallHandler?
    public var signature: PackSignature?

    public init(
        id: String, version: String, kind: PackKind, name: String, summary: String = "",
        publisher: String = "RoachWares LLC",
        requires: PackRequirements = PackRequirements(), dependencies: [PackDependency] = [],
        capabilities: [PackCapability] = [],
        resources: [PackResource] = [], dataRoots: [PackDataRoot] = [], install: PackInstallHandler? = nil,
        signature: PackSignature? = nil
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

    public var downloadBytes: Int {
        var total = 0
        for resource in resources {
            let (sum, overflow) = total.addingReportingOverflow(resource.bytes)
            total = overflow ? Int.max : sum
        }
        return total
    }

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

    public func validate() throws {
        guard schema == Self.schema else { throw PackError.invalidManifest("Unsupported pack schema \(schema).") }
        guard Self.isValidID(id) else {
            throw PackError.invalidManifest("Pack id \"\(id)\" must be 2–64 lowercase letters, digits, dots or dashes.")
        }
        guard SemanticVersion(version) != nil else {
            throw PackError.invalidManifest("Pack \(id) has a non-semantic version \"\(version)\".")
        }
        guard Self.isSafeVersion(version) else {
            throw PackError.invalidManifest(
                "Pack \(id) has a version \"\(version)\" with characters a version doesn't use (only letters, digits, \".\", \"+\" and \"-\")."
            )
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PackError.invalidManifest("Pack \(id) has no name.")
        }
        if let minimum = requires.roachnet, SemanticVersion(minimum) == nil {
            throw PackError.invalidManifest("Pack \(id) names a non-semantic minimum RoachNet version \"\(minimum)\".")
        }
        var seenDependencies = Set<String>()
        for dependency in dependencies {
            guard Self.isValidID(dependency.id) else {
                throw PackError.invalidManifest("Pack \(id) depends on an invalid id \"\(dependency.id)\".")
            }
            guard dependency.id != id else { throw PackError.invalidManifest("Pack \(id) depends on itself.") }
            guard seenDependencies.insert(dependency.id).inserted else {
                throw PackError.invalidManifest("Pack \(id) lists \(dependency.id) twice.")
            }
            if let minimum = dependency.minimumVersion, SemanticVersion(minimum) == nil {
                throw PackError.invalidManifest(
                    "Pack \(id) requires \(dependency.id) \"\(minimum)\", which is not a version.")
            }
        }
        guard resources.count <= Self.maxResources else {
            throw PackError.invalidManifest("Pack \(id) lists more than \(Self.maxResources) resources.")
        }
        var seenPaths = Set<String>()
        for resource in resources {
            guard Self.isSafeRelativePath(resource.path) else {
                throw PackError.invalidManifest(
                    "Pack \(id) resource path \"\(resource.path)\" escapes the pack folder.")
            }
            guard seenPaths.insert(resource.path).inserted else {
                throw PackError.invalidManifest("Pack \(id) lists resource \"\(resource.path)\" twice.")
            }
            guard JS.matches("^[a-f0-9]{64}$", resource.sha256) else {
                throw PackError.invalidManifest("Pack \(id) resource \"\(resource.path)\" has no SHA-256.")
            }
            guard resource.bytes > 0 else {
                throw PackError.invalidManifest("Pack \(id) resource \"\(resource.path)\" has no byte size.")
            }
            guard resource.bytes <= Self.maxResourceBytes else {
                throw PackError.invalidManifest("Pack \(id) resource \"\(resource.path)\" is larger than 1 TB.")
            }
            if let url = resource.url {
                guard let parsed = WebURL(url),
                    parsed.scheme == "https"
                        || (parsed.scheme == "http" && CompanionProxy.isLoopback(parsed.bareHostname))
                else {
                    throw PackError.invalidManifest(
                        "Pack \(id) resource \"\(resource.path)\" must download over https.")
                }
            }
        }
        for root in dataRoots {
            guard Self.isSafeRelativePath(root.path) else {
                throw PackError.invalidManifest("Pack \(id) data root \"\(root.path)\" escapes the storage root.")
            }
        }
        if kind == .capability, !resources.isEmpty {
            throw PackError.invalidManifest(
                "Capability pack \(id) cannot carry downloadable resources; code ships with the app.")
        }
        if let install {
            guard PackInstallHandler.knownHandlers.contains(install.handler) else {
                throw PackError.invalidManifest("Pack \(id) names an unknown install handler \"\(install.handler)\".")
            }
            if install.handler == PackInstallHandler.roachSpeechPack {
                guard resources.count == 1, resources[0].archive == "zip" else {
                    throw PackError.invalidManifest(
                        "Pack \(id) uses the RoachSpeech installer, which takes exactly one zip resource.")
                }
                guard let kind = install.kind, ["roachVoice", "roachWhisper"].contains(kind) else {
                    throw PackError.invalidManifest(
                        "Pack \(id) must say whether it is a roachVoice or roachWhisper pack.")
                }
            }
        }
    }

    public static func isValidID(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (2...64).contains(scalars.count), let first = scalars.first, isLowercaseLetterOrDigit(first) else {
            return false
        }
        return scalars.dropFirst().allSatisfy { isLowercaseLetterOrDigit($0) || $0 == "." || $0 == "-" }
    }

    public static func isSafeVersion(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...64).contains(scalars.count),
            scalars.allSatisfy({ isASCIILetterOrDigit($0) || $0 == "." || $0 == "+" || $0 == "-" })
        else { return false }
        return SemanticVersion(value) != nil && !Path.isDotComponent(value)
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    public static let maxResourceBytes = 1 << 40

    public static let maxResources = 4_096

    public static func isSafeRelativePath(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !value.isEmpty, !Path.startsWithSlash(value), !scalars.contains("\\"), !scalars.contains("\0") else {
            return false
        }
        let segments = Path.fileSystemComponents(value, omittingEmpty: false)
        return segments.allSatisfy { !$0.isEmpty && !Path.isDotComponent($0) }
    }
}

public enum PackKind: String, Codable, CaseIterable {
    case capability
    case resource
    case theme
    case animation
    case background
}

public struct PackRequirements: Codable, Equatable {
    public var roachnet: String?
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
    public var minimumVersion: String?

    public init(id: String, minimumVersion: String? = nil) {
        self.id = id
        self.minimumVersion = minimumVersion
    }
}

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
    public var path: String
    public var url: String?
    public var sha256: String
    public var bytes: Int
    public var archive: String?

    public init(path: String, url: String? = nil, sha256: String, bytes: Int, archive: String? = nil) {
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.archive = archive
    }
}

public struct PackInstallHandler: Codable, Equatable {
    public static let roachSpeechPack = "roachspeech-pack"
    public static let knownHandlers: Set<String> = [roachSpeechPack]

    public var handler: String
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

public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preRelease: String?

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: "^v", with: "", options: .regularExpression)
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
        case (nil, _): return false
        case (_, nil): return true
        case (let a?, let b?): return a < b
        }
    }
}
