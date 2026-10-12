import Foundation

public struct GenerationOptions {
    public var sampling = SamplingOptions()
    /// Maximum tokens to generate (`num_predict`); negative means until the context fills.
    public var maxTokens = 512
    /// Text that ends generation; it is not included in the output.
    public var stop: [String] = []
    /// Limits what may be generated (JSON, a JSON Schema). Generation ends
    /// as soon as the constrained output is complete.
    public var constraint: GenerationConstraint?

    public init() {}
}

public struct GenerationResult {
    public enum StopReason: String { case endOfGeneration = "stop", length, stopSequence = "stop_sequence", cancelled }
    public let text: String
    public let tokens: [Int32]
    public let promptTokenCount: Int
    public let reusedPromptTokens: Int
    public let stopReason: StopReason
    public let promptDuration: TimeInterval
    public let generationDuration: TimeInterval

    public var tokensPerSecond: Double {
        generationDuration > 0 ? Double(tokens.count) / generationDuration : 0
    }
}

/// High-level text generation over a loaded model: prompt formatting, prefix
/// reuse, sampling, stop handling and streamed UTF-8 output.
public final class InferenceEngine {
    public let model: TransformerModel
    public let session: InferenceSession
    public let chatTemplate: ChatTemplate
    public let defaultSystemPrompt: String?
    /// The model reasons in a `<think>` block first (Qwen3, DeepSeek R1 and
    /// others trained that way), so a reply can be split into thinking and
    /// content, and thinking can be switched off.
    public let supportsThinking: Bool

    public convenience init(model: TransformerModel, contextLength: Int? = nil) {
        self.init(session: InferenceSession(model: model, contextLength: contextLength))
    }

    /// An engine over a prepared session (a model split across Macs runs on a cluster backend).
    public init(session: InferenceSession) {
        let model = session.model
        self.model = model
        self.session = session
        let source = model.file["tokenizer.chat_template"]?.stringValue
        chatTemplate = ChatTemplate.detect(templateSource: source, tokenizer: model.tokenizer)
        defaultSystemPrompt = chatTemplate == .chatML ? ChatTemplate.defaultSystemPrompt(in: source) : nil
        supportsThinking = InferenceEngine.thinks(templateSource: source)
    }

    /// Another engine over the same weights with its own KV cache (a parallel request slot).
    public func sibling() -> InferenceEngine? {
        session.sibling().map(InferenceEngine.init(session:))
    }

    public static func thinks(templateSource: String?) -> Bool {
        guard let source = templateSource else { return false }
        return source.contains("enable_thinking") || source.contains("</think>")
    }

    public convenience init(modelPath: String, contextLength: Int? = nil) throws {
        self.init(model: try TransformerModel(path: modelPath), contextLength: contextLength)
    }

    public var tokenizer: Tokenizer { model.tokenizer }

    /// How this model pools embeddings: GGUF `<arch>.pooling_type`, else mean.
    public var pooling: InferenceSession.Pooling {
        let value = model.file["\(model.hyperparameters.architecture).pooling_type"]?.doubleValue.map { Int($0) }
        return value.flatMap(InferenceSession.Pooling.init(rawValue:)) ?? .mean
    }

    /// An L2-normalized embedding of `text`, truncated to the context when `truncate`.
    public func embed(_ text: String, truncate: Bool = true, normalize: Bool = true) throws -> (vector: [Float], tokens: Int) {
        var tokens = tokenizer.encode(text, addSpecial: true, parseSpecial: false)
        // Last-token pooling reads the end-of-text token's state (Qwen3 embedding models).
        if pooling == .last, let eos = tokenizer.eos, tokens.last != eos { tokens.append(eos) }
        if tokens.count > session.contextLength {
            guard truncate else { throw InferenceError.invalid("Input is \(tokens.count) tokens; the context holds \(session.contextLength).") }
            tokens = Array(tokens.prefix(session.contextLength))
        }
        return (try session.embed(tokens, pooling: pooling, normalize: normalize), tokens.count)
    }

    public func renderChat(_ messages: [ChatMessage]) -> String {
        chatTemplate.render(messages, defaultSystem: defaultSystemPrompt)
    }

    public func chat(
        _ messages: [ChatMessage],
        options: GenerationOptions = GenerationOptions(),
        cancelled: @escaping () -> Bool = { false },
        onText: (String) -> Void = { _ in }
    ) throws -> GenerationResult {
        let prompt = renderChat(messages)
        // Templates open with BOS themselves only through the tokenizer.
        return try generate(tokens: tokenizer.encode(prompt, addSpecial: true, parseSpecial: true), options: options, cancelled: cancelled, onText: onText)
    }

    public func generate(
        prompt: String,
        options: GenerationOptions = GenerationOptions(),
        cancelled: @escaping () -> Bool = { false },
        onText: (String) -> Void = { _ in }
    ) throws -> GenerationResult {
        try generate(tokens: tokenizer.encode(prompt, addSpecial: true, parseSpecial: true), options: options, cancelled: cancelled, onText: onText)
    }

    public func generate(
        tokens prompt: [Int32],
        options: GenerationOptions,
        cancelled: @escaping () -> Bool = { false },
        onText: (String) -> Void = { _ in }
    ) throws -> GenerationResult {
        let promptStart = Date()
        let cachedBefore = session.cachedTokens
        var logits = try session.prefill(prompt, cancelled: cancelled)
        var reused = 0
        while reused < min(cachedBefore.count, prompt.count - 1), cachedBefore[reused] == prompt[reused] { reused += 1 }
        let promptDuration = Date().timeIntervalSince(promptStart)

        var sampler = Sampler(options: options.sampling)
        var decoder = StreamingDecoder()
        var generated: [Int32] = []
        var text = ""
        var emitted = 0
        var reason = GenerationResult.StopReason.length
        let limit = options.maxTokens < 0 ? session.contextLength : options.maxTokens
        let stops = options.stop.filter { !$0.isEmpty }
        let holdBack = (stops.map { $0.count }.max() ?? 1) - 1
        let generationStart = Date()

        func flushReady(final: Bool) {
            let end = final ? text.count : max(emitted, text.count - holdBack)
            if end > emitted {
                let start = text.index(text.startIndex, offsetBy: emitted)
                let stop = text.index(text.startIndex, offsetBy: end)
                onText(String(text[start..<stop]))
                emitted = end
            }
        }

        let constraint = options.constraint
        generation: while generated.count < limit {
            if cancelled() { reason = .cancelled; break }
            let token: Int32
            if let constraint {
                let tokenizer = self.tokenizer
                let current = decoder
                guard let chosen = sampler.sample(logits, history: session.cachedTokens, allowed: { id in
                    if tokenizer.isEndOfGeneration(id) { return constraint.canEnd }
                    let bytes = tokenizer.piece(id)
                    guard !bytes.isEmpty else { return false }
                    var probe = current
                    let piece = probe.append(bytes)
                    if piece.isEmpty { return constraint.insideFreeText }
                    return constraint.allows(piece)
                }) else {
                    reason = .endOfGeneration
                    break
                }
                token = chosen
            } else {
                token = sampler.sample(logits, history: session.cachedTokens)
            }
            if tokenizer.isEndOfGeneration(token) {
                reason = .endOfGeneration
                break
            }
            generated.append(token)
            let piece = decoder.append(tokenizer.piece(token))
            text += piece
            if let constraint, !piece.isEmpty {
                constraint.accept(piece)
                if constraint.isComplete {
                    flushReady(final: true)
                    reason = .endOfGeneration
                    break generation
                }
            }
            for stop in stops {
                if let range = text.range(of: stop) {
                    text = String(text[..<range.lowerBound])
                    emitted = min(emitted, text.count)
                    reason = .stopSequence
                    break generation
                }
            }
            flushReady(final: false)
            if generated.count >= limit || session.cachedTokens.count >= session.contextLength { break }
            try session.step(token)
            logits = session.logits()
        }
        if reason != .stopSequence { text += decoder.flush() }
        flushReady(final: true)

        return GenerationResult(
            text: text,
            tokens: generated,
            promptTokenCount: prompt.count,
            reusedPromptTokens: reused,
            stopReason: reason,
            promptDuration: promptDuration,
            generationDuration: Date().timeIntervalSince(generationStart)
        )
    }
}
