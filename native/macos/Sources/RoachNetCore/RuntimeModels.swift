import Foundation

public struct RoachNetInstallerConfig: Codable, Sendable, Equatable {
    public var installPath: String
    public var installedAppPath: String
    public var storagePath: String
    public var installProfile: String
    public var useDockerContainerization: Bool
    public var installRoachClaw: Bool
    public var companionEnabled: Bool
    public var companionHost: String
    public var companionPort: Int
    public var companionToken: String
    public var companionAdvertisedURL: String
    public var roachClawDefaultModel: String
    public var autoInstallDependencies: Bool
    public var autoLaunch: Bool
    public var releaseChannel: String
    public var setupCompletedAt: String?
    public var bootstrapPending: Bool
    public var bootstrapFailureCount: Int
    public var lastRuntimeHealthAt: String?
    public var pendingLaunchIntro: Bool
    public var pendingRoachClawSetup: Bool

    public init(
        installPath: String,
        installedAppPath: String,
        storagePath: String? = nil,
        installProfile: String = "standard",
        useDockerContainerization: Bool = false,
        installRoachClaw: Bool = true,
        companionEnabled: Bool = true,
        companionHost: String = "127.0.0.1",
        companionPort: Int = 38111,
        companionToken: String = RoachNetInstallerConfig.generateCompanionToken(),
        companionAdvertisedURL: String = "",
        roachClawDefaultModel: String = "qwen2.5-coder:1.5b",
        autoInstallDependencies: Bool = true,
        autoLaunch: Bool = true,
        releaseChannel: String = "stable",
        setupCompletedAt: String? = nil,
        bootstrapPending: Bool = false,
        bootstrapFailureCount: Int = 0,
        lastRuntimeHealthAt: String? = nil,
        pendingLaunchIntro: Bool = false,
        pendingRoachClawSetup: Bool = false
    ) {
        self.installPath = installPath
        self.installedAppPath = installedAppPath
        self.storagePath = storagePath ?? RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath)
        self.installProfile = installProfile
        self.useDockerContainerization = useDockerContainerization
        self.installRoachClaw = installRoachClaw
        self.companionEnabled = companionEnabled
        self.companionHost = companionHost
        self.companionPort = companionPort
        self.companionToken = companionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetInstallerConfig.generateCompanionToken()
            : companionToken
        self.companionAdvertisedURL = companionAdvertisedURL
        self.roachClawDefaultModel = roachClawDefaultModel
        self.autoInstallDependencies = autoInstallDependencies
        self.autoLaunch = autoLaunch
        self.releaseChannel = releaseChannel
        self.setupCompletedAt = setupCompletedAt
        self.bootstrapPending = bootstrapPending
        self.bootstrapFailureCount = max(0, bootstrapFailureCount)
        self.lastRuntimeHealthAt = lastRuntimeHealthAt
        self.pendingLaunchIntro = pendingLaunchIntro
        self.pendingRoachClawSetup = pendingRoachClawSetup
    }

    private enum CodingKeys: String, CodingKey {
        case installPath
        case installedAppPath
        case storagePath
        case installProfile
        case useDockerContainerization
        case installRoachClaw
        case companionEnabled
        case companionHost
        case companionPort
        case companionToken
        case companionAdvertisedURL
        case roachClawDefaultModel
        case autoInstallDependencies
        case autoLaunch
        case releaseChannel
        case setupCompletedAt
        case bootstrapPending
        case bootstrapFailureCount
        case lastRuntimeHealthAt
        case pendingLaunchIntro
        case pendingRoachClawSetup
    }

    private enum CompatibilityKeys: String, CodingKey {
        case appInstallPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let compatibility = try decoder.container(keyedBy: CompatibilityKeys.self)
        let installPath = try container.decodeIfPresent(String.self, forKey: .installPath) ?? RoachNetRepositoryLocator.defaultInstallPath()
        let installedAppPath =
            try container.decodeIfPresent(String.self, forKey: .installedAppPath) ??
            compatibility.decodeIfPresent(String.self, forKey: .appInstallPath) ??
            RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath)
        let storagePath =
            try container.decodeIfPresent(String.self, forKey: .storagePath) ??
            RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath)

        self.init(
            installPath: installPath,
            installedAppPath: installedAppPath,
            storagePath: storagePath,
            installProfile: try container.decodeIfPresent(String.self, forKey: .installProfile) ?? "standard",
            useDockerContainerization: try container.decodeIfPresent(Bool.self, forKey: .useDockerContainerization) ?? false,
            installRoachClaw: try container.decodeIfPresent(Bool.self, forKey: .installRoachClaw) ?? true,
            companionEnabled: try container.decodeIfPresent(Bool.self, forKey: .companionEnabled) ?? true,
            companionHost: try container.decodeIfPresent(String.self, forKey: .companionHost) ?? "127.0.0.1",
            companionPort: try container.decodeIfPresent(Int.self, forKey: .companionPort) ?? 38111,
            companionToken: try container.decodeIfPresent(String.self, forKey: .companionToken) ?? RoachNetInstallerConfig.generateCompanionToken(),
            companionAdvertisedURL: try container.decodeIfPresent(String.self, forKey: .companionAdvertisedURL) ?? "",
            roachClawDefaultModel: try container.decodeIfPresent(String.self, forKey: .roachClawDefaultModel) ?? "qwen2.5-coder:1.5b",
            autoInstallDependencies: try container.decodeIfPresent(Bool.self, forKey: .autoInstallDependencies) ?? true,
            autoLaunch: try container.decodeIfPresent(Bool.self, forKey: .autoLaunch) ?? true,
            releaseChannel: try container.decodeIfPresent(String.self, forKey: .releaseChannel) ?? "stable",
            setupCompletedAt: try container.decodeIfPresent(String.self, forKey: .setupCompletedAt),
            bootstrapPending: try container.decodeIfPresent(Bool.self, forKey: .bootstrapPending) ?? false,
            bootstrapFailureCount: try container.decodeIfPresent(Int.self, forKey: .bootstrapFailureCount) ?? 0,
            lastRuntimeHealthAt: try container.decodeIfPresent(String.self, forKey: .lastRuntimeHealthAt),
            pendingLaunchIntro: try container.decodeIfPresent(Bool.self, forKey: .pendingLaunchIntro) ?? false,
            pendingRoachClawSetup: try container.decodeIfPresent(Bool.self, forKey: .pendingRoachClawSetup) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(installPath, forKey: .installPath)
        try container.encode(installedAppPath, forKey: .installedAppPath)
        try container.encode(storagePath, forKey: .storagePath)
        try container.encode(installProfile, forKey: .installProfile)
        try container.encode(useDockerContainerization, forKey: .useDockerContainerization)
        try container.encode(installRoachClaw, forKey: .installRoachClaw)
        try container.encode(companionEnabled, forKey: .companionEnabled)
        try container.encode(companionHost, forKey: .companionHost)
        try container.encode(companionPort, forKey: .companionPort)
        try container.encode(companionToken, forKey: .companionToken)
        try container.encode(companionAdvertisedURL, forKey: .companionAdvertisedURL)
        try container.encode(roachClawDefaultModel, forKey: .roachClawDefaultModel)
        try container.encode(autoInstallDependencies, forKey: .autoInstallDependencies)
        try container.encode(autoLaunch, forKey: .autoLaunch)
        try container.encode(releaseChannel, forKey: .releaseChannel)
        try container.encodeIfPresent(setupCompletedAt, forKey: .setupCompletedAt)
        try container.encode(bootstrapPending, forKey: .bootstrapPending)
        try container.encode(bootstrapFailureCount, forKey: .bootstrapFailureCount)
        try container.encodeIfPresent(lastRuntimeHealthAt, forKey: .lastRuntimeHealthAt)
        try container.encode(pendingLaunchIntro, forKey: .pendingLaunchIntro)
        try container.encode(pendingRoachClawSetup, forKey: .pendingRoachClawSetup)
    }

    public static func generateCompanionToken() -> String {
        let first = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let second = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(first)\(second)"
    }
}

public struct RoachNetSetupState: Decodable {
    public struct NativeApp: Decodable {
        public let installPath: String
        public let installed: Bool
        public let kind: String
    }

    public struct ContainerRuntime: Decodable {
        public struct Docs: Decodable {
            public let desktop: String?
            public let composeUp: String?
            public let composeFile: String?
            public let desktopWindowsWsl: String?

            public init(desktop: String? = nil, composeUp: String? = nil, composeFile: String? = nil, desktopWindowsWsl: String? = nil) {
                self.desktop = desktop
                self.composeUp = composeUp
                self.composeFile = composeFile
                self.desktopWindowsWsl = desktopWindowsWsl
            }

            public init(from decoder: Decoder) throws {
                if let singleValue = try? decoder.singleValueContainer(),
                   let stringValue = try? singleValue.decode(String.self)
                {
                    self.init(desktop: stringValue)
                    return
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.init(
                    desktop: try container.decodeIfPresent(String.self, forKey: .desktop),
                    composeUp: try container.decodeIfPresent(String.self, forKey: .composeUp),
                    composeFile: try container.decodeIfPresent(String.self, forKey: .composeFile),
                    desktopWindowsWsl: try container.decodeIfPresent(String.self, forKey: .desktopWindowsWsl)
                )
            }

            private enum CodingKeys: String, CodingKey {
                case desktop
                case composeUp
                case composeFile
                case desktopWindowsWsl
            }
        }

        public let available: Bool?
        public let daemonRunning: Bool?
        public let composeAvailable: Bool?
        public let ready: Bool?
        public let detectionPending: Bool?
        public let type: String?
        public let docs: Docs?
    }

    public struct Dependency: Decodable, Identifiable {
        public let id: String
        public let label: String
        public let available: Bool
        public let required: Bool
        public let version: String?
        public let minimumVersion: String?
        public let needsUpdate: Bool
        public let detectionPending: Bool?
        public let notes: String?
    }

    public struct TaskResult: Decodable {
        public let installPath: String?
        public let appPath: String?
        public let url: String?
    }

    public struct TaskState: Decodable {
        public let id: String
        public let status: String
        public let phase: String?
        public let currentStep: String?
        public let progress: Int?
        public let startedAt: String?
        public let updatedAt: String?
        public let finishedAt: String?
        public let logs: [String]?
        public let error: String?
        public let result: TaskResult?
    }

    public let config: RoachNetInstallerConfig
    public let installPath: String
    public let nativeApp: NativeApp
    public let installLooksReady: Bool
    public let containerRuntime: ContainerRuntime
    public let dependencies: [Dependency]
    public let activeTask: TaskState?
    public let lastCompletedTask: TaskState?
}

public enum RoachNetRepositoryLocator {
    /// Name of the native runtime helper shipped in `Contents/Helpers`.
    public static let nativeRuntimeExecutableName = "roachnet-runtime"

    /// Locates the native Swift runtime helper. Releases ship it inside the
    /// app bundle; development builds find it beside the app executable.
    public static func nativeRuntimeBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["ROACHNET_RUNTIME_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(nativeRuntimeExecutableName)
                .path
        )
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(nativeRuntimeExecutableName)
                    .path
            )
        }

        let fileManager = FileManager.default
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Read-only catalog data (collections manifests) used by the native runtime.
    public static func nativeRuntimeDataRoot() -> URL? {
        let fileManager = FileManager.default
        func hasCatalogs(_ candidate: URL) -> Bool {
            fileManager.fileExists(atPath: candidate.appendingPathComponent("collections/maps.json").path)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("RoachNetRuntimeData", isDirectory: true)
            if hasCatalogs(bundled) {
                return bundled
            }
        }

        if let repoRoot = repositoryRoot(), hasCatalogs(repoRoot) {
            return repoRoot
        }

        return nil
    }

    public static func repositoryRoot() -> URL? {
        if
            let explicitOverride = ProcessInfo.processInfo.environment["ROACHNET_REPO_ROOT"],
            !explicitOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let root = ascendForRepoRoot(from: URL(fileURLWithPath: explicitOverride))
        {
            return root
        }

        if let configuredRoot = configuredRepositoryRoot() {
            return configuredRoot
        }

        let envCandidates = [
            ProcessInfo.processInfo.environment["PWD"],
        ]
        .compactMap { $0 }
        .map(URL.init(fileURLWithPath:))

        let pathCandidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath)
                .deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ]

        for candidate in envCandidates + pathCandidates {
            if let root = ascendForRepoRoot(from: candidate) {
                return root
            }
        }

        return nil
    }

    public static func bundledInstallerAssetsDirectory() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let candidate = resourceURL.appendingPathComponent("InstallerAssets", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return candidate
    }

    public static func configURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["ROACHNET_INSTALLER_CONFIG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = support ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("roachnet", isDirectory: true)
            .appendingPathComponent("roachnet-installer.json")
    }

    static func shouldPreserveTransientInstallPaths() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if let explicitConfigPath = environment["ROACHNET_INSTALLER_CONFIG_PATH"],
           !explicitConfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }

        return environment["ROACHNET_ALLOW_TRANSIENT_INSTALL_PATHS"] == "1"
    }

    static func isTransientRoachNetPath(_ candidatePath: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: candidatePath).standardizedFileURL.path.lowercased()
        let tmpRoots = [
            FileManager.default.temporaryDirectory.path,
            "/tmp",
            "/private/tmp",
            "/var/folders",
            "/private/var/folders",
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() }

        return tmpRoots.contains(where: { normalizedPath.hasPrefix($0) }) && normalizedPath.contains("roachnet")
    }

    static func isInstallerScratchPath(_ candidatePath: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        let lowercasedSegments = normalizedPath
            .split(separator: "/")
            .map { $0.lowercased() }
        let lastSegment = lowercasedSegments.last ?? ""

        if isTransientRoachNetPath(normalizedPath) {
            return true
        }

        if lowercasedSegments.contains(".roachnet-setup") || lowercasedSegments.contains(".smoke-work") {
            return true
        }

        return ["staging", "regression", "regressioncheck"].contains {
            lastSegment.range(of: #"(^|[-_.])\#($0)([-_.]|$)"#, options: .regularExpression) != nil
        }
    }

    static func sanitizedInstallPath(_ installPath: String) -> String {
        let trimmedInstallPath = installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstallPath = trimmedInstallPath.isEmpty ? defaultInstallPath() : trimmedInstallPath
        guard !shouldPreserveTransientInstallPaths(), isInstallerScratchPath(normalizedInstallPath) else {
            return URL(fileURLWithPath: normalizedInstallPath).standardizedFileURL.path
        }

        return defaultInstallPath()
    }

    static func sanitizedPersistedConfig(_ config: RoachNetInstallerConfig) -> RoachNetInstallerConfig {
        guard !shouldPreserveTransientInstallPaths() else {
            return config
        }

        let normalizedInstallPath = sanitizedInstallPath(config.installPath)
        let defaultInstalledAppPath = defaultInstalledAppPath(installPath: normalizedInstallPath)
        let defaultStoragePath = defaultStoragePath(installPath: normalizedInstallPath)
        let installPathWasTransient =
            URL(fileURLWithPath: config.installPath).standardizedFileURL.path != normalizedInstallPath

        let normalizedInstalledAppPath = {
            let candidate = URL(fileURLWithPath: config.installedAppPath).standardizedFileURL.path
            guard !isInstallerScratchPath(candidate), candidate.hasPrefix(normalizedInstallPath + "/") else {
                return defaultInstalledAppPath
            }
            return candidate
        }()

        let normalizedStoragePath = {
            let candidate = URL(fileURLWithPath: config.storagePath).standardizedFileURL.path
            guard !isInstallerScratchPath(candidate), candidate.hasPrefix(normalizedInstallPath + "/") else {
                return defaultStoragePath
            }
            return candidate
        }()

        var refreshed = config
        refreshed.installPath = normalizedInstallPath
        refreshed.installedAppPath = normalizedInstalledAppPath
        refreshed.storagePath = normalizedStoragePath

        if installPathWasTransient {
            refreshed.setupCompletedAt = nil
            refreshed.bootstrapPending = false
            refreshed.bootstrapFailureCount = 0
            refreshed.lastRuntimeHealthAt = nil
            refreshed.pendingLaunchIntro = false
            refreshed.pendingRoachClawSetup = false
        }

        return refreshed
    }

    public static func defaultInstallPath() -> String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("RoachNet", isDirectory: true)
            .path
    }

    public static func defaultInstalledAppPath(installPath: String? = nil) -> String {
        let root = installPath ?? defaultInstallPath()
        return URL(fileURLWithPath: root)
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("RoachNet.app", isDirectory: true)
            .path
    }

    public static func defaultStoragePath(installPath: String? = nil) -> String {
        let root = installPath ?? defaultInstallPath()
        return URL(fileURLWithPath: root)
            .appendingPathComponent("storage", isDirectory: true)
            .path
    }

    public static func defaultLocalBinPath(installPath: String? = nil) -> String {
        let root = installPath ?? defaultInstallPath()
        return URL(fileURLWithPath: root)
            .appendingPathComponent("bin", isDirectory: true)
            .path
    }

    public static func defaultOpenClawWorkspacePath(storagePath: String? = nil, installPath: String? = nil) -> String {
        let root = storagePath ?? defaultStoragePath(installPath: installPath)
        return URL(fileURLWithPath: root)
            .appendingPathComponent("openclaw", isDirectory: true)
            .path
    }

    public static func defaultOllamaModelsPath(storagePath: String? = nil, installPath: String? = nil) -> String {
        let root = storagePath ?? defaultStoragePath(installPath: installPath)
        return URL(fileURLWithPath: root)
            .appendingPathComponent("ollama", isDirectory: true)
            .path
    }

    public static func defaultRuntimeStatePath(storagePath: String? = nil, installPath: String? = nil) -> String {
        if
            let override = ProcessInfo.processInfo.environment["ROACHNET_RUNTIME_STATE_ROOT"],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }

        let root = storagePath ?? defaultStoragePath(installPath: installPath)
        return URL(fileURLWithPath: root)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("runtime-state", isDirectory: true)
            .path
    }

    public static func defaultSetupWorkspaceRoot(installPath: String? = nil) -> String {
        if let override = ProcessInfo.processInfo.environment["ROACHNET_SETUP_WORK_ROOT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }

        let configuredInstallPath = installPath ?? readConfig().installPath
        let normalizedInstallPath = sanitizedInstallPath(configuredInstallPath)
        return URL(fileURLWithPath: normalizedInstallPath)
            .appendingPathComponent(".roachnet-setup", isDirectory: true)
            .path
    }

    public static func portableRuntimeHandshakePath(storagePath: String? = nil, installPath: String? = nil) -> String {
        URL(fileURLWithPath: defaultRuntimeStatePath(storagePath: storagePath, installPath: installPath))
            .appendingPathComponent("native-server-info.json", isDirectory: false)
            .path
    }

    public static func isHomebrewInstallProfile(_ profile: String) -> Bool {
        profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "homebrew-cask"
    }

    public static func preferredBinarySearchPath() -> String {
        let pathSeparator = ":"
        let existingSegments = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: Character(pathSeparator))
            .map(String.init)
        let configuredInstallPath = readConfig().installPath
        let preferredSegments = [
            ProcessInfo.processInfo.environment["ROACHNET_LOCAL_BIN_PATH"],
            defaultLocalBinPath(installPath: configuredInstallPath),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].compactMap { $0 }

        var orderedSegments: [String] = []
        var seen = Set<String>()

        for segment in preferredSegments + existingSegments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                continue
            }

            orderedSegments.append(trimmed)
            seen.insert(trimmed)
        }

        return orderedSegments.joined(separator: pathSeparator)
    }

    public static func readConfig() -> RoachNetInstallerConfig {
        let url = configURL()

        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(RoachNetInstallerConfig.self, from: data)
        else {
            let installPath = defaultInstallPath()
            return RoachNetInstallerConfig(
                installPath: installPath,
                installedAppPath: defaultInstalledAppPath(installPath: installPath),
                storagePath: defaultStoragePath(installPath: installPath)
            )
        }

        let sanitized = sanitizedPersistedConfig(decoded)

        if sanitized.companionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var refreshed = sanitized
            refreshed.companionToken = RoachNetInstallerConfig.generateCompanionToken()
            try? writeConfig(refreshed)
            return refreshed
        }

        if sanitized != decoded {
            var refreshed = decoded
            refreshed = sanitized
            try? writeConfig(refreshed)
            return refreshed
        }

        return sanitized
    }

    private static func configuredRepositoryRoot() -> URL? {
        let configuredInstallPath = readConfig().installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredInstallPath.isEmpty else {
            return nil
        }

        let candidate = URL(fileURLWithPath: configuredInstallPath).standardizedFileURL
        return isRepositoryRoot(candidate) ? candidate : nil
    }

    public static func writeConfig(_ config: RoachNetInstallerConfig) throws {
        let url = configURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: url, options: .atomic)
        // The file carries the companion token; keep it owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func ascendForRepoRoot(from start: URL) -> URL? {
        var current = start.standardizedFileURL

        for _ in 0..<12 {
            if isRepositoryRoot(current) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return nil
    }

    /// A RoachNet source checkout: the Swift package and the content catalogs.
    private static func isRepositoryRoot(_ candidate: URL) -> Bool {
        let fileManager = FileManager.default
        let package = candidate.appendingPathComponent("native/macos/Package.swift").path
        let catalogs = candidate.appendingPathComponent("collections/maps.json").path
        return fileManager.fileExists(atPath: package) && fileManager.fileExists(atPath: catalogs)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
