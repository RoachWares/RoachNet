import Foundation
import RoachInference

/// Ollama-compatible model API served by RoachNet's own inference engine.
/// RoachClaw and every existing local-model client keep working unchanged:
/// `/api/version`, `/api/tags`, `/api/show`, `/api/pull`, `/api/delete`,
/// `/api/copy`, `/api/generate`, `/api/chat`, `/api/ps`, plus
/// `/v1/chat/completions` and `/v1/models` for OpenAI-style adapters.
final class NativeModelServer {
    static let engineVersion = "roachnet-native-1.1.0"

    final class LoadedModel {
        let name: String
        let engine: InferenceEngine
        let contextLength: Int
        var requestedContext = 0
        let lock = NSLock()
        var lastUsed = Date()
        var expiresAt: Date
        init(name: String, engine: InferenceEngine, contextLength: Int, keepAlive: TimeInterval) {
            self.name = name
            self.engine = engine
            self.contextLength = contextLength
            expiresAt = Date().addingTimeInterval(keepAlive)
        }
    }

    let store: NativeModelStore
    private let lock = NSLock()
    private var loaded: [String: LoadedModel] = [:]
    private let maxLoadedModels: Int
    private var reaper: DispatchSourceTimer?
    var server: LoopbackHTTPServer?

    init(store: NativeModelStore, maxLoadedModels: Int = 2) {
        self.store = store
        self.maxLoadedModels = maxLoadedModels
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

    // MARK: Routing

    /// Desktop shells whose pages Ollama accepts by default (OLLAMA_ORIGINS).
    static let appOriginSchemes = ["app://", "file://", "tauri://", "vscode-webview://"]

    /// Ollama's stance: no rebound Host and no cross-site Origin, so a web page
    /// can neither read this port nor run pulls, chats or deletes on it. Bodies
    /// stay free-form because Ollama clients (`curl -d`) post without a JSON type.
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
        do {
            switch (request.method, path) {
            case ("GET", "/"), ("HEAD", "/"):
                return HTTPResponse(status: 200, headers: [("content-type", "text/plain")], body: Data("RoachNet native model server is running".utf8))
            case ("GET", "/api/version"):
                return .json(200, ["version": JSON(NativeModelServer.engineVersion)])
            case ("GET", "/api/tags"):
                return .json(200, ["models": .array(store.list().map(tagJSON))])
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
                return try generate(readJSON(&request))
            case ("POST", "/api/chat"):
                return try chat(readJSON(&request))
            case ("POST", "/api/embed"), ("POST", "/api/embeddings"), ("POST", "/v1/embeddings"):
                return .json(501, ["error": "Embeddings are not available in the native engine yet."])
            case ("GET", "/v1/models"):
                return .json(200, ["object": "list", "data": .array(store.list().map {
                    ["id": JSON($0.name), "object": "model", "created": JSON(Double(Int(Date().timeIntervalSince1970))), "owned_by": "roachnet"]
                })])
            case ("POST", "/v1/chat/completions"):
                return try openAIChat(readJSON(&request))
            default:
                return .json(404, ["error": "404 page not found"])
            }
        } catch let error as RuntimeError {
            return .json(error.statusCode, ["error": JSON(error.message)])
        } catch {
            return .json(500, ["error": JSON("\(error)")])
        }
    }

    private func readJSON(_ request: inout HTTPRequest) throws -> JSON {
        let data = try request.body()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .object(JSONObject()) }
        do { return try JSON.parse(text) } catch { throw requestError("invalid JSON body", 400) }
    }

    // MARK: Models

    private func details(_ manifest: JSON) -> JSON {
        let family = manifest["family"].stringValue ?? manifest["architecture"].stringValue ?? ""
        return ["parent_model": "", "format": "gguf", "family": JSON(family), "families": .array([JSON(family)]),
                "parameter_size": manifest["parameterSize"] || "", "quantization_level": manifest["quantization"] || ""]
    }

    private func tagJSON(_ entry: NativeModelStore.Entry) -> JSON {
        ["name": JSON(entry.name), "model": JSON(entry.name), "modified_at": entry.manifest["modifiedAt"] || JSON(JS.isoNow()),
         "size": entry.manifest["size"] || 0, "digest": entry.manifest["sha256"] || "", "details": details(entry.manifest)]
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
        return .json(200, ["modelfile": JSON("# RoachNet native model\nFROM \(entry.name)\n"), "parameters": "", "template": JSON(template),
                           "details": details(entry.manifest), "model_info": .object(info),
                           "capabilities": ["completion"], "modified_at": entry.manifest["modifiedAt"] || ""])
    }

    private func copy(_ body: JSON) throws -> HTTPResponse {
        guard let source = body["source"].stringValue, let destination = body["destination"].stringValue,
              let entry = store.entry(source) else { throw requestError("model not found", 404) }
        _ = try store.importFile(entry.modelPath, as: destination)
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
                _ = try store.pull(name, request: body) { status in writer.write(Data((status.serialized() + "\n").utf8)) }
            } catch let error as RuntimeError {
                let failure: JSON = ["error": JSON(error.message)]
                writer.write(Data((failure.serialized() + "\n").utf8))
            } catch {
                let failure: JSON = ["error": JSON("\(error)")]
                writer.write(Data((failure.serialized() + "\n").utf8))
            }
        }
    }

    // MARK: Loading

    private func keepAlive(_ value: JSON) -> TimeInterval {
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
        guard let entry = store.entry(name) else { throw requestError("model '\(rawName)' not found, try pulling it first", 404) }
        lock.lock()
        defer { lock.unlock() }
        let wanted = contextLength ?? 4096
        if let existing = loaded[name], existing.requestedContext == wanted || existing.contextLength == wanted {
            existing.expiresAt = Date().addingTimeInterval(seconds)
            existing.lastUsed = Date()
            return existing
        }
        if loaded.count >= maxLoadedModels, let oldest = loaded.values.min(by: { $0.lastUsed < $1.lastUsed }) {
            loaded[oldest.name] = nil
        }
        let model = try TransformerModel(path: entry.modelPath)
        let engine = InferenceEngine(model: model, contextLength: wanted)
        let item = LoadedModel(name: name, engine: engine, contextLength: engine.session.contextLength, keepAlive: seconds)
        item.requestedContext = wanted
        loaded[name] = item
        RuntimeLog.write("native engine loaded \(name) (ctx \(item.contextLength))")
        return item
    }

    func unload(_ name: String) {
        lock.lock()
        loaded[name] = nil
        lock.unlock()
    }

    private func unloadExpired() {
        lock.lock()
        let now = Date()
        for (name, item) in loaded where item.expiresAt < now && item.lock.try() {
            item.lock.unlock()
            loaded[name] = nil
        }
        lock.unlock()
    }

    private func loadedSnapshot() -> [JSON] {
        lock.lock()
        defer { lock.unlock() }
        return loaded.values.map { item in
            let entry = store.entry(item.name)
            let manifest = entry?.manifest ?? .null
            return ["name": JSON(item.name), "model": JSON(item.name), "size": manifest["size"] || 0,
                    "digest": manifest["sha256"] || "", "details": details(manifest),
                    "expires_at": JSON(item.expiresAt == .distantFuture || item.expiresAt.timeIntervalSinceNow > 1e9 ? "2318-01-01T00:00:00Z" : JS.iso(item.expiresAt)),
                    "size_vram": 0, "context_length": JSON(item.contextLength)]
        }
    }

    // MARK: Generation

    static func options(_ value: JSON) -> GenerationOptions {
        var options = GenerationOptions()
        let o = value
        if let v = o["temperature"].numberValue { options.sampling.temperature = Float(v) }
        if let v = o["top_k"].numberValue { options.sampling.topK = Int(v) }
        if let v = o["top_p"].numberValue { options.sampling.topP = Float(v) }
        if let v = o["min_p"].numberValue { options.sampling.minP = Float(v) }
        if let v = o["repeat_penalty"].numberValue { options.sampling.repeatPenalty = Float(v) }
        if let v = o["repeat_last_n"].numberValue { options.sampling.repeatLastN = Int(v) }
        if let v = o["presence_penalty"].numberValue { options.sampling.presencePenalty = Float(v) }
        if let v = o["frequency_penalty"].numberValue { options.sampling.frequencyPenalty = Float(v) }
        if let v = o["seed"].numberValue, v >= 0 { options.sampling.seed = UInt64(v) }
        if let v = o["num_predict"].numberValue { options.maxTokens = Int(v) }
        options.stop = o["stop"].array.compactMap(\.stringValue)
        return options
    }

    private func timings(_ result: GenerationResult, load: TimeInterval, started: Date) -> JSONObject {
        var object = JSONObject()
        object["total_duration"] = JSON(Double(Int(Date().timeIntervalSince(started) * 1e9)))
        object["load_duration"] = JSON(Double(Int(load * 1e9)))
        object["prompt_eval_count"] = JSON(result.promptTokenCount - result.reusedPromptTokens)
        object["prompt_eval_duration"] = JSON(Double(Int(result.promptDuration * 1e9)))
        object["eval_count"] = JSON(result.tokens.count)
        object["eval_duration"] = JSON(Double(Int(result.generationDuration * 1e9)))
        return object
    }

    private func doneReason(_ result: GenerationResult) -> String {
        switch result.stopReason {
        case .length: return "length"
        case .cancelled: return "cancelled"
        default: return "stop"
        }
    }

    private struct Prepared {
        let item: LoadedModel
        let tokens: [Int32]
        let options: GenerationOptions
        let loadDuration: TimeInterval
        let started: Date
    }

    private func prepare(_ body: JSON, messages: [ChatMessage]?, prompt: String?) throws -> Prepared {
        let started = Date()
        let name = body["model"].stringValue ?? ""
        let num = body["options"]["num_ctx"].numberValue.map { Int($0) }
        let item = try load(name, contextLength: num, keepAlive: keepAlive(body["keep_alive"]))
        let loadDuration = Date().timeIntervalSince(started)
        let engine = item.engine
        let text: String
        if let messages {
            text = engine.renderChat(messages)
        } else if body["raw"].truthy {
            text = prompt ?? ""
        } else {
            var turn: [ChatMessage] = []
            if let system = body["system"].stringValue, !system.isEmpty { turn.append(ChatMessage(role: .system, content: system)) }
            turn.append(ChatMessage(role: .user, content: prompt ?? ""))
            text = engine.renderChat(turn)
        }
        var tokens = engine.tokenizer.encode(text, addSpecial: true, parseSpecial: true)
        if tokens.count > item.contextLength - 8 {
            // Keep the most recent context, as the reference runtime does.
            tokens = Array(tokens.suffix(max(1, item.contextLength / 2)))
        }
        var options = NativeModelServer.options(body["options"])
        let remaining = item.contextLength - tokens.count
        if options.maxTokens < 0 || options.maxTokens > remaining { options.maxTokens = max(1, remaining) }
        return Prepared(item: item, tokens: tokens, options: options, loadDuration: loadDuration, started: started)
    }

    static func messages(_ value: JSON) -> [ChatMessage] {
        value.array.compactMap { message in
            guard let content = message["content"].stringValue ?? (message["content"].isUndefined ? nil : message["content"].jsString) else { return nil }
            let role = ChatMessage.Role(rawValue: message["role"].stringValue ?? "user") ?? .user
            return ChatMessage(role: role, content: content)
        }
    }

    private func run(_ prepared: Prepared, writer: HTTPStreamWriter?, onText: @escaping (String) -> Void) throws -> GenerationResult {
        prepared.item.lock.lock()
        defer {
            prepared.item.lastUsed = Date()
            prepared.item.lock.unlock()
        }
        return try prepared.item.engine.generate(
            tokens: prepared.tokens,
            options: prepared.options,
            cancelled: { writer?.isClosed ?? false },
            onText: onText
        )
    }

    private func line(_ value: JSON) -> Data { Data((value.serialized() + "\n").utf8) }

    private func generate(_ body: JSON) throws -> HTTPResponse {
        let model = body["model"].stringValue ?? ""
        let prompt = body["prompt"].stringValue ?? ""
        if prompt.isEmpty && body["images"].isUndefined {
            // Load (or unload with keep_alive 0) only.
            if keepAlive(body["keep_alive"]) == 0 { unload((try? NativeModelStore.normalize(model).name) ?? model) }
            else { _ = try load(model, contextLength: nil, keepAlive: keepAlive(body["keep_alive"])) }
            return .json(200, ["model": JSON(model), "created_at": JSON(JS.isoNow()), "response": "", "done": true, "done_reason": "load"])
        }
        let prepared = try prepare(body, messages: nil, prompt: prompt)
        let stream = body["stream"].isUndefined ? true : body["stream"].truthy
        if !stream {
            let result = try run(prepared, writer: nil) { _ in }
            var out = JSONObject()
            out["model"] = JSON(model); out["created_at"] = JSON(JS.isoNow()); out["response"] = JSON(result.text)
            out["done"] = true; out["done_reason"] = JSON(doneReason(result))
            for (k, v) in timings(result, load: prepared.loadDuration, started: prepared.started) { out[k] = v }
            return .json(200, .object(out))
        }
        return .ndjsonStream { [self] writer in
            do {
                let result = try self.run(prepared, writer: writer) { piece in
                    writer.write(self.line(["model": JSON(model), "created_at": JSON(JS.isoNow()), "response": JSON(piece), "done": false]))
                }
                var out = JSONObject()
                out["model"] = JSON(model); out["created_at"] = JSON(JS.isoNow()); out["response"] = ""
                out["done"] = true; out["done_reason"] = JSON(self.doneReason(result))
                for (k, v) in self.timings(result, load: prepared.loadDuration, started: prepared.started) { out[k] = v }
                writer.write(self.line(.object(out)))
            } catch {
                writer.write(self.line(["error": JSON("\(error)")]))
            }
        }
    }

    private func chat(_ body: JSON) throws -> HTTPResponse {
        let model = body["model"].stringValue ?? ""
        let messages = NativeModelServer.messages(body["messages"])
        if messages.isEmpty {
            _ = try load(model, contextLength: nil, keepAlive: keepAlive(body["keep_alive"]))
            return .json(200, ["model": JSON(model), "created_at": JSON(JS.isoNow()), "message": ["role": "assistant", "content": ""], "done": true, "done_reason": "load"])
        }
        let prepared = try prepare(body, messages: messages, prompt: nil)
        let stream = body["stream"].isUndefined ? true : body["stream"].truthy
        if !stream {
            let result = try run(prepared, writer: nil) { _ in }
            var out = JSONObject()
            out["model"] = JSON(model); out["created_at"] = JSON(JS.isoNow())
            out["message"] = ["role": "assistant", "content": JSON(result.text)]
            out["done"] = true; out["done_reason"] = JSON(doneReason(result))
            for (k, v) in timings(result, load: prepared.loadDuration, started: prepared.started) { out[k] = v }
            return .json(200, .object(out))
        }
        return .ndjsonStream { [self] writer in
            do {
                let result = try self.run(prepared, writer: writer) { piece in
                    writer.write(self.line(["model": JSON(model), "created_at": JSON(JS.isoNow()),
                                            "message": ["role": "assistant", "content": JSON(piece)], "done": false]))
                }
                var out = JSONObject()
                out["model"] = JSON(model); out["created_at"] = JSON(JS.isoNow())
                out["message"] = ["role": "assistant", "content": ""]
                out["done"] = true; out["done_reason"] = JSON(self.doneReason(result))
                for (k, v) in self.timings(result, load: prepared.loadDuration, started: prepared.started) { out[k] = v }
                writer.write(self.line(.object(out)))
            } catch {
                writer.write(self.line(["error": JSON("\(error)")]))
            }
        }
    }

    private func openAIChat(_ body: JSON) throws -> HTTPResponse {
        var translated = body
        var options = JSONObject()
        if let v = body["temperature"].numberValue { options["temperature"] = JSON(v) }
        if let v = body["top_p"].numberValue { options["top_p"] = JSON(v) }
        if let v = body["max_tokens"].numberValue ?? body["max_completion_tokens"].numberValue { options["num_predict"] = JSON(v) }
        if let v = body["seed"].numberValue { options["seed"] = JSON(v) }
        if let stop = body["stop"].stringValue { options["stop"] = .array([JSON(stop)]) } else if !body["stop"].array.isEmpty { options["stop"] = body["stop"] }
        translated["options"] = .object(options)
        let model = body["model"].stringValue ?? ""
        let prepared = try prepare(translated, messages: NativeModelServer.messages(body["messages"]), prompt: nil)
        let id = "chatcmpl-" + JS.randomHex(12)
        let created = JSON(Double(Int(Date().timeIntervalSince1970)))
        if !body["stream"].truthy {
            let result = try run(prepared, writer: nil) { _ in }
            return .json(200, ["id": JSON(id), "object": "chat.completion", "created": created, "model": JSON(model),
                               "choices": [["index": 0, "message": ["role": "assistant", "content": JSON(result.text)],
                                            "finish_reason": JSON(result.stopReason == .length ? "length" : "stop")]],
                               "usage": ["prompt_tokens": JSON(result.promptTokenCount), "completion_tokens": JSON(result.tokens.count),
                                         "total_tokens": JSON(result.promptTokenCount + result.tokens.count)]])
        }
        var response = HTTPResponse(status: 200, headers: [("content-type", "text/event-stream"), ("cache-control", "no-store")])
        response.stream = { [self] writer in
            func event(_ value: JSON) { writer.write(Data(("data: " + value.serialized() + "\n\n").utf8)) }
            do {
                let result = try self.run(prepared, writer: writer) { piece in
                    event(["id": JSON(id), "object": "chat.completion.chunk", "created": created, "model": JSON(model),
                           "choices": [["index": 0, "delta": ["role": "assistant", "content": JSON(piece)], "finish_reason": nil]]])
                }
                event(["id": JSON(id), "object": "chat.completion.chunk", "created": created, "model": JSON(model),
                       "choices": [["index": 0, "delta": [:], "finish_reason": JSON(result.stopReason == .length ? "length" : "stop")]]])
            } catch {
                event(["error": ["message": JSON("\(error)")]])
            }
            writer.write(Data("data: [DONE]\n\n".utf8))
        }
        return response
    }
}
