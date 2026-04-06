import Foundation

public struct AIRuntimeStatusResponse: Decodable, Sendable {
    public let provider: String
    public let available: Bool
    public let source: String
    public let baseUrl: String?
    public let error: String?
}

public struct OllamaChatResponse: Decodable, Sendable {
    public struct Message: Decodable, Sendable {
        public let role: String?
        public let content: String
    }

    public let message: Message?
}

public struct AIRuntimeProvidersResponse: Decodable, Sendable {
    public let providers: [String: AIRuntimeStatusResponse]
}

public struct ManagedSystemService: Decodable, Identifiable, Sendable {
    public let service_name: String
    public let friendly_name: String?
    public let description: String?
    public let icon: String?
    public let installed: Bool?
    public let installation_status: String?
    public let status: String?
    public let ui_location: String?
    public let powered_by: String?
    public let display_order: Int?

    public var id: String { service_name }
}

public struct ManagedDownloadJob: Decodable, Identifiable, Sendable {
    public let jobId: String
    public let url: String
    public let progress: Int
    public let filepath: String
    public let filetype: String
    public let status: String?
    public let failedReason: String?

    public var id: String { jobId }
}

public struct RoachClawStatusResponse: Decodable, Sendable {
    public struct CLIStatus: Decodable, Sendable {
        public let openclawAvailable: Bool
        public let clawhubAvailable: Bool
        public let workspacePath: String
        public let runner: String
    }

    public let label: String
    public let ollama: AIRuntimeStatusResponse
    public let openclaw: AIRuntimeStatusResponse
    public let cliStatus: CLIStatus
    public let workspacePath: String
    public let defaultModel: String?
    public let resolvedDefaultModel: String?
    public let preferredMode: String?
    public let ready: Bool?
    public let installedModels: [String]
    public let configFilePath: String?
}

public struct ManagedRoachTailPeer: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let status: String
    public let endpoint: String?
    public let lastSeenAt: String?
    public let allowsExitNode: Bool?
    public let tags: [String]
}

public struct ManagedRoachTailStatusResponse: Decodable, Sendable {
    public let enabled: Bool
    public let networkName: String
    public let deviceName: String
    public let deviceId: String
    public let status: String
    public let relayHost: String?
    public let advertisedUrl: String?
    public let joinCode: String?
    public let lastUpdatedAt: String?
    public let notes: [String]
    public let peers: [ManagedRoachTailPeer]
}

public struct ManagedRoachTailActionResponse: Decodable, Sendable {
    public let success: Bool?
    public let ok: Bool?
    public let message: String?
    public let state: ManagedRoachTailStatusResponse?
}

public struct OllamaInstalledModel: Decodable, Identifiable, Sendable {
    public let name: String
    public let size: Int64?

    public var id: String { name }
}

public struct OpenClawInstalledSkill: Decodable, Identifiable, Sendable {
    public let slug: String
    public let name: String
    public let description: String?
    public let homepage: String?
    public let path: String

    public var id: String { slug }
}

public struct OpenClawInstalledSkillsResponse: Decodable, Sendable {
    public let workspacePath: String
    public let skills: [OpenClawInstalledSkill]
}

public struct MapCuratedCollection: Decodable, Identifiable, Sendable {
    public struct Resource: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let size_mb: Int?
        public let description: String?
    }

    public let slug: String
    public let name: String
    public let description: String?
    public let installed_count: Int?
    public let total_count: Int?
    public let resources: [Resource]

    public var id: String { slug }
}

public struct EducationCategory: Decodable, Identifiable, Sendable {
    public struct Tier: Decodable, Identifiable, Sendable {
        public struct Resource: Decodable, Identifiable, Sendable {
            public let id: String
            public let title: String
            public let size_mb: Int?
            public let description: String?
        }

        public let name: String
        public let slug: String
        public let description: String?
        public let recommended: Bool?
        public let resources: [Resource]

        public var id: String { slug }
    }

    public let slug: String
    public let name: String
    public let description: String?
    public let tiers: [Tier]

    public var id: String { slug }
}

public struct WikipediaStateResponse: Decodable, Sendable {
    public struct Option: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let size_mb: Int?
    }

    public struct Selection: Decodable, Sendable {
        public let optionId: String?
        public let status: String?
        public let filename: String?
        public let url: String?
    }

    public let options: [Option]
    public let currentSelection: Selection?
}

public struct SiteArchive: Decodable, Identifiable, Sendable {
    public let slug: String
    public let title: String?
    public let url: String?
    public let createdAt: String?

    public var id: String { slug }
}

public struct SiteArchivesResponse: Decodable, Sendable {
    public let archives: [SiteArchive]
}

public struct RagFilesResponse: Decodable, Sendable {
    public let files: [String]
}

public struct SystemInfoResponse: Decodable, Sendable {
    public struct CPU: Decodable, Sendable {
        public let manufacturer: String?
        public let brand: String?
        public let physicalCores: Int?
        public let cores: Int?
    }

    public struct Memory: Decodable, Sendable {
        public let total: UInt64
        public let available: UInt64
        public let swapused: UInt64?
    }

    public struct OSInfo: Decodable, Sendable {
        public let hostname: String?
        public let arch: String?
        public let distro: String?
    }

    public struct HardwareProfile: Decodable, Sendable {
        public let platformLabel: String
        public let chipFamily: String
        public let isAppleSilicon: Bool
        public let memoryTier: String
        public let recommendedRuntime: String
        public let recommendedModelClass: String
        public let notes: [String]
        public let warnings: [String]
    }

    public let cpu: CPU
    public let mem: Memory
    public let os: OSInfo
    public let hardwareProfile: HardwareProfile
}

public struct ManagedAppServerInfo: Decodable, Sendable {
    public let pid: Int32?
    public let healthUrl: String
    public let webUrl: String?
    public let companionUrl: String?
    public let companionAdvertisedUrl: String?
    public let target: String?
    public let repoRoot: String?
    public let logPath: String?
}

public struct ManagedAppSnapshot: Sendable {
    public let serverInfo: ManagedAppServerInfo
    public let internetConnected: Bool
    public let systemInfo: SystemInfoResponse
    public let services: [ManagedSystemService]
    public let downloads: [ManagedDownloadJob]
    public let providers: AIRuntimeProvidersResponse
    public let roachClaw: RoachClawStatusResponse
    public let roachTail: ManagedRoachTailStatusResponse
    public let installedModels: [OllamaInstalledModel]
    public let installedSkills: [OpenClawInstalledSkill]
    public let knowledgeFiles: [String]
    public let mapCollections: [MapCuratedCollection]
    public let educationCategories: [EducationCategory]
    public let wikipediaState: WikipediaStateResponse
    public let siteArchives: [SiteArchive]
}

public actor ManagedAppRuntimeBridge {
    public static let shared = ManagedAppRuntimeBridge()

    private var process: Process?
    private var serverInfoURL: URL?
    private var cachedServerInfo: ManagedAppServerInfo?
    private let nativeStartupTimeoutSeconds: TimeInterval = 300

    public init() {}

    public func ensureRunning(using config: RoachNetInstallerConfig) async throws -> ManagedAppServerInfo {
        try await ensureRunning(using: config, allowBootstrapRepair: true)
    }

    private func ensureRunning(
        using config: RoachNetInstallerConfig,
        allowBootstrapRepair: Bool
    ) async throws -> ManagedAppServerInfo {
        if let cachedServerInfo, try await isHealthy(cachedServerInfo.healthUrl) {
            persistHealthyBootstrapStateIfNeeded(using: config)
            return cachedServerInfo
        }

        let repoRoot = resolveRuntimeRoot(from: config)
        let scriptURL = repoRoot.appendingPathComponent("scripts/run-roachnet.mjs")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(domain: "RoachNetRuntime", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Missing RoachNet launcher at \(scriptURL.path)."
            ])
        }

        let infoURL = try containedServerInfoURL()
        serverInfoURL = infoURL

        guard let node = RoachNetRepositoryLocator.preferredPortableNodeBinary() else {
            throw NSError(domain: "RoachNetRuntime", code: 22, userInfo: [
                NSLocalizedDescriptionKey:
                    "RoachNet could not find a portable Node runtime for the contained launch lane."
            ])
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let exitState = ProcessExitState()
        process.currentDirectoryURL = repoRoot
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = node == "/usr/bin/env" ? ["node", scriptURL.path] : [scriptURL.path]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { process in
            exitState.record(process)
        }

        process.environment = runtimeLaunchEnvironment(
            using: config,
            repoRoot: repoRoot,
            nodeBinary: node,
            serverInfoURL: infoURL
        )

        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(nativeStartupTimeoutSeconds)
        while Date() < deadline {
            if
                let data = try? Data(contentsOf: infoURL),
                let serverInfo = try? JSONDecoder().decode(ManagedAppServerInfo.self, from: data),
                try await isHealthy(serverInfo.healthUrl)
            {
                cachedServerInfo = serverInfo
                persistHealthyBootstrapStateIfNeeded(using: config)
                return serverInfo
            }

            if let exitDescription = exitState.describeExit() {
                let stderr = Self.readPipeOutput(from: stderrPipe)
                let stdout = Self.readPipeOutput(from: stdoutPipe)
                let details = [stderr, stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                let startupLogsPath = runtimeLogPath(using: config)
                let message = details.map {
                    "RoachNet exited before it became healthy (\(exitDescription)). \($0)"
                } ?? "RoachNet exited before it became healthy (\(exitDescription)). Check \(startupLogsPath) for startup logs."

                if shouldAttemptBootstrapRepair(using: config, allowBootstrapRepair: allowBootstrapRepair) {
                    let repairedConfig = try await repairContainedBootstrap(using: config)
                    return try await ensureRunning(using: repairedConfig, allowBootstrapRepair: false)
                }

                throw NSError(domain: "RoachNetRuntime", code: 24, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }

            try await Task.sleep(for: .milliseconds(300))
        }

        if shouldAttemptBootstrapRepair(using: config, allowBootstrapRepair: allowBootstrapRepair) {
            let repairedConfig = try await repairContainedBootstrap(using: config)
            return try await ensureRunning(using: repairedConfig, allowBootstrapRepair: false)
        }

        throw NSError(domain: "RoachNetRuntime", code: 21, userInfo: [
            NSLocalizedDescriptionKey:
                "RoachNet did not become healthy before the native timeout (\(Int(nativeStartupTimeoutSeconds)) seconds). Check \(runtimeLogPath(using: config)) for startup logs."
        ])
    }

    public func fetchSnapshot(using config: RoachNetInstallerConfig) async throws -> ManagedAppSnapshot {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        let workspacePath = defaultWorkspacePath(from: config)
        let fallbackSystemInfo = self.fallbackSystemInfo()
        let fallbackProviders = self.fallbackProviders()
        let fallbackRoachClawStatus = self.fallbackRoachClawStatus(
            workspacePath: workspacePath,
            defaultModel: config.roachClawDefaultModel
        )
        let fallbackRoachTailStatus = self.fallbackRoachTailStatus(
            config: config,
            serverInfo: serverInfo
        )

        async let internetConnected = fetchOrFallback(
            "/api/system/internet-status",
            baseURL: baseURL,
            fallback: false
        )
        async let systemInfo = fetchOrFallback(
            "/api/system/info",
            baseURL: baseURL,
            fallback: fallbackSystemInfo
        )
        async let services = fetchOrFallback(
            "/api/system/services",
            baseURL: baseURL,
            fallback: [ManagedSystemService]()
        )
        async let downloads = fetchOrFallback(
            "/api/downloads/jobs",
            baseURL: baseURL,
            fallback: [ManagedDownloadJob]()
        )
        async let providers = fetchOrFallback(
            "/api/system/ai/providers",
            baseURL: baseURL,
            fallback: fallbackProviders
        )
        async let roachClaw = fetchOrFallback(
            "/api/roachclaw/status",
            baseURL: baseURL,
            fallback: fallbackRoachClawStatus
        )
        async let roachTail = fetchOrFallback(
            "/api/companion/roachtail",
            baseURL: baseURL,
            fallback: fallbackRoachTailStatus
        )
        async let models = fetchOrFallback(
            "/api/ollama/installed-models",
            baseURL: baseURL,
            fallback: [OllamaInstalledModel]()
        )
        async let skills = fetchOrFallback(
            "/api/openclaw/skills/installed",
            baseURL: baseURL,
            fallback: OpenClawInstalledSkillsResponse(workspacePath: workspacePath, skills: [])
        )
        async let files = fetchOrFallback(
            "/api/rag/files",
            baseURL: baseURL,
            fallback: RagFilesResponse(files: [])
        )
        async let mapCollections = fetchOrFallback(
            "/api/maps/curated-collections",
            baseURL: baseURL,
            fallback: [MapCuratedCollection]()
        )
        async let educationCategories = fetchOrFallback(
            "/api/zim/curated-categories",
            baseURL: baseURL,
            fallback: [EducationCategory]()
        )
        async let wikipediaState = fetchOrFallback(
            "/api/zim/wikipedia",
            baseURL: baseURL,
            fallback: WikipediaStateResponse(options: [], currentSelection: nil)
        )
        async let siteArchives = fetchOrFallback(
            "/api/site-archives",
            baseURL: baseURL,
            fallback: SiteArchivesResponse(archives: [])
        )

        return ManagedAppSnapshot(
            serverInfo: serverInfo,
            internetConnected: await internetConnected,
            systemInfo: await systemInfo,
            services: await services,
            downloads: await downloads,
            providers: await providers,
            roachClaw: await roachClaw,
            roachTail: await roachTail,
            installedModels: await models,
            installedSkills: (await skills).skills,
            knowledgeFiles: (await files).files,
            mapCollections: await mapCollections,
            educationCategories: await educationCategories,
            wikipediaState: await wikipediaState,
            siteArchives: (await siteArchives).archives
        )
    }

    public func applyRoachClawDefaults(
        using config: RoachNetInstallerConfig,
        model: String,
        workspacePath: String? = nil
    ) async throws {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let model: String
            let workspacePath: String?
        }

        let payload = Payload(model: model, workspacePath: workspacePath)
        let _: EmptyOKResponse = try await post("/api/roachclaw/apply", baseURL: baseURL, body: payload)
    }

    public func installService(
        using config: RoachNetInstallerConfig,
        serviceName: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let service_name: String
        }

        let response: ActionResponse = try await post(
            "/api/system/services/install",
            baseURL: baseURL,
            body: Payload(service_name: serviceName)
        )
        return response.message ?? "Service install queued."
    }

    public func affectService(
        using config: RoachNetInstallerConfig,
        serviceName: String,
        action: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let service_name: String
            let action: String
        }

        let response: ActionResponse = try await post(
            "/api/system/services/affect",
            baseURL: baseURL,
            body: Payload(service_name: serviceName, action: action)
        )
        return response.message ?? "Service action queued."
    }

    public func affectRoachTail(
        using config: RoachNetInstallerConfig,
        action: String,
        relayHost: String? = nil
    ) async throws -> ManagedRoachTailActionResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let action: String
            let relayHost: String?
        }

        return try await post(
            "/api/companion/roachtail/affect",
            baseURL: baseURL,
            body: Payload(action: action, relayHost: relayHost)
        )
    }

    public func downloadBaseMapAssets(using config: RoachNetInstallerConfig) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        let response: ActionResponse = try await post(
            "/api/maps/download-base-assets",
            baseURL: baseURL,
            body: EmptyRequest()
        )
        return response.message ?? "Base map assets queued."
    }

    public func downloadMapCollection(using config: RoachNetInstallerConfig, slug: String) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let slug: String
        }

        let response: ActionResponse = try await post(
            "/api/maps/download-collection",
            baseURL: baseURL,
            body: Payload(slug: slug)
        )
        return response.message ?? "Map collection queued."
    }

    public func downloadEducationTier(
        using config: RoachNetInstallerConfig,
        categorySlug: String,
        tierSlug: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let categorySlug: String
            let tierSlug: String
        }

        let response: ActionResponse = try await post(
            "/api/zim/download-category-tier",
            baseURL: baseURL,
            body: Payload(categorySlug: categorySlug, tierSlug: tierSlug)
        )
        return response.message ?? "Education content queued."
    }

    public func downloadEducationResource(
        using config: RoachNetInstallerConfig,
        categorySlug: String,
        resourceId: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let categorySlug: String
            let resourceId: String
        }

        let response: ActionResponse = try await post(
            "/api/zim/download-category-resource",
            baseURL: baseURL,
            body: Payload(categorySlug: categorySlug, resourceId: resourceId)
        )
        return response.message ?? "Education course queued."
    }

    public func downloadRemoteZim(
        using config: RoachNetInstallerConfig,
        url: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let url: String
        }

        let response: ActionResponse = try await post(
            "/api/zim/download-remote",
            baseURL: baseURL,
            body: Payload(url: url)
        )
        return response.message ?? "Knowledge pack queued."
    }

    public func downloadRemoteMap(
        using config: RoachNetInstallerConfig,
        url: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let url: String
        }

        let response: ActionResponse = try await post(
            "/api/maps/download-remote",
            baseURL: baseURL,
            body: Payload(url: url)
        )
        return response.message ?? "Map pack queued."
    }

    public func selectWikipedia(
        using config: RoachNetInstallerConfig,
        optionId: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let optionId: String
        }

        let response: ActionResponse = try await post(
            "/api/zim/wikipedia/select",
            baseURL: baseURL,
            body: Payload(optionId: optionId)
        )
        return response.message ?? "Wikipedia selection updated."
    }

    public func removeDownloadJob(
        using config: RoachNetInstallerConfig,
        jobId: String
    ) async throws {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        let _: EmptyOKResponse = try await delete("/api/downloads/jobs/\(jobId)", baseURL: baseURL)
    }

    public func resolveRouteURL(using config: RoachNetInstallerConfig, path: String) async throws -> URL {
        let serverInfo = try await ensureRunning(using: config)
        let baseURLString = serverInfo.webUrl ?? serverInfo.healthUrl

        guard let baseURL = URL(string: baseURLString) else {
            throw NSError(domain: "RoachNetRuntime", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "Invalid RoachNet web URL."
            ])
        }

        let root = URL(string: "/", relativeTo: baseURL)?.absoluteURL ?? baseURL
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let resolved = URL(string: normalizedPath, relativeTo: root)?.absoluteURL else {
            throw NSError(domain: "RoachNetRuntime", code: 26, userInfo: [
                NSLocalizedDescriptionKey: "Failed to resolve RoachNet route \(path)."
            ])
        }

        return resolved
    }

    public func sendChat(
        using config: RoachNetInstallerConfig,
        model: String,
        prompt: String,
        timeout: TimeInterval = 120
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct ChatMessage: Encodable {
            let role: String
            let content: String
        }

        struct Payload: Encodable {
            let model: String
            let stream: Bool
            let think: Bool
            let messages: [ChatMessage]
        }

        let payload = Payload(
            model: model,
            stream: false,
            think: false,
            messages: [.init(role: "user", content: prompt)]
        )

        let response: OllamaChatResponse = try await post(
            "/api/ollama/chat",
            baseURL: baseURL,
            body: payload,
            timeoutInterval: timeout
        )
        return response.message?.content ?? ""
    }

    public func stopRuntime(using config: RoachNetInstallerConfig) async {
        let repoRoot = resolveRuntimeRoot(from: config)
        let scriptURL = repoRoot.appendingPathComponent("scripts/run-roachnet.mjs")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            cachedServerInfo = nil
            process = nil
            return
        }

        let node = RoachNetRepositoryLocator.preferredPortableNodeBinary() ?? RoachNetRepositoryLocator.preferredNodeBinary()
        let stopProcess = Process()
        stopProcess.currentDirectoryURL = repoRoot
        stopProcess.executableURL = URL(fileURLWithPath: node)
        stopProcess.arguments = node == "/usr/bin/env" ? ["node", scriptURL.path, "--stop"] : [scriptURL.path, "--stop"]
        stopProcess.environment = runtimeLaunchEnvironment(
            using: config,
            repoRoot: repoRoot,
            nodeBinary: node
        )

        do {
            try stopProcess.run()
            stopProcess.waitUntilExit()
        } catch {
            NSLog("[ManagedAppRuntimeBridge] Failed to stop runtime: %@", error.localizedDescription)
        }

        cachedServerInfo = nil
        process = nil
        serverInfoURL = nil
    }

    public func stopRuntime() async {
        await stopRuntime(using: RoachNetRepositoryLocator.readConfig())
    }

    private func runtimeLaunchEnvironment(
        using config: RoachNetInstallerConfig,
        repoRoot: URL,
        nodeBinary: String,
        serverInfoURL: URL? = nil
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let normalizedStoragePath = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        let normalizedInstallPath = config.installPath.isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        let normalizedWorkspacePath = defaultWorkspacePath(from: config)
        let normalizedLocalBinPath = RoachNetRepositoryLocator.defaultLocalBinPath(installPath: normalizedInstallPath)
        let normalizedOllamaModelsPath = RoachNetRepositoryLocator.defaultOllamaModelsPath(storagePath: normalizedStoragePath)
        let normalizedContainerlessMode = config.useDockerContainerization ? "0" : "1"
        let normalizedNodeBinDirectory = nodeBinary == "/usr/bin/env"
            ? nil
            : URL(fileURLWithPath: nodeBinary).deletingLastPathComponent().path

        environment["ROACHNET_NO_BROWSER"] = "1"
        environment["ROACHNET_REPO_ROOT"] = repoRoot.path
        environment["ROACHNET_RUNTIME_STATE_ROOT"] = RoachNetRepositoryLocator.defaultRuntimeStatePath()
        environment["ROACHNET_LOCAL_BIN_PATH"] = normalizedLocalBinPath
        environment["ROACHNET_NODE_BINARY"] = nodeBinary
        environment["ROACHNET_REQUIRE_PORTABLE_NODE"] = "1"
        environment["ROACHNET_INSTALL_PROFILE"] = config.installProfile
        environment["ROACHNET_BOOTSTRAP_PENDING"] = config.bootstrapPending ? "1" : "0"
        environment["NOMAD_STORAGE_PATH"] = normalizedStoragePath
        environment["OPENCLAW_WORKSPACE_PATH"] = normalizedWorkspacePath
        environment["OLLAMA_MODELS"] = normalizedOllamaModelsPath
        environment["OLLAMA_BASE_URL"] = "http://127.0.0.1:36434"
        environment["OPENCLAW_BASE_URL"] = "http://127.0.0.1:13001"
        environment["ROACHNET_CONTAINERLESS_MODE"] = normalizedContainerlessMode
        environment["ROACHNET_DISABLE_QUEUE"] = normalizedContainerlessMode == "1" ? "1" : "0"
        environment["ROACHNET_ROACHCLAW_DEFAULT_MODEL"] = config.roachClawDefaultModel
        environment["ROACHNET_COMPANION_ENABLED"] = config.companionEnabled ? "1" : "0"
        environment["ROACHNET_COMPANION_HOST"] = config.companionHost
        environment["ROACHNET_COMPANION_PORT"] = String(config.companionPort)
        environment["ROACHNET_COMPANION_TOKEN"] = config.companionToken
        if let serverInfoURL {
            environment["ROACHNET_SERVER_INFO_FILE"] = serverInfoURL.path
        } else {
            environment.removeValue(forKey: "ROACHNET_SERVER_INFO_FILE")
        }
        if config.companionAdvertisedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment.removeValue(forKey: "ROACHNET_COMPANION_ADVERTISED_URL")
        } else {
            environment["ROACHNET_COMPANION_ADVERTISED_URL"] = config.companionAdvertisedURL
        }
        environment["PATH"] = [
            normalizedLocalBinPath,
            normalizedNodeBinDirectory,
            environment["PATH"],
        ]
        .compactMap { $0 }
        .joined(separator: ":")

        return environment
    }

    private func containedServerInfoURL() throws -> URL {
        let url = URL(fileURLWithPath: RoachNetRepositoryLocator.portableRuntimeHandshakePath())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func runtimeLogPath(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        return URL(fileURLWithPath: normalizedStoragePath)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("roachnet-server.log", isDirectory: false)
            .path
    }

    private func runtimeProcessStatePath(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        return URL(fileURLWithPath: normalizedStoragePath)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("roachnet-runtime-processes.json", isDirectory: false)
            .path
    }

    private func runtimeCacheRoot(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        return URL(fileURLWithPath: normalizedStoragePath)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("runtime-cache", isDirectory: true)
            .path
    }

    private func shouldAttemptBootstrapRepair(
        using config: RoachNetInstallerConfig,
        allowBootstrapRepair: Bool
    ) -> Bool {
        allowBootstrapRepair &&
            RoachNetRepositoryLocator.isHomebrewInstallProfile(config.installProfile) &&
            config.bootstrapPending &&
            config.bootstrapFailureCount < 1
    }

    private func repairContainedBootstrap(using config: RoachNetInstallerConfig) async throws -> RoachNetInstallerConfig {
        var updatedConfig = config
        updatedConfig.bootstrapPending = true
        updatedConfig.bootstrapFailureCount += 1

        do {
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
        } catch {
            NSLog("[ManagedAppRuntimeBridge] Failed to persist bootstrap repair state: %@", error.localizedDescription)
        }

        await stopRuntime(using: updatedConfig)

        let fileManager = FileManager.default
        let runtimeCacheRoot = runtimeCacheRoot(using: updatedConfig)
        let runtimeProcessStatePath = runtimeProcessStatePath(using: updatedConfig)
        let handshakePath = RoachNetRepositoryLocator.portableRuntimeHandshakePath()

        if fileManager.fileExists(atPath: runtimeCacheRoot) {
            try? fileManager.removeItem(atPath: runtimeCacheRoot)
        }
        if fileManager.fileExists(atPath: runtimeProcessStatePath) {
            try? fileManager.removeItem(atPath: runtimeProcessStatePath)
        }
        if fileManager.fileExists(atPath: handshakePath) {
            try? fileManager.removeItem(atPath: handshakePath)
        }

        return updatedConfig
    }

    private func persistHealthyBootstrapStateIfNeeded(using config: RoachNetInstallerConfig) {
        guard
            config.bootstrapPending ||
            config.bootstrapFailureCount > 0 ||
            (RoachNetRepositoryLocator.isHomebrewInstallProfile(config.installProfile) && config.lastRuntimeHealthAt == nil)
        else {
            return
        }

        var updatedConfig = config
        updatedConfig.bootstrapPending = false
        updatedConfig.bootstrapFailureCount = 0
        updatedConfig.lastRuntimeHealthAt = ISO8601DateFormatter().string(from: Date())

        do {
            try RoachNetRepositoryLocator.writeConfig(updatedConfig)
        } catch {
            NSLog("[ManagedAppRuntimeBridge] Failed to persist runtime health state: %@", error.localizedDescription)
        }
    }

    private func resolveRuntimeRoot(from config: RoachNetInstallerConfig) -> URL {
        if let bundledRoot = RoachNetRepositoryLocator.bundledRepositoryRoot() {
            return bundledRoot
        }

        let configuredRoot = URL(fileURLWithPath: config.installPath)
        let configuredScript = configuredRoot.appendingPathComponent("scripts/run-roachnet.mjs")

        if FileManager.default.fileExists(atPath: configuredScript.path) {
            return configuredRoot
        }

        return RoachNetRepositoryLocator.repositoryRoot()
            ?? configuredRoot
    }

    private func runtimeBaseURL(from info: ManagedAppServerInfo) throws -> URL {
        guard let baseURL = URL(string: info.healthUrl) else {
            throw NSError(domain: "RoachNetRuntime", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Invalid RoachNet runtime URL."
            ])
        }

        let root = URL(string: "/", relativeTo: baseURL)?.absoluteURL
        guard let root else {
            throw NSError(domain: "RoachNetRuntime", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Failed to compute RoachNet API root."
            ])
        }

        return root
    }

    private func defaultWorkspacePath(from config: RoachNetInstallerConfig) -> String {
        let storageRoot = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath

        return RoachNetRepositoryLocator.defaultOpenClawWorkspacePath(storagePath: storageRoot)
    }

    private func isHealthy(_ healthURLString: String) async throws -> Bool {
        guard let url = URL(string: healthURLString) else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        return (200..<300).contains(status)
    }

    private func fetchOrFallback<Response: Decodable & Sendable>(
        _ path: String,
        baseURL: URL,
        fallback: Response
    ) async -> Response {
        do {
            return try await get(path, baseURL: baseURL)
        } catch {
            NSLog("[ManagedAppRuntimeBridge] Falling back for %@: %@", path, error.localizedDescription)
            return fallback
        }
    }

    private func fallbackProviders() -> AIRuntimeProvidersResponse {
        AIRuntimeProvidersResponse(providers: [
            "ollama": fallbackRuntimeStatus(provider: "ollama"),
            "openclaw": fallbackRuntimeStatus(provider: "openclaw"),
        ])
    }

    private func fallbackRoachClawStatus(
        workspacePath: String,
        defaultModel: String
    ) -> RoachClawStatusResponse {
        RoachClawStatusResponse(
            label: "RoachClaw",
            ollama: fallbackRuntimeStatus(provider: "ollama"),
            openclaw: fallbackRuntimeStatus(provider: "openclaw"),
            cliStatus: .init(
                openclawAvailable: false,
                clawhubAvailable: false,
                workspacePath: workspacePath,
                runner: "none"
            ),
            workspacePath: workspacePath,
            defaultModel: defaultModel,
            resolvedDefaultModel: nil,
            preferredMode: "offline",
            ready: false,
            installedModels: [],
            configFilePath: nil
        )
    }

    private func fallbackRoachTailStatus(
        config: RoachNetInstallerConfig,
        serverInfo: ManagedAppServerInfo
    ) -> ManagedRoachTailStatusResponse {
        ManagedRoachTailStatusResponse(
            enabled: config.companionEnabled,
            networkName: "RoachTail",
            deviceName: Host.current().localizedName ?? "RoachNet desktop",
            deviceId: "roachnet-desktop",
            status: config.companionEnabled ? "armed" : "local-only",
            relayHost: nil,
            advertisedUrl: serverInfo.companionAdvertisedUrl ?? serverInfo.companionUrl,
            joinCode: nil,
            lastUpdatedAt: nil,
            notes: config.companionEnabled
                ? ["RoachTail is still warming up inside the local runtime."]
                : ["RoachTail is off in this runtime configuration."],
            peers: []
        )
    }

    private func fallbackRuntimeStatus(provider: String) -> AIRuntimeStatusResponse {
        AIRuntimeStatusResponse(
            provider: provider,
            available: false,
            source: "none",
            baseUrl: nil,
            error: "Provider unavailable while the local runtime finishes starting."
        )
    }

    private func fallbackSystemInfo() -> SystemInfoResponse {
        SystemInfoResponse(
            cpu: .init(
                manufacturer: nil,
                brand: nil,
                physicalCores: nil,
                cores: nil
            ),
            mem: .init(
                total: 0,
                available: 0,
                swapused: nil
            ),
            os: .init(
                hostname: Host.current().localizedName,
                arch: nil,
                distro: nil
            ),
            hardwareProfile: .init(
                platformLabel: "Unavailable",
                chipFamily: "Unknown",
                isAppleSilicon: false,
                memoryTier: "unknown",
                recommendedRuntime: "native_local",
                recommendedModelClass: "small",
                notes: [],
                warnings: ["System info is still warming up."]
            )
        )
    }

    private static func readPipeOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return ""
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func get<Response: Decodable>(_ path: String, baseURL: URL) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200..<300).contains(status) else {
            throw NSError(domain: "RoachNetRuntime", code: status, userInfo: [
                NSLocalizedDescriptionKey: "GET \(path) failed with status \(status)."
            ])
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func post<Response: Decodable>(
        _ path: String,
        baseURL: URL,
        body: some Encodable,
        timeoutInterval: TimeInterval = 120
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200..<300).contains(status) else {
            throw NSError(domain: "RoachNetRuntime", code: status, userInfo: [
                NSLocalizedDescriptionKey: "POST \(path) failed with status \(status)."
            ])
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func delete<Response: Decodable>(_ path: String, baseURL: URL) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200..<300).contains(status) else {
            throw NSError(domain: "RoachNetRuntime", code: status, userInfo: [
                NSLocalizedDescriptionKey: "DELETE \(path) failed with status \(status)."
            ])
        }

        if data.isEmpty {
            return EmptyOKResponse(success: true, ok: true, message: nil) as! Response
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct EmptyOKResponse: Decodable {
    let success: Bool?
    let ok: Bool?
    let message: String?
}

private struct ActionResponse: Decodable {
    let success: Bool?
    let ok: Bool?
    let message: String?
}

private struct EmptyRequest: Encodable {}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        self.encodeImpl = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private final class ProcessExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var description: String?

    func record(_ process: Process) {
        let reason: String
        switch process.terminationReason {
        case .exit:
            reason = "exit code \(process.terminationStatus)"
        case .uncaughtSignal:
            reason = "signal \(process.terminationStatus)"
        @unknown default:
            reason = "unknown termination \(process.terminationStatus)"
        }

        lock.lock()
        description = reason
        lock.unlock()
    }

    func describeExit() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return description
    }
}
