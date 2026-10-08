import Foundation

/// One decoding context: a KV cache plus scratch buffers for a model.
/// Not thread-safe; use one session per concurrent conversation.
public final class InferenceSession {
    public let model: TransformerModel
    public let contextLength: Int
    /// Tokens whose keys and values are in the cache, in order.
    public private(set) var cachedTokens: [Int32] = []

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

    public init(model: TransformerModel, contextLength: Int? = nil) {
        self.model = model
        let hp = model.hyperparameters
        let context = max(16, min(contextLength ?? min(hp.contextLength, 4096), hp.contextLength))
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

    public var vocabularySize: Int { model.outputProjection.rows }

    /// Forgets cached tokens beyond `count` (prefix reuse).
    public func truncate(to count: Int) {
        if count < cachedTokens.count { cachedTokens.removeLast(cachedTokens.count - count) }
    }

    public func reset() { cachedTokens.removeAll(keepingCapacity: true) }

    /// Reuses the longest cached prefix of `tokens`, evaluates the rest, and
    /// returns the logits for the final token. At least one token is always
    /// re-evaluated so logits are fresh.
    public func prefill(_ tokens: [Int32], cancelled: () -> Bool = { false }) throws -> [Float] {
        guard !tokens.isEmpty else { throw InferenceError.invalid("Prompt is empty.") }
        guard tokens.count <= contextLength else {
            throw InferenceError.invalid("Prompt is \(tokens.count) tokens; the context holds \(contextLength).")
        }
        var common = 0
        while common < min(tokens.count - 1, cachedTokens.count), tokens[common] == cachedTokens[common] { common += 1 }
        truncate(to: common)
        for token in tokens[common...] {
            if cancelled() { throw InferenceError.cancelled }
            try step(token)
        }
        return logits()
    }

    /// Appends one token and runs the forward pass for it.
    public func step(_ token: Int32) throws {
        guard cachedTokens.count < contextLength else { throw InferenceError.invalid("The context window is full.") }
        guard token >= 0, Int(token) < model.tokenEmbedding.rows else { throw InferenceError.invalid("Token \(token) is out of range.") }
        forward(token: Int(token), position: cachedTokens.count)
        cachedTokens.append(token)
    }

    public func logits() -> [Float] {
        Array(UnsafeBufferPointer(start: logitsBuffer, count: vocabularySize))
    }

    // MARK: Forward pass

    private func forward(token: Int, position: Int) {
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

        Kernels.rmsNorm(x, model.outputNorm, dim, hp.rmsEpsilon, into: normed)
        model.outputProjection.multiply(normed, into: logitsBuffer)
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
