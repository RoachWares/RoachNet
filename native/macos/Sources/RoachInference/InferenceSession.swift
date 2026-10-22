import Foundation

public final class InferenceSession {
    public let model: TransformerModel
    public let contextLength: Int
    public let backend: TransformerBackend
    public private(set) var cachedTokens: [Int32] = []

    public init(model: TransformerModel, contextLength: Int? = nil, backend preferred: BackendPreference = .automatic) {
        self.model = model
        let hp = model.hyperparameters
        let context = max(16, min(contextLength ?? min(hp.contextLength, 4096), hp.contextLength))
        self.contextLength = context
        self.backend = BackendSelector.make(model: model, contextLength: context, preference: preferred)
    }

    public init(model: TransformerModel, backend: TransformerBackend) {
        self.model = model
        self.contextLength = backend.contextLength
        self.backend = backend
    }

    public var vocabularySize: Int { model.vocabularyRows }

    public func sibling() -> InferenceSession? {
        #if canImport(Metal)
        if let metal = backend as? MetalBackend {
            return (try? metal.sibling()).map { InferenceSession(model: model, backend: $0) }
        }
        #endif
        if backend is CPUBackend {
            return InferenceSession(model: model, backend: CPUBackend(model: model, contextLength: contextLength))
        }
        return nil
    }

    @discardableResult
    public func adoptPrefix(of other: InferenceSession, count: Int) -> Bool {
        let count = min(count, other.cachedTokens.count, contextLength)
        guard count > 0, other.model === model, let copier = backend as? CacheCopying,
            copier.copyCache(from: other.backend, count: count)
        else { return false }
        cachedTokens = Array(other.cachedTokens.prefix(count))
        return true
    }

    private func checkBackend() throws {
        if let failure = (backend as? FallibleBackend)?.takeFailure() {
            reset()
            throw failure
        }
    }

    public func truncate(to count: Int) {
        if count < cachedTokens.count { cachedTokens.removeLast(cachedTokens.count - count) }
    }

    public func reset() { cachedTokens.removeAll(keepingCapacity: true) }

    public func prefill(_ tokens: [Int32], cancelled: () -> Bool = { false }) throws -> [Float] {
        guard !tokens.isEmpty else { throw InferenceError.invalid("Prompt is empty.") }
        guard tokens.count <= contextLength else {
            throw InferenceError.invalid("Prompt is \(tokens.count) tokens; the context holds \(contextLength).")
        }
        var common = 0
        while common < min(tokens.count - 1, cachedTokens.count), tokens[common] == cachedTokens[common] { common += 1 }
        truncate(to: common)
        for token in tokens[common...] where token < 0 || Int(token) >= model.vocabularyRows {
            throw InferenceError.invalid("Token \(token) is out of range.")
        }
        if let batched = backend as? BatchForwarding, batched.maxBatch >= 4, tokens.count - common >= 2 {
            var index = common
            while index < tokens.count {
                if cancelled() { throw InferenceError.cancelled }
                let end = min(tokens.count, index + batched.maxBatch)
                let chunk = tokens[index..<end]
                batched.forward(
                    tokens: chunk.map { Int($0) }, position: index, output: end == tokens.count ? .logits : .none,
                    each: nil)
                try checkBackend()
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

    public func step(_ token: Int32, output: ForwardOutput = .logits) throws {
        guard cachedTokens.count < contextLength else { throw InferenceError.invalid("The context window is full.") }
        guard token >= 0, Int(token) < model.vocabularyRows else {
            throw InferenceError.invalid("Token \(token) is out of range.")
        }
        backend.forward(token: Int(token), position: cachedTokens.count, output: output)
        try checkBackend()
        cachedTokens.append(token)
    }

    public enum Pooling: Int {
        case mean = 1
        case cls = 2
        case last = 3
    }

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
            for token in tokens where token < 0 || Int(token) >= model.vocabularyRows {
                throw InferenceError.invalid("Token \(token) is out of range.")
            }
            var index = 0
            while index < tokens.count {
                let end = min(tokens.count, index + batched.maxBatch)
                let chunk = tokens[index..<end]
                let start = index
                let wanted =
                    pooling == .mean || (pooling == .cls && start == 0) || (pooling == .last && end == tokens.count)
                batched.forward(
                    tokens: chunk.map { Int($0) }, position: start, output: .none,
                    each: wanted
                        ? { offset, hidden in
                            let t = start + offset
                            if pooling == .mean {
                                for d in 0..<width { sum[d] += hidden[d] }
                            } else if (pooling == .cls && t == 0) || (pooling == .last && t == tokens.count - 1) {
                                chosen = Array(hidden)
                            }
                        } : nil)
                try checkBackend()
                cachedTokens.append(contentsOf: chunk)
                index = end
            }
        }
        for (index, token) in tokens.enumerated() where cachedTokens.count <= index {
            let wanted =
                pooling == .mean || (pooling == .cls && index == 0) || (pooling == .last && index == tokens.count - 1)
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

public enum KVCacheType: String {
    case f16, f32
    public var bytes: Int { self == .f16 ? 2 : 4 }
    public static var preferred: KVCacheType {
        ProcessInfo.processInfo.environment["ROACHNET_KV_CACHE"].flatMap(KVCacheType.init(rawValue:)) ?? .f16
    }
}

enum BackendSelector {
    static func make(model: TransformerModel, contextLength: Int, preference: BackendPreference) -> TransformerBackend {
        let forced = ProcessInfo.processInfo.environment["ROACHNET_INFERENCE_BACKEND"].flatMap(
            BackendPreference.init(rawValue:))
        let choice = forced ?? preference
        #if canImport(Metal)
        if choice != .cpu, let metal = MetalBackend.makeVerified(model: model, contextLength: contextLength) {
            return metal
        }
        #endif
        return CPUBackend(model: model, contextLength: contextLength)
    }
}

public enum ForwardOutput {
    case logits
    case hidden
    case none
}

public protocol BatchForwarding: AnyObject {
    var maxBatch: Int { get }
    func forward(
        tokens: [Int], position: Int, output: ForwardOutput, each: ((Int, UnsafeBufferPointer<Float>) -> Void)?)
}

public protocol StageBackend: AnyObject {
    var residualState: UnsafeBufferPointer<Float> { get }
    func forward(residual: UnsafePointer<Float>, position: Int, output: ForwardOutput)
    func applyHead(residual: UnsafePointer<Float>, output: ForwardOutput)
}

public protocol StageBatchForwarding: BatchForwarding {
    func forward(
        residuals: UnsafePointer<Float>, count: Int, position: Int, output: ForwardOutput,
        each: ((Int, UnsafeBufferPointer<Float>) -> Void)?)
    func batchResiduals(count: Int) -> [Float]
}

public protocol CacheCopying: AnyObject {
    func copyCache(from other: TransformerBackend, count: Int) -> Bool
}

public protocol FallibleBackend: AnyObject {
    func takeFailure() -> Error?
}

public protocol TransformerBackend: AnyObject {
    var name: String { get }
    var contextLength: Int { get }
    func forward(token: Int, position: Int, output: ForwardOutput)
    var logits: UnsafeBufferPointer<Float> { get }
    var hiddenState: UnsafeBufferPointer<Float> { get }
}

extension TransformerBackend {
    public func forward(token: Int, position: Int) { forward(token: token, position: position, output: .logits) }
}

public final class CPUBackend: TransformerBackend, StageBackend, CacheCopying {
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
        keyCache = buffer(model.layers.count * layerKeyStride)
        valueCache = buffer(model.layers.count * layerValueStride)
        let width = max(hp.embeddingLength, hp.headCount * hp.valueDimension)
        x = buffer(hp.embeddingLength)
        normed = buffer(width)
        projected = buffer(width)
        query = buffer(hp.headCount * hp.headDimension)
        attention = buffer(hp.headCount * hp.valueDimension)
        hidden = buffer(hp.feedForwardLength)
        hiddenUp = buffer(hp.feedForwardLength)
        scores = buffer(hp.headCount * context)
        logitsBuffer = buffer(model.vocabularyRows)
    }

    deinit {
        for pointer in [
            keyCache, valueCache, x, normed, projected, query, attention, hidden, hiddenUp, scores, logitsBuffer,
        ] {
            pointer.deallocate()
        }
    }

    public func copyCache(from other: TransformerBackend, count: Int) -> Bool {
        guard let other = other as? CPUBackend, other.model === model, other.contextLength == contextLength,
            count <= contextLength
        else { return false }
        for layer in 0..<model.layers.count {
            (keyCache + layer * layerKeyStride).update(
                from: other.keyCache + layer * layerKeyStride, count: count * kvKeyWidth)
            (valueCache + layer * layerValueStride).update(
                from: other.valueCache + layer * layerValueStride, count: count * kvValueWidth)
        }
        return true
    }

    public var logits: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: logitsBuffer, count: model.vocabularyRows)
    }

    public var hiddenState: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: normed, count: model.hyperparameters.embeddingLength)
    }

    public var residualState: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: x, count: model.hyperparameters.embeddingLength)
    }

    public func forward(token: Int, position: Int, output: ForwardOutput) {
        if model.stage.embedding { model.tokenEmbedding.dequantizeRow(token, into: x) }
        runLayers(position: position)
        head(output)
    }

    public func forward(residual: UnsafePointer<Float>, position: Int, output: ForwardOutput) {
        x.update(from: residual, count: model.hyperparameters.embeddingLength)
        runLayers(position: position)
        head(output)
    }

    public func applyHead(residual: UnsafePointer<Float>, output: ForwardOutput) {
        x.update(from: residual, count: model.hyperparameters.embeddingLength)
        head(output)
    }

    private func head(_ output: ForwardOutput) {
        guard output != .none, model.stage.head else { return }
        let hp = model.hyperparameters
        Kernels.rmsNorm(x, model.outputNorm, hp.embeddingLength, hp.rmsEpsilon, into: normed)
        if output == .logits { model.outputProjection.multiply(normed, into: logitsBuffer) }
    }

    private func runLayers(position: Int) {
        let hp = model.hyperparameters
        let dim = hp.embeddingLength
        let headDim = hp.headDimension
        let valueDim = hp.valueDimension
        let heads = hp.headCount
        let group = heads / hp.headCountKV
        let scale = 1 / sqrtf(Float(headDim))

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
                for h in 0..<heads {
                    Kernels.rmsNorm(query + h * headDim, norm, headDim, hp.rmsEpsilon, into: query + h * headDim)
                }
            }
            if let norm = layer.keyNorm {
                for h in 0..<hp.headCountKV {
                    Kernels.rmsNorm(keyRow + h * headDim, norm, headDim, hp.rmsEpsilon, into: keyRow + h * headDim)
                }
            }
            Kernels.rope(
                query, heads: heads, headDim: headDim, position: position,
                inverseFrequencies: model.ropeInverseFrequencies, style: hp.ropeStyle)
            Kernels.rope(
                keyRow, heads: hp.headCountKV, headDim: headDim, position: position,
                inverseFrequencies: model.ropeInverseFrequencies, style: hp.ropeStyle)

            let span = position + 1
            let q = UnsafeSendablePointer(query)
            let out = UnsafeSendablePointer(attention)
            let s = UnsafeSendablePointer(scores)
            let k = UnsafeSendablePointer(keys)
            let v = UnsafeSendablePointer(values)
            let keyWidth = kvKeyWidth
            let valueWidth = kvValueWidth
            let context = contextLength
            ParallelFor.run(heads, workers: ParallelFor.workerCount(for: heads * span * headDim * 2)) { start, end in
                for h in start..<end {
                    let kvHead = h / group
                    let qh = UnsafePointer(q.pointer + h * headDim)
                    let row = s.pointer + h * context
                    var maximum = -Float.infinity
                    for t in 0..<span {
                        let score =
                            Quantization.dotF32(qh, k.pointer + t * keyWidth + kvHead * headDim, headDim) * scale
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
    }
}

enum Kernels {
    static func rmsNorm(
        _ input: UnsafePointer<Float>, _ weight: [Float], _ count: Int, _ epsilon: Float,
        into output: UnsafeMutablePointer<Float>
    ) {
        var sum: Double = 0
        for i in 0..<count { sum += Double(input[i]) * Double(input[i]) }
        let scale = Float(1 / (sum / Double(count) + Double(epsilon)).squareRoot())
        weight.withUnsafeBufferPointer { w in
            for i in 0..<count { output[i] = input[i] * scale * w[i] }
        }
    }

    static func rmsNorm(
        _ input: UnsafeMutablePointer<Float>, _ weight: [Float], _ count: Int, _ epsilon: Float,
        into output: UnsafeMutablePointer<Float>
    ) {
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

    static func rope(
        _ vector: UnsafeMutablePointer<Float>, heads: Int, headDim: Int, position: Int, inverseFrequencies: [Float],
        style: RopeStyle
    ) {
        let pairs = inverseFrequencies.count
        let p = Float(position)
        for h in 0..<heads {
            let head = vector + h * headDim
            for i in 0..<pairs {
                let theta = p * inverseFrequencies[i]
                let c = cosf(theta)
                let s = sinf(theta)
                let a: Int
                let b: Int
                switch style {
                case .interleaved:
                    a = 2 * i
                    b = 2 * i + 1
                case .neox:
                    a = i
                    b = i + pairs
                }
                let x0 = head[a]
                let x1 = head[b]
                head[a] = x0 * c - x1 * s
                head[b] = x0 * s + x1 * c
            }
        }
    }
}
