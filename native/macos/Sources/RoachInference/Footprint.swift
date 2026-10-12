import Foundation

/// What running a model takes in memory, worked out from its GGUF metadata
/// alone: nothing is loaded and the weights are not read.
public struct ModelFootprint: Equatable {
    /// The mapped weights (the GGUF file).
    public let weights: Int
    /// Keys and values for every layer, in FP32, for `context` tokens.
    public let cache: Int
    /// Activations, scores, logits and the batched-prefill buffers.
    public let scratch: Int
    public let context: Int
    /// The context the model was trained for.
    public let trainedContext: Int

    public var total: Int { weights + cache + scratch }

    /// Bytes of cache per token of context.
    public let cachePerToken: Int

    /// `stage`: one part of a model split across Macs (the whole model when nil).
    public init(file: GGUFFile, contextLength: Int, stage: ModelStage? = nil) throws {
        let vocabulary = file.tensors["token_embd.weight"]?.shape.last ?? 32_000
        let hp = try ModelHyperparameters(gguf: file, vocabularySize: vocabulary)
        trainedContext = hp.contextLength
        context = max(16, min(contextLength, hp.contextLength))
        let keyValueWidth = hp.headCountKV * (hp.headDimension + hp.valueDimension)
        let stage = stage ?? .whole(hp.blockCount)
        cachePerToken = stage.layers.count * keyValueWidth * 4
        cache = cachePerToken * context
        let width = max(hp.embeddingLength, hp.headCount * hp.valueDimension)
        let decode = 4 * (hp.embeddingLength + 2 * width + hp.headCount * (hp.headDimension + hp.valueDimension)
            + 2 * hp.feedForwardLength + hp.headCount * context + hp.vocabularySize)
        let packedWidth = 2 * hp.embeddingLength + hp.headCount * (hp.headDimension + hp.valueDimension) + keyValueWidth + 2 * hp.feedForwardLength
        let batch = 512 / 4 * 16 * packedWidth
        // Kernels, pipelines and the startup check against the CPU reference.
        scratch = decode + batch + (48 << 20)
        if stage.isWhole(hp.blockCount) {
            weights = file.fileSize
        } else {
            let tied = file.tensors["output.weight"] == nil
            weights = file.tensors.values.filter { stage.includes(tensor: $0.name, tiedOutput: tied) }.reduce(0) { $0 + $1.byteCount }
        }
    }

    /// Bytes of one layer's weights, and of the embedding and head, for planning a split.
    public static func layerBytes(_ file: GGUFFile) -> (layers: [Int], embedding: Int, head: Int) {
        var layers: [Int: Int] = [:]
        var embedding = 0, head = 0
        for info in file.tensors.values {
            if info.name.hasPrefix("blk."), let index = Int(info.name.dropFirst(4).prefix { $0.isNumber }) {
                layers[index, default: 0] += info.byteCount
            } else if info.name == "token_embd.weight" {
                embedding = info.byteCount
            } else if info.name == "output.weight" || info.name == "output_norm.weight" {
                head += info.byteCount
            }
        }
        if file.tensors["output.weight"] == nil { head += embedding }
        let count = (layers.keys.max() ?? -1) + 1
        return ((0..<count).map { layers[$0] ?? 0 }, embedding, head)
    }

    /// The same model at another context length.
    public func with(context newContext: Int) -> ModelFootprint {
        ModelFootprint(weights: weights, cache: cachePerToken * newContext, scratch: scratch, context: newContext,
                       trainedContext: trainedContext, cachePerToken: cachePerToken)
    }

    init(weights: Int, cache: Int, scratch: Int, context: Int, trainedContext: Int, cachePerToken: Int) {
        self.weights = weights
        self.cache = cache
        self.scratch = scratch
        self.context = context
        self.trainedContext = trainedContext
        self.cachePerToken = cachePerToken
    }
}
