import Foundation
import RoachInference

/// `/api/embed`, `/api/embeddings` (Ollama's older form) and `/v1/embeddings`.
extension NativeModelServer {
    enum EmbeddingAPI { case ollama, ollamaLegacy, openAI }

    func answerEmbeddings(_ body: JSON, api: EmbeddingAPI, traceparent: String?) throws -> HTTPResponse {
        let started = Date()
        let model = body["model"].stringValue ?? ""
        if SubscriptionModels.parse(model) != nil { throw requestError("Plan models don't make embeddings; pick a local model.", 400) }
        var inputs: [String] = []
        let input = api == .ollamaLegacy ? body["prompt"] : body["input"]
        if let text = input.stringValue {
            inputs = [text]
        } else if !input.array.isEmpty {
            guard input.array.allSatisfy({ $0.stringValue != nil }) else {
                throw requestError("Send input as text or a list of texts; token lists aren't accepted.", 400)
            }
            inputs = input.array.compactMap(\.stringValue)
        }
        let item = try load(model, contextLength: body["options"]["num_ctx"].clampedInt(), keepAlive: keepAlive(body["keep_alive"]))
        let loadDuration = Date().timeIntervalSince(started)
        if inputs.isEmpty {
            // Ollama loads the model and answers with nothing for an empty input.
            return api == .openAI ? .json(200, ["object": "list", "data": [], "model": JSON(model), "usage": ["prompt_tokens": 0, "total_tokens": 0]])
                : .json(200, ["model": JSON(model), "embeddings": []])
        }
        let truncate = body["truncate"].isUndefined ? true : body["truncate"].truthy
        let dimensions = body["dimensions"].clampedInt()
        if let dimensions, dimensions < 1 { throw requestError("dimensions must be at least 1.", 400) }

        let trace = embeddingTrace(model: item.name, inputs: inputs, traceparent: traceparent)
        var vectors: [[Float]] = []
        var tokens = 0
        let evalStart = Date()
        do {
            try withSlot(item, prompt: []) { engine in
                for text in inputs {
                    let (vector, count) = try engine.embed(text, truncate: truncate, normalize: api != .ollamaLegacy)
                    vectors.append(dimensions.map { NativeModelServer.shortened(vector, to: $0) } ?? vector)
                    tokens += count
                }
            }
        } catch {
            let message = (error as? InferenceError).map { "\($0)" } ?? "\(error)"
            trace?.observation.end(level: .error, statusMessage: message)
            trace?.ownTrace?.end(status: "error", message: message)
            throw requestError(message, 400)
        }
        let evalDuration = Date().timeIntervalSince(evalStart)
        trace?.observation.end(usage: TraceUsage(inputTokens: tokens, outputTokens: 0, cachedInputTokens: 0), cost: .local,
                               metadata: JSONObject([("engine", "roachinference"), ("inputs", JSON(inputs.count)),
                                                     ("dimensions", JSON(vectors.first?.count ?? 0)), ("eval_ms", JSON(Int(evalDuration * 1_000)))]))
        trace?.ownTrace?.end(status: "ok")

        func floats(_ vector: [Float]) -> JSON { .array(vector.map { JSON(Double($0)) }) }
        switch api {
        case .ollamaLegacy:
            return .json(200, ["embedding": floats(vectors[0])])
        case .ollama:
            return .json(200, ["model": JSON(model), "embeddings": .array(vectors.map(floats)),
                               "total_duration": JSON(Double(Int(Date().timeIntervalSince(started) * 1e9))),
                               "load_duration": JSON(Double(Int(loadDuration * 1e9))), "prompt_eval_count": JSON(tokens)])
        case .openAI:
            let base64 = body["encoding_format"].stringValue == "base64"
            let data: [JSON] = vectors.enumerated().map { index, vector in
                let value: JSON = base64 ? JSON(vector.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()) : floats(vector)
                return ["object": "embedding", "index": JSON(index), "embedding": value]
            }
            return .json(200, ["object": "list", "data": .array(data), "model": JSON(model),
                               "usage": ["prompt_tokens": JSON(tokens), "total_tokens": JSON(tokens)]])
        }
    }

    /// Matryoshka-style shortening: the first `count` values, scaled back to unit length.
    static func shortened(_ vector: [Float], to count: Int) -> [Float] {
        guard count < vector.count else { return vector }
        let head = Array(vector.prefix(count))
        let norm = head.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? head.map { $0 / norm } : head
    }

    private func embeddingTrace(model: String, inputs: [String], traceparent: String?) -> GenerationTrace? {
        guard let tracer else { return nil }
        let input: JSON = inputs.count == 1 ? JSON(inputs[0]) : JSON(inputs)
        if let (handle, parent) = tracer.attach(traceparent: traceparent) {
            let observation = handle.observation(.embedding, "embed \(model)", parentId: parent.id, input: input, model: model, provider: "roachinference")
            return GenerationTrace(observation: observation, ownTrace: nil, enrichesParent: false)
        }
        guard tracer.settings.traceModelServer,
              let handle = tracer.startTrace(kind: "model", name: "embed \(model)", tags: ["model-server", "embedding"], input: input) else { return nil }
        let observation = handle.observation(.embedding, model, input: input, model: model, provider: "roachinference")
        return GenerationTrace(observation: observation, ownTrace: handle, enrichesParent: false)
    }
}
