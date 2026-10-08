import Foundation

public struct GenerationOptions {
    public var sampling = SamplingOptions()
    /// Maximum tokens to generate (`num_predict`); negative means until the context fills.
    public var maxTokens = 512
    /// Text that ends generation; it is not included in the output.
    public var stop: [String] = []

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

    public init(model: TransformerModel, contextLength: Int? = nil) {
        self.model = model
        session = InferenceSession(model: model, contextLength: contextLength)
        let source = model.file["tokenizer.chat_template"]?.stringValue
        chatTemplate = ChatTemplate.detect(templateSource: source, tokenizer: model.tokenizer)
        defaultSystemPrompt = chatTemplate == .chatML ? ChatTemplate.defaultSystemPrompt(in: source) : nil
    }

    public convenience init(modelPath: String, contextLength: Int? = nil) throws {
        self.init(model: try TransformerModel(path: modelPath), contextLength: contextLength)
    }

    public var tokenizer: Tokenizer { model.tokenizer }

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

        generation: while generated.count < limit {
            if cancelled() { reason = .cancelled; break }
            let token = sampler.sample(logits, history: session.cachedTokens)
            if tokenizer.isEndOfGeneration(token) {
                reason = .endOfGeneration
                break
            }
            generated.append(token)
            text += decoder.append(tokenizer.piece(token))
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
