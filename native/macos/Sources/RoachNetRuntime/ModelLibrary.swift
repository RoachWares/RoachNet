import Foundation

struct ModelLibraryEntry: Equatable {
    let name: String
    let title: String
    let use: String
    let publisher: String
    let license: String
    let family: String
    let parameterSize: String
    let quantization: String
    let size: Int64

    init?(_ item: JSON) {
        guard let raw = item["name"].stringValue, let name = try? NativeModelStore.normalize(raw).name,
            let url = item["url"].stringValue, !url.isEmpty
        else { return nil }
        self.name = name
        let title = (item["title"].stringValue ?? "").trimmingCharacters(in: .whitespaces)
        self.title = title.isEmpty ? name : title
        let use = (item["use"].stringValue ?? "").lowercased()
        self.use = use == "code" ? "code" : "chat"
        publisher = item["publisher"].stringValue ?? ""
        license = item["license"].stringValue ?? ""
        family = item["family"].stringValue ?? ""
        parameterSize = item["parameterSize"].stringValue ?? ""
        quantization = item["quantization"].stringValue ?? ""
        size = Int64(item["size"].numberValue ?? 0)
    }
}

enum ModelLibrary {
    static func load(_ path: String) -> [ModelLibraryEntry] {
        (JSON.read(contentsOf: path)?["models"].array ?? []).compactMap(ModelLibraryEntry.init)
    }

    static func estimatedMemory(size: Int64) -> Int64 {
        size + size / 10 + (512 << 20)
    }

    static func fit(size: Int64, budget: Int64) -> String {
        let needed = estimatedMemory(size: size)
        if needed <= budget / 4 * 3 { return "good" }
        if needed <= budget { return "tight" }
        return "too-big"
    }

    static func budget(memoryBytes: UInt64, environment: [String: String]) -> Int64 {
        if let text = environment["ROACHNET_MODEL_MEMORY_GB"], let gigabytes = Double(text), gigabytes > 0 {
            return Int64(gigabytes * 1_073_741_824)
        }
        return Int64(memoryBytes) / 10 * 8
    }

    static func json(_ entry: ModelLibraryEntry, budget: Int64, recommended: String) -> JSONObject {
        JSONObject([
            ("name", JSON(entry.name)),
            ("title", JSON(entry.title)),
            ("use", JSON(entry.use)),
            ("publisher", JSON(entry.publisher)),
            ("license", JSON(entry.license)),
            ("family", JSON(entry.family)),
            ("parameterSize", JSON(entry.parameterSize)),
            ("quantization", JSON(entry.quantization)),
            ("size", JSON(entry.size)),
            ("memoryNeeded", JSON(estimatedMemory(size: entry.size))),
            ("fit", JSON(fit(size: entry.size, budget: budget))),
            ("recommended", JSON(entry.name == recommended)),
        ])
    }
}

final class ModelPullTracker {
    struct Pull: Equatable {
        var state: String
        var phase: String
        var completed: Int64 = 0
        var total: Int64?
        var message: String?
        var updatedAt: Date
    }

    private let lock = NSLock()
    private var pulls: [String: Pull] = [:]
    private var stopRequests: Set<String> = []
    var keepFinishedFor: TimeInterval = 15 * 60

    func begin(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pulls[name]?.state == "running" { return false }
        stopRequests.remove(name)
        pulls[name] = Pull(state: "running", phase: "queued", updatedAt: Date())
        return true
    }

    func stopRequested(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequests.contains(name)
    }

    @discardableResult
    func update(_ name: String, _ status: JSON) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var pull = pulls[name], pull.state == "running" else { return true }
        let text = status["status"].stringValue ?? ""
        if text == "pulling manifest" {
            pull.phase = "starting"
        } else if text.hasPrefix("retrying") {
            pull.phase = "retrying"
            pull.message = text
        } else if text.hasPrefix("pulling") {
            pull.phase = "downloading"
            pull.message = nil
        } else if text.hasPrefix("verifying") {
            pull.phase = "verifying"
        } else if text == "writing manifest" {
            pull.phase = "installing"
        }
        if let completed = status["completed"].numberValue { pull.completed = Int64(completed) }
        if let total = status["total"].numberValue, total > 0 { pull.total = Int64(total) }
        pull.updatedAt = Date()
        pulls[name] = pull
        return !stopRequests.contains(name)
    }

    func finish(_ name: String, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard var pull = pulls[name] else { return }
        let stopped = stopRequests.remove(name) != nil
        if error == nil {
            pull.state = "done"
            pull.message = nil
            if let total = pull.total { pull.completed = total }
        } else if stopped {
            pull.state = "stopped"
            pull.message = nil
        } else {
            pull.state = "failed"
            pull.message = error
        }
        pull.updatedAt = Date()
        pulls[name] = pull
    }

    func stop(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pulls[name]?.state == "running" else { return false }
        stopRequests.insert(name)
        return true
    }

    func snapshot(now: Date = Date()) -> [(name: String, pull: Pull)] {
        lock.lock()
        defer { lock.unlock() }
        pulls = pulls.filter {
            $0.value.state == "running" || now.timeIntervalSince($0.value.updatedAt) < keepFinishedFor
        }
        return pulls.map { (name: $0.key, pull: $0.value) }.sorted { $0.pull.updatedAt > $1.pull.updatedAt }
    }

    static func json(name: String, pull: Pull) -> JSON {
        .object(
            JSONObject([
                ("name", JSON(name)),
                ("state", JSON(pull.state)),
                ("phase", JSON(pull.phase)),
                ("completed", JSON(pull.completed)),
                ("total", pull.total.map { JSON($0) } ?? .null),
                ("message", JSON(pull.message)),
                ("updatedAt", JSON(JS.iso(pull.updatedAt))),
            ]))
    }
}

extension NativeRuntime {
    func modelLibraryState() -> JSON {
        let entries = ModelLibrary.load(nativeModelStore.catalogPath)
        let installed: Set<String> =
            usesNativeEngine
            ? Set(nativeModelStore.list().map(\.name))
            : Set(
                installedModels().compactMap {
                    $0["name"].stringValue.flatMap { try? NativeModelStore.normalize($0).name }
                })
        let memory = ProcessInfo.processInfo.physicalMemory
        let budget = ModelLibrary.budget(memoryBytes: memory, environment: ProcessInfo.processInfo.environment)
        let recommended = SetupPlatform.recommendedModel(memoryBytes: memory).model
        let pulls = modelPulls.snapshot()
        let models: [JSON] = entries.map { entry in
            var object = ModelLibrary.json(entry, budget: budget, recommended: recommended)
            object["installed"] = JSON(installed.contains(entry.name))
            return .object(object)
        }
        return .object(
            JSONObject([
                ("models", .array(models)),
                ("pulls", .array(pulls.map { ModelPullTracker.json(name: $0.name, pull: $0.pull) })),
                ("memoryBytes", JSON(Int64(memory))),
                ("budgetBytes", JSON(budget)),
                ("recommendedModel", JSON(recommended)),
            ]))
    }

    func startModelLibraryPull(_ body: JSON) throws -> JSON {
        let raw = (body["model"].stringValue ?? body["name"].stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let name = try NativeModelStore.normalize(raw).name
        guard ModelLibrary.load(nativeModelStore.catalogPath).contains(where: { $0.name == name }) else {
            throw requestError("\(name) isn't in RoachNet's model library.", 404)
        }
        let started = pullModel(name)
        return ["ok": true, "model": JSON(name), "status": JSON(started ? "queued" : "already-running")]
    }

    func stopModelLibraryPull(_ body: JSON) throws -> JSON {
        let raw = (body["model"].stringValue ?? body["name"].stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let name = try NativeModelStore.normalize(raw).name
        return ["ok": true, "model": JSON(name), "stopped": JSON(modelPulls.stop(name))]
    }
}
