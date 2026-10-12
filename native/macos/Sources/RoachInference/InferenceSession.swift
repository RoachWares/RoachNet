import Foundation

/// One decoding context: a backend (CPU or Metal) with its KV cache, plus
/// prefix reuse. Not thread-safe; use one session per concurrent conversation.
public final class InferenceSession {
    public let model: TransformerModel
    public let contextLength: Int
    public let backend: TransformerBackend
    /// Tokens whose keys and values are in the cache, in order.
    public private(set) var cachedTokens: [Int32] = []

    public init(model: TransformerModel, contextLength: Int? = nil, backend preferred: BackendPreference = .automatic) {
        self.model = model
        let hp = model.hyperparameters
        let context = max(16, min(contextLength ?? min(hp.contextLength, 4096), hp.contextLength))
        self.contextLength = context
        self.backend = BackendSelector.make(model: model, contextLength: context, preference: preferred)
    }

    public var vocabularySize: Int { model.outputProjection.rows }

    /// Forgets cached tokens beyond `count` (prefix reuse).
    public func truncate(to count: Int) {
        if count < cachedTokens.count { cachedTokens.removeLast(cachedTokens.count - count) }
    }

    public func reset() { cachedTokens.removeAll(keepingCapacity: true) }

    /// Reuses the longest cached prefix of `tokens`, evaluates the rest, and
    /// returns the logits for the final token. At least one token is always
    /// re-evaluated so logits are fresh. Only the last token pays for the
    /// vocabulary projection.
    public func prefill(_ tokens: [Int32], cancelled: () -> Bool = { false }) throws -> [Float] {
        guard !tokens.isEmpty else { throw InferenceError.invalid("Prompt is empty.") }
        guard tokens.count <= contextLength else {
            throw InferenceError.invalid("Prompt is \(tokens.count) tokens; the context holds \(contextLength).")
        }
        var common = 0
        while common < min(tokens.count - 1, cachedTokens.count), tokens[common] == cachedTokens[common] { common += 1 }
        truncate(to: common)
        for token in tokens[common...] where token < 0 || Int(token) >= model.tokenEmbedding.rows {
            throw InferenceError.invalid("Token \(token) is out of range.")
        }
        if let batched = backend as? BatchForwarding, batched.maxBatch >= 4, tokens.count - common >= 2 {
            var index = common
            while index < tokens.count {
                if cancelled() { throw InferenceError.cancelled }
                let end = min(tokens.count, index + batched.maxBatch)
                let chunk = tokens[index..<end]
                batched.forward(tokens: chunk.map { Int($0) }, position: index, output: end == tokens.count ? .logits : .none, each: nil)
                cachedTokens.append(contentsOf: chunk)
                index = end
            }
            return logits()
        }
        let last = tokens.count - 1
        for index in common..<tokens.count {
            if cancelled() { throw InferenceError.cancelled }
            try step(tokens[index], output: index == last ? .logits : .none)
        }
        return logits()
    }

    /// Appends one token and runs the forward pass for it.
    public func step(_ token: Int32, output: ForwardOutput = .logits) throws {
        guard cachedTokens.count < contextLength else { throw InferenceError.invalid("The context window is full.") }
        guard token >= 0, Int(token) < model.tokenEmbedding.rows else { throw InferenceError.invalid("Token \(token) is out of range.") }
        backend.forward(token: Int(token), position: cachedTokens.count, output: output)
        cachedTokens.append(token)
    }

    /// How an embedding is pooled from per-token hidden states (GGUF `pooling_type`).
    public enum Pooling: Int { case mean = 1, cls = 2, last = 3 }

    /// One embedding for `tokens`, from a cleared cache. The cache is left
    /// holding these tokens, so a chat on this session starts fresh after it.
    public func embed(_ tokens: [Int32], pooling: Pooling, normalize: Bool = true) throws -> [Float] {
        guard !tokens.isEmpty else { throw InferenceError.invalid("Input is empty.") }
        guard tokens.count <= contextLength else {
            throw InferenceError.invalid("Input is \(tokens.count) tokens; the context holds \(contextLength).")
        }
        reset()
        let width = model.hyperparameters.embeddingLength
        var sum = [Float](repeating: 0, count: width)
        var chosen: [Float] = []
        if let batched = backend as? BatchForwarding, batched.maxBatch >= 4, tokens.count >= 2 {
            for token in tokens where token < 0 || Int(token) >= model.tokenEmbedding.rows {
                throw InferenceError.invalid("Token \(token) is out of range.")
            }
            var index = 0
            while index < tokens.count {
                let end = min(tokens.count, index + batched.maxBatch)
                let chunk = tokens[index..<end]
                let start = index
                let wanted = pooling == .mean || (pooling == .cls && start == 0) || (pooling == .last && end == tokens.count)
                batched.forward(tokens: chunk.map { Int($0) }, position: start, output: .none, each: wanted ? { offset, hidden in
                    let t = start + offset
                    if pooling == .mean {
                        for d in 0..<width { sum[d] += hidden[d] }
                    } else if (pooling == .cls && t == 0) || (pooling == .last && t == tokens.count - 1) {
                        chosen = Array(hidden)
                    }
                } : nil)
                cachedTokens.append(contentsOf: chunk)
                index = end
            }
        }
        for (index, token) in tokens.enumerated() where cachedTokens.count <= index {
            let wanted = pooling == .mean || (pooling == .cls && index == 0) || (pooling == .last && index == tokens.count - 1)
            try step(token, output: wanted ? .hidden : .none)
            guard wanted else { continue }
            let hidden = backend.hiddenState
            if pooling == .mean {
                for d in 0..<width { sum[d] += hidden[d] }
            } else {
                chosen = Array(hidden)
            }
        }
        var vector = pooling == .mean ? sum.map { $0 / Float(tokens.count) } : chosen
        if normalize {
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { vector = vector.map { $0 / norm } }
        }
        return vector
    }

    public func logits() -> [Float] { Array(backend.logits) }
}

public enum BackendPreference: String {
    case automatic, cpu, metal
}

enum BackendSelector {
    static func make(model: TransformerModel, contextLength: Int, preference: BackendPreference) -> TransformerBackend {
        let forced = ProcessInfo.processInfo.environment["ROACHNET_INFERENCE_BACKEND"].flatMap(BackendPreference.init(rawValue:))
        let choice = forced ?? preference
        #if canImport(Metal)
        if choice != .cpu, let metal = MetalBackend.makeVerified(model: model, contextLength: contextLength) {
            return metal
        }
        #endif
        return CPUBackend(model: model, contextLength: contextLength)
    }
}

/// What a forward pass leaves behind besides the KV cache.
public enum ForwardOutput {
    /// Logits over the vocabulary (and the final hidden state).
    case logits
    /// Only the final normalized hidden state (embeddings).
    case hidden
    /// Nothing: a prompt token whose output nobody reads.
    case none
}

/// A backend that runs many prompt tokens in one pass (batched prefill).
public protocol BatchForwarding: AnyObject {
    /// The most tokens one call takes; 0 when this model can't be batched here.
    var maxBatch: Int { get }
    /// Runs `tokens` at positions `position…`, writing their keys and values
    /// into the cache. `.logits` and `.hidden` leave the last token's output as
    /// one `forward` would; `each`, when given, gets every token's final hidden state.
    func forward(tokens: [Int], position: Int, output: ForwardOutput, each: ((Int, UnsafeBufferPointer<Float>) -> Void)?)
}

/// A device that runs the transformer forward pass and owns its KV cache.
public protocol TransformerBackend: AnyObject {
    var name: String { get }
    var contextLength: Int { get }
    /// Runs one token at `position`, writing its keys/values into the cache.
    func forward(token: Int, position: Int, output: ForwardOutput)
    /// Logits produced by the most recent `.logits` forward.
    var logits: UnsafeBufferPointer<Float> { get }
    /// The final normalized hidden state from the most recent `.logits` or `.hidden` forward.
    var hiddenState: UnsafeBufferPointer<Float> { get }
}

extension TransformerBackend {
    public func forward(token: Int, position: Int) { forward(token: token, position: position, output: .logits) }
}

/// CPU reference backend: plain Swift with SIMD and multithreaded matvecs.
public final class CPUBackend: TransformerBackend {
    public let model: TransformerModel
    public let contextLength: Int
    public var name: String { "cpu" }

    private let keyCache: UnsafeMutablePointer<Float>
    private let valueCache: UnsafeMutablePointer<Float>
    private let x: UnsafeMutablePointer<Float>
    private let normed: UnsafeMutablePointer<Float>
    private let projected: UnsafeMutablePointer<Float>
    private let query: UnsafeMutablePointer<Float>
    private let attention: UnsafeMutablePointer<Float>
    private let hidden: UnsafeMutablePointer<Float>
    private let hiddenUp: UnsafeMutablePointer<Float>
    private let scores: UnsafeMutablePointer<Float>
    private let logitsBuffer: UnsafeMutablePointer<Float>
    private let kvKeyWidth: Int
    private let kvValueWidth: Int
    private let layerKeyStride: Int
    private let layerValueStride: Int

    public init(model: TransformerModel, contextLength context: Int) {
        self.model = model
        let hp = model.hyperparameters
        self.contextLength = context
        kvKeyWidth = hp.headCountKV * hp.headDimension
        kvValueWidth = hp.headCountKV * hp.valueDimension
        layerKeyStride = context * kvKeyWidth
        layerValueStride = context * kvValueWidth
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            pointer.initialize(repeating: 0, count: max(count, 1))
            return pointer
        }
        keyCache = buffer(hp.blockCount * layerKeyStride)
        valueCache = buffer(hp.blockCount * layerValueStride)
        let width = max(hp.embeddingLength, hp.headCount * hp.valueDimension)
        x = buffer(hp.embeddingLength)
        normed = buffer(width)
        projected = buffer(width)
        query = buffer(hp.headCount * hp.headDimension)
        attention = buffer(hp.headCount * hp.valueDimension)
        hidden = buffer(hp.feedForwardLength)
        hiddenUp = buffer(hp.feedForwardLength)
        scores = buffer(hp.headCount * context)
        logitsBuffer = buffer(model.outputProjection.rows)
    }

    deinit {
        for pointer in [keyCache, valueCache, x, normed, projected, query, attention, hidden, hiddenUp, scores, logitsBuffer] {
            pointer.deallocate()
        }
    }

    public var logits: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: logitsBuffer, count: model.outputProjection.rows)
    }

    public var hiddenState: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: normed, count: model.hyperparameters.embeddingLength)
    }

    // MARK: Forward pass

    public func forward(token: Int, position: Int, output: ForwardOutput) {
        let hp = model.hyperparameters
        let dim = hp.embeddingLength
        let headDim = hp.headDimension
        let valueDim = hp.valueDimension
        let heads = hp.headCount
        let group = heads / hp.headCountKV
        let scale = 1 / sqrtf(Float(headDim))

        model.tokenEmbedding.dequantizeRow(token, into: x)

        for (layerIndex, layer) in model.layers.enumerated() {
            let keys = keyCache + layerIndex * layerKeyStride
            let values = valueCache + layerIndex * layerValueStride
            let keyRow = keys + position * kvKeyWidth
            let valueRow = values + position * kvValueWidth

            Kernels.rmsNorm(x, layer.attentionNorm, dim, hp.rmsEpsilon, into: normed)
            layer.query.multiply(normed, into: query)
            layer.key.multiply(normed, into: keyRow)
            layer.value.multiply(normed, into: valueRow)
            if let bias = layer.queryBias { Kernels.add(query, bias) }
            if let bias = layer.keyBias { Kernels.add(keyRow, bias) }
            if let bias = layer.valueBias { Kernels.add(valueRow, bias) }
            if let norm = layer.queryNorm {
                for h in 0..<heads { Kernels.rmsNorm(query + h * headDim, norm, headDim, hp.rmsEpsilon, into: query + h * headDim) }
            }
            if let norm = layer.keyNorm {
                for h in 0..<hp.headCountKV { Kernels.rmsNorm(keyRow + h * headDim, norm, headDim, hp.rmsEpsilon, into: keyRow + h * headDim) }
            }
            Kernels.rope(query, heads: heads, headDim: headDim, position: position, inverseFrequencies: model.ropeInverseFrequencies, style: hp.ropeStyle)
            Kernels.rope(keyRow, heads: hp.headCountKV, headDim: headDim, position: position, inverseFrequencies: model.ropeInverseFrequencies, style: hp.ropeStyle)

            // Grouped-query attention over positions 0...position.
            let span = position + 1
            let q = UnsafeSendablePointer(query), out = UnsafeSendablePointer(attention), s = UnsafeSendablePointer(scores)
            let k = UnsafeSendablePointer(keys), v = UnsafeSendablePointer(values)
            let keyWidth = kvKeyWidth, valueWidth = kvValueWidth, context = contextLength
            ParallelFor.run(heads, workers: ParallelFor.workerCount(for: heads * span * headDim * 2)) { start, end in
                for h in start..<end {
                    let kvHead = h / group
                    let qh = UnsafePointer(q.pointer + h * headDim)
                    let row = s.pointer + h * context
                    var maximum = -Float.infinity
                    for t in 0..<span {
                        let score = Quantization.dotF32(qh, k.pointer + t * keyWidth + kvHead * headDim, headDim) * scale
                        row[t] = score
                        if score > maximum { maximum = score }
                    }
                    var sum: Float = 0
                    for t in 0..<span {
                        let e = expf(row[t] - maximum)
                        row[t] = e
                        sum += e
                    }
                    let inverse = 1 / sum
                    let destination = out.pointer + h * valueDim
                    destination.initialize(repeating: 0, count: valueDim)
                    for t in 0..<span {
                        let weight = row[t] * inverse
                        let vt = v.pointer + t * valueWidth + kvHead * valueDim
                        for d in 0..<valueDim { destination[d] += weight * vt[d] }
                    }
                }
            }

            layer.output.multiply(attention, into: projected)
            Kernels.add(x, projected, dim)

            Kernels.rmsNorm(x, layer.feedForwardNorm, dim, hp.rmsEpsilon, into: normed)
            layer.gate.multiply(normed, into: hidden)
            layer.up.multiply(normed, into: hiddenUp)
            Kernels.siluMultiply(hidden, hiddenUp, hp.feedForwardLength)
            layer.down.multiply(hidden, into: projected)
            Kernels.add(x, projected, dim)
        }

        guard output != .none else { return }
        Kernels.rmsNorm(x, model.outputNorm, dim, hp.rmsEpsilon, into: normed)
        if output == .logits { model.outputProjection.multiply(normed, into: logitsBuffer) }
    }
}

/// CPU reference kernels. The Metal backend mirrors these one for one.
enum Kernels {
    static func rmsNorm(_ input: UnsafePointer<Float>, _ weight: [Float], _ count: Int, _ epsilon: Float, into output: UnsafeMutablePointer<Float>) {
        var sum: Double = 0
        for i in 0..<count { sum += Double(input[i]) * Double(input[i]) }
        let scale = Float(1 / (sum / Double(count) + Double(epsilon)).squareRoot())
        weight.withUnsafeBufferPointer { w in
            for i in 0..<count { output[i] = input[i] * scale * w[i] }
        }
    }

    static func rmsNorm(_ input: UnsafeMutablePointer<Float>, _ weight: [Float], _ count: Int, _ epsilon: Float, into output: UnsafeMutablePointer<Float>) {
        rmsNorm(UnsafePointer(input), weight, count, epsilon, into: output)
    }

    static func add(_ target: UnsafeMutablePointer<Float>, _ values: [Float]) {
        for i in values.indices { target[i] += values[i] }
    }

    static func add(_ target: UnsafeMutablePointer<Float>, _ values: UnsafePointer<Float>, _ count: Int) {
        for i in 0..<count { target[i] += values[i] }
    }

    static func add(_ target: UnsafeMutablePointer<Float>, _ values: UnsafeMutablePointer<Float>, _ count: Int) {
        add(target, UnsafePointer(values), count)
    }

    static func siluMultiply(_ gate: UnsafeMutablePointer<Float>, _ up: UnsafeMutablePointer<Float>, _ count: Int) {
        for i in 0..<count {
            let g = gate[i]
            gate[i] = g / (1 + expf(-g)) * up[i]
        }
    }

    static func rope(_ vector: UnsafeMutablePointer<Float>, heads: Int, headDim: Int, position: Int, inverseFrequencies: [Float], style: RopeStyle) {
        let pairs = inverseFrequencies.count
        let p = Float(position)
        for h in 0..<heads {
            let head = vector + h * headDim
            for i in 0..<pairs {
                let theta = p * inverseFrequencies[i]
                let c = cosf(theta), s = sinf(theta)
                let a: Int, b: Int
                switch style {
                case .interleaved: a = 2 * i; b = 2 * i + 1
                case .neox: a = i; b = i + pairs
                }
                let x0 = head[a], x1 = head[b]
                head[a] = x0 * c - x1 * s
                head[b] = x0 * s + x1 * c
            }
        }
    }
}
