import Foundation

public struct RoachNetInstallerConfig: Codable, Sendable {
    public var installPath: String
    public var installedAppPath: String
    public var installRoachClaw: Bool
    public var roachClawDefaultModel: String
    public var autoInstallDependencies: Bool
    public var autoLaunch: Bool
    public var releaseChannel: String
    public var setupCompletedAt: String?
    public var pendingLaunchIntro: Bool
    public var pendingRoachClawSetup: Bool

    public init(
        installPath: String,
        installedAppPath: String,
        installRoachClaw: Bool = true,
        roachClawDefaultModel: String = "qwen2.5-coder:7b",
        autoInstallDependencies: Bool = true,
        autoLaunch: Bool = true,
        releaseChannel: String = "stable",
        setupCompletedAt: String? = nil,
        pendingLaunchIntro: Bool = false,
        pendingRoachClawSetup: Bool = false
    ) {
        self.installPath = installPath
        self.installedAppPath = installedAppPath
        self.installRoachClaw = installRoachClaw
        self.roachClawDefaultModel = roachClawDefaultModel
        self.autoInstallDependencies = autoInstallDependencies
        self.autoLaunch = autoLaunch
        self.releaseChannel = releaseChannel
        self.setupCompletedAt = setupCompletedAt
        self.pendingLaunchIntro = pendingLaunchIntro
        self.pendingRoachClawSetup = pendingRoachClawSetup
    }

    private enum CodingKeys: String, CodingKey {
        case installPath
        case installedAppPath
        case installRoachClaw
        case roachClawDefaultModel
        case autoInstallDependencies
        case autoLaunch
        case releaseChannel
        case setupCompletedAt
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

        self.init(
            installPath: installPath,
            installedAppPath: installedAppPath,
            installRoachClaw: try container.decodeIfPresent(Bool.self, forKey: .installRoachClaw) ?? true,
            roachClawDefaultModel: try container.decodeIfPresent(String.self, forKey: .roachClawDefaultModel) ?? "qwen2.5-coder:7b",
            autoInstallDependencies: try container.decodeIfPresent(Bool.self, forKey: .autoInstallDependencies) ?? true,
            autoLaunch: try container.decodeIfPresent(Bool.self, forKey: .autoLaunch) ?? true,
            releaseChannel: try container.decodeIfPresent(String.self, forKey: .releaseChannel) ?? "stable",
            setupCompletedAt: try container.decodeIfPresent(String.self, forKey: .setupCompletedAt),
            pendingLaunchIntro: try container.decodeIfPresent(Bool.self, forKey: .pendingLaunchIntro) ?? false,
            pendingRoachClawSetup: try container.decodeIfPresent(Bool.self, forKey: .pendingRoachClawSetup) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(installPath, forKey: .installPath)
        try container.encode(installedAppPath, forKey: .installedAppPath)
        try container.encode(installRoachClaw, forKey: .installRoachClaw)
        try container.encode(roachClawDefaultModel, forKey: .roachClawDefaultModel)
        try container.encode(autoInstallDependencies, forKey: .autoInstallDependencies)
        try container.encode(autoLaunch, forKey: .autoLaunch)
        try container.encode(releaseChannel, forKey: .releaseChannel)
        try container.encodeIfPresent(setupCompletedAt, forKey: .setupCompletedAt)
        try container.encode(pendingLaunchIntro, forKey: .pendingLaunchIntro)
        try container.encode(pendingRoachClawSetup, forKey: .pendingRoachClawSetup)
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
    public static func repositoryRoot() -> URL? {
        let envCandidates = [
            ProcessInfo.processInfo.environment["ROACHNET_REPO_ROOT"],
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

    public static func preferredNodeBinary() -> String {
        let candidates = [
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

    public static func readConfig() -> RoachNetInstallerConfig {
        let url = configURL()

        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(RoachNetInstallerConfig.self, from: data)
        else {
            let installPath = defaultInstallPath()
            return RoachNetInstallerConfig(
                installPath: installPath,
                installedAppPath: defaultInstalledAppPath(installPath: installPath)
            )
        }

        return decoded
    }

    public static func writeConfig(_ config: RoachNetInstallerConfig) throws {
        let url = configURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: url, options: .atomic)
    }

    private static func ascendForRepoRoot(from start: URL) -> URL? {
        var current = start.standardizedFileURL
        let fileManager = FileManager.default

        for _ in 0..<12 {
            let script = current.appendingPathComponent("scripts/run-roachnet-setup.mjs").path
            let package = current.appendingPathComponent("package.json").path

            if fileManager.fileExists(atPath: script), fileManager.fileExists(atPath: package) {
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
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
