import Foundation
import RoachInference

final class NativeModelServer {
    static let engineVersion = "roachnet-native-1.1.0"

    final class LoadedModel {
        let name: String
        var fileKey = ""
        var footprint: ModelFootprint?
        var isBroken: Bool {
            #if canImport(CryptoKit) && canImport(Metal)
            return (engine.session.backend as? ClusterBackend)?.isBroken ?? false
            #else
            return false
            #endif
        }
        let engine: InferenceEngine
        let contextLength: Int
        var requestedContext = 0
        var lastUsed = Date()
        var expiresAt: Date

        final class Slot {
            let engine: InferenceEngine
            var busy = false
            var lastUsed = Date()
            var lastPrompt = 0
            init(engine: InferenceEngine) { self.engine = engine }
        }
        private var slots: [Slot]
        private var growing = 0
        private let condition = NSCondition()
        var maxSlots = 1
        private(set) var extraSlots = 0
        var resident: Int { (footprint?.total ?? 0) + extraSlots * slotBytes }
        var slotBytes: Int { footprint.map { $0.cache + $0.scratch } ?? 0 }

        init(name: String, engine: InferenceEngine, contextLength: Int, keepAlive: TimeInterval) {
            self.name = name
            self.engine = engine
            self.contextLength = contextLength
            slots = [Slot(engine: engine)]
            expiresAt = Date().addingTimeInterval(keepAlive)
        }

        var isBusy: Bool {
            condition.lock()
            defer { condition.unlock() }
            return growing > 0 || slots.contains { $0.busy }
        }

        var slotCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return slots.count
        }

        static func shared(_ a: [Int32], _ b: [Int32]) -> Int {
            var count = 0
            while count < min(a.count, b.count), a[count] == b[count] { count += 1 }
            return count
        }

        static let forkMinimum = 32

        func acquire(for prompt: [Int32], grow: () -> InferenceEngine?) -> Slot {
            condition.lock()
            defer { condition.unlock() }
            func take(_ slot: Slot) -> Slot {
                slot.busy = true
                slot.lastPrompt = prompt.count
                return slot
            }
            while true {
                let idle = slots.filter { !$0.busy }
                let scored = idle.map { ($0, LoadedModel.shared($0.engine.session.cachedTokens, prompt)) }
                let best = scored.max { $0.1 < $1.1 }
                let continuing = scored.filter { slot, shared in shared > 0 && shared + 8 >= slot.lastPrompt }
                if let (slot, _) = continuing.max(by: { $0.1 < $1.1 }) { return take(slot) }
                let source = best.flatMap { $0.1 >= LoadedModel.forkMinimum ? $0 : nil }
                if let empty = idle.first(where: { $0.engine.session.cachedTokens.isEmpty }) {
                    if let (from, shared) = source {
                        empty.engine.session.adoptPrefix(of: from.engine.session, count: shared)
                    }
                    return take(empty)
                }
                if !prompt.isEmpty, slots.count + growing < maxSlots {
                    source?.0.busy = true
                    growing += 1
                    condition.unlock()
                    let engine = grow()
                    if let engine, let (from, shared) = source {
                        engine.session.adoptPrefix(of: from.engine.session, count: shared)
                    }
                    condition.lock()
                    growing -= 1
                    if let from = source?.0 {
                        from.busy = false
                        condition.broadcast()
                    }
                    if let engine {
                        let slot = Slot(engine: engine)
                        slots.append(slot)
                        extraSlots = slots.count - 1
                        return take(slot)
                    }
                    maxSlots = slots.count
                    continue
                }
                if let (slot, _) = source { return take(slot) }
                if let oldest = idle.min(by: { $0.lastUsed < $1.lastUsed }) { return take(oldest) }
                condition.wait()
            }
        }

        func release(_ slot: Slot) {
            condition.lock()
            slot.busy = false
            slot.lastUsed = Date()
            lastUsed = slot.lastUsed
            condition.broadcast()
            condition.unlock()
        }

        func trimSlots(idleSince cutoff: Date) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let before = slots.count
            slots = [slots[0]] + slots.dropFirst().filter { $0.busy || $0.lastUsed >= cutoff }
            extraSlots = slots.count - 1
            return slots.count != before
        }
    }

    let store: NativeModelStore
    private let lock = NSLock()
    var loaded: [String: LoadedModel] = [:] {
        didSet { refreshResident() }
    }
    func refreshResident() { residentTotal = loaded.values.reduce(0) { $0 + $1.resident } }
    let slotsPerModel: Int = {
        let value = Int(ProcessInfo.processInfo.environment["ROACHNET_MODEL_SLOTS"] ?? "") ?? 4
        return max(1, min(16, value))
    }()

    func growSlot(_ item: LoadedModel) -> InferenceEngine? {
        lock.lock()
        defer { lock.unlock() }
        let extra = item.slotBytes
        guard extra > 0, residentTotal + extra <= SystemMemory.modelBudget, extra * 2 < SystemMemory.available() else {
            return nil
        }
        guard let engine = item.engine.sibling() else { return nil }
        residentTotal += extra
        RuntimeLog.write("native engine: \(item.name) gets another request slot (\(SystemMemory.gigabytes(extra)))")
        return engine
    }

    func withSlot<T>(_ item: LoadedModel, prompt: [Int32], _ body: (InferenceEngine) throws -> T) rethrows -> T {
        let slot = item.acquire(for: prompt) { growSlot(item) }
        defer { item.release(slot) }
        return try body(slot.engine)
    }
    private(set) var residentTotal = 0

    func lockedLoaded<T>(_ body: ([String: LoadedModel]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(loaded)
    }
    private let maxLoadedModels: Int
    private var reaper: DispatchSourceTimer?
    var server: LoopbackHTTPServer?
    var tracer: Tracer?
    var subscriptions: SubscriptionModels?
    var planAccess: ((HTTPRequest) -> Bool)?
    #if canImport(CryptoKit) && canImport(Metal)
    var cluster: ClusterNode?
    #endif

    init(store: NativeModelStore, maxLoadedModels: Int = 2) {
        self.store = store
        let configured = ProcessInfo.processInfo.environment["ROACHNET_MAX_LOADED_MODELS"].flatMap { Int($0) }
        self.maxLoadedModels = max(1, configured ?? maxLoadedModels)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.unloadExpired() }
        timer.resume()
        reaper = timer
    }

    func start(host: String, port: UInt16) throws {
        let server = LoopbackHTTPServer(host: host, port: port, maxBodyBytes: 32 << 20) { [unowned self] request in
            self.handle(&request)
        }
        try server.start()
        self.server = server
        RuntimeLog.write("native model server listening on http://\(host):\(server.port)")
    }

    func stop() { server?.stop() }

    static let appOriginSchemes = ["app://", "file://", "tauri://", "vscode-webview://"]

    static func refusal(_ request: HTTPRequest) -> HTTPResponse? {
        guard NativeRuntime.isTrustedLoopbackHost(request.header("host")) else {
            return .json(403, ["error": "Model server requests must use a loopback Host."])
        }
        let origin = request.header("origin")
        let appOrigin = origin.map { value in appOriginSchemes.contains { value.lowercased().hasPrefix($0) } } ?? false
        guard appOrigin || NativeRuntime.isTrustedLoopbackOrigin(origin) else {
            return .json(403, ["error": "Model server requests from other sites are refused."])
        }
        return nil
    }

    func handle(_ request: inout HTTPRequest) -> HTTPResponse {
        if let refusal = Self.refusal(request) { return refusal }
        let path = String(request.target.split(separator: "?", maxSplits: 1).first ?? "")
        let traceparent = request.header("traceparent")
        let plans = request.method == "POST" && (planAccess?(request) ?? false)
        do {
            switch (request.method, path) {
            case ("GET", "/"), ("HEAD", "/"):
                return HTTPResponse(
                    status: 200, headers: [("content-type", "text/plain")],
                    body: Data("RoachNet native model server is running".utf8))
            case ("GET", "/api/version"):
                return .json(200, ["version": JSON(NativeModelServer.engineVersion)])
            case ("GET", "/api/tags"):
                return .json(200, ["models": .array(store.list().map(tagJSON) + subscriptionTags())])
            case ("GET", "/api/ps"):
                return .json(200, ["models": .array(loadedSnapshot())])
            case ("POST", "/api/show"):
                return try show(readJSON(&request))
            case ("POST", "/api/pull"):
                return try pull(readJSON(&request))
            case ("DELETE", "/api/delete"):
                let body = try readJSON(&request)
                let name = body["model"].stringValue ?? body["name"].stringValue ?? ""
                unload(try NativeModelStore.normalize(name).name)
                try store.delete(name)
                return .json(200, [:])
            case ("POST", "/api/copy"):
                return try copy(readJSON(&request))
            case ("POST", "/api/generate"):
                return try answerOllama(readJSON(&request), chat: false, traceparent: traceparent, plans: plans)
            case ("POST", "/api/chat"):
                return try answerOllama(readJSON(&request), chat: true, traceparent: traceparent, plans: plans)
            case ("POST", "/api/create"):
                return try createModel(readJSON(&request))
            case ("POST", "/api/embed"):
                return try answerEmbeddings(readJSON(&request), api: .ollama, traceparent: traceparent)
            case ("POST", "/api/embeddings"):
                return try answerEmbeddings(readJSON(&request), api: .ollamaLegacy, traceparent: traceparent)
            case ("POST", "/v1/embeddings"):
                return try answerEmbeddings(readJSON(&request), api: .openAI, traceparent: traceparent)
            case ("GET", "/v1/models"):
                return .json(
                    200,
                    [
                        "object": "list",
                        "data": .array(
                            store.list().map {
                                [
                                    "id": JSON($0.name), "object": "model",
                                    "created": JSON(Double(Int(Date().timeIntervalSince1970))), "owned_by": "roachnet",
                                ]
                            } + subscriptionOpenAIModels()),
                    ])
            case ("GET", _) where path.hasPrefix("/v1/models/"):
                let id = String(path.dropFirst("/v1/models/".count)).removingPercentEncoding ?? ""
                guard
                    store.entry(id) != nil || subscriptionOpenAIModels().contains(where: { $0["id"].stringValue == id })
                else {
                    throw requestError("The model '\(id)' does not exist", 404)
                }
                return .json(
                    200,
                    ["id": JSON(id), "object": "model", "created": NativeModelServer.created(), "owned_by": "roachnet"])
            case ("POST", "/v1/chat/completions"):
                return try answerOpenAIChat(readJSON(&request), traceparent: traceparent, plans: plans)
            case ("POST", "/v1/completions"):
                return try answerCompletions(readJSON(&request), traceparent: traceparent, plans: plans)
            case ("POST", "/v1/responses"):
                return try answerResponses(readJSON(&request), traceparent: traceparent, plans: plans)
            case ("POST", "/v1/messages"):
                return try answerAnthropic(readJSON(&request), traceparent: traceparent, plans: plans)
            case ("POST", "/v1/messages/count_tokens"):
                return try countAnthropicTokens(readJSON(&request))
            default:
                return .json(404, ["error": "404 page not found"])
            }
        } catch let error as RuntimeError {
            return NativeModelServer.failure(path, status: error.statusCode, message: error.message)
        } catch {
            return NativeModelServer.failure(path, status: 500, message: "\(error)")
        }
    }

    static func failure(_ path: String, status: Int, message: String) -> HTTPResponse {
        if path.hasPrefix("/v1/messages") {
            let kind = status == 404 ? "not_found_error" : status < 500 ? "invalid_request_error" : "api_error"
            return .json(status, ["type": "error", "error": ["type": JSON(kind), "message": JSON(message)]])
        }
        if path.hasPrefix("/v1/") {
            let kind = status < 500 ? "invalid_request_error" : "api_error"
            return .json(
                status,
                [
                    "error": [
                        "message": JSON(message), "type": JSON(kind), "param": .null,
                        "code": status == 404 ? "model_not_found" : .null,
                    ]
                ])
        }
        return .json(status, ["error": JSON(message)])
    }

    func readJSON(_ request: inout HTTPRequest) throws -> JSON {
        let data = try request.body()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .object(JSONObject()) }
        do { return try JSON.parse(text) } catch { throw requestError("invalid JSON body", 400) }
    }

    func details(_ manifest: JSON) -> JSON {
        let family = manifest["family"].stringValue ?? manifest["architecture"].stringValue ?? ""
        return [
            "parent_model": manifest["derivedFrom"] || "", "format": "gguf", "family": JSON(family),
            "families": .array([JSON(family)]),
            "parameter_size": manifest["parameterSize"] || "", "quantization_level": manifest["quantization"] || "",
        ]
    }

    func tagJSON(_ entry: NativeModelStore.Entry) -> JSON {
        [
            "name": JSON(entry.name), "model": JSON(entry.name),
            "modified_at": entry.manifest["modifiedAt"] || JSON(JS.isoNow()),
            "size": entry.manifest["size"] || 0, "digest": entry.manifest["sha256"] || "",
            "details": details(entry.manifest),
        ]
    }

    private func show(_ body: JSON) throws -> HTTPResponse {
        let name = body["model"].stringValue ?? body["name"].stringValue ?? ""
        guard let entry = store.entry(name) else { throw requestError("model '\(name)' not found", 404) }
        let file = try GGUFFile(path: entry.modelPath)
        var info = JSONObject()
        for (key, value) in file.metadata where !key.hasPrefix("tokenizer.ggml.") {
            switch value {
            case .string(let s): info[key] = JSON(s)
            case .uint, .int, .float: info[key] = JSON(value.doubleValue ?? 0)
            case .bool(let b): info[key] = JSON(b)
            case .array: continue
            }
        }
        let template = file["tokenizer.chat_template"]?.stringValue ?? ""
        let made = Modelfile.text(for: entry)
        let embedding = file["\(file.architecture).pooling_type"] != nil
        var capabilities: [JSON] = embedding ? ["embedding"] : ["completion", "tools"]
        if InferenceEngine.thinks(templateSource: template) { capabilities.append("thinking") }
        var out = JSONObject([
            ("modelfile", JSON(made.modelfile)), ("parameters", JSON(made.parameters)), ("template", JSON(template)),
            ("details", details(entry.manifest)), ("model_info", .object(info)), ("capabilities", .array(capabilities)),
            ("modified_at", entry.manifest["modifiedAt"] || ""),
        ])
        if !made.system.isEmpty { out["system"] = JSON(made.system) }
        let opening = entry.manifest["profile"]["messages"]
        if !opening.array.isEmpty { out["messages"] = opening }
        return .json(200, .object(out))
    }

    private func copy(_ body: JSON) throws -> HTTPResponse {
        guard let source = body["source"].stringValue, let destination = body["destination"].stringValue,
            let entry = store.entry(source)
        else { throw requestError("model not found", 404) }
        _ = try store.copy(entry, as: destination)
        return .json(200, [:])
    }

    private func pull(_ body: JSON) throws -> HTTPResponse {
        let name = body["model"].stringValue ?? body["name"].stringValue ?? ""
        _ = try NativeModelStore.normalize(name)
        let stream = body["stream"].isUndefined ? true : body["stream"].truthy
        if !stream {
            _ = try store.pull(name, request: body) { _ in true }
            return .json(200, ["status": "success"])
        }
        return .ndjsonStream { [store] writer in
            do {
                _ = try store.pull(name, request: body) { status in
                    writer.write(Data((status.serialized() + "\n").utf8))
                }
            } catch let error as RuntimeError {
                let failure: JSON = ["error": JSON(error.message)]
                writer.write(Data((failure.serialized() + "\n").utf8))
            } catch {
                let failure: JSON = ["error": JSON("\(error)")]
                writer.write(Data((failure.serialized() + "\n").utf8))
            }
        }
    }

    func keepAlive(_ value: JSON) -> TimeInterval {
        if let seconds = value.numberValue { return seconds < 0 ? .infinity : seconds }
        guard let text = value.stringValue, !text.isEmpty else { return 300 }
        if text.hasPrefix("-") { return .infinity }
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            if let number = Double(text.dropLast(suffix.count)) { return number * scale }
        }
        return Double(text) ?? 300
    }

    func load(_ rawName: String, contextLength: Int?, keepAlive seconds: TimeInterval) throws -> LoadedModel {
        let name = try NativeModelStore.normalize(rawName).name
        guard let entry = store.entry(name) else {
            throw requestError("model '\(rawName)' not found, try pulling it first", 404)
        }
        lock.lock()
        defer { lock.unlock() }
        let wanted = contextLength ?? 4096
        let fileKey = NativeModelStore.fileIdentity(entry.modelPath)
        func fits(_ item: LoadedModel) -> Bool { item.requestedContext == wanted || item.contextLength == wanted }
        if let broken = loaded[name], broken.isBroken { loaded[name] = nil }
        if let existing = loaded[name].flatMap({ fits($0) && $0.fileKey == fileKey ? $0 : nil })
            ?? loaded.values.first(where: { $0.fileKey == fileKey && fits($0) && !$0.isBroken })
        {
            existing.expiresAt = max(existing.expiresAt, Date().addingTimeInterval(seconds))
            existing.lastUsed = Date()
            return existing
        }
        if loaded.count >= maxLoadedModels, let oldest = loaded.values.min(by: { $0.lastUsed < $1.lastUsed }) {
            loaded[oldest.name] = nil
        }
        let file = try GGUFFile(path: entry.modelPath)
        let wantedFootprint = try ModelFootprint(file: file, contextLength: wanted)
        #if canImport(CryptoKit) && canImport(Metal)
        if let cluster, cluster.isActive, cluster.spreadsEveryModel || wantedFootprint.total > SystemMemory.modelBudget
        {
            let others = loaded.values.reduce(0) { $0 + $1.resident }
            if let plan = try cluster.plan(
                file: file, footprint: wantedFootprint, budget: SystemMemory.modelBudget - others,
                spread: cluster.spreadsEveryModel)
            {
                return try loadAcrossCluster(
                    name, entry: entry, file: file, footprint: wantedFootprint, plan: plan, cluster: cluster,
                    keepAlive: seconds, fileKey: fileKey, requested: wanted)
            }
        }
        #endif
        let footprint = try makeRoom(for: name, footprint: wantedFootprint, budget: SystemMemory.modelBudget)
        let model = try TransformerModel(path: entry.modelPath)
        let engine = InferenceEngine(model: model, contextLength: footprint.context)
        let item = LoadedModel(
            name: name, engine: engine, contextLength: engine.session.contextLength, keepAlive: seconds)
        item.requestedContext = wanted
        item.fileKey = fileKey
        item.footprint = footprint
        item.maxSlots = slotsPerModel
        loaded[name] = item
        RuntimeLog.write("native engine loaded \(name) (ctx \(item.contextLength))")
        return item
    }

    func unload(_ name: String) {
        let fileKey = store.entry(name).map { NativeModelStore.fileIdentity($0.modelPath) }
        lock.lock()
        if loaded[name] != nil {
            loaded[name] = nil
        } else if let fileKey {
            for (key, item) in loaded where item.fileKey == fileKey { loaded[key] = nil }
        }
        lock.unlock()
    }

    private func unloadExpired() {
        lock.lock()
        let now = Date()
        for (name, item) in loaded where item.expiresAt < now && !item.isBusy {
            loaded[name] = nil
        }
        var trimmed = false
        for item in loaded.values where item.trimSlots(idleSince: now.addingTimeInterval(-300)) { trimmed = true }
        if trimmed { refreshResident() }
        lock.unlock()
    }

    private func loadedSnapshot() -> [JSON] {
        lock.lock()
        defer { lock.unlock() }
        return loaded.values.map { item in
            let entry = store.entry(item.name)
            let manifest = entry?.manifest ?? .null
            return [
                "name": JSON(item.name), "model": JSON(item.name),
                "digest": manifest["sha256"] || "", "details": details(manifest),
                "expires_at": JSON(
                    item.expiresAt == .distantFuture || item.expiresAt.timeIntervalSinceNow > 1e9
                        ? "2318-01-01T00:00:00Z" : JS.iso(item.expiresAt)),
                "size": JSON(item.footprint == nil ? (manifest["size"].clampedInt(0...(1 << 50)) ?? 0) : item.resident),
                "size_vram": JSON(item.engine.session.backend is CPUBackend ? 0 : item.resident),
                "context_length": JSON(item.contextLength), "backend": JSON(item.engine.session.backend.name),
                "slots": JSON(item.slotCount),
            ]
        }
    }

    static func options(_ value: JSON) -> GenerationOptions {
        var options = GenerationOptions()
        let o = value
        if let v = o["temperature"].numberValue { options.sampling.temperature = Float(v) }
        if let v = o["top_k"].clampedInt() { options.sampling.topK = v }
        if let v = o["top_p"].numberValue { options.sampling.topP = Float(v) }
        if let v = o["min_p"].numberValue { options.sampling.minP = Float(v) }
        if let v = o["repeat_penalty"].numberValue { options.sampling.repeatPenalty = Float(v) }
        if let v = o["repeat_last_n"].clampedInt() { options.sampling.repeatLastN = v }
        if let v = o["presence_penalty"].numberValue { options.sampling.presencePenalty = Float(v) }
        if let v = o["frequency_penalty"].numberValue { options.sampling.frequencyPenalty = Float(v) }
        if let v = o["seed"].numberValue, v >= 0, v.isFinite {
            options.sampling.seed = UInt64(v < 0x1p64 ? v : v.truncatingRemainder(dividingBy: 0x1p64))
        }
        if let v = o["num_predict"].clampedInt() { options.maxTokens = v }
        options.stop = o["stop"].array.compactMap(\.stringValue)
        return options
    }

    func timings(_ result: GenerationResult, load: TimeInterval, started: Date) -> JSONObject {
        var object = JSONObject()
        object["total_duration"] = JSON(Double(Int(Date().timeIntervalSince(started) * 1e9)))
        object["load_duration"] = JSON(Double(Int(load * 1e9)))
        object["prompt_eval_count"] = JSON(result.promptTokenCount - result.reusedPromptTokens)
        object["prompt_eval_duration"] = JSON(Double(Int(result.promptDuration * 1e9)))
        object["eval_count"] = JSON(result.tokens.count)
        object["eval_duration"] = JSON(Double(Int(result.generationDuration * 1e9)))
        return object
    }

    func doneReason(_ result: GenerationResult) -> String {
        switch result.stopReason {
        case .length: return "length"
        case .cancelled: return "cancelled"
        default: return "stop"
        }
    }

    struct Prepared {
        let item: LoadedModel
        let tokens: [Int32]
        let options: GenerationOptions
        let loadDuration: TimeInterval
        let started: Date
        var endpoint = ""
        var traceInput: JSON = .null
        var traceparent: String?
    }

    func run(_ prepared: Prepared, writer: HTTPStreamWriter?, onText: @escaping (String) -> Void) throws
        -> GenerationResult
    {
        let trace = beginTrace(prepared)
        var sawFirstToken = false
        do {
            let result = try withSlot(prepared.item, prompt: prepared.tokens) { engine in
                try engine.generate(
                    tokens: prepared.tokens,
                    options: prepared.options,
                    cancelled: { writer?.isClosed ?? false },
                    onText: { piece in
                        if !sawFirstToken {
                            sawFirstToken = true
                            trace?.observation.markFirstToken()
                        }
                        onText(piece)
                    }
                )
            }
            endTrace(trace, prepared, result: result, error: nil)
            return result
        } catch {
            endTrace(trace, prepared, result: nil, error: error)
            throw error
        }
    }

    struct GenerationTrace {
        let observation: ObservationHandle
        let ownTrace: TraceHandle?
        let enrichesParent: Bool
    }

    func beginTrace(_ prepared: Prepared) -> GenerationTrace? {
        guard let tracer else { return nil }
        let parameters: JSON = [
            "temperature": JSON(Double(prepared.options.sampling.temperature)),
            "top_k": JSON(prepared.options.sampling.topK),
            "top_p": JSON(Double(prepared.options.sampling.topP)), "num_predict": JSON(prepared.options.maxTokens),
            "num_ctx": JSON(prepared.item.contextLength),
        ]
        if let attached = tracer.attach(traceparent: prepared.traceparent) {
            let handle = attached.0
            let parent = attached.1
            if parent.type == .generation {
                let observation = ObservationHandle(tracer: tracer, traceId: handle.traceId, id: parent.id)
                observation.update { record in
                    record.model = record.model ?? prepared.item.name
                    if record.provider == nil { record.provider = "roachinference" }
                    if record.modelParameters.isNullish { record.modelParameters = parameters }
                }
                return GenerationTrace(observation: observation, ownTrace: nil, enrichesParent: true)
            }
            let observation = handle.observation(
                .generation, "\(prepared.endpoint) \(prepared.item.name)", parentId: parent.id,
                input: prepared.traceInput, model: prepared.item.name, provider: "roachinference",
                modelParameters: parameters)
            return GenerationTrace(observation: observation, ownTrace: nil, enrichesParent: false)
        }
        guard tracer.settings.traceModelServer,
            let handle = tracer.startTrace(
                kind: "model", name: "\(prepared.endpoint) \(prepared.item.name)", tags: ["model-server"],
                input: prepared.traceInput,
                metadata: JSONObject([("endpoint", JSON(prepared.endpoint))]))
        else { return nil }
        let observation = handle.observation(
            .generation, prepared.item.name, input: prepared.traceInput, model: prepared.item.name,
            provider: "roachinference", modelParameters: parameters)
        return GenerationTrace(observation: observation, ownTrace: handle, enrichesParent: false)
    }

    func endTrace(_ trace: GenerationTrace?, _ prepared: Prepared, result: GenerationResult?, error: Error?) {
        guard let trace else { return }
        guard let result else {
            let message = (error as? RuntimeError)?.message ?? error.map { "\($0)" } ?? "generation failed"
            trace.observation.end(level: .error, statusMessage: message)
            trace.ownTrace?.end(status: "error", message: message)
            return
        }
        let usage = TraceUsage(
            inputTokens: result.promptTokenCount, outputTokens: result.tokens.count,
            cachedInputTokens: result.reusedPromptTokens)
        let evaluated = result.promptTokenCount - result.reusedPromptTokens
        let engine: JSONObject = JSONObject([
            ("engine", "roachinference"), ("backend", JSON(prepared.item.engine.session.backend.name)),
            ("context_length", JSON(prepared.item.contextLength)),
            ("load_ms", JSON(Int(prepared.loadDuration * 1_000))),
            ("prompt_eval_ms", JSON(Int(result.promptDuration * 1_000))),
            ("eval_ms", JSON(Int(result.generationDuration * 1_000))),
            ("reused_prompt_tokens", JSON(result.reusedPromptTokens)), ("done_reason", JSON(doneReason(result))),
        ])
        trace.observation.update { record in
            record.promptTokensPerSecond =
                result.promptDuration > 0 && evaluated > 0 ? Double(evaluated) / result.promptDuration : nil
            record.outputTokensPerSecond = result.tokensPerSecond > 0 ? result.tokensPerSecond : nil
        }
        trace.observation.end(
            output: trace.enrichesParent ? .null : JSON(result.text), usage: usage, cost: .local,
            level: result.stopReason == .cancelled ? .warning : nil,
            statusMessage: result.stopReason == .cancelled ? "The client went away before the reply finished." : nil,
            metadata: engine)
        trace.ownTrace?.end(status: result.stopReason == .cancelled ? "cancelled" : "ok", output: JSON(result.text))
    }

    func line(_ value: JSON) -> Data { Data((value.serialized() + "\n").utf8) }
}
