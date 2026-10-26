import Foundation

public final class NativeRuntime {
    public let config: RuntimeConfiguration
    let stateLock = NSRecursiveLock()
    var collectionsRefreshInFlight = false
    var packCatalogRefreshInFlight = false
    var collectionsBackoff = RetryBackoff()
    var packCatalogBackoff = RetryBackoff()
    var now: () -> Date = { Date() }

    var benchmarkStatus: JSON = ["status": "idle", "benchmarkId": nil]
    var systemUpdateStatus: JSON
    var latestReleaseCache: (cachedAt: Double, release: JSON)?
    var downloadJobs: [DownloadJob] = []
    var downloadWriters: [String: DownloadJob] = [:]
    var companionLocalURL: String?
    var listenPort: UInt16 = 0
    var companionBoundPort: UInt16 = 0
    var nativeModelServer: NativeModelServer?
    let planKey = JS.randomHex(64)
    var roachTailJoinCode: (hash: String, code: String)?
    let modelPulls = ModelPullTracker()
    let modelPullQueue = DispatchQueue(label: "org.roachnet.runtime.model-pulls", qos: .utility)

    var usesNativeEngine: Bool {
        (config.env("ROACHNET_INFERENCE_ENGINE") ?? "native").lowercased() != "ollama"
    }

    let modelServerAddress = LockedBox<String?>(nil)
    let roachInferenceAddress = LockedBox<String?>(nil)
    let personsOllamaInUse = LockedBox(false)
    let personsOllamaMissingLogged = LockedBox(false)

    var modelServerBaseUrl: String {
        modelServerAddress.value ?? (usesNativeEngine ? roachInferenceURL : personsOllamaURL)
    }

    lazy var subscriptionModels = SubscriptionModels(root: Path.join(config.storageRoot, "state"))

    #if canImport(CryptoKit) && canImport(Metal)
    lazy var cluster = ClusterNode(
        stateRoot: Path.join(config.storageRoot, "state"), storageRoot: config.storageRoot,
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

    lazy var orgService: OrgService = {
        let service = OrgService(runtime: self)
        service.engine.start()
        return service
    }()

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
        store.ollamaRoot =
            config.env("OLLAMA_MODELS").flatMap { $0.isEmpty ? nil : $0 }
            ?? Path.join(config.storageRoot, "models", "ollama")
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

    lazy var roachInferenceIdentityCache = TTLCache<Bool>(ttlMs: config.runtimeProbeCacheMs) { [unowned self] url in
        guard let reply = try? HTTPClient.fetchJSON(url, timeoutMs: self.config.serviceHealthProbeTimeoutMs) else {
            return false
        }
        return reply["version"].stringValue?.hasPrefix("roachnet-native") == true
    }

    lazy var installedModelsCache = TTLCache<[JSON]>(ttlMs: config.runtimeProbeCacheMs) { baseUrl in
        let tagsURL = WebURL("/api/tags", base: WebURL(baseUrl))?.withoutCredentials ?? baseUrl + "/api/tags"
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

func nullIfEmpty(_ value: String) -> JSON { value.isEmpty ? .null : .string(value) }

func safeIntegerOr(_ value: JSON, min minimum: Double = 0, _ fallback: JSON) -> JSON {
    let number = value.jsNumber
    return JSCoercion.isSafeInteger(number) ? .number(max(minimum, number)) : fallback
}

func jsonStrings(_ values: [String]) -> JSON { .array(values.map { .string($0) }) }

extension NativeRuntime {
    var orgStoreIsEmpty: Bool {
        let companies = Path.join(storageRoot, "RoachClaw", "org", "companies")
        return ((try? FileManager.default.contentsOfDirectory(atPath: companies)) ?? []).isEmpty
    }
}
