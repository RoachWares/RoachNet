import Foundation

public struct RoachNetInstallerConfig: Codable, Sendable {
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
    public var distributedInferenceBackend: String
    public var exoBaseUrl: String
    public var exoModelId: String
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
        companionHost: String = "0.0.0.0",
        companionPort: Int = 38111,
        companionToken: String = RoachNetInstallerConfig.generateCompanionToken(),
        companionAdvertisedURL: String = "",
        roachClawDefaultModel: String = "qwen2.5-coder:1.5b",
        distributedInferenceBackend: String = "disabled",
        exoBaseUrl: String = "http://127.0.0.1:52415",
        exoModelId: String = "",
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
        self.distributedInferenceBackend = distributedInferenceBackend
        self.exoBaseUrl = exoBaseUrl
        self.exoModelId = exoModelId
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
        case distributedInferenceBackend
        case exoBaseUrl
        case exoModelId
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
            companionHost: try container.decodeIfPresent(String.self, forKey: .companionHost) ?? "0.0.0.0",
            companionPort: try container.decodeIfPresent(Int.self, forKey: .companionPort) ?? 38111,
            companionToken: try container.decodeIfPresent(String.self, forKey: .companionToken) ?? RoachNetInstallerConfig.generateCompanionToken(),
            companionAdvertisedURL: try container.decodeIfPresent(String.self, forKey: .companionAdvertisedURL) ?? "",
            roachClawDefaultModel: try container.decodeIfPresent(String.self, forKey: .roachClawDefaultModel) ?? "qwen2.5-coder:1.5b",
            distributedInferenceBackend: try container.decodeIfPresent(String.self, forKey: .distributedInferenceBackend) ?? "disabled",
            exoBaseUrl: try container.decodeIfPresent(String.self, forKey: .exoBaseUrl) ?? "http://127.0.0.1:52415",
            exoModelId: try container.decodeIfPresent(String.self, forKey: .exoModelId) ?? "",
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
        try container.encode(distributedInferenceBackend, forKey: .distributedInferenceBackend)
        try container.encode(exoBaseUrl, forKey: .exoBaseUrl)
        try container.encode(exoModelId, forKey: .exoModelId)
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
        public let startedAt: String?
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
    public static func embeddedNodeRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let candidate = resourceURL
            .appendingPathComponent("EmbeddedRuntime", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return candidate
    }

    public static func embeddedNodeBinary() -> String? {
        guard let root = embeddedNodeRoot() else {
            return nil
        }

        let binaryPath = root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("node")
            .path

        return FileManager.default.isExecutableFile(atPath: binaryPath) ? binaryPath : nil
    }

    public static func embeddedNodeBinDirectory() -> String? {
        guard let root = embeddedNodeRoot() else {
            return nil
        }

        let binPath = root.appendingPathComponent("bin", isDirectory: true).path
        return FileManager.default.fileExists(atPath: binPath) ? binPath : nil
    }

    public static func repositoryRoot() -> URL? {
        if
            let explicitOverride = ProcessInfo.processInfo.environment["ROACHNET_REPO_ROOT"],
            !explicitOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let root = ascendForRepoRoot(from: URL(fileURLWithPath: explicitOverride))
        {
            return root
        }

        if isSetupBundle(), let bundledRoot = bundledRepositoryRoot() {
            return bundledRoot
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

        if let bundledRoot = bundledRepositoryRoot() {
            return bundledRoot
        }

        return nil
    }

    public static func bundledRepositoryRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let candidate = resourceURL.appendingPathComponent("RoachNetSource", isDirectory: true)
        guard isRepositoryRoot(candidate) else {
            guard let archiveURL = bundledRepositoryArchiveURL(resourceURL: resourceURL) else {
                return nil
            }

            return extractBundledRepositoryArchive(from: archiveURL)
        }

        return candidate
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

    public static func portableRuntimeHandshakePath(storagePath: String? = nil, installPath: String? = nil) -> String {
        URL(fileURLWithPath: defaultRuntimeStatePath(storagePath: storagePath, installPath: installPath))
            .appendingPathComponent("native-server-info.json", isDirectory: false)
            .path
    }

    public static func isHomebrewInstallProfile(_ profile: String) -> Bool {
        profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "homebrew-cask"
    }

    private static func isAllowedPortableLibraryPath(_ libraryPath: String, runtimeRoot: String) -> Bool {
        if
            libraryPath.hasPrefix("@rpath/") ||
            libraryPath.hasPrefix("@loader_path/") ||
            libraryPath.hasPrefix("@executable_path/")
        {
            return true
        }

        if libraryPath.hasPrefix("/System/Library/") || libraryPath.hasPrefix("/usr/lib/") {
            return true
        }

        let resolvedRuntimeRoot = URL(fileURLWithPath: runtimeRoot).standardizedFileURL.path
        return libraryPath == resolvedRuntimeRoot || libraryPath.hasPrefix("\(resolvedRuntimeRoot)/")
    }

    private static func isPortableNodeBinary(at path: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: path) else {
            return false
        }

        #if os(macOS)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", path]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0,
              let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return false
        }

        let runtimeRoot = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .path

        return output
            .split(separator: "\n")
            .dropFirst()
            .map { line in
                line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: " (compatibility version")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            .filter { !$0.isEmpty }
            .allSatisfy { isAllowedPortableLibraryPath($0, runtimeRoot: runtimeRoot) }
        #else
        return true
        #endif
    }

    public static func preferredNodeBinary() -> String {
        let candidates = [
            embeddedNodeBinary(),
            ProcessInfo.processInfo.environment["ROACHNET_NODE_BINARY"],
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].compactMap { $0 }

        let fileManager = FileManager.default
        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return match
        }

        return "/usr/bin/env"
    }

    public static func preferredPortableNodeBinary() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["ROACHNET_NODE_BINARY"],
            embeddedNodeBinary(),
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].compactMap { $0 }

        return candidates.first(where: { isPortableNodeBinary(at: $0) })
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
            embeddedNodeBinDirectory(),
            "/opt/homebrew/opt/node@22/bin",
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

        if decoded.companionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var refreshed = decoded
            refreshed.companionToken = RoachNetInstallerConfig.generateCompanionToken()
            try? writeConfig(refreshed)
            return refreshed
        }

        return decoded
    }

    private static func bundledRepositoryArchiveURL(resourceURL: URL) -> URL? {
        let archiveURL = resourceURL.appendingPathComponent("RoachNetSource.tar.gz", isDirectory: false)
        return FileManager.default.fileExists(atPath: archiveURL.path) ? archiveURL : nil
    }

    private static func isSetupBundle() -> Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".setup")
    }

    private static func configuredRepositoryRoot() -> URL? {
        let configuredInstallPath = readConfig().installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredInstallPath.isEmpty else {
            return nil
        }

        let candidate = URL(fileURLWithPath: configuredInstallPath).standardizedFileURL
        return isRepositoryRoot(candidate) ? candidate : nil
    }

    private static func bundledRepositoryExtractionRoot() -> URL {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.roachwares.roachnet"
        if bundleIdentifier.hasSuffix(".setup") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("roachnet-setup-source-\(version)", isDirectory: true)
        }

        let installPath = readConfig().installPath
        let normalizedInstallPath = installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultInstallPath()
            : installPath

        return URL(fileURLWithPath: normalizedInstallPath)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("bundled-source", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    private static func extractBundledRepositoryArchive(from archiveURL: URL) -> URL? {
        let fileManager = FileManager.default
        let extractionRoot = bundledRepositoryExtractionRoot()
        let extractedRepositoryRoot = extractionRoot.appendingPathComponent("RoachNetSource", isDirectory: true)
        if isRepositoryRoot(extractedRepositoryRoot) {
            return extractedRepositoryRoot
        }

        let parentDirectory = extractionRoot.deletingLastPathComponent()
        let stagingRoot = parentDirectory.appendingPathComponent(
            "\(extractionRoot.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: extractionRoot)
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archiveURL.path, "-C", stagingRoot.path]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                try? fileManager.removeItem(at: stagingRoot)
                return nil
            }

            let stagedRepositoryRoot = stagingRoot.appendingPathComponent("RoachNetSource", isDirectory: true)
            guard isRepositoryRoot(stagedRepositoryRoot) else {
                try? fileManager.removeItem(at: stagingRoot)
                return nil
            }

            try fileManager.moveItem(at: stagingRoot, to: extractionRoot)
            return extractionRoot.appendingPathComponent("RoachNetSource", isDirectory: true)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            return nil
        }
    }

    public static func writeConfig(_ config: RoachNetInstallerConfig) throws {
        let url = configURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: url, options: .atomic)
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

    private static func isRepositoryRoot(_ candidate: URL) -> Bool {
        let fileManager = FileManager.default
        let script = candidate.appendingPathComponent("scripts/run-roachnet-setup.mjs").path
        let package = candidate.appendingPathComponent("package.json").path
        return fileManager.fileExists(atPath: script) && fileManager.fileExists(atPath: package)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
