import Foundation

/// The model server's side of plan models: listing them and answering
/// `/api/chat`, `/api/generate` and `/v1/chat/completions` in each API's own
/// shape, streamed or not, and traced like any other generation.
extension NativeModelServer {
    func subscriptionTags() -> [JSON] {
        guard let subscriptions else { return [] }
        return subscriptions.listed().map { item in
            let name = "\(item.provider.rawValue):\(item.model)"
            return [
                "name": JSON(name), "model": JSON(name), "modified_at": JSON(JS.isoNow()), "size": 0, "digest": "",
                "details": ["parent_model": "", "format": "subscription", "family": JSON(item.provider.rawValue), "families": [JSON(item.provider.rawValue)],
                            "parameter_size": "", "quantization_level": ""],
                "remote_host": JSON(item.provider.kind.label),
            ]
        }
    }

    func subscriptionOpenAIModels() -> [JSON] {
        guard let subscriptions else { return [] }
        return subscriptions.listed().map { item in
            ["id": JSON("\(item.provider.rawValue):\(item.model)"), "object": "model", "created": JSON(Double(Int(Date().timeIntervalSince1970))),
             "owned_by": JSON(item.provider.ownedBy)]
        }
    }

    enum SubscriptionEndpoint { case chat, generate, openAI }

    func subscriptionResponse(_ body: JSON, endpoint: SubscriptionEndpoint, traceparent: String?) throws -> HTTPResponse? {
        let name = body["model"].stringValue ?? ""
        guard let (provider, model) = SubscriptionModels.parse(name) else { return nil }
        guard let subscriptions else { throw requestError("Plan models aren't available in this runtime.", 404) }
        var messages = body["messages"].array
        if endpoint == .generate {
            var built: [JSON] = []
            if let system = body["system"].stringValue, !system.isEmpty { built.append(["role": "system", "content": JSON(system)]) }
            built.append(["role": "user", "content": body["prompt"]])
            messages = built
        }
        guard !messages.isEmpty else {
            return .json(200, ["model": JSON(name), "created_at": JSON(JS.isoNow()), "message": ["role": "assistant", "content": ""], "done": true, "done_reason": "load"])
        }
        let stream = endpoint == .openAI ? body["stream"].truthy : (body["stream"].isUndefined ? true : body["stream"].truthy)
        let label = endpoint == .openAI ? "v1/chat/completions" : (endpoint == .chat ? "chat" : "generate")
        let started = Date()

        func answer(_ onText: @escaping (String) -> Void) throws -> SubscriptionModels.Reply {
            let trace = subscriptionTrace(name: "\(label) \(name)", model: name, provider: provider, input: .array(messages), traceparent: traceparent)
            do {
                let reply = try subscriptions.reply(provider, model: model, messages: messages, onText: onText)
                if let first = reply.firstTokenMs { trace?.observation.markFirstToken(at: first) }
                var metadata = JSONObject([("engine", JSON(provider == .claude ? "claude-code" : "codex")), ("plan", JSON(provider.label))])
                if let usd = reply.apiEquivalentUsd { metadata["apiEquivalentUsd"] = JSON(usd) }
                trace?.observation.end(output: trace?.enrichesParent == true ? .null : JSON(reply.text), usage: reply.usage,
                                       cost: TraceCost(totalUsd: 0, status: "included", billingType: "subscription_included"), metadata: metadata, model: reply.model)
                trace?.ownTrace?.end(status: "ok", output: JSON(reply.text))
                return reply
            } catch {
                let message = (error as? RuntimeError)?.message ?? "\(error)"
                trace?.observation.end(level: .error, statusMessage: message)
                trace?.ownTrace?.end(status: "error", message: message)
                throw error
            }
        }

        func timings(_ reply: SubscriptionModels.Reply) -> [(String, JSON)] {
            let total = Int64(Date().timeIntervalSince(started) * 1_000_000_000)
            return [("total_duration", JSON(Double(total))), ("prompt_eval_count", JSON(reply.usage.inputTokens - reply.usage.cachedInputTokens)),
                    ("eval_count", JSON(reply.usage.outputTokens))]
        }
        func line(_ value: JSON) -> Data { Data((value.serialized() + "\n").utf8) }

        switch endpoint {
        case .openAI:
            let id = "chatcmpl-" + JS.randomHex(12)
            let created = JSON(Double(Int(Date().timeIntervalSince1970)))
            if !stream {
                let reply = try answer { _ in }
                return .json(200, ["id": JSON(id), "object": "chat.completion", "created": created, "model": JSON(name),
                                   "choices": [["index": 0, "message": ["role": "assistant", "content": JSON(reply.text)], "finish_reason": "stop"]],
                                   "usage": ["prompt_tokens": JSON(reply.usage.inputTokens), "completion_tokens": JSON(reply.usage.outputTokens),
                                             "total_tokens": JSON(reply.usage.totalTokens),
                                             "prompt_tokens_details": ["cached_tokens": JSON(reply.usage.cachedInputTokens)]]])
            }
            var response = HTTPResponse(status: 200, headers: [("content-type", "text/event-stream"), ("cache-control", "no-store")])
            response.stream = { writer in
                func event(_ value: JSON) { writer.write(Data(("data: " + value.serialized() + "\n\n").utf8)) }
                do {
                    _ = try answer { piece in
                        event(["id": JSON(id), "object": "chat.completion.chunk", "created": created, "model": JSON(name),
                               "choices": [["index": 0, "delta": ["role": "assistant", "content": JSON(piece)], "finish_reason": nil]]])
                    }
                    event(["id": JSON(id), "object": "chat.completion.chunk", "created": created, "model": JSON(name),
                           "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]])
                } catch {
                    event(["error": ["message": JSON((error as? RuntimeError)?.message ?? "\(error)")]])
                }
                writer.write(Data("data: [DONE]\n\n".utf8))
            }
            return response
        case .chat, .generate:
            func piece(_ text: String, done: Bool) -> JSON {
                var out = JSONObject([("model", JSON(name)), ("created_at", JSON(JS.isoNow()))])
                if endpoint == .chat { out["message"] = ["role": "assistant", "content": JSON(text)] } else { out["response"] = JSON(text) }
                out["done"] = JSON(done)
                return .object(out)
            }
            if !stream {
                let reply = try answer { _ in }
                var out = piece(reply.text, done: true).object
                out["done_reason"] = "stop"
                for (key, value) in timings(reply) { out[key] = value }
                return .json(200, .object(out))
            }
            return .ndjsonStream { writer in
                do {
                    let reply = try answer { text in writer.write(line(piece(text, done: false))) }
                    var out = piece("", done: true).object
                    out["done_reason"] = "stop"
                    for (key, value) in timings(reply) { out[key] = value }
                    writer.write(line(.object(out)))
                } catch {
                    writer.write(line(["error": JSON((error as? RuntimeError)?.message ?? "\(error)")]))
                }
            }
        }
    }

    struct SubscriptionTrace {
        var observation: ObservationHandle
        var ownTrace: TraceHandle?
        var enrichesParent: Bool
    }

    /// Nests under a caller's trace when it sent `traceparent` (enriching the
    /// caller's own generation), or starts a "model" trace of its own.
    private func subscriptionTrace(name: String, model: String, provider: SubscriptionModels.Provider, input: JSON, traceparent: String?) -> SubscriptionTrace? {
        guard let tracer else { return nil }
        if let attached = tracer.attach(traceparent: traceparent) {
            let (handle, parent) = attached
            if parent.type == .generation {
                let observation = ObservationHandle(tracer: tracer, traceId: handle.traceId, id: parent.id)
                observation.update { record in
                    if record.model == nil { record.model = model }
                    if record.provider == nil { record.provider = provider.kind.provider }
                }
                return SubscriptionTrace(observation: observation, ownTrace: nil, enrichesParent: true)
            }
            let observation = handle.observation(.generation, name, parentId: parent.id, input: input, model: model, provider: provider.kind.provider)
            return SubscriptionTrace(observation: observation, ownTrace: nil, enrichesParent: false)
        }
        guard tracer.settings.traceModelServer,
              let own = tracer.startTrace(kind: "model", name: name, tags: ["model-server", "plan"], input: input) else { return nil }
        let observation = own.observation(.generation, model, input: input, model: model, provider: provider.kind.provider)
        return SubscriptionTrace(observation: observation, ownTrace: own, enrichesParent: false)
    }
}
