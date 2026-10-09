import Foundation

/// The native RoachNet runtime: owns local state, RoachClaw stores, RoachTail,
/// downloads, and the loopback API surface the app and iOS companion use.
public final class NativeRuntime {
    public let config: RuntimeConfiguration
    /// Serializes read-modify-write cycles on local state files and in-memory
    /// job tables (the previous runtime relied on a single-threaded loop).
    let stateLock = NSRecursiveLock()

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

    lazy var nativeModelStore: NativeModelStore = {
        let store = NativeModelStore(
            root: Path.join(config.storageRoot, "models", "native"),
            catalogPath: Path.join(config.repoRoot, "collections", "native-models.json")
        )
        store.ollamaRoot = config.env("OLLAMA_MODELS").flatMap { $0.isEmpty ? nil : $0 } ?? Path.join(config.storageRoot, "models", "ollama")
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

