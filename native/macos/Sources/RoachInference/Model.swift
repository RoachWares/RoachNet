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
    /// Llama 3.1-style frequency scaling declared in metadata (used when the file has no `rope_freqs.weight`).
    public let llama3Scaling: Llama3RopeScaling?
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
        // Sizes from the file are checked before anything divides or multiplies by
        // them: a GGUF with a zero head count or a 2^60 width must be refused, not
        // trap the runtime. The ranges sit well past every model RoachNet runs.
        func sized(_ key: String, _ value: Int?, _ range: ClosedRange<Int>) throws -> Int {
            guard let value else { throw InferenceError.missingKey("\(arch).\(key)") }
            guard range.contains(value) else { throw InferenceError.invalid("Implausible \(arch).\(key) (\(value)).") }
            return value
        }
        architecture = arch
        contextLength = try sized("context_length", int("context_length") ?? 2048, 1...(1 << 24))
        embeddingLength = try sized("embedding_length", int("embedding_length"), 1...(1 << 17))
        blockCount = try sized("block_count", int("block_count"), 1...1_024)
        feedForwardLength = try sized("feed_forward_length", int("feed_forward_length"), 1...(1 << 20))
        headCount = try sized("attention.head_count", int("attention.head_count"), 1...1_024)
        headCountKV = try sized("attention.head_count_kv", int("attention.head_count_kv") ?? headCount, 1...1_024)
        headDimension = try sized("attention.key_length", int("attention.key_length") ?? embeddingLength / headCount, 1...4_096)
        valueDimension = try sized("attention.value_length", int("attention.value_length") ?? headDimension, 1...4_096)
        rmsEpsilon = Float(double("attention.layer_norm_rms_epsilon") ?? 1e-5)
        ropeBase = Float(double("rope.freq_base") ?? 10_000)
        ropeDimensions = try sized("rope.dimension_count", int("rope.dimension_count") ?? headDimension, 0...4_096)
        let scalingType = gguf["\(arch).rope.scaling.type"]?.stringValue
        if scalingType == "linear", let factor = double("rope.scaling.factor"), factor > 0, factor.isFinite {
            ropeFrequencyScale = Float(1 / factor)
        } else {
            ropeFrequencyScale = 1
        }
        // Llama 3.1+ scales low frequencies by `factor` and leaves high ones alone,
        // blending between. Most GGUFs carry the result as `rope_freqs.weight`;
        // when one declares the scaling without that tensor, compute it.
        if scalingType == "llama3", let factor = double("rope.scaling.factor"), factor > 0, factor.isFinite {
            llama3Scaling = Llama3RopeScaling(
                factor: factor,
                lowFrequencyFactor: double("rope.scaling.low_freq_factor") ?? 1,
                highFrequencyFactor: double("rope.scaling.high_freq_factor") ?? 4,
                originalContext: double("rope.scaling.original_context_length") ?? 8_192
            )
        } else {
            llama3Scaling = nil
        }
        ropeStyle = (arch == "qwen2" || arch == "qwen3") ? .neox : .interleaved
        self.vocabularySize = try sized("vocab_size", int("vocab_size") ?? vocabularySize, 1...(1 << 22))
        hasQKNorm = arch == "qwen3"
        guard headCount % headCountKV == 0, ropeDimensions <= headDimension, ropeDimensions % 2 == 0 else {
            throw InferenceError.invalid("Inconsistent attention hyperparameters.")
        }
    }
}

/// Llama 3.1's RoPE frequency scaling: wavelengths longer than the original
/// context / `lowFrequencyFactor` are divided by `factor`, shorter than
/// original context / `highFrequencyFactor` are kept, and the band between is
/// blended. Matches Meta's reference and llama.cpp's `rope_freqs` factors.
public struct Llama3RopeScaling: Equatable {
    public var factor: Double
    public var lowFrequencyFactor: Double
    public var highFrequencyFactor: Double
    public var originalContext: Double

    /// The divisor for one inverse frequency (1 leaves it as is).
    public func divisor(forInverseFrequency frequency: Double) -> Double {
        let lowWavelength = originalContext / lowFrequencyFactor
        let highWavelength = originalContext / highFrequencyFactor
        let wavelength = 2 * Double.pi / frequency
        if wavelength < highWavelength { return 1 }
        if wavelength > lowWavelength { return factor }
        guard highFrequencyFactor != lowFrequencyFactor else { return 1 }
        let smooth = (originalContext / wavelength - lowFrequencyFactor) / (highFrequencyFactor - lowFrequencyFactor)
        // Scaled frequency is (1 - smooth) * f / factor + smooth * f.
        return 1 / ((1 - smooth) / factor + smooth)
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

/// The part of a model one machine runs: a contiguous range of layers, plus
/// the token embedding (the first stage) and the final norm and vocabulary
/// projection (the head). One stage holding everything is the whole model.
/// RoachNet Cluster splits a model into stages across Macs.
public struct ModelStage: Equatable, Sendable, CustomStringConvertible {
    public var layers: Range<Int>
    public var embedding: Bool
    public var head: Bool

    public init(layers: Range<Int>, embedding: Bool, head: Bool) {
        self.layers = layers
        self.embedding = embedding
        self.head = head
    }

    public static func whole(_ blockCount: Int) -> ModelStage { ModelStage(layers: 0..<blockCount, embedding: true, head: true) }

    public func isWhole(_ blockCount: Int) -> Bool { self == .whole(blockCount) }

    /// `"0-14,embedding,head"`, as stored in a shard file.
    public var description: String {
        ([ "\(layers.lowerBound)-\(layers.upperBound)" ] + (embedding ? ["embedding"] : []) + (head ? ["head"] : [])).joined(separator: ",")
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ",").map(String.init)
        let bounds = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
        self.init(layers: bounds[0]..<bounds[1], embedding: parts.contains("embedding"), head: parts.contains("head"))
    }

    /// Whether a tensor belongs to this stage.
    public func includes(tensor name: String, tiedOutput: Bool) -> Bool {
        if name.hasPrefix("blk.") {
            let index = name.dropFirst(4).prefix { $0.isNumber }
            return Int(index).map(layers.contains) ?? false
        }
        switch name {
        case "token_embd.weight": return embedding || (head && tiedOutput)
        case "output_norm.weight", "output.weight": return head
        default: return true
        }
    }
}

/// Weights for a decoder-only transformer, memory-mapped from a GGUF file.
public final class TransformerModel {
    public let file: GGUFFile
    public let hyperparameters: ModelHyperparameters
    public let tokenizer: Tokenizer
    public let stage: ModelStage
    let embeddingMatrix: QuantizedMatrix?
    let outputNorm: [Float]
    let projectionMatrix: QuantizedMatrix?
    let layers: [TransformerLayer]
    let ropeInverseFrequencies: [Float]

    /// The token embedding; only stages with `embedding` (or a tied head) have one.
    var tokenEmbedding: QuantizedMatrix { embeddingMatrix! }
    /// The vocabulary projection; only stages with `head` have one.
    var outputProjection: QuantizedMatrix { projectionMatrix! }
    /// Rows of the vocabulary: logits per token.
    public var vocabularyRows: Int { projectionMatrix?.rows ?? embeddingMatrix?.rows ?? hyperparameters.vocabularySize }

    public convenience init(path: String, stage: ModelStage? = nil) throws {
        try self.init(file: GGUFFile(path: path), stage: stage)
    }

    public init(file: GGUFFile, stage requested: ModelStage? = nil) throws {
        self.file = file
        let tokenizer = try Tokenizer(gguf: file)
        self.tokenizer = tokenizer
        let hp = try ModelHyperparameters(gguf: file, vocabularySize: tokenizer.vocabularySize)
        self.hyperparameters = hp
        let stage = requested ?? file["roachnet.stage"]?.stringValue.flatMap(ModelStage.init) ?? .whole(hp.blockCount)
        guard stage.layers.lowerBound >= 0, stage.layers.upperBound <= hp.blockCount else {
            throw InferenceError.invalid("Stage \(stage) is outside the model's \(hp.blockCount) layers.")
        }
        self.stage = stage
        // A whole model pages in ahead of use; a stage touches only its own tensors.
        if stage.isWhole(hp.blockCount) { file.adviseWillNeed() }

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

        let tied = file.tensors["output.weight"] == nil
        let embedding = stage.embedding || (stage.head && tied) ? try matrix("token_embd.weight") : nil
        embeddingMatrix = embedding
        outputNorm = stage.head ? try vector("output_norm.weight") : []
        projectionMatrix = stage.head ? (tied ? embedding : try matrix("output.weight")) : nil
        if let embedding, embedding.columns != hp.embeddingLength {
            throw InferenceError.invalid("token_embd width \(embedding.columns) does not match embedding length \(hp.embeddingLength).")
        }

        var layers: [TransformerLayer] = []
        for index in stage.layers {
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
            if let scaling = hp.llama3Scaling { return Float(Double(base) / scaling.divisor(forInverseFrequency: Double(base))) }
            return base
        }
    }

    public var displayName: String { file.modelName ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent }
}
