import Foundation

enum ContentCollection: String, CaseIterable {
    case maps
    case kiwix = "kiwix-categories"
    case wikipedia

    var fileName: String { "\(rawValue).json" }
    var bundledCandidates: [String] { ["collections/\(fileName)", "website-apps-dist/collections/\(fileName)"] }
    var listKey: String {
        switch self {
        case .maps: return "collections"
        case .kiwix: return "categories"
        case .wikipedia: return "options"
        }
    }

    static let maxBytes = 4 * 1024 * 1024
    static let refreshInterval: TimeInterval = 6 * 3600
}

struct RetryBackoff {
    static let firstWait: TimeInterval = 300
    private(set) var notBefore: Date?
    private(set) var wait: TimeInterval = 0

    func allows(at now: Date) -> Bool { notBefore.map { now >= $0 } ?? true }

    mutating func failed(at now: Date, upTo limit: TimeInterval) {
        wait = min(max(wait * 2, Self.firstWait), limit)
        notBefore = now.addingTimeInterval(wait)
    }

    mutating func succeeded() {
        notBefore = nil
        wait = 0
    }
}

enum ContentCollectionValidator {
    static let slugPattern = "^[a-z0-9][a-z0-9_-]{0,79}$"

    static func problem(_ collection: ContentCollection, _ file: JSON) -> String? {
        guard file.isObject else { return "not a JSON object" }
        let list = file[collection.listKey]
        guard list.isArray, !list.array.isEmpty else { return "missing \(collection.listKey)" }
        guard list.array.count <= 500 else { return "too many \(collection.listKey)" }
        switch collection {
        case .maps:
            for entry in list.array {
                guard isSlug(entry["slug"]), entry["name"].stringValue?.isEmpty == false else {
                    return "map collection without slug/name"
                }
                guard entry["resources"].isArray, entry["resources"].array.count <= 500 else {
                    return "map collection \(entry["slug"].jsString) has no resource list"
                }
                for resource in entry["resources"].array {
                    if let reason = resourceProblem(resource) { return "map \(entry["slug"].jsString): \(reason)" }
                }
            }
        case .kiwix:
            for entry in list.array {
                guard isSlug(entry["slug"]), entry["name"].stringValue?.isEmpty == false else {
                    return "category without slug/name"
                }
                guard entry["tiers"].isArray else { return "category \(entry["slug"].jsString) has no tiers" }
                for tier in entry["tiers"].array {
                    guard isSlug(tier["slug"]), tier["resources"].isArray, tier["resources"].array.count <= 1000 else {
                        return "category \(entry["slug"].jsString) has a malformed tier"
                    }
                    for resource in tier["resources"].array {
                        if let reason = resourceProblem(resource) {
                            return "\(entry["slug"].jsString)/\(tier["slug"].jsString): \(reason)"
                        }
                    }
                }
            }
        case .wikipedia:
            for option in list.array {
                guard isSlug(option["id"]) else { return "Wikipedia option without an id" }
                if option["url"].isNullish {
                    if option["id"].stringValue == "none" { continue }
                    return "Wikipedia \(option["id"].jsString) has no URL"
                }
                if let reason = urlProblem(option["url"]) { return "Wikipedia \(option["id"].jsString): \(reason)" }
            }
        }
        return nil
    }

    static func isSlug(_ value: JSON) -> Bool {
        guard let text = value.stringValue else { return false }
        return JS.matches(slugPattern, text)
    }

    static func resourceProblem(_ resource: JSON) -> String? {
        guard let id = resource["id"].stringValue, !id.isEmpty, id.count <= 200 else { return "resource without an id" }
        if let reason = urlProblem(resource["url"]) { return "\(id): \(reason)" }
        if !resource["size_mb"].isNullish {
            let size = resource["size_mb"].jsNumber
            guard size.isFinite, size >= 0, size < 10_000_000 else { return "\(id): bad size_mb" }
        }
        if let sha = resource["sha256"].stringValue, !JS.matches("^[a-f0-9]{64}$", sha) { return "\(id): bad sha256" }
        return nil
    }

    static func urlProblem(_ value: JSON) -> String? {
        guard let raw = value.stringValue, let parsed = WebURL(raw) else { return "missing url" }
        guard parsed.scheme == "https" else { return "url is not https" }
        let name = Path.basename(parsed.pathname)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return "url has no file name" }
        return nil
    }
}

extension NativeRuntime {
    var collectionsBaseURL: String? {
        let raw = (config.environment["ROACHNET_COLLECTIONS_BASE_URL"] ?? "https://apps.roachnet.org/collections")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let parsed = WebURL(raw), !parsed.hasCredentials,
            parsed.scheme == "https" || (parsed.scheme == "http" && CompanionProxy.isLoopback(parsed.bareHostname))
        else { return nil }
        return JS.replace("/+$", in: parsed.withoutCredentials, with: "")
    }

    func collectionCachePath(_ collection: ContentCollection) -> String {
        Path.join(config.storageRoot, "collections", collection.fileName)
    }

    func loadCollection(_ collection: ContentCollection) -> JSON {
        let cachePath = collectionCachePath(collection)
        if collectionsBaseURL != nil, Files.exists(cachePath), let cached = JSON.read(contentsOf: cachePath) {
            if let reason = ContentCollectionValidator.problem(collection, cached) {
                log("collection \(collection.rawValue) cache ignored: \(reason)")
            } else {
                return cached
            }
        }
        return readJSONFile(collection.bundledCandidates, [collection.listKey: []])
    }

    func collectionsStatus() -> JSON {
        .array(
            ContentCollection.allCases.map { collection in
                let cachePath = collectionCachePath(collection)
                let cached = JSON.read(contentsOf: cachePath)
                let usable = cached.map { ContentCollectionValidator.problem(collection, $0) == nil } ?? false
                return [
                    "id": JSON(collection.rawValue),
                    "source": JSON(collectionsBaseURL != nil && usable ? "live" : "bundled"),
                    "url": collectionsBaseURL.map { JSON("\($0)/\(collection.fileName)") } ?? .null,
                    "fetchedAt": usable ? JSON(Files.modificationISO(cachePath)) : .null,
                    "specVersion": (usable ? cached?["spec_version"] : nil)
                        ?? readJSONFile(collection.bundledCandidates, .null)["spec_version"],
                ]
            })
    }

    func refreshCollections(force: Bool = false) {
        guard let base = collectionsBaseURL else { return }
        let due = ContentCollection.allCases.filter { collection in
            if force { return true }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: collectionCachePath(collection)),
                let modified = attributes[.modificationDate] as? Date
            else { return true }
            return Date().timeIntervalSince(modified) >= ContentCollection.refreshInterval
        }
        if due.isEmpty { return }
        let claimed: Bool = withState {
            if collectionsRefreshInFlight { return false }
            if !force, !collectionsBackoff.allows(at: now()) { return false }
            collectionsRefreshInFlight = true
            return true
        }
        guard claimed else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let fetched = due.map { fetchCollection($0, from: "\(base)/\($0.fileName)") }
            withState {
                if fetched.allSatisfy({ $0 }) {
                    collectionsBackoff.succeeded()
                } else {
                    collectionsBackoff.failed(at: now(), upTo: ContentCollection.refreshInterval)
                }
                collectionsRefreshInFlight = false
            }
        }
    }

    @discardableResult
    func fetchCollection(_ collection: ContentCollection, from url: String) -> Bool {
        do {
            let response = try HTTPClient.request(
                url,
                headers: [
                    "accept": "application/json",
                    "user-agent": "RoachNet/\(config.version) collections",
                ], timeoutMs: 20_000, maxResponseBytes: ContentCollection.maxBytes)
            guard response.ok else { throw RuntimeError("HTTP \(response.status)") }
            let file = try JSON.parse(response.body)
            if let reason = ContentCollectionValidator.problem(collection, file) {
                throw RuntimeError("rejected: \(reason)")
            }
            let cachePath = collectionCachePath(collection)
            try Files.mkdirp(Path.dirname(cachePath))
            chmod(Path.dirname(cachePath), 0o700)
            try Files.writePrettyJSON(file, to: cachePath, mode: Files.privateFileMode)
            log("collection \(collection.rawValue) refreshed from \(WebURL.display(url))")
            return true
        } catch {
            log("collection \(collection.rawValue) refresh skipped (\(WebURL.display(url))): \(error)")
            return false
        }
    }
}
