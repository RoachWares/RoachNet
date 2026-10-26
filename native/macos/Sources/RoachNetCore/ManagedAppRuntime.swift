import Foundation
import Security

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
    public let error: String?

    public func replyText() throws -> String {
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RoachNetChatError(reason: error)
        }
        return message?.content ?? ""
    }
}

public struct RoachNetChatError: LocalizedError, Sendable {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public var isModelMissing: Bool {
        let lowered = reason.lowercased()
        return lowered.contains("not found") && lowered.contains("model")
    }

    public var errorDescription: String? { reason }
}

public struct AIRuntimeProvidersResponse: Decodable, Sendable {
    public let providers: [String: AIRuntimeStatusResponse]
}

public struct RoachClawPlaybookLaneResponse: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let status: String
    public let icon: String?
    public let accent: String?
    public let localFirst: Bool?
    public let actions: [String]?
}

public struct RoachClawFeatureGroupResponse: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let status: String
    public let nativeSurface: String?
    public let capabilities: [String]?
}

public struct RoachClawReferenceSourceResponse: Decodable, Sendable {
    public let repository: String
    public let commit: String
    public let latestSeenCommit: String?
    public let posture: String?
    public let sourceKind: String?
}

public struct RoachClawReferenceModuleResponse: Decodable, Identifiable, Sendable {
    public let id: String
    public let category: String
    public let source: String
    public let nativeSurface: String
    public let status: String
}

public struct RoachClawReferenceInventoryGroupResponse: Decodable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let prefix: String
    public let fileCount: Int
    public let nativeSurface: String
    public let status: String
    public let notes: String?
}

public struct RoachClawReferenceInventoryResponse: Decodable, Sendable {
    public let schema: String
    public let repository: String
    public let commit: String
    public let latestSeenCommit: String?
    public let sourceKind: String?
    public let observedFileCount: Int
    public let functionalFileCount: Int
    public let coverageGroups: [RoachClawReferenceInventoryGroupResponse]
    public let nonShippingPolicy: String?
}

public struct RoachClawPlaybookResponse: Decodable, Sendable {
    public let schema: String
    public let source: String?
    public let updatedAt: String?
    public let capabilities: [String]?
    public let referenceSource: RoachClawReferenceSourceResponse?
    public let featureGroups: [RoachClawFeatureGroupResponse]?
    public let referenceModules: [RoachClawReferenceModuleResponse]?
    public let referenceInventory: RoachClawReferenceInventoryResponse?
    public let lanes: [RoachClawPlaybookLaneResponse]
}

public struct RoachClawOperationsResponse: Decodable, Sendable {
    public struct Probe: Decodable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let available: Bool
        public let detail: String?
    }

    public struct Diagnostics: Decodable, Sendable {
        public let status: String
        public let probes: [Probe]
        public let warnings: [String]?
    }

    public struct Contacts: Decodable, Sendable {
        public let status: String
        public let storagePath: String?
        public let recordCount: Int?
        public let scopes: [String]
        public let notes: [String]?
    }

    public struct HookEndpoint: Decodable, Identifiable, Sendable {
        public let id: String
        public let method: String
        public let path: String
        public let scope: String
    }

    public struct Hooks: Decodable, Sendable {
        public let status: String
        public let storagePath: String?
        public let endpoints: [HookEndpoint]
        public let secretsPolicy: String?
    }

    public struct JobSummary: Decodable, Identifiable, Sendable {
        public let id: String
        public let kind: String?
        public let status: String
        public let progress: Int?
        public let target: String?
        public let updatedAt: String?
    }

    public struct Scheduler: Decodable, Sendable {
        public let status: String
        public let storagePath: String?
        public let pending: Int
    }

    public struct Jobs: Decodable, Sendable {
        public let status: String
        public let downloads: [JobSummary]
        public let scheduler: Scheduler
    }

    public struct Reports: Decodable, Sendable {
        public let status: String
        public let root: String?
        public let formats: [String]
        public let templates: [String]
        public let count: Int?
    }

    public struct CollectionLane: Decodable, Sendable {
        public let status: String
        public let storagePath: String?
        public let count: Int?
        public let open: Int?
        public let messages: Int?
        public let drafts: Int?
        public let active: Int?
        public let queued: Int?
        public let stalled: Int?
        public let priority: String?
        public let route: String?
        public let hotkey: String?
        public let summaryItems: [String]?
        public let detail: String?
        public let actions: [String]?
    }

    public struct Uploads: Decodable, Sendable {
        public let status: String
        public let root: String?
        public let maxRequestBytes: Int?
        public let ownership: String?
        public let isolation: String?
    }

    public struct Preferences: Decodable, Sendable {
        public let status: String
        public let storagePath: String?
        public let scrubPolicy: String?
        public let appearance: [String]?
    }

    public struct AdminRecovery: Decodable, Sendable {
        public let status: String
        public let actions: [String]
        public let remoteAccess: Bool
    }

    public let schema: String
    public let updatedAt: String?
    public let diagnostics: Diagnostics?
    public let serviceHealth: CollectionLane?
    public let contacts: Contacts?
    public let hooks: Hooks?
    public let jobs: Jobs?
    public let notesTasks: CollectionLane?
    public let calendar: CollectionLane?
    public let reports: Reports?
    public let memories: CollectionLane?
    public let skills: CollectionLane?
    public let editorDrafts: CollectionLane?
    public let migrationDocumentTools: CollectionLane?
    public let searchCache: CollectionLane?
    public let gallery: CollectionLane?
    public let webhooks: CollectionLane?
    public let agentRuns: CollectionLane?
    public let contextCompactions: CollectionLane?
    public let toolIndex: CollectionLane?
    public let events: CollectionLane?
    public let commandDeck: CollectionLane?
    public let contextRail: CollectionLane?
    public let vaultNavigator: CollectionLane?
    public let agentMonitor: CollectionLane?
    public let orchestrationDashboard: CollectionLane?
    public let mail: CollectionLane?
    public let presets: CollectionLane?
    public let signatures: CollectionLane?
    public let apiTokens: CollectionLane?
    public let cloudProviders: CollectionLane?
    public let workspaceBrowser: CollectionLane?
    public let userTime: CollectionLane?
    public let cookbookServeLifecycle: CollectionLane?
    public let scopedToolBridge: CollectionLane?
    public let tlsOverrides: CollectionLane?
    public let uploadLimits: CollectionLane?
    public let memoryProvider: CollectionLane?
    public let providerOAuth: CollectionLane?
    public let embeddingLanes: CollectionLane?
    public let toolPolicy: CollectionLane?
    public let backups: CollectionLane?
    public let uploads: Uploads?
    public let preferences: Preferences?
    public let adminRecovery: AdminRecovery?
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

    public struct PortableProfile: Decodable, Sendable {
        public struct ProviderEndpoints: Decodable, Sendable {
            public let ollamaBaseUrl: String?
            public let openclawBaseUrl: String?
        }

        public struct RuntimeHints: Decodable, Sendable {
            public let contained: Bool
            public let launchMode: String
            public let notes: [String]
        }

        public let profileVersion: Int
        public let label: String
        public let profilePath: String
        public let portableRoot: String
        public let workspacePath: String
        public let stateDir: String
        public let configFilePath: String?
        public let preferredMode: String
        public let defaultModel: String?
        public let preferredModels: [String]
        public let installedModels: [String]
        public let providerEndpoints: ProviderEndpoints
        public let runtimeHints: RuntimeHints
        public let updatedAt: String
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
    public let preferredModels: [String]?
    public let configFilePath: String?
    public let portableProfile: PortableProfile?
    public let playbook: RoachClawPlaybookResponse?
    public let operations: RoachClawOperationsResponse?
    public let defaultModelInstalled: Bool?
    public let modelPulls: [RoachModelPull]?
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

public struct ManagedRoachTailControlPlane: Decodable, Sendable {
    public let provider: String
    public let designReference: String?
    public let namespace: String?
    public let nodeApproval: String?
    public let routeApproval: String?
    public let authKeyTtlSeconds: Int?
    public let joinCodeTtlSeconds: Int?
    public let policyMode: String?
    public let dnsName: String?
}

public struct ManagedRoachTailPreAuthKey: Decodable, Identifiable, Sendable {
    public let id: String
    public let createdAt: String?
    public let expiresAt: String?
    public let reusable: Bool?
    public let ephemeral: Bool?
    public let used: Bool?
    public let tags: [String]?
    public let capabilities: [String]?
}

public struct ManagedRoachTailRoute: Decodable, Identifiable, Sendable {
    public let id: String
    public let type: String?
    public let target: String?
    public let approved: Bool?
    public let advertised: Bool?
    public let primary: Bool?
    public let tags: [String]?
    public let description: String?
}

public struct ManagedRoachTailDERPRegion: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let host: String?
    public let url: String?
    public let embedded: Bool?
}

public struct ManagedRoachTailDERPMap: Decodable, Sendable {
    public let mode: String?
    public let regions: [ManagedRoachTailDERPRegion]?
}

public struct ManagedRoachTailStatusResponse: Decodable, Sendable {
    public let enabled: Bool
    public let networkName: String
    public let deviceName: String
    public let deviceId: String
    public let status: String
    public let transportMode: String?
    public let secureOverlay: Bool?
    public let relayHost: String?
    public let advertisedUrl: String?
    public let runtimeOrigin: String?
    public let runtimeTunnelUrl: String?
    public let joinCode: String?
    public let joinCodeExpiresAt: String?
    public let pairingPayload: String?
    public let pairingIssuedAt: String?
    public let lastUpdatedAt: String?
    public let notes: [String]
    public let peers: [ManagedRoachTailPeer]
    public let controlPlane: ManagedRoachTailControlPlane?
    public let preAuthKeys: [ManagedRoachTailPreAuthKey]?
    public let routes: [ManagedRoachTailRoute]?
    public let derpMap: ManagedRoachTailDERPMap?
}

public struct ManagedRoachTailActionResponse: Decodable, Sendable {
    public let success: Bool?
    public let ok: Bool?
    public let message: String?
    public let state: ManagedRoachTailStatusResponse?
}

public struct ManagedRoachSyncActionResponse: Decodable, Sendable {
    public let success: Bool?
    public let ok: Bool?
    public let message: String?
    public let state: ManagedRoachSyncStatusResponse?
}

public struct ManagedRoachSyncPeer: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let deviceId: String
    public let status: String
    public let lastSeenAt: String?
}

public struct ManagedRoachSyncStatusResponse: Decodable, Sendable {
    public let enabled: Bool
    public let provider: String
    public let networkName: String
    public let deviceName: String
    public let deviceId: String
    public let status: String
    public let folderId: String
    public let folderPath: String
    public let guiUrl: String?
    public let apiUrl: String?
    public let transportMode: String?
    public let secureOverlay: Bool?
    public let notes: [String]
    public let peers: [ManagedRoachSyncPeer]
    public let lastUpdatedAt: String?
}

public struct ManagedAccountStateResponse: Decodable, Sendable {
    public let linked: Bool
    public let provider: String
    public let portalUrl: String
    public let accountId: String?
    public let email: String?
    public let displayName: String?
    public let status: String
    public let settingsSyncEnabled: Bool
    public let savedAppsSyncEnabled: Bool
    public let hostedChatEnabled: Bool
    public let aliasHost: String
    public let bridgeUrl: String?
    public let runtimeOrigin: String?
    public let linkedAt: String?
    public let lastSeenAt: String?
    public let lastUpdatedAt: String?
    public let notes: [String]
}

public struct ManagedAccountActionResponse: Decodable, Sendable {
    public let success: Bool?
    public let message: String?
    public let state: ManagedAccountStateResponse?
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
        public let url: String?

        public var fileName: String {
            if let url, let name = URL(string: url)?.lastPathComponent, name.hasSuffix(".pmtiles") { return name }
            return "\(id).pmtiles"
        }
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
    public let installedTierSlug: String?
    public let tiers: [Tier]

    public var id: String { slug }

    public var tierToRecommend: Tier? {
        tiers.first { $0.recommended == true && !$0.resources.isEmpty } ?? tiers.first { !$0.resources.isEmpty }
    }
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

public struct RoachNetLatestVersionResponse: Decodable, Sendable {
    public let success: Bool
    public let updateAvailable: Bool
    public let currentVersion: String
    public let latestVersion: String
    public let message: String?
}

public struct RoachNetSystemUpdateStatusResponse: Decodable, Sendable {
    public let stage: String
    public let progress: Int
    public let message: String
    public let timestamp: String
}

public struct RoachNetSystemUpdateRequestResponse: Decodable, Sendable {
    public let success: Bool
    public let message: String?
    public let note: String?
    public let error: String?
}

public struct RoachNetBenchmarkStatusResponse: Decodable, Sendable {
    public let status: String
    public let benchmarkId: String?

    public init(status: String, benchmarkId: String?) {
        self.status = status
        self.benchmarkId = benchmarkId
    }
}

public struct RoachNetBenchmarkRunResponse: Decodable, Sendable {
    public let success: Bool
    public let job_id: String?
    public let benchmark_id: String?
    public let message: String?
    public let error: String?
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
    public let account: ManagedAccountStateResponse
    public let roachTail: ManagedRoachTailStatusResponse
    public let roachSync: ManagedRoachSyncStatusResponse
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
    public static let appleSiliconLocalAIProfile = "apple-silicon-efficient"
    public static let appleSiliconLocalAIEnvironmentDefaults: [String: String] = [
        "OLLAMA_FLASH_ATTENTION": "1",
        "OLLAMA_KEEP_ALIVE": "15m",
        "OLLAMA_MAX_LOADED_MODELS": "1",
        "OLLAMA_MAX_QUEUE": "32",
        "OLLAMA_NUM_PARALLEL": "1",
        "ROACHNET_APPLE_SILICON_NATIVE": "1",
        "ROACHNET_LOCAL_AI_PROFILE": appleSiliconLocalAIProfile,
    ]

    private var process: Process?
    private var serverInfoURL: URL?
    private var cachedServerInfo: ManagedAppServerInfo?
    private var apiToken: String?
    private var startupTask: Task<ManagedAppServerInfo, Error>?
    private let nativeStartupTimeoutSeconds: TimeInterval = 300

    public init() {}

    static func launchEnvironment(_ environment: [String: String], token: String, onInput: Bool) -> [String: String] {
        var environment = environment
        if onInput {
            environment.removeValue(forKey: "ROACHNET_API_TOKEN")
            environment["ROACHNET_API_TOKEN_STDIN"] = "1"
        } else {
            environment.removeValue(forKey: "ROACHNET_API_TOKEN_STDIN")
            environment["ROACHNET_API_TOKEN"] = token
        }
        return environment
    }

    static func describesRuntime(
        _ info: ManagedAppServerInfo,
        startedAs pid: Int32,
        listeningPorts: (Int32) -> Set<UInt16> = ProcessSockets.listeningTCPPorts(of:)
    ) -> Bool {
        func origin(_ address: String) -> (host: String, port: Int)? {
            guard let url = URL(string: address), url.scheme == "http", url.user == nil, url.password == nil,
                let host = url.host, host == "127.0.0.1" || host == "::1",
                let port = url.port, (1...65_535).contains(port)
            else { return nil }
            return (host, port)
        }
        guard pid > 0, info.pid == pid, let health = origin(info.healthUrl) else { return false }
        if let web = info.webUrl {
            guard let api = origin(web), api == health else { return false }
        }
        return listeningPorts(pid).contains(UInt16(health.port))
    }

    enum LaunchTokenCheck: Equatable {
        case refused
        case answered(Int)
        case noAnswer
    }

    static let launchTokenCheckPath = "api/system/info"

    static func checkLaunchToken(at baseURL: URL, session: URLSession = .shared) async -> LaunchTokenCheck {
        var request = URLRequest(url: baseURL.appending(path: launchTokenCheckPath))
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await session.data(for: request),
            let status = (response as? HTTPURLResponse)?.statusCode
        else { return .noAnswer }
        return status == 401 ? .refused : .answered(status)
    }

    static func launchTokenInput(_ token: String) -> Data { Data((token + "\n").utf8) }

    private static func handOver(_ token: String, to handle: FileHandle) throws {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { try? handle.close() }
        try handle.write(contentsOf: launchTokenInput(token))
    }

    public static var isAppleSiliconNativeRuntime: Bool {
        #if os(macOS) && arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static func applyAppleSiliconLocalAIEnvironmentDefaults(
        to environment: inout [String: String],
        isAppleSiliconNative: Bool = ManagedAppRuntimeBridge.isAppleSiliconNativeRuntime
    ) {
        guard isAppleSiliconNative,
            environment["ROACHNET_DISABLE_APPLE_SILICON_AI_DEFAULTS"] != "1"
        else {
            return
        }

        for (key, value) in appleSiliconLocalAIEnvironmentDefaults where environment[key].isBlankEnvironmentValue {
            environment[key] = value
        }
    }

    public static func localRuntimeRouteURL(baseURLString: String, path rawPath: String) throws -> URL {
        guard let baseURL = URL(string: baseURLString),
            let scheme = baseURL.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            baseURL.host?.isEmpty == false
        else {
            throw NSError(
                domain: "RoachNetRuntime", code: 25,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid RoachNet web URL."
                ])
        }

        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
            !trimmedPath.hasPrefix("//"),
            !trimmedPath.contains("\\"),
            trimmedPath.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw NSError(
                domain: "RoachNetRuntime", code: 26,
                userInfo: [
                    NSLocalizedDescriptionKey: "RoachNet only opens its own local pages, and this address isn't one."
                ])
        }

        guard let parsedRoute = URLComponents(string: trimmedPath),
            parsedRoute.scheme == nil,
            parsedRoute.host == nil
        else {
            throw NSError(
                domain: "RoachNetRuntime", code: 26,
                userInfo: [
                    NSLocalizedDescriptionKey: "RoachNet only opens its own local pages, and this address isn't one."
                ])
        }

        let rootURL = URL(string: "/", relativeTo: baseURL)?.absoluteURL ?? baseURL
        guard var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "RoachNetRuntime", code: 26,
                userInfo: [
                    NSLocalizedDescriptionKey: "RoachNet couldn't build the address for that page."
                ])
        }

        let routePath = parsedRoute.path.hasPrefix("/") ? parsedRoute.path : "/\(parsedRoute.path)"
        components.path = routePath.isEmpty ? "/" : routePath
        components.percentEncodedQuery = parsedRoute.percentEncodedQuery
        components.percentEncodedFragment = parsedRoute.percentEncodedFragment

        guard let resolved = components.url else {
            throw NSError(
                domain: "RoachNetRuntime", code: 26,
                userInfo: [
                    NSLocalizedDescriptionKey: "RoachNet couldn't build the address for that page."
                ])
        }

        return resolved
    }

    private var startedRuntimeIsRunning: Bool { process?.isRunning == true }

    public func ensureRunning(using config: RoachNetInstallerConfig) async throws -> ManagedAppServerInfo {
        if let cachedServerInfo, startedRuntimeIsRunning, try await isHealthy(cachedServerInfo.healthUrl) {
            persistHealthyBootstrapStateIfNeeded(using: config)
            return cachedServerInfo
        }

        if let startupTask {
            return try await startupTask.value
        }

        let task = Task { [self] in
            try await startRuntime(using: config, allowBootstrapRepair: true)
        }
        startupTask = task

        do {
            let serverInfo = try await task.value
            startupTask = nil
            return serverInfo
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func startRuntime(
        using config: RoachNetInstallerConfig,
        allowBootstrapRepair: Bool
    ) async throws -> ManagedAppServerInfo {
        if let cachedServerInfo, startedRuntimeIsRunning, try await isHealthy(cachedServerInfo.healthUrl) {
            persistHealthyBootstrapStateIfNeeded(using: config)
            return cachedServerInfo
        }

        let launch = try resolveRuntimeLaunch(using: config)
        let infoURL = try containedServerInfoURL(using: config)
        serverInfoURL = infoURL

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        let exitState = ProcessExitState()
        process.currentDirectoryURL = launch.workingDirectory
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }
        process.terminationHandler = { process in
            exitState.record(process)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        let launchToken = Self.newAPIToken()
        apiToken = launchToken
        process.environment = Self.launchEnvironment(
            runtimeLaunchEnvironment(
                using: config,
                repoRoot: launch.repoRoot,
                nodeBinary: launch.nodeBinary,
                serverInfoURL: infoURL
            ), token: launchToken, onInput: launch.takesTokenOnInput)
        let tokenPipe = launch.takesTokenOnInput ? Pipe() : nil
        process.standardInput = tokenPipe ?? FileHandle.nullDevice

        try process.run()
        self.process = process
        if let tokenPipe {
            try? tokenPipe.fileHandleForReading.close()
            try? Self.handOver(launchToken, to: tokenPipe.fileHandleForWriting)
        }

        let deadline = Date().addingTimeInterval(nativeStartupTimeoutSeconds)
        while Date() < deadline {
            if let data = try? Data(contentsOf: infoURL),
                let serverInfo = try? JSONDecoder().decode(ManagedAppServerInfo.self, from: data),
                Self.describesRuntime(serverInfo, startedAs: process.processIdentifier),
                try await isHealthy(serverInfo.healthUrl)
            {
                let baseURL = try runtimeBaseURL(from: serverInfo)
                switch await Self.checkLaunchToken(at: baseURL) {
                case .refused:
                    cachedServerInfo = serverInfo
                    persistHealthyBootstrapStateIfNeeded(using: config)
                    return serverInfo
                case .answered(let status):
                    process.terminate()
                    self.process = nil
                    apiToken = nil
                    throw NSError(
                        domain: "RoachNetRuntime", code: 27,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The RoachNet runtime answered a request that didn't carry its launch token (HTTP \(status)), so its local API would have been open to every program on this Mac. RoachNet stopped it. Reinstall RoachNet with RoachNet Setup to restore its runtime helper."
                        ])
                case .noAnswer:
                    break
                }
            }

            if let exitDescription = exitState.describeExit() {
                let stderr = stderrBuffer.text
                let stdout = stdoutBuffer.text
                let details = [stderr, stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                let startupLogsPath = runtimeLogPath(using: config)
                let message =
                    details.map {
                        "The RoachNet runtime stopped before it finished starting (\(exitDescription)). \($0)"
                    }
                    ?? "The RoachNet runtime stopped before it finished starting (\(exitDescription)). Check \(startupLogsPath) for startup logs."

                if shouldAttemptBootstrapRepair(using: config, allowBootstrapRepair: allowBootstrapRepair) {
                    let repairedConfig = try await repairContainedBootstrap(using: config)
                    return try await startRuntime(using: repairedConfig, allowBootstrapRepair: false)
                }

                throw NSError(
                    domain: "RoachNetRuntime", code: 24,
                    userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])
            }

            try await Task.sleep(for: .milliseconds(300))
        }

        if shouldAttemptBootstrapRepair(using: config, allowBootstrapRepair: allowBootstrapRepair) {
            let repairedConfig = try await repairContainedBootstrap(using: config)
            return try await startRuntime(using: repairedConfig, allowBootstrapRepair: false)
        }

        throw NSError(
            domain: "RoachNetRuntime", code: 21,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The RoachNet runtime didn't finish starting within \(Int(nativeStartupTimeoutSeconds)) seconds. Check \(runtimeLogPath(using: config)) for startup logs."
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
        let fallbackAccountStatus = self.fallbackAccountStatus(
            config: config,
            serverInfo: serverInfo
        )
        let fallbackRoachTailStatus = self.fallbackRoachTailStatus(
            config: config,
            serverInfo: serverInfo
        )
        let fallbackRoachSyncStatus = self.fallbackRoachSyncStatus(
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
        async let account = fetchOrFallback(
            "/api/companion/account",
            baseURL: baseURL,
            fallback: fallbackAccountStatus
        )
        async let roachTail = fetchOrFallback(
            "/api/companion/roachtail",
            baseURL: baseURL,
            fallback: fallbackRoachTailStatus
        )
        async let roachSync = fetchOrFallback(
            "/api/companion/roachsync",
            baseURL: baseURL,
            fallback: fallbackRoachSyncStatus
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
            account: await account,
            roachTail: await roachTail,
            roachSync: await roachSync,
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

    public func fetchModelLibrary(using config: RoachNetInstallerConfig) async throws -> RoachModelLibrary {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        return try await get("/api/roachclaw/models", baseURL: baseURL)
    }

    public func downloadLibraryModel(using config: RoachNetInstallerConfig, model: String) async throws {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        let _: ModelLibraryActionResponse = try await post(
            "/api/roachclaw/models/pull", baseURL: baseURL, body: ModelLibraryActionPayload(model: model)
        )
    }

    public func stopLibraryModelDownload(using config: RoachNetInstallerConfig, model: String) async throws {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        let _: ModelLibraryActionResponse = try await post(
            "/api/roachclaw/models/stop", baseURL: baseURL, body: ModelLibraryActionPayload(model: model)
        )
    }

    private struct ModelLibraryActionPayload: Encodable {
        let model: String
    }

    private struct ModelLibraryActionResponse: Decodable {
        let ok: Bool?
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
        relayHost: String? = nil,
        peerId: String? = nil
    ) async throws -> ManagedRoachTailActionResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let action: String
            let relayHost: String?
            let peerId: String?
        }

        return try await post(
            "/api/companion/roachtail/affect",
            baseURL: baseURL,
            body: Payload(action: action, relayHost: relayHost, peerId: peerId)
        )
    }

    public func affectRoachSync(
        using config: RoachNetInstallerConfig,
        action: String,
        folderPath: String? = nil
    ) async throws -> ManagedRoachSyncActionResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let action: String
            let folderPath: String?
        }

        return try await post(
            "/api/companion/roachsync/affect",
            baseURL: baseURL,
            body: Payload(action: action, folderPath: folderPath)
        )
    }

    public func affectAccount(
        using config: RoachNetInstallerConfig,
        action: String,
        accountId: String? = nil,
        email: String? = nil,
        displayName: String? = nil,
        portalUrl: String? = nil,
        settingsSyncEnabled: Bool? = nil,
        savedAppsSyncEnabled: Bool? = nil,
        hostedChatEnabled: Bool? = nil
    ) async throws -> ManagedAccountActionResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let action: String
            let accountId: String?
            let email: String?
            let displayName: String?
            let portalUrl: String?
            let settingsSyncEnabled: Bool?
            let savedAppsSyncEnabled: Bool?
            let hostedChatEnabled: Bool?
        }

        return try await post(
            "/api/companion/account/affect",
            baseURL: baseURL,
            body: Payload(
                action: action,
                accountId: accountId,
                email: email,
                displayName: displayName,
                portalUrl: portalUrl,
                settingsSyncEnabled: settingsSyncEnabled,
                savedAppsSyncEnabled: savedAppsSyncEnabled,
                hostedChatEnabled: hostedChatEnabled
            )
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

    public func downloadRoachSpeechPack(
        using config: RoachNetInstallerConfig,
        url: String,
        packID: String,
        kind: String
    ) async throws -> String {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let url: String
            let packID: String
            let kind: String
        }

        let response: ActionResponse = try await post(
            "/api/roachspeech/model-packs/download",
            baseURL: baseURL,
            body: Payload(url: url, packID: packID, kind: kind)
        )
        return response.message ?? "RoachSpeech pack queued."
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

    public func checkLatestVersion(
        using config: RoachNetInstallerConfig,
        force: Bool
    ) async throws -> RoachNetLatestVersionResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        var components = URLComponents(
            url: baseURL.appending(path: "/api/system/latest-version"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "force", value: force ? "true" : "false")]

        guard let url = components?.url else {
            throw NSError(
                domain: "RoachNetRuntime", code: 30,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RoachNet couldn't build the update check address. Your installed version keeps working."
                ])
        }

        return try await get(url: url)
    }

    public func getSystemUpdateStatus(
        using config: RoachNetInstallerConfig
    ) async throws -> RoachNetSystemUpdateStatusResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        return try await get("/api/system/update/status", baseURL: baseURL)
    }

    public func requestSystemUpdate(
        using config: RoachNetInstallerConfig
    ) async throws -> RoachNetSystemUpdateRequestResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        return try await post(
            "/api/system/update",
            baseURL: baseURL,
            body: EmptyRequest()
        )
    }

    public func getBenchmarkStatus(
        using config: RoachNetInstallerConfig
    ) async throws -> RoachNetBenchmarkStatusResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        return try await get("/api/benchmark/status", baseURL: baseURL)
    }

    public func runBenchmark(
        using config: RoachNetInstallerConfig,
        type: String,
        synchronous: Bool = false
    ) async throws -> RoachNetBenchmarkRunResponse {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)

        struct Payload: Encodable {
            let benchmark_type: String
        }

        let suffix = synchronous ? "?sync=true" : ""
        return try await post(
            "/api/benchmark/run\(suffix)",
            baseURL: baseURL,
            body: Payload(benchmark_type: type),
            timeoutInterval: synchronous ? 600 : 120
        )
    }

    public func resolveRouteURL(using config: RoachNetInstallerConfig, path: String) async throws -> URL {
        let serverInfo = try await ensureRunning(using: config)
        let baseURLString = serverInfo.webUrl ?? serverInfo.healthUrl

        return try Self.localRuntimeRouteURL(baseURLString: baseURLString, path: path)
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
        return try response.replyText()
    }

    public func stopRuntime(using config: RoachNetInstallerConfig) async {
        guard let launch = try? resolveRuntimeLaunch(using: config, allowAnyNode: true) else {
            cachedServerInfo = nil
            process = nil
            return
        }

        let stopProcess = Process()
        stopProcess.currentDirectoryURL = launch.workingDirectory
        stopProcess.executableURL = URL(fileURLWithPath: launch.executable)
        stopProcess.arguments = launch.arguments + ["--stop"]
        stopProcess.environment = runtimeLaunchEnvironment(
            using: config,
            repoRoot: launch.repoRoot,
            nodeBinary: launch.nodeBinary
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
        nodeBinary: String?,
        serverInfoURL: URL? = nil
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ROACHNET_API_TOKEN")
        let normalizedStoragePath =
            config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        let normalizedInstallPath =
            config.installPath.isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        let normalizedWorkspacePath = defaultWorkspacePath(from: config)
        let normalizedLocalBinPath = RoachNetRepositoryLocator.defaultLocalBinPath(installPath: normalizedInstallPath)
        let normalizedOllamaModelsPath = RoachNetRepositoryLocator.defaultOllamaModelsPath(
            storagePath: normalizedStoragePath)
        let normalizedRuntimeStatePath = runtimeStateRoot(using: config)
        let normalizedContainerlessMode = config.useDockerContainerization ? "0" : "1"
        let normalizedNodeBinDirectory = nodeBinary.flatMap { binary in
            binary == "/usr/bin/env" ? nil : URL(fileURLWithPath: binary).deletingLastPathComponent().path
        }

        environment["ROACHNET_NO_BROWSER"] = "1"
        environment["ROACHNET_REPO_ROOT"] = repoRoot.path
        environment["ROACHNET_RUNTIME_STATE_ROOT"] = normalizedRuntimeStatePath
        environment["ROACHNET_LOCAL_BIN_PATH"] = normalizedLocalBinPath
        if let nodeBinary {
            environment["ROACHNET_NODE_BINARY"] = nodeBinary
            environment["ROACHNET_REQUIRE_PORTABLE_NODE"] = "1"
            environment["ROACHNET_RUNTIME_KIND"] = "node-compat"
        } else {
            environment.removeValue(forKey: "ROACHNET_NODE_BINARY")
            environment.removeValue(forKey: "ROACHNET_REQUIRE_PORTABLE_NODE")
            environment["ROACHNET_RUNTIME_KIND"] = "native"
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                environment["ROACHNET_APP_VERSION"] = version
            }
        }
        environment["ROACHNET_INSTALL_PROFILE"] = config.installProfile
        environment["ROACHNET_BOOTSTRAP_PENDING"] = config.bootstrapPending ? "1" : "0"
        environment["ROACHNET_STORAGE_PATH"] = normalizedStoragePath
        environment["OPENCLAW_WORKSPACE_PATH"] = normalizedWorkspacePath
        environment["OLLAMA_MODELS"] = normalizedOllamaModelsPath
        environment["OLLAMA_BASE_URL"] = "http://127.0.0.1:36434"
        environment["OPENCLAW_BASE_URL"] = "http://127.0.0.1:13001"
        environment["ROACHNET_CONTAINERLESS_MODE"] = normalizedContainerlessMode
        environment["ROACHNET_DISABLE_QUEUE"] = normalizedContainerlessMode == "1" ? "1" : "0"
        environment["ROACHNET_ROACHCLAW_DEFAULT_MODEL"] = config.roachClawDefaultModel
        environment["ROACHNET_LOCAL_HOSTNAME"] =
            ProcessInfo.processInfo.environment["ROACHNET_LOCAL_HOSTNAME"] ?? "RoachNet"
        environment["ROACHNET_COMPANION_ENABLED"] = config.companionEnabled ? "1" : "0"
        environment["ROACHNET_COMPANION_HOST"] = config.companionHost
        environment["ROACHNET_COMPANION_PORT"] = String(config.companionPort)
        environment["ROACHNET_COMPANION_TOKEN"] = config.companionToken
        Self.applyAppleSiliconLocalAIEnvironmentDefaults(to: &environment)
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

    private func containedServerInfoURL(using config: RoachNetInstallerConfig) throws -> URL {
        let url = URL(fileURLWithPath: runtimeHandshakePath(using: config))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func runtimeStateRoot(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath =
            config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        let normalizedInstallPath =
            config.installPath.isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        return RoachNetRepositoryLocator.defaultRuntimeStatePath(
            storagePath: normalizedStoragePath,
            installPath: normalizedInstallPath
        )
    }

    private func runtimeHandshakePath(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath =
            config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        let normalizedInstallPath =
            config.installPath.isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        return RoachNetRepositoryLocator.portableRuntimeHandshakePath(
            storagePath: normalizedStoragePath,
            installPath: normalizedInstallPath
        )
    }

    private func runtimeLogPath(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath =
            config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        return URL(fileURLWithPath: normalizedStoragePath)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("roachnet-server.log", isDirectory: false)
            .path
    }

    private func runtimeProcessStatePath(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath =
            config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath
        return URL(fileURLWithPath: normalizedStoragePath)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("roachnet-runtime-processes.json", isDirectory: false)
            .path
    }

    private func runtimeCacheRoot(using config: RoachNetInstallerConfig) -> String {
        let normalizedStoragePath =
            config.storagePath.isEmpty
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
        allowBootstrapRepair && RoachNetRepositoryLocator.isHomebrewInstallProfile(config.installProfile)
            && config.bootstrapPending && config.bootstrapFailureCount < 1
    }

    private func repairContainedBootstrap(using config: RoachNetInstallerConfig) async throws -> RoachNetInstallerConfig
    {
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
        let handshakePath = runtimeHandshakePath(using: updatedConfig)

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
            config.bootstrapPending || config.bootstrapFailureCount > 0
                || (RoachNetRepositoryLocator.isHomebrewInstallProfile(config.installProfile)
                    && config.lastRuntimeHealthAt == nil)
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
        let configuredRoot = URL(fileURLWithPath: config.installPath)
        let configuredScript = runtimeLauncherURL(in: configuredRoot)

        if FileManager.default.fileExists(atPath: configuredScript.path) {
            return configuredRoot
        }

        if let bundledRoot = RoachNetRepositoryLocator.bundledRepositoryRoot() {
            return bundledRoot
        }

        return RoachNetRepositoryLocator.repositoryRoot()
            ?? configuredRoot
    }

    struct RuntimeLaunch {
        let executable: String
        let arguments: [String]
        let workingDirectory: URL
        let repoRoot: URL
        let nodeBinary: String?

        var takesTokenOnInput: Bool { nodeBinary == nil }
    }

    func resolveRuntimeLaunch(using config: RoachNetInstallerConfig, allowAnyNode: Bool = false) throws -> RuntimeLaunch
    {
        if let nativeBinary = RoachNetRepositoryLocator.nativeRuntimeBinary() {
            let dataRoot = RoachNetRepositoryLocator.nativeRuntimeDataRoot() ?? resolveRuntimeRoot(from: config)
            return RuntimeLaunch(
                executable: nativeBinary,
                arguments: [],
                workingDirectory: dataRoot,
                repoRoot: dataRoot,
                nodeBinary: nil
            )
        }

        let repoRoot = resolveRuntimeRoot(from: config)
        let scriptURL = runtimeLauncherURL(in: repoRoot)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(
                domain: "RoachNetRuntime", code: 20,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RoachNet could not find its native runtime helper. Reinstall RoachNet with RoachNet Setup to restore it."
                ])
        }

        let resolvedNode =
            allowAnyNode
            ? (RoachNetRepositoryLocator.preferredPortableNodeBinary()
                ?? RoachNetRepositoryLocator.preferredNodeBinary())
            : RoachNetRepositoryLocator.preferredPortableNodeBinary()
        guard let node = resolvedNode else {
            throw NSError(
                domain: "RoachNetRuntime", code: 22,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RoachNet could not find its native runtime helper or a compatible development runtime."
                ])
        }

        return RuntimeLaunch(
            executable: node,
            arguments: node == "/usr/bin/env" ? ["node", scriptURL.path] : [scriptURL.path],
            workingDirectory: repoRoot,
            repoRoot: repoRoot,
            nodeBinary: node
        )
    }

    private func runtimeLauncherURL(in repoRoot: URL) -> URL {
        let nativeAPIURL = repoRoot.appendingPathComponent("scripts/run-roachnet-native-api.mjs")
        if FileManager.default.fileExists(atPath: nativeAPIURL.path) {
            return nativeAPIURL
        }

        return repoRoot.appendingPathComponent("scripts/run-roachnet.mjs")
    }

    private func runtimeBaseURL(from info: ManagedAppServerInfo) throws -> URL {
        guard let baseURL = URL(string: info.healthUrl) else {
            throw NSError(
                domain: "RoachNetRuntime", code: 22,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid RoachNet runtime URL."
                ])
        }

        let root = URL(string: "/", relativeTo: baseURL)?.absoluteURL
        guard let root else {
            throw NSError(
                domain: "RoachNetRuntime", code: 23,
                userInfo: [
                    NSLocalizedDescriptionKey: "RoachNet couldn't work out the address of its local API."
                ])
        }

        return root
    }

    private func defaultWorkspacePath(from config: RoachNetInstallerConfig) -> String {
        let storageRoot =
            config.storagePath.isEmpty
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
            preferredModels: [],
            configFilePath: nil,
            portableProfile: nil,
            playbook: nil,
            operations: nil,
            defaultModelInstalled: nil,
            modelPulls: nil
        )
    }

    private func fallbackAccountStatus(
        config: RoachNetInstallerConfig,
        serverInfo: ManagedAppServerInfo
    ) -> ManagedAccountStateResponse {
        let portalURL =
            ProcessInfo.processInfo.environment["ROACHNET_ACCOUNT_PORTAL_URL"] ?? "https://accounts.roachnet.org/"
        let aliasHost = ProcessInfo.processInfo.environment["ROACHNET_LOCAL_HOSTNAME"] ?? "RoachNet"
        return ManagedAccountStateResponse(
            linked: false,
            provider: "RoachNet Account",
            portalUrl: portalURL,
            accountId: nil,
            email: nil,
            displayName: nil,
            status: "local-only",
            settingsSyncEnabled: false,
            savedAppsSyncEnabled: false,
            hostedChatEnabled: config.companionEnabled,
            aliasHost: aliasHost,
            bridgeUrl: serverInfo.companionAdvertisedUrl ?? serverInfo.companionUrl,
            runtimeOrigin: serverInfo.webUrl,
            linkedAt: nil,
            lastSeenAt: nil,
            lastUpdatedAt: nil,
            notes: [
                "A RoachNet account is optional. It links web extras like web chat and saved apps to this install. Nothing in the app needs it.",
                "RoachTail links your own devices, like this Mac and an iPhone or iPad running RoachNet for iOS.",
            ]
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
            transportMode: "local-bridge",
            secureOverlay: false,
            relayHost: nil,
            advertisedUrl: serverInfo.companionAdvertisedUrl ?? serverInfo.companionUrl,
            runtimeOrigin: serverInfo.webUrl,
            runtimeTunnelUrl: serverInfo.companionAdvertisedUrl ?? serverInfo.companionUrl,
            joinCode: nil,
            joinCodeExpiresAt: nil,
            pairingPayload: nil,
            pairingIssuedAt: nil,
            lastUpdatedAt: nil,
            notes: config.companionEnabled
                ? ["RoachTail is still warming up inside the local runtime."]
                : ["RoachTail is off in this runtime configuration."],
            peers: [],
            controlPlane: ManagedRoachTailControlPlane(
                provider: "roachnet-native",
                designReference: "headscale",
                namespace: "roachnet",
                nodeApproval: "owner-local",
                routeApproval: "owner-local",
                authKeyTtlSeconds: 86_400,
                joinCodeTtlSeconds: 600,
                policyMode: "local-owner",
                dnsName: "roachnet-desktop.roachtail.local"
            ),
            preAuthKeys: [],
            routes: [
                ManagedRoachTailRoute(
                    id: "companion-bridge",
                    type: "service",
                    target: serverInfo.companionAdvertisedUrl ?? serverInfo.companionUrl,
                    approved: true,
                    advertised: config.companionEnabled,
                    primary: true,
                    tags: ["tag:companion"],
                    description: "Companion control bridge"
                )
            ],
            derpMap: ManagedRoachTailDERPMap(
                mode: "local-only",
                regions: [
                    ManagedRoachTailDERPRegion(
                        id: "roachnet-local",
                        name: "RoachTail local bridge",
                        host: "RoachNet",
                        url: serverInfo.companionAdvertisedUrl ?? serverInfo.companionUrl,
                        embedded: true
                    )
                ]
            )
        )
    }

    private func fallbackRoachSyncStatus(
        config: RoachNetInstallerConfig,
        serverInfo: ManagedAppServerInfo
    ) -> ManagedRoachSyncStatusResponse {
        let syncBaseURL = publicRoachNetURL(
            port: "8384",
            path: "",
            fallback: serverInfo.webUrl
        )
        return ManagedRoachSyncStatusResponse(
            enabled: false,
            provider: "Syncthing",
            networkName: "RoachSync",
            deviceName: Host.current().localizedName ?? "RoachNet desktop",
            deviceId: "roachsync-desktop",
            status: "idle",
            folderId: "roachnet-vault",
            folderPath: RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath),
            guiUrl: syncBaseURL,
            apiUrl: "\(syncBaseURL)/rest",
            transportMode: config.companionEnabled ? "local-bridge" : "local-only",
            secureOverlay: false,
            notes: ["RoachSync isn't turned on in this runtime configuration."],
            peers: [],
            lastUpdatedAt: nil
        )
    }

    private func publicRoachNetURL(
        port: String,
        path: String,
        fallback: String?
    ) -> String {
        if let fallback,
            let baseURL = URL(string: fallback)
        {
            var components = URLComponents()
            components.scheme = baseURL.scheme ?? "http"
            components.host =
                baseURL.host ?? (ProcessInfo.processInfo.environment["ROACHNET_LOCAL_HOSTNAME"] ?? "RoachNet")
            components.port = Int(port)
            components.path = path
            if let rendered = components.url?.absoluteString {
                return rendered
            }
        }

        let host = ProcessInfo.processInfo.environment["ROACHNET_LOCAL_HOSTNAME"] ?? "RoachNet"
        let suffix = path.hasPrefix("/") || path.isEmpty ? path : "/\(path)"
        return "http://\(host):\(port)\(suffix)"
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
                warnings: ["System info is still loading."]
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
        try await get(url: baseURL.appending(path: path))
    }

    static func newAPIToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func authorize(_ request: inout URLRequest) {
        guard let apiToken, let url = request.url,
            let web = cachedServerInfo?.webUrl ?? cachedServerInfo.map({ $0.healthUrl }),
            let runtime = URL(string: web),
            url.scheme == runtime.scheme, url.host == runtime.host, url.port == runtime.port
        else { return }
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
    }

    private func get<Response: Decodable>(url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "RoachNetRuntime", code: status,
                userInfo: [
                    NSLocalizedDescriptionKey: "GET \(url.path) failed with status \(status)."
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
        authorize(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "RoachNetRuntime", code: status,
                userInfo: [
                    NSLocalizedDescriptionKey: "POST \(path) failed with status \(status)."
                ])
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    public func orgRequest(
        using config: RoachNetInstallerConfig,
        path: String,
        method: String = "GET",
        jsonBody: Data? = nil
    ) async throws -> Data {
        let serverInfo = try await ensureRunning(using: config)
        let baseURL = try runtimeBaseURL(from: serverInfo)
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = baseURL.appending(path: String(pieces[0]))
        if pieces.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(pieces[1])
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(
                domain: "RoachNetOrg", code: status,
                userInfo: [
                    NSLocalizedDescriptionKey: message ?? "\(method) \(path) failed with status \(status)."
                ])
        }
        return data
    }

    private func delete<Response: Decodable>(_ path: String, baseURL: URL) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        authorize(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "RoachNetRuntime", code: status,
                userInfo: [
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

extension Optional where Wrapped == String {
    fileprivate var isBlankEnvironmentValue: Bool {
        guard let value = self else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes = 64 * 1024

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        if data.count > maxBytes {
            data.removeFirst(data.count - maxBytes)
        }
    }
}
