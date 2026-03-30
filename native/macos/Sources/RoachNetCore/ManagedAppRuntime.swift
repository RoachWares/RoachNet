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
        public let id: String?
        public let name: String?
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
    public let target: String?
    public let repoRoot: String?
    public let logPath: String?
}

public struct ManagedAppSnapshot: Sendable {
    public let serverInfo: ManagedAppServerInfo
    public let systemInfo: SystemInfoResponse
    public let providers: AIRuntimeProvidersResponse
    public let roachClaw: RoachClawStatusResponse
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

    public init() {}

    public func ensureRunning(using config: RoachNetInstallerConfig) async throws -> ManagedAppServerInfo {
        if let cachedServerInfo, try await isHealthy(cachedServerInfo.healthUrl) {
            return cachedServerInfo
        }

        let repoRoot = resolveRuntimeRoot(from: config)
        let scriptURL = repoRoot.appendingPathComponent("scripts/run-roachnet.mjs")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(domain: "RoachNetRuntime", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Missing RoachNet launcher at \(scriptURL.path)."
            ])
        }

        let infoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roachnet-server-\(UUID().uuidString).json")
        serverInfoURL = infoURL

        let node = RoachNetRepositoryLocator.preferredNodeBinary()
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

        var environment = ProcessInfo.processInfo.environment
        environment["ROACHNET_NO_BROWSER"] = "1"
        environment["ROACHNET_SERVER_INFO_FILE"] = infoURL.path
        environment["ROACHNET_REPO_ROOT"] = repoRoot.path
        process.environment = environment

        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if
                let data = try? Data(contentsOf: infoURL),
                let serverInfo = try? JSONDecoder().decode(ManagedAppServerInfo.self, from: data),
                try await isHealthy(serverInfo.healthUrl)
            {
                cachedServerInfo = serverInfo
                return serverInfo
            }

            if let exitDescription = exitState.describeExit() {
                let stderr = Self.readPipeOutput(from: stderrPipe)
                let stdout = Self.readPipeOutput(from: stdoutPipe)
                let details = [stderr, stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })

                throw NSError(domain: "RoachNetRuntime", code: 24, userInfo: [
                    NSLocalizedDescriptionKey: details.map {
                        "RoachNet exited before it became healthy (\(exitDescription)). \($0)"
                    } ?? "RoachNet exited before it became healthy (\(exitDescription))."
                ])
            }

            try await Task.sleep(for: .milliseconds(300))
        }

        throw NSError(domain: "RoachNetRuntime", code: 21, userInfo: [
            NSLocalizedDescriptionKey: "RoachNet did not become healthy before the native timeout."
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

        async let systemInfo = fetchOrFallback(
            "/api/system/info",
            baseURL: baseURL,
            fallback: fallbackSystemInfo
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
            systemInfo: await systemInfo,
            providers: await providers,
            roachClaw: await roachClaw,
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

    public func sendChat(
        using config: RoachNetInstallerConfig,
        model: String,
        prompt: String
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

        let response: OllamaChatResponse = try await post("/api/ollama/chat", baseURL: baseURL, body: payload)
        return response.message?.content ?? ""
    }

    private func resolveRuntimeRoot(from config: RoachNetInstallerConfig) -> URL {
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
        URL(fileURLWithPath: config.installPath)
            .appendingPathComponent("storage")
            .appendingPathComponent("openclaw")
            .path
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

    private func post<Response: Decodable>(_ path: String, baseURL: URL, body: some Encodable) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
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
}

private struct EmptyOKResponse: Decodable {
    let success: Bool?
    let ok: Bool?
    let message: String?
}

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
