import Foundation

public struct ModelFootprint: Equatable {
    public let weights: Int
    public let cache: Int
    public let scratch: Int
    public let context: Int
    public let trainedContext: Int

    public var total: Int { weights + cache + scratch }

    public let cachePerToken: Int

    public init(file: GGUFFile, contextLength: Int, stage: ModelStage? = nil, cacheType: KVCacheType = .preferred)
        throws
    {
        let vocabulary = file.tensors["token_embd.weight"]?.shape.last ?? 32_000
        let hp = try ModelHyperparameters(gguf: file, vocabularySize: vocabulary)
        trainedContext = hp.contextLength
        context = max(16, min(contextLength, hp.contextLength))
        let keyValueWidth = hp.headCountKV * (hp.headDimension + hp.valueDimension)
        let stage = stage ?? .whole(hp.blockCount)
        cachePerToken = stage.layers.count * keyValueWidth * cacheType.bytes
        cache = cachePerToken * context
        let width = max(hp.embeddingLength, hp.headCount * hp.valueDimension)
        let decode =
            4
            * (hp.embeddingLength + 2 * width + hp.headCount * (hp.headDimension + hp.valueDimension)
                + 2 * hp.feedForwardLength + hp.headCount * context + hp.vocabularySize)
        let packedWidth =
            2 * hp.embeddingLength + hp.headCount * (hp.headDimension + hp.valueDimension) + keyValueWidth + 2
            * hp.feedForwardLength
        let batch = 512 / 4 * 16 * packedWidth
        scratch = decode + batch + (48 << 20)
        if stage.isWhole(hp.blockCount) {
            weights = file.fileSize
        } else {
            let tied = file.tensors["output.weight"] == nil
            weights = file.tensors.values.filter { stage.includes(tensor: $0.name, tiedOutput: tied) }.reduce(0) {
                $0 + $1.byteCount
            }
        }
    }

    public static func layerBytes(_ file: GGUFFile) -> (layers: [Int], embedding: Int, head: Int) {
        var layers: [Int: Int] = [:]
        var embedding = 0
        var head = 0
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

    public func with(context newContext: Int) -> ModelFootprint {
        ModelFootprint(
            weights: weights, cache: cachePerToken * newContext, scratch: scratch, context: newContext,
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
