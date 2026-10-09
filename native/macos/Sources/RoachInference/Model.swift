import Foundation

public enum RopeStyle: String {
    /// Rotates adjacent pairs (x[2i], x[2i+1]); llama-family GGUFs.
    case interleaved
    /// Rotates halves (x[i], x[i + d/2]); qwen-family GGUFs.
    case neox
}

/// Transformer hyperparameters read from GGUF metadata.
public struct ModelHyperparameters: Equatable {
    public let architecture: String
    public let contextLength: Int
    public let embeddingLength: Int
    public let blockCount: Int
    public let feedForwardLength: Int
    public let headCount: Int
    public let headCountKV: Int
    public let headDimension: Int
    public let valueDimension: Int
    public let rmsEpsilon: Float
    public let ropeBase: Float
    public let ropeDimensions: Int
    public let ropeFrequencyScale: Float
    public let ropeStyle: RopeStyle
    public let vocabularySize: Int
    public let hasQKNorm: Bool

    public static let supportedArchitectures: Set<String> = ["llama", "mistral", "qwen2", "qwen3"]

    init(gguf: GGUFFile, vocabularySize: Int) throws {
        let arch = gguf.architecture
        guard ModelHyperparameters.supportedArchitectures.contains(arch) else {
            throw InferenceError.unsupportedArchitecture(arch)
        }
        func int(_ key: String) -> Int? { gguf["\(arch).\(key)"]?.intValue }
        func double(_ key: String) -> Double? { gguf["\(arch).\(key)"]?.doubleValue }
        func required(_ key: String) throws -> Int {
            guard let value = int(key) else { throw InferenceError.missingKey("\(arch).\(key)") }
            return value
        }
        architecture = arch
        contextLength = int("context_length") ?? 2048
        embeddingLength = try required("embedding_length")
        blockCount = try required("block_count")
        feedForwardLength = try required("feed_forward_length")
        headCount = try required("attention.head_count")
        headCountKV = int("attention.head_count_kv") ?? headCount
        headDimension = int("attention.key_length") ?? embeddingLength / headCount
        valueDimension = int("attention.value_length") ?? headDimension
        rmsEpsilon = Float(double("attention.layer_norm_rms_epsilon") ?? 1e-5)
        ropeBase = Float(double("rope.freq_base") ?? 10_000)
        ropeDimensions = int("rope.dimension_count") ?? headDimension
        if let type = gguf["\(arch).rope.scaling.type"]?.stringValue, type == "linear", let factor = double("rope.scaling.factor"), factor > 0 {
            ropeFrequencyScale = Float(1 / factor)
        } else {
            ropeFrequencyScale = 1
        }
        ropeStyle = (arch == "qwen2" || arch == "qwen3") ? .neox : .interleaved
        self.vocabularySize = int("vocab_size") ?? vocabularySize
        hasQKNorm = arch == "qwen3"
        guard headCount % headCountKV == 0, ropeDimensions <= headDimension, ropeDimensions % 2 == 0 else {
            throw InferenceError.invalid("Inconsistent attention hyperparameters.")
        }
    }
}

/// A row-major weight matrix stored in its quantized GGUF form.
public struct QuantizedMatrix {
    public let type: GGMLType
    /// Output features (number of rows).
    public let rows: Int
    /// Input features (elements per row).
    public let columns: Int
    public let rowBytes: Int
    let data: UnsafeRawPointer

    init(_ info: GGUFTensorInfo, file: GGUFFile) {
        type = info.type
        columns = info.rowLength
        rows = info.rowCount
        rowBytes = info.rowBytes
        data = file.pointer(to: info)
    }

    @inline(__always)
    func row(_ index: Int) -> UnsafeRawPointer { data + index * rowBytes }

    func dequantizeRow(_ index: Int, into output: UnsafeMutablePointer<Float>) {
        Quantization.dequantize(type, row(index), count: columns, into: output)
    }

    /// y = W·x, parallelised over output rows.
    func multiply(_ x: UnsafePointer<Float>, into y: UnsafeMutablePointer<Float>) {
        let rows = self.rows, columns = self.columns, type = self.type
        let workers = ParallelFor.workerCount(for: rows * columns)
        let output = UnsafeSendablePointer(y)
        let input = UnsafeSendableConstPointer(x)
        ParallelFor.run(rows, workers: workers) { start, end in
            for r in start..<end {
                output.pointer[r] = Quantization.dot(type, self.row(r), input.pointer, count: columns)
            }
        }
    }
}

struct UnsafeSendablePointer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    init(_ pointer: UnsafeMutablePointer<Float>) { self.pointer = pointer }
}

struct UnsafeSendableConstPointer: @unchecked Sendable {
    let pointer: UnsafePointer<Float>
    init(_ pointer: UnsafePointer<Float>) { self.pointer = pointer }
}

enum ParallelFor {
    static let processorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    static func workerCount(for work: Int) -> Int {
        // Below ~64k multiply-adds threading costs more than it saves.
        work < 65_536 ? 1 : min(processorCount, max(1, work / 65_536))
    }

    static func run(_ count: Int, workers: Int, _ body: @escaping (Int, Int) -> Void) {
        guard count > 0 else { return }
        let workers = max(1, min(workers, count))
        if workers == 1 {
            body(0, count)
            return
        }
        let chunk = (count + workers - 1) / workers
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let start = worker * chunk
            let end = min(count, start + chunk)
            if start < end { body(start, end) }
        }
    }
}

struct TransformerLayer {
    let attentionNorm: [Float]
    let query: QuantizedMatrix
    let key: QuantizedMatrix
    let value: QuantizedMatrix
    let output: QuantizedMatrix
    let queryBias: [Float]?
    let keyBias: [Float]?
    let valueBias: [Float]?
    let queryNorm: [Float]?
    let keyNorm: [Float]?
    let feedForwardNorm: [Float]
    let gate: QuantizedMatrix
    let up: QuantizedMatrix
    let down: QuantizedMatrix
}

/// Weights for a decoder-only transformer, memory-mapped from a GGUF file.
public final class TransformerModel {
    public let file: GGUFFile
    public let hyperparameters: ModelHyperparameters
    public let tokenizer: Tokenizer
    let tokenEmbedding: QuantizedMatrix
    let outputNorm: [Float]
    let outputProjection: QuantizedMatrix
    let layers: [TransformerLayer]
    let ropeInverseFrequencies: [Float]

    public convenience init(path: String) throws {
        try self.init(file: GGUFFile(path: path))
    }

    public init(file: GGUFFile) throws {
        self.file = file
        file.adviseWillNeed()
        let tokenizer = try Tokenizer(gguf: file)
        self.tokenizer = tokenizer
        let hp = try ModelHyperparameters(gguf: file, vocabularySize: tokenizer.vocabularySize)
        self.hyperparameters = hp

        func matrix(_ name: String) throws -> QuantizedMatrix {
            QuantizedMatrix(try file.tensor(name), file: file)
        }
        func vector(_ name: String) throws -> [Float] {
            let info = try file.tensor(name)
            var values = [Float](repeating: 0, count: info.elementCount)
            values.withUnsafeMutableBufferPointer {
                Quantization.dequantize(info.type, file.pointer(to: info), count: info.elementCount, into: $0.baseAddress!)
            }
            return values
        }
        func optionalVector(_ name: String) throws -> [Float]? {
            file.tensors[name] == nil ? nil : try vector(name)
        }

        tokenEmbedding = try matrix("token_embd.weight")
        outputNorm = try vector("output_norm.weight")
        outputProjection = file.tensors["output.weight"] != nil ? try matrix("output.weight") : tokenEmbedding
        guard tokenEmbedding.columns == hp.embeddingLength else {
            throw InferenceError.invalid("token_embd width \(tokenEmbedding.columns) does not match embedding length \(hp.embeddingLength).")
        }

        var layers: [TransformerLayer] = []
        for index in 0..<hp.blockCount {
            let p = "blk.\(index)."
            let layer = TransformerLayer(
                attentionNorm: try vector(p + "attn_norm.weight"),
                query: try matrix(p + "attn_q.weight"),
                key: try matrix(p + "attn_k.weight"),
                value: try matrix(p + "attn_v.weight"),
                output: try matrix(p + "attn_output.weight"),
                queryBias: try optionalVector(p + "attn_q.bias"),
                keyBias: try optionalVector(p + "attn_k.bias"),
                valueBias: try optionalVector(p + "attn_v.bias"),
                queryNorm: try optionalVector(p + "attn_q_norm.weight"),
                keyNorm: try optionalVector(p + "attn_k_norm.weight"),
                feedForwardNorm: try vector(p + "ffn_norm.weight"),
                gate: try matrix(p + "ffn_gate.weight"),
                up: try matrix(p + "ffn_up.weight"),
                down: try matrix(p + "ffn_down.weight")
            )
            guard layer.query.rows == hp.headCount * hp.headDimension,
                  layer.key.rows == hp.headCountKV * hp.headDimension,
                  layer.value.rows == hp.headCountKV * hp.valueDimension,
                  layer.gate.rows == hp.feedForwardLength else {
                throw InferenceError.invalid("Layer \(index) tensor shapes do not match the model hyperparameters.")
            }
            layers.append(layer)
        }
        self.layers = layers

        // RoPE inverse frequencies, with optional per-dimension factors (llama 3.1+).
        let half = hp.ropeDimensions / 2
        let factors = try optionalVector("rope_freqs.weight")
        ropeInverseFrequencies = (0..<half).map { i in
            let base = powf(hp.ropeBase, -2 * Float(i) / Float(hp.ropeDimensions)) * hp.ropeFrequencyScale
            if let factors, i < factors.count { return base / factors[i] }
            return base
        }
    }

    public var displayName: String { file.modelName ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent }
}
