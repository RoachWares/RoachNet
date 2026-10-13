import Foundation

/// The native RoachNet runtime: owns local state, RoachClaw stores, RoachTail,
/// downloads, and the loopback API surface the app and iOS companion use.
public final class NativeRuntime {
    public let config: RuntimeConfiguration
    /// Serializes read-modify-write cycles on local state files and in-memory
    /// job tables (the previous runtime relied on a single-threaded loop).
    let stateLock = NSRecursiveLock()
    /// One background fetch of the live content collections at a time.
    var collectionsRefreshInFlight = false

    var benchmarkStatus: JSON = ["status": "idle", "benchmarkId": nil]
    var systemUpdateStatus: JSON
    var latestReleaseCache: (cachedAt: Double, release: JSON)?
    var ollamaProcessPID: Int32?
    var downloadJobs: [DownloadJob] = []
    var companionLocalURL: String?
    var listenPort: UInt16 = 0
    var companionBoundPort: UInt16 = 0
    /// RoachNet's own inference engine behind an Ollama-compatible API. Default
    /// engine; set ROACHNET_INFERENCE_ENGINE=ollama to use an external runner.
    var nativeModelServer: NativeModelServer?

    var usesNativeEngine: Bool {
        (config.env("ROACHNET_INFERENCE_ENGINE") ?? "native").lowercased() != "ollama"
    }

    /// Set when another program already answered on the configured model
    /// address and RoachInference took a free loopback port instead.
    let modelServerAddressOverride = LockedBox<String?>(nil)

    /// Where RoachNet's own model traffic goes: `OLLAMA_BASE_URL`, unless
    /// RoachInference had to serve on another port (see `ensureNativeModelServer`).
    var modelServerBaseUrl: String { modelServerAddressOverride.value ?? config.ollamaBaseUrl }

    /// RoachTrace: local traces of Org runs, chats and model-server requests
    /// (`<storage>/state/traces`, owner-only). The server touches it at start
    /// so it is never first created from two threads at once.
    /// Claude and ChatGPT plans as models, off until the person turns them on.
    lazy var subscriptionModels = SubscriptionModels(root: Path.join(config.storageRoot, "state"))

    #if canImport(CryptoKit) && canImport(Metal)
    /// RoachNet Cluster: off until the person turns it on and pairs another Mac.
    lazy var cluster = ClusterNode(stateRoot: Path.join(config.storageRoot, "state"), storageRoot: config.storageRoot,
                                   store: nativeModelStore, version: config.version)
    #endif

    lazy var tracer: Tracer = {
        let store = TraceStore(root: Path.join(config.storageRoot, "state", "traces"))
        let tracer = Tracer(store: store)
        let exporter = TraceExporter(store: store, version: config.version)
        tracer.onTraceEnded = { trace, observations in exporter.enqueue(trace, observations) }
        exporter.start()
        traceExporterStorage = exporter
        return tracer
    }()
    private var traceExporterStorage: TraceExporter?
    var traceExporter: TraceExporter {
        _ = tracer
        return traceExporterStorage!
    }

    /// RoachClaw Org (native multi-agent company runtime). Created on first use.
    lazy var orgService: OrgService = {
        let service = OrgService(runtime: self)
        service.engine.start()
        return service
    }()

    /// Feature packs: what is installed and switched on. Created on first use;
    /// a stale staging folder from an interrupted install is swept then.
    lazy var packRegistry: PackRegistry = {
        let registry = PackRegistry(storageRoot: config.storageRoot, appVersion: config.version)
        registry.onChange = { [weak self] id, event in self?.log("pack \(id) \(event)") }
        registry.catalogPacks = loadPackCatalog()
        registry.externalShelf = self
        _ = PackInstaller(registry: registry).sweepStaleStaging()
        return registry
    }()

    lazy var nativeModelStore: NativeModelStore = {
        let store = NativeModelStore(
            root: Path.join(config.storageRoot, "models", "native"),
            catalogPath: Path.join(config.repoRoot, "collections", "native-models.json")
        )
        store.ollamaRoot = config.env("OLLAMA_MODELS").flatMap { $0.isEmpty ? nil : $0 } ?? Path.join(config.storageRoot, "models", "ollama")
        store.stallTimeoutMs = config.downloadStallTimeoutMs
        store.maxAttempts = config.downloadMaxAttempts
        return store
    }()

    lazy var runtimeReachabilityCache = TTLCache<Bool>(ttlMs: config.runtimeProbeCacheMs) { [unowned self] url in
        do {
            _ = try HTTPClient.fetchJSON(url, timeoutMs: self.config.serviceHealthProbeTimeoutMs)
            return true
        } catch {
            return false
        }
    }

    /// Whether the program answering a `/api/version` URL is RoachInference.
    lazy var roachInferenceIdentityCache = TTLCache<Bool>(ttlMs: config.runtimeProbeCacheMs) { [unowned self] url in
        guard let reply = try? HTTPClient.fetchJSON(url, timeoutMs: self.config.serviceHealthProbeTimeoutMs) else { return false }
        return reply["version"].stringValue?.hasPrefix("roachnet-native") == true
    }

    lazy var installedModelsCache = TTLCache<[JSON]>(ttlMs: config.runtimeProbeCacheMs) { baseUrl in
        let tagsURL = WebURL("/api/tags", base: WebURL(baseUrl))?.description ?? baseUrl + "/api/tags"
        let tags = try HTTPClient.fetchJSON(tagsURL, timeoutMs: 2_500)
        return tags["models"].array.map { model in
            ["name": model["name"], "size": model["size"] || nil]
        }
    }

    public init(config: RuntimeConfiguration = .shared) {
        self.config = config
        self.systemUpdateStatus = NativeRuntime.updateStatus("idle", 0, "No update in progress")
    }

    static func updateStatus(_ stage: String, _ progress: Double, _ message: String) -> JSON {
        ["stage": JSON(stage), "progress": JSON(progress), "message": JSON(message), "timestamp": JSON(JS.isoNow())]
    }

    func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    var storageRoot: String { config.storageRoot }
    var defaultModel: String { config.defaultModel }
    var version: String { config.version }

    func log(_ line: String) { RuntimeLog.write(line) }
}

// MARK: - Shared helpers

/// `compactString(...) || null`
func nullIfEmpty(_ value: String) -> JSON { value.isEmpty ? .null : .string(value) }

/// `Number.isSafeInteger(Number(v)) ? Math.max(min, Number(v)) : fallback`
func safeIntegerOr(_ value: JSON, min minimum: Double = 0, _ fallback: JSON) -> JSON {
    let number = value.jsNumber
    return JSCoercion.isSafeInteger(number) ? .number(max(minimum, number)) : fallback
}

func jsonStrings(_ values: [String]) -> JSON { .array(values.map { .string($0) }) }


extension NativeRuntime {
    /// True when no Org company has been created yet, so startup can skip loading the engine.
    var orgStoreIsEmpty: Bool {
        let companies = Path.join(storageRoot, "RoachClaw", "org", "companies")
        return ((try? FileManager.default.contentsOfDirectory(atPath: companies)) ?? []).isEmpty
    }
}
