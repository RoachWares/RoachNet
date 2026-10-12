#if canImport(Metal)
import Foundation
import Metal

/// GPU backend for Apple Silicon built only on our own Metal kernels
/// (`MetalKernelSource`). Weights stay quantized and are read in place from the
/// memory-mapped GGUF file; activations and the KV cache live in shared buffers.
public final class MetalBackend: TransformerBackend, StageBatchForwarding, StageBackend, CacheCopying {
    public let model: TransformerModel
    public let contextLength: Int
    public var name: String { "metal (\(device.name))" }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipelines: [String: MTLComputePipelineState]
    let weights: MTLBuffer
    let weightsBase: UnsafeRawPointer

    struct LayerBuffers {
        let attentionNorm: MTLBuffer
        let feedForwardNorm: MTLBuffer
        let queryBias: MTLBuffer?
        let keyBias: MTLBuffer?
        let valueBias: MTLBuffer?
        let queryNorm: MTLBuffer?
        let keyNorm: MTLBuffer?
    }
    let layerBuffers: [LayerBuffers]
    let outputNorm: MTLBuffer
    let inverseFrequencies: MTLBuffer

    let x: MTLBuffer, normed: MTLBuffer, projected: MTLBuffer, query: MTLBuffer
    let attention: MTLBuffer, hidden: MTLBuffer, hiddenUp: MTLBuffer, scores: MTLBuffer, logitsBuffer: MTLBuffer
    let keyCache: MTLBuffer, valueCache: MTLBuffer
    /// One token's key and value in FP32, before a half cache stores them.
    let keyStage: MTLBuffer, valueStage: MTLBuffer
    /// How keys and values are stored.
    public let cacheType: KVCacheType
    var cacheBytes: Int { cacheType.bytes }
    /// Names the half-cache variant of a cache kernel.
    var cacheSuffix: String { cacheType == .f16 ? "_h" : "" }
    /// Partial softmax results of decode attention split across keys.
    let attentionParts: MTLBuffer
    static let attentionChunk = 128
    /// `ROACHNET_METAL_ATTENTION=fused` uses one threadgroup per head instead (A/B checks).
    var splitAttention = ProcessInfo.processInfo.environment["ROACHNET_METAL_ATTENTION"] != "fused"
    let kvKeyWidth: Int, kvValueWidth: Int
    /// Rows each simdgroup computes in a matvec (1, 2 or 4; `ROACHNET_METAL_ROWS` overrides).
    let rowsPerSimdgroup: Int = {
        let value = Int(ProcessInfo.processInfo.environment["ROACHNET_METAL_ROWS"] ?? "") ?? 4
        return [1, 2, 4].contains(value) ? value : 4
    }()
    /// `ROACHNET_METAL_FULL_ROWS=1` keeps 32 lanes per row even on short rows (A/B checks).
    let fullSimdgroupRows = ProcessInfo.processInfo.environment["ROACHNET_METAL_FULL_ROWS"] == "1"
    /// `ROACHNET_METAL_SERIAL=1` encodes one dispatch after another (for A/B checks).
    let serialDispatch = ProcessInfo.processInfo.environment["ROACHNET_METAL_SERIAL"] == "1"
    /// GPU time of the most recent forward pass, for profiling.
    public private(set) var lastGPUSeconds: Double = 0
    /// Prompt tokens per batched pass; 0 runs prompts a token at a time.
    public private(set) var maxBatch = 0
    /// Prefill matrices use the simdgroup matrix units (Apple7 GPUs and later);
    /// `ROACHNET_METAL_MATMUL=simple` uses the plain four-token kernels (A/B checks).
    lazy var matmulKernel: (prefix: String, rows: Int) = {
        let choice = ProcessInfo.processInfo.environment["ROACHNET_METAL_MATMUL"] ?? ""
        guard device.supportsFamily(.apple7), choice != "simple" else { return ("matmul_", 32) }
        return ("matmul_sg_", 64)
    }()
    private var batchStorage: BatchBuffers?

    private static var cachedLibrary: [ObjectIdentifier: MTLLibrary] = [:]
    private static let libraryLock = NSLock()

    /// Builds the backend and checks one forward pass against the CPU
    /// reference; returns nil (CPU fallback) on any failure or mismatch.
    public static func makeVerified(model: TransformerModel, contextLength: Int) -> MetalBackend? {
        guard ProcessInfo.processInfo.environment["ROACHNET_INFERENCE_BACKEND"] != "cpu" else { return nil }
        do {
            let backend = try MetalBackend(model: model, contextLength: contextLength)
            if ProcessInfo.processInfo.environment["ROACHNET_METAL_VERIFY"] == "0" { return backend }
            let reference = CPUBackend(model: model, contextLength: 16)
            let a: UnsafeBufferPointer<Float>, b: UnsafeBufferPointer<Float>
            if model.stage.embedding && model.stage.head {
                let token = Int(model.tokenizer.bos ?? 0)
                reference.forward(token: token, position: 0)
                backend.forward(token: token, position: 0)
                a = reference.logits
                b = backend.logits
            } else {
                let probe = MetalBackend.probeResiduals(model, count: 1)
                defer { probe.deallocate() }
                reference.forward(residual: probe, position: 0, output: .none)
                backend.forward(residual: probe, position: 0, output: .none)
                a = reference.residualState
                b = backend.residualState
            }
            var worst: Float = 0, magnitude: Float = 1e-6
            for i in 0..<a.count {
                worst = max(worst, abs(a[i] - b[i]))
                magnitude = max(magnitude, abs(a[i]))
            }
            guard worst <= 1e-2 * magnitude + 1e-3 else {
                FileHandle.standardError.write(Data("RoachInference: Metal parity check failed (max |Δ| \(worst)); using CPU.\n".utf8))
                return nil
            }
            backend.verifyBatching()
            return backend
        } catch {
            FileHandle.standardError.write(Data("RoachInference: Metal unavailable (\(error)); using CPU.\n".utf8))
            return nil
        }
    }

    public init(model: TransformerModel, contextLength: Int, cacheType: KVCacheType = .preferred) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw InferenceError.invalid("No Metal device.")
        }
        self.model = model
        self.contextLength = contextLength
        self.cacheType = cacheType
        self.device = device
        self.queue = queue
        let hp = model.hyperparameters

        // Kernels whose rows are not whole 32-element chunks stay on the CPU path.
        for layer in model.layers {
            for matrix in [layer.query, layer.key, layer.value, layer.output, layer.gate, layer.up, layer.down] where matrix.columns % 32 != 0 {
                throw InferenceError.invalid("Matrix width \(matrix.columns) is not supported by the Metal kernels.")
            }
        }
        guard !model.stage.head || model.outputProjection.columns % 32 == 0 else {
            throw InferenceError.invalid("Output width \(model.outputProjection.columns) is not supported by the Metal kernels.")
        }

        let library: MTLLibrary = try {
            MetalBackend.libraryLock.lock()
            defer { MetalBackend.libraryLock.unlock() }
            if let cached = MetalBackend.cachedLibrary[ObjectIdentifier(device)] { return cached }
            let options = MTLCompileOptions()
            if #available(macOS 15.0, iOS 18.0, *) {
                options.mathMode = .safe
            } else {
                options.fastMathEnabled = false
            }
            let library = try device.makeLibrary(source: MetalKernelSource.source, options: options)
            MetalBackend.cachedLibrary[ObjectIdentifier(device)] = library
            return library
        }()
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in library.functionNames {
            guard let function = library.makeFunction(name: name) else { continue }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines

        // Wrap the whole mapped file without copying.
        let file = model.file
        let page = Int(getpagesize())
        let length = (file.fileSize + page - 1) / page * page
        guard length <= device.maxBufferLength,
              let weights = device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(mutating: file.base), length: length,
                                              options: .storageModeShared, deallocator: nil) else {
            throw InferenceError.invalid("Model is larger than one Metal buffer on this device.")
        }
        self.weights = weights
        self.weightsBase = file.base

        func floats(_ values: [Float]) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(bytes: values, length: max(4, values.count * 4), options: .storageModeShared) else {
                throw InferenceError.invalid("Metal allocation failed.")
            }
            return buffer
        }
        layerBuffers = try model.layers.map { layer in
            LayerBuffers(
                attentionNorm: try floats(layer.attentionNorm),
                feedForwardNorm: try floats(layer.feedForwardNorm),
                queryBias: try layer.queryBias.map(floats),
                keyBias: try layer.keyBias.map(floats),
                valueBias: try layer.valueBias.map(floats),
                queryNorm: try layer.queryNorm.map(floats),
                keyNorm: try layer.keyNorm.map(floats)
            )
        }
        outputNorm = try floats(model.outputNorm)
        inverseFrequencies = try floats(model.ropeInverseFrequencies)
        kvKeyWidth = hp.headCountKV * hp.headDimension
        kvValueWidth = hp.headCountKV * hp.valueDimension
        let s = try Scratch(device: device, model: model, contextLength: contextLength, cacheBytes: cacheType.bytes)
        x = s.x; normed = s.normed; projected = s.projected; query = s.query; attention = s.attention
        hidden = s.hidden; hiddenUp = s.hiddenUp; scores = s.scores; logitsBuffer = s.logits
        keyCache = s.keyCache; valueCache = s.valueCache; attentionParts = s.attentionParts
        keyStage = s.keyStage; valueStage = s.valueStage
        maxBatch = min(MetalBackend.batchSize(for: model), contextLength / 4 * 4)
    }

    /// One slot's working memory: activations, the KV cache and attention partials.
    private struct Scratch {
        let x, normed, projected, query, attention, hidden, hiddenUp, scores, logits, keyCache, valueCache, attentionParts: MTLBuffer
        let keyStage, valueStage: MTLBuffer

        init(device: MTLDevice, model: TransformerModel, contextLength: Int, cacheBytes: Int) throws {
            func scratch(_ count: Int, bytes: Int = 4) throws -> MTLBuffer {
                guard let buffer = device.makeBuffer(length: max(4, count * bytes), options: .storageModeShared) else {
                    throw InferenceError.invalid("Metal allocation failed.")
                }
                memset(buffer.contents(), 0, buffer.length)
                return buffer
            }
            let hp = model.hyperparameters
            let width = max(hp.embeddingLength, hp.headCount * hp.valueDimension)
            x = try scratch(hp.embeddingLength)
            normed = try scratch(width)
            projected = try scratch(width)
            query = try scratch(hp.headCount * hp.headDimension)
            attention = try scratch(hp.headCount * hp.valueDimension)
            hidden = try scratch(hp.feedForwardLength)
            hiddenUp = try scratch(hp.feedForwardLength)
            scores = try scratch(hp.headCount * contextLength)
            logits = try scratch(model.vocabularyRows)
            keyCache = try scratch(model.layers.count * contextLength * hp.headCountKV * hp.headDimension, bytes: cacheBytes)
            valueCache = try scratch(model.layers.count * contextLength * hp.headCountKV * hp.valueDimension, bytes: cacheBytes)
            keyStage = try scratch(hp.headCountKV * hp.headDimension)
            valueStage = try scratch(hp.headCountKV * hp.valueDimension)
            attentionParts = try scratch(hp.headCount * ((contextLength + MetalBackend.attentionChunk - 1) / MetalBackend.attentionChunk) * (2 + hp.valueDimension))
        }
    }

    /// Another backend over the same weights and kernels with its own KV cache
    /// and working memory, for a parallel request slot. Nothing is compiled or
    /// checked again: it runs exactly the kernels this backend verified.
    public func sibling() throws -> MetalBackend {
        try MetalBackend(sharing: self)
    }

    private init(sharing other: MetalBackend) throws {
        guard let queue = other.device.makeCommandQueue() else { throw InferenceError.invalid("No Metal command queue.") }
        model = other.model
        contextLength = other.contextLength
        cacheType = other.cacheType
        device = other.device
        self.queue = queue
        pipelines = other.pipelines
        weights = other.weights
        weightsBase = other.weightsBase
        layerBuffers = other.layerBuffers
        outputNorm = other.outputNorm
        inverseFrequencies = other.inverseFrequencies
        kvKeyWidth = other.kvKeyWidth
        kvValueWidth = other.kvValueWidth
        let s = try Scratch(device: other.device, model: other.model, contextLength: other.contextLength, cacheBytes: other.cacheType.bytes)
        x = s.x; normed = s.normed; projected = s.projected; query = s.query; attention = s.attention
        hidden = s.hidden; hiddenUp = s.hiddenUp; scores = s.scores; logitsBuffer = s.logits
        keyCache = s.keyCache; valueCache = s.valueCache; attentionParts = s.attentionParts
        keyStage = s.keyStage; valueStage = s.valueStage
        splitAttention = other.splitAttention
        maxBatch = other.maxBatch
    }

    /// Copies another slot's keys and values for positions `0..<count` (a
    /// shared prompt prefix). Both caches are shared memory and neither slot
    /// has GPU work in flight, so a plain copy is enough.
    public func copyCache(from other: TransformerBackend, count: Int) -> Bool {
        guard let other = other as? MetalBackend, other !== self, other.model === model, other.cacheType == cacheType,
              other.contextLength == contextLength, count <= contextLength else { return false }
        for index in 0..<model.layers.count {
            let keyLayer = index * contextLength * kvKeyWidth * cacheBytes
            let valueLayer = index * contextLength * kvValueWidth * cacheBytes
            memcpy(keyCache.contents() + keyLayer, other.keyCache.contents() + keyLayer, count * kvKeyWidth * cacheBytes)
            memcpy(valueCache.contents() + valueLayer, other.valueCache.contents() + valueLayer, count * kvValueWidth * cacheBytes)
        }
        return true
    }

    public var logits: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: logitsBuffer.contents().assumingMemoryBound(to: Float.self), count: model.vocabularyRows)
    }

    public var hiddenState: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: normed.contents().assumingMemoryBound(to: Float.self), count: model.hyperparameters.embeddingLength)
    }

    // MARK: Encoding helpers

    private func pipeline(_ name: String) -> MTLComputePipelineState {
        guard let pipeline = pipelines[name] else { fatalError("Missing Metal kernel \(name)") }
        return pipeline
    }

    private static func matvecKernel(_ type: GGMLType) -> String {
        switch type {
        case .f32: return "matvec_f32"
        case .f16: return "matvec_f16"
        case .bf16: return "matvec_bf16"
        case .q4_0: return "matvec_q4_0"
        case .q4_1: return "matvec_q4_1"
        case .q5_0: return "matvec_q5_0"
        case .q5_1: return "matvec_q5_1"
        case .q8_0: return "matvec_q8_0"
        case .q2_K: return "matvec_q2_K"
        case .q3_K: return "matvec_q3_K"
        case .q4_K: return "matvec_q4_K"
        case .q5_K: return "matvec_q5_K"
        case .q6_K: return "matvec_q6_K"
        case .q8_K: return "matvec_q8_K"
        }
    }

    private func matvec(_ encoder: MTLComputeCommandEncoder, _ matrix: QuantizedMatrix, _ input: MTLBuffer, _ output: MTLBuffer,
                        outputOffset: Int = 0, bias: MTLBuffer? = nil, accumulate: Bool = false) {
        struct Args { var cols: UInt32; var rowBytes: UInt32; var rows: UInt32; var flags: UInt32 }
        var args = Args(cols: UInt32(matrix.columns), rowBytes: UInt32(matrix.rowBytes), rows: UInt32(matrix.rows),
                        flags: (accumulate ? 1 : 0) | (bias != nil ? 2 : 0))
        let rows = matrix.type == .q2_K || matrix.type == .q3_K ? 1 : rowsPerSimdgroup
        // Vectorized kernels split a simdgroup in two for short rows.
        let halves = rows > 1 && [.q4_0, .q8_0, .q4_K, .q6_K].contains(matrix.type) && matrix.columns < 2048 && !fullSimdgroupRows
        let kernel = MetalBackend.matvecKernel(matrix.type) + (rows > 1 ? (halves ? "_h\(rows)" : "_r\(rows)") : "")
        encoder.setComputePipelineState(pipeline(kernel))
        encoder.setBuffer(weights, offset: matrix.data - weightsBase, index: 0)
        encoder.setBuffer(input, offset: 0, index: 1)
        encoder.setBuffer(output, offset: outputOffset, index: 2)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 3)
        encoder.setBuffer(bias ?? output, offset: 0, index: 4)
        let perGroup = 4 * rows * (halves ? 2 : 1)
        encoder.dispatchThreadgroups(MTLSize(width: (matrix.rows + perGroup - 1) / perGroup, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
    }

    private func rmsNorm(_ encoder: MTLComputeCommandEncoder, _ input: MTLBuffer, inputOffset: Int = 0, _ weight: MTLBuffer,
                         _ output: MTLBuffer, outputOffset: Int = 0, count: Int, rows: Int = 1) {
        struct Args { var n: UInt32; var eps: Float }
        var args = Args(n: UInt32(count), eps: model.hyperparameters.rmsEpsilon)
        encoder.setComputePipelineState(pipeline("rms_norm"))
        encoder.setBuffer(input, offset: inputOffset, index: 0)
        encoder.setBuffer(weight, offset: 0, index: 1)
        encoder.setBuffer(output, offset: outputOffset, index: 2)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 3)
        let threads = min(pipeline("rms_norm").maxTotalThreadsPerThreadgroup, 1024, max(32, (count + 31) / 32 * 32))
        encoder.dispatchThreadgroups(MTLSize(width: rows, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
    }

    private func elementwise(_ encoder: MTLComputeCommandEncoder, _ kernel: String, _ target: MTLBuffer, targetOffset: Int = 0, _ other: MTLBuffer, count: Int) {
        encoder.setComputePipelineState(pipeline(kernel))
        encoder.setBuffer(target, offset: targetOffset, index: 0)
        encoder.setBuffer(other, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, count), height: 1, depth: 1))
    }

    private func rope(_ encoder: MTLComputeCommandEncoder, _ buffer: MTLBuffer, offset: Int, heads: Int, position: Int) {
        struct Args { var headDim: UInt32; var pairs: UInt32; var position: UInt32; var neox: UInt32 }
        let hp = model.hyperparameters
        var args = Args(headDim: UInt32(hp.headDimension), pairs: UInt32(model.ropeInverseFrequencies.count),
                        position: UInt32(position), neox: hp.ropeStyle == .neox ? 1 : 0)
        encoder.setComputePipelineState(pipeline("rope"))
        encoder.setBuffer(buffer, offset: offset, index: 0)
        encoder.setBuffer(inverseFrequencies, offset: 0, index: 1)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 2)
        let pairs = model.ropeInverseFrequencies.count
        encoder.dispatchThreads(MTLSize(width: pairs, height: heads, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(pairs, 64), height: 1, depth: 1))
    }

    // MARK: Forward

    public var residualState: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: x.contents().assumingMemoryBound(to: Float.self), count: model.hyperparameters.embeddingLength)
    }

    /// A fixed, model-independent residual stream for checking a stage.
    static func probeResiduals(_ model: TransformerModel, count: Int) -> UnsafePointer<Float> {
        let dim = model.hyperparameters.embeddingLength
        let values = UnsafeMutablePointer<Float>.allocate(capacity: dim * count)
        for i in 0..<(dim * count) { values[i] = sinf(Float(i) * 0.37) * 0.05 }
        return UnsafePointer(values)
    }

    public func forward(residual: UnsafePointer<Float>, position: Int, output: ForwardOutput) {
        x.contents().assumingMemoryBound(to: Float.self).update(from: residual, count: model.hyperparameters.embeddingLength)
        encodeForward(position: position, output: output)
    }

    public func applyHead(residual: UnsafePointer<Float>, output: ForwardOutput) {
        guard model.stage.head, output != .none else { return }
        let dim = model.hyperparameters.embeddingLength
        x.contents().assumingMemoryBound(to: Float.self).update(from: residual, count: dim)
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        rmsNorm(encoder, x, outputNorm, normed, count: dim)
        if output == .logits {
            encoder.memoryBarrier(scope: .buffers)
            matvec(encoder, model.outputProjection, normed, logitsBuffer)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    public func forward(token: Int, position: Int, output: ForwardOutput) {
        if model.stage.embedding { model.tokenEmbedding.dequantizeRow(token, into: x.contents().assumingMemoryBound(to: Float.self)) }
        encodeForward(position: position, output: output)
    }

    private func encodeForward(position: Int, output: ForwardOutput) {
        let hp = model.hyperparameters
        let dim = hp.embeddingLength
        let heads = hp.headCount

        // Concurrent dispatch with explicit barriers: independent kernels (q/k/v,
        // gate/up, the two RoPEs) overlap instead of draining the GPU between them.
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: serialDispatch ? .serial : .concurrent) else { return }
        let serial = serialDispatch
        func barrier() { if !serial { encoder.memoryBarrier(scope: .buffers) } }
        struct AttnArgs {
            var headDim: UInt32; var valueDim: UInt32; var keyWidth: UInt32; var valueWidth: UInt32
            var group: UInt32; var context: UInt32; var span: UInt32; var scale: Float
        }
        var attn = AttnArgs(headDim: UInt32(hp.headDimension), valueDim: UInt32(hp.valueDimension),
                            keyWidth: UInt32(kvKeyWidth), valueWidth: UInt32(kvValueWidth),
                            group: UInt32(heads / hp.headCountKV), context: UInt32(contextLength),
                            span: UInt32(position + 1), scale: 1 / sqrtf(Float(hp.headDimension)))
        struct SplitArgs {
            var headDim: UInt32; var valueDim: UInt32; var keyWidth: UInt32; var valueWidth: UInt32
            var group: UInt32; var heads: UInt32; var span: UInt32; var chunk: UInt32; var scale: Float
        }
        var split = SplitArgs(headDim: UInt32(hp.headDimension), valueDim: UInt32(hp.valueDimension),
                              keyWidth: UInt32(kvKeyWidth), valueWidth: UInt32(kvValueWidth), group: UInt32(heads / hp.headCountKV),
                              heads: UInt32(heads), span: UInt32(position + 1), chunk: UInt32(MetalBackend.attentionChunk),
                              scale: 1 / sqrtf(Float(hp.headDimension)))

        let half = cacheType == .f16
        let suffix = cacheSuffix
        var storeWidths = SIMD2<UInt32>(UInt32(kvKeyWidth), UInt32(kvValueWidth))

        for (index, layer) in model.layers.enumerated() {
            let buffers = layerBuffers[index]
            let keyLayer = index * contextLength * kvKeyWidth * cacheBytes
            let valueLayer = index * contextLength * kvValueWidth * cacheBytes
            let keyRow = keyLayer + position * kvKeyWidth * cacheBytes
            let valueRow = valueLayer + position * kvValueWidth * cacheBytes
            // An FP32 cache takes the new key and value in place; a half cache
            // gets them from the staging rows once they are normalized and rotated.
            let (keyTarget, keyOffset) = half ? (keyStage, 0) : (keyCache, keyRow)
            let (valueTarget, valueOffset) = half ? (valueStage, 0) : (valueCache, valueRow)

            rmsNorm(encoder, x, buffers.attentionNorm, normed, count: dim)
            barrier()
            matvec(encoder, layer.query, normed, query, bias: buffers.queryBias)
            matvec(encoder, layer.key, normed, keyTarget, outputOffset: keyOffset, bias: buffers.keyBias)
            matvec(encoder, layer.value, normed, valueTarget, outputOffset: valueOffset, bias: buffers.valueBias)
            barrier()
            if let norm = buffers.queryNorm {
                rmsNorm(encoder, query, norm, query, count: hp.headDimension, rows: heads)
            }
            if let norm = buffers.keyNorm {
                rmsNorm(encoder, keyTarget, inputOffset: keyOffset, norm, keyTarget, outputOffset: keyOffset, count: hp.headDimension, rows: hp.headCountKV)
            }
            if buffers.queryNorm != nil || buffers.keyNorm != nil { barrier() }
            rope(encoder, query, offset: 0, heads: heads, position: position)
            rope(encoder, keyTarget, offset: keyOffset, heads: hp.headCountKV, position: position)
            barrier()
            if half {
                encoder.setComputePipelineState(pipeline("kv_store_h"))
                encoder.setBuffer(keyStage, offset: 0, index: 0)
                encoder.setBuffer(valueStage, offset: 0, index: 1)
                encoder.setBuffer(keyCache, offset: keyRow, index: 2)
                encoder.setBuffer(valueCache, offset: valueRow, index: 3)
                encoder.setBytes(&storeWidths, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
                let width = max(kvKeyWidth, kvValueWidth)
                encoder.dispatchThreads(MTLSize(width: width, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, width), height: 1, depth: 1))
                barrier()
            }

            // Short contexts are one chunk: the single fused kernel is quicker there.
            if splitAttention && position >= MetalBackend.attentionChunk {
                let group = heads / hp.headCountKV
                encoder.setComputePipelineState(pipeline("attn_split" + suffix))
                encoder.setBuffer(query, offset: 0, index: 0)
                encoder.setBuffer(keyCache, offset: keyLayer, index: 1)
                encoder.setBuffer(valueCache, offset: valueLayer, index: 2)
                encoder.setBuffer(attentionParts, offset: 0, index: 3)
                encoder.setBytes(&split, length: MemoryLayout<SplitArgs>.stride, index: 4)
                encoder.dispatchThreadgroups(MTLSize(width: hp.headCountKV, height: (group + 3) / 4, depth: (position + MetalBackend.attentionChunk) / MetalBackend.attentionChunk),
                                             threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
                barrier()
                encoder.setComputePipelineState(pipeline("attn_merge"))
                encoder.setBuffer(attentionParts, offset: 0, index: 0)
                encoder.setBuffer(attention, offset: 0, index: 1)
                encoder.setBytes(&split, length: MemoryLayout<SplitArgs>.stride, index: 2)
                encoder.dispatchThreadgroups(MTLSize(width: heads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            } else {
                encoder.setComputePipelineState(pipeline("attn_fused" + suffix))
                encoder.setBuffer(query, offset: 0, index: 0)
                encoder.setBuffer(keyCache, offset: keyLayer, index: 1)
                encoder.setBuffer(valueCache, offset: valueLayer, index: 2)
                encoder.setBuffer(scores, offset: 0, index: 3)
                encoder.setBuffer(attention, offset: 0, index: 4)
                encoder.setBytes(&attn, length: MemoryLayout<AttnArgs>.stride, index: 5)
                encoder.dispatchThreadgroups(MTLSize(width: heads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            barrier()
            matvec(encoder, layer.output, attention, x, accumulate: true)
            barrier()

            rmsNorm(encoder, x, buffers.feedForwardNorm, normed, count: dim)
            barrier()
            matvec(encoder, layer.gate, normed, hidden)
            matvec(encoder, layer.up, normed, hiddenUp)
            barrier()
            elementwise(encoder, "silu_mul", hidden, hiddenUp, count: hp.feedForwardLength)
            barrier()
            matvec(encoder, layer.down, hidden, x, accumulate: true)
            barrier()
        }

        if output != .none && model.stage.head {
            rmsNorm(encoder, x, outputNorm, normed, count: dim)
            barrier()
            if output == .logits { matvec(encoder, model.outputProjection, normed, logitsBuffer) }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastGPUSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
    }

    // MARK: Batched prefill

    /// Weight types the batched kernels read (q2_K and q3_K models prefill a token at a time).
    static let batchTypes: Set<GGMLType> = [.f32, .f16, .bf16, .q4_0, .q4_1, .q5_0, .q5_1, .q8_0, .q4_K, .q5_K, .q6_K, .q8_K]

    /// Tokens per batched pass for this model, or 0 when it can't be batched.
    /// `ROACHNET_METAL_BATCH=0` turns batching off (A/B checks); a number sets the size.
    static func batchSize(for model: TransformerModel) -> Int {
        let setting = ProcessInfo.processInfo.environment["ROACHNET_METAL_BATCH"].flatMap { Int($0) }
        if setting == 0 { return 0 }
        let hp = model.hyperparameters
        guard hp.headDimension <= 256, hp.valueDimension <= 256 else { return 0 }
        for layer in model.layers {
            for matrix in [layer.query, layer.key, layer.value, layer.output, layer.gate, layer.up, layer.down] where !batchTypes.contains(matrix.type) {
                return 0
            }
        }
        return max(4, min(setting ?? 512, 2048)) / 4 * 4
    }

    final class BatchBuffers {
        let groups: Int
        let x: MTLBuffer, normed: MTLBuffer, query: MTLBuffer, key: MTLBuffer, value: MTLBuffer
        let attention: MTLBuffer, hidden: MTLBuffer, up: MTLBuffer

        init(device: MTLDevice, model: TransformerModel, groups: Int) throws {
            let hp = model.hyperparameters
            func packed(_ width: Int) throws -> MTLBuffer {
                guard let buffer = device.makeBuffer(length: max(16, groups * width * 16), options: .storageModeShared) else {
                    throw InferenceError.invalid("Metal allocation failed.")
                }
                return buffer
            }
            self.groups = groups
            x = try packed(hp.embeddingLength)
            normed = try packed(hp.embeddingLength)
            query = try packed(hp.headCount * hp.headDimension)
            key = try packed(hp.headCountKV * hp.headDimension)
            value = try packed(hp.headCountKV * hp.valueDimension)
            attention = try packed(hp.headCount * hp.valueDimension)
            hidden = try packed(hp.feedForwardLength)
            up = try packed(hp.feedForwardLength)
        }
    }

    private func batchBuffers() -> BatchBuffers? {
        if let batchStorage { return batchStorage }
        batchStorage = try? BatchBuffers(device: device, model: model, groups: maxBatch / 4)
        return batchStorage
    }

    private func matmul(_ encoder: MTLComputeCommandEncoder, _ matrix: QuantizedMatrix, _ input: MTLBuffer, _ output: MTLBuffer,
                        groups: Int, bias: MTLBuffer? = nil, accumulate: Bool = false) {
        struct Args { var cols: UInt32; var rowBytes: UInt32; var rows: UInt32; var flags: UInt32; var groups: UInt32 }
        var args = Args(cols: UInt32(matrix.columns), rowBytes: UInt32(matrix.rowBytes), rows: UInt32(matrix.rows),
                        flags: (accumulate ? 1 : 0) | (bias != nil ? 2 : 0), groups: UInt32(groups))
        let (prefix, tileRows) = matmulKernel
        let kernel = prefix + MetalBackend.matvecKernel(matrix.type).dropFirst("matvec_".count)
        encoder.setComputePipelineState(pipeline(kernel))
        encoder.setBuffer(weights, offset: matrix.data - weightsBase, index: 0)
        encoder.setBuffer(input, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 3)
        encoder.setBuffer(bias ?? output, offset: 0, index: 4)
        encoder.dispatchThreadgroups(MTLSize(width: (matrix.rows + tileRows - 1) / tileRows, height: (groups + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
    }

    private func rmsNorm4(_ encoder: MTLComputeCommandEncoder, _ input: MTLBuffer, _ weight: MTLBuffer, _ output: MTLBuffer, count: Int, rows: Int) {
        struct Args { var n: UInt32; var eps: Float }
        var args = Args(n: UInt32(count), eps: model.hyperparameters.rmsEpsilon)
        let state = pipeline("rms_norm4")
        encoder.setComputePipelineState(state)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(weight, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 3)
        let threads = min(state.maxTotalThreadsPerThreadgroup, 1024, max(32, (count + 31) / 32 * 32))
        encoder.dispatchThreadgroups(MTLSize(width: rows, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
    }

    private func rope4(_ encoder: MTLComputeCommandEncoder, _ buffer: MTLBuffer, heads: Int, groups: Int, start: Int) {
        struct Args { var headDim: UInt32; var pairs: UInt32; var start: UInt32; var neox: UInt32; var heads: UInt32 }
        let hp = model.hyperparameters
        let pairs = model.ropeInverseFrequencies.count
        var args = Args(headDim: UInt32(hp.headDimension), pairs: UInt32(pairs), start: UInt32(start),
                        neox: hp.ropeStyle == .neox ? 1 : 0, heads: UInt32(heads))
        encoder.setComputePipelineState(pipeline("rope4"))
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBuffer(inverseFrequencies, offset: 0, index: 1)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: pairs, height: heads, depth: groups),
                                threadsPerThreadgroup: MTLSize(width: min(pairs, 64), height: 1, depth: 1))
    }

    private func store4(_ encoder: MTLComputeCommandEncoder, _ source: MTLBuffer, into cache: MTLBuffer, offset: Int, width: Int, groups: Int, count: Int) {
        struct Args { var width: UInt32; var count: UInt32 }
        var args = Args(width: UInt32(width), count: UInt32(count))
        encoder.setComputePipelineState(pipeline("kv_store4" + cacheSuffix))
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(cache, offset: offset, index: 1)
        encoder.setBytes(&args, length: MemoryLayout<Args>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: width, height: groups, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, width), height: 1, depth: 1))
    }

    /// Runs `tokens` at positions `position…` in one pass: every matrix is read
    /// once per 32 tokens instead of once per token.
    public func forward(tokens: [Int], position: Int, output: ForwardOutput, each: ((Int, UnsafeBufferPointer<Float>) -> Void)?) {
        let embed = model.stage.embedding
        forwardBatch(count: tokens.count, position: position, output: output, each: each,
                     single: { offset, wanted in self.forward(token: tokens[offset], position: position + offset, output: wanted) },
                     fill: { t, row in if embed { self.model.tokenEmbedding.dequantizeRow(tokens[t], into: row) } })
    }

    public func forward(residuals: UnsafePointer<Float>, count: Int, position: Int, output: ForwardOutput,
                        each: ((Int, UnsafeBufferPointer<Float>) -> Void)?) {
        let dim = model.hyperparameters.embeddingLength
        forwardBatch(count: count, position: position, output: output, each: each,
                     single: { offset, wanted in self.forward(residual: residuals + offset * dim, position: position + offset, output: wanted) },
                     fill: { t, row in row.update(from: residuals + t * dim, count: dim) })
    }

    /// Every token's residual stream after the last batched pass.
    public func batchResiduals(count: Int) -> [Float] {
        let dim = model.hyperparameters.embeddingLength
        guard count <= maxBatch, let b = batchStorage else { return Array(residualState) }
        let packed = b.x.contents().assumingMemoryBound(to: Float.self)
        var out = [Float](repeating: 0, count: count * dim)
        out.withUnsafeMutableBufferPointer { buffer in
            for t in 0..<count {
                let base = packed + (t / 4) * dim * 4 + t % 4
                for i in 0..<dim { buffer[t * dim + i] = base[i * 4] }
            }
        }
        return out
    }

    private func forwardBatch(count: Int, position: Int, output: ForwardOutput, each: ((Int, UnsafeBufferPointer<Float>) -> Void)?,
                              single: (Int, ForwardOutput) -> Void, fill: (Int, UnsafeMutablePointer<Float>) -> Void) {
        guard count > 0 else { return }
        guard count <= maxBatch, let b = batchBuffers() else {
            for offset in 0..<count {
                let last = offset == count - 1
                let wanted: ForwardOutput = each != nil ? (last && output == .logits ? .logits : .hidden) : (last ? output : .none)
                single(offset, wanted)
                each?(offset, hiddenState)
            }
            return
        }
        let hp = model.hyperparameters
        let dim = hp.embeddingLength, heads = hp.headCount, kvHeads = hp.headCountKV
        let groups = (count + 3) / 4

        // Inputs (embeddings or the previous stage's residual streams), packed four tokens to a float4.
        let packed = b.x.contents().assumingMemoryBound(to: Float.self)
        let row = UnsafeMutablePointer<Float>.allocate(capacity: dim)
        defer { row.deallocate() }
        for t in 0..<(groups * 4) {
            row.initialize(repeating: 0, count: dim)
            if t < count { fill(t, row) }
            let base = packed + (t / 4) * dim * 4 + t % 4
            for i in 0..<dim { base[i * 4] = row[i] }
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: serialDispatch ? .serial : .concurrent) else { return }
        let serial = serialDispatch
        func barrier() { if !serial { encoder.memoryBarrier(scope: .buffers) } }
        struct AttnArgs {
            var headDim: UInt32; var valueDim: UInt32; var keyWidth: UInt32; var valueWidth: UInt32
            var group: UInt32; var heads: UInt32; var start: UInt32; var count: UInt32; var scale: Float
        }
        var attn = AttnArgs(headDim: UInt32(hp.headDimension), valueDim: UInt32(hp.valueDimension),
                            keyWidth: UInt32(kvKeyWidth), valueWidth: UInt32(kvValueWidth), group: UInt32(heads / kvHeads),
                            heads: UInt32(heads), start: UInt32(position), count: UInt32(count), scale: 1 / sqrtf(Float(hp.headDimension)))

        for (index, layer) in model.layers.enumerated() {
            let buffers = layerBuffers[index]
            let keyLayer = index * contextLength * kvKeyWidth * cacheBytes
            let valueLayer = index * contextLength * kvValueWidth * cacheBytes

            rmsNorm4(encoder, b.x, buffers.attentionNorm, b.normed, count: dim, rows: groups)
            barrier()
            matmul(encoder, layer.query, b.normed, b.query, groups: groups, bias: buffers.queryBias)
            matmul(encoder, layer.key, b.normed, b.key, groups: groups, bias: buffers.keyBias)
            matmul(encoder, layer.value, b.normed, b.value, groups: groups, bias: buffers.valueBias)
            barrier()
            if let norm = buffers.queryNorm { rmsNorm4(encoder, b.query, norm, b.query, count: hp.headDimension, rows: groups * heads) }
            if let norm = buffers.keyNorm { rmsNorm4(encoder, b.key, norm, b.key, count: hp.headDimension, rows: groups * kvHeads) }
            if buffers.queryNorm != nil || buffers.keyNorm != nil { barrier() }
            rope4(encoder, b.query, heads: heads, groups: groups, start: position)
            rope4(encoder, b.key, heads: kvHeads, groups: groups, start: position)
            barrier()
            store4(encoder, b.key, into: keyCache, offset: keyLayer + position * kvKeyWidth * cacheBytes, width: kvKeyWidth, groups: groups, count: count)
            store4(encoder, b.value, into: valueCache, offset: valueLayer + position * kvValueWidth * cacheBytes, width: kvValueWidth, groups: groups, count: count)
            barrier()

            encoder.setComputePipelineState(pipeline("attn4" + cacheSuffix))
            encoder.setBuffer(b.query, offset: 0, index: 0)
            encoder.setBuffer(keyCache, offset: keyLayer, index: 1)
            encoder.setBuffer(valueCache, offset: valueLayer, index: 2)
            encoder.setBuffer(b.attention, offset: 0, index: 3)
            encoder.setBytes(&attn, length: MemoryLayout<AttnArgs>.stride, index: 4)
            encoder.dispatchThreadgroups(MTLSize(width: heads, height: groups, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            barrier()

            matmul(encoder, layer.output, b.attention, b.x, groups: groups, accumulate: true)
            barrier()
            rmsNorm4(encoder, b.x, buffers.feedForwardNorm, b.normed, count: dim, rows: groups)
            barrier()
            matmul(encoder, layer.gate, b.normed, b.hidden, groups: groups)
            matmul(encoder, layer.up, b.normed, b.up, groups: groups)
            barrier()
            elementwise(encoder, "silu_mul", b.hidden, b.up, count: groups * hp.feedForwardLength * 4)
            barrier()
            matmul(encoder, layer.down, b.hidden, b.x, groups: groups, accumulate: true)
            barrier()
        }

        let head = model.stage.head
        if each != nil && head { rmsNorm4(encoder, b.x, outputNorm, b.normed, count: dim, rows: groups) }
        if output != .none && head {
            // The last token's state goes through the usual final norm (and projection).
            var pick = SIMD2<UInt32>(UInt32(dim), UInt32((count - 1) % 4))
            encoder.setComputePipelineState(pipeline("take4"))
            encoder.setBuffer(b.x, offset: ((count - 1) / 4) * dim * 16, index: 0)
            encoder.setBuffer(x, offset: 0, index: 1)
            encoder.setBytes(&pick, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: dim, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, dim), height: 1, depth: 1))
            barrier()
            rmsNorm(encoder, x, outputNorm, normed, count: dim)
            barrier()
            if output == .logits { matvec(encoder, model.outputProjection, normed, logitsBuffer) }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastGPUSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime

        if let each, head {
            let states = b.normed.contents().assumingMemoryBound(to: Float.self)
            for t in 0..<count {
                let base = states + (t / 4) * dim * 4 + t % 4
                for i in 0..<dim { row[i] = base[i * 4] }
                each(t, UnsafeBufferPointer(start: row, count: dim))
            }
        }
    }

    /// Checks a batched pass against token-by-token passes on this GPU;
    /// batching is turned off for this model if they disagree.
    func verifyBatching() {
        guard maxBatch > 0 else { return }
        let reference: [Float], batched: [Float]
        if model.stage.embedding && model.stage.head {
            var tokens = model.tokenizer.encode("The quick brown fox jumps").map { Int($0) }
            if let bos = model.tokenizer.bos, tokens.first != Int(bos) { tokens.insert(Int(bos), at: 0) }
            tokens = Array(tokens.prefix(6))
            while tokens.count < 6 { tokens.append(tokens.last ?? 0) }
            for (position, token) in tokens.enumerated() { forward(token: token, position: position, output: position == tokens.count - 1 ? .logits : .none) }
            reference = Array(logits)
            forward(tokens: tokens, position: 0, output: .logits, each: nil)
            batched = Array(logits)
        } else {
            // A stage in the middle of a model: compare the residual streams it hands on.
            let dim = model.hyperparameters.embeddingLength
            let probe = MetalBackend.probeResiduals(model, count: 6)
            defer { probe.deallocate() }
            for position in 0..<6 { forward(residual: probe + position * dim, position: position, output: .none) }
            reference = Array(residualState)
            forward(residuals: probe, count: 6, position: 0, output: .none, each: nil)
            batched = Array(batchResiduals(count: 6).suffix(dim))
        }
        var worst: Float = 0, magnitude: Float = 1e-6
        for i in 0..<reference.count {
            worst = max(worst, abs(reference[i] - batched[i]))
            magnitude = max(magnitude, abs(reference[i]))
        }
        if !(worst <= 1e-2 * magnitude + 1e-3) {
            FileHandle.standardError.write(Data("RoachInference: batched prefill check failed (max |Δ| \(worst)); prompts run a token at a time.\n".utf8))
            maxBatch = 0
        }
    }

    /// Times every layer's matrix of each kind on the GPU (profiling aid for
    /// `roachnet-infer bench`). Returns (label, type, seconds per pass, bytes per pass).
    public func profileMatvecs(iterations: Int = 20) -> [(label: String, type: String, seconds: Double, bytes: Int)] {
        var groups: [(String, [QuantizedMatrix])] = [
            ("attn_q", model.layers.map(\.query)), ("attn_k", model.layers.map(\.key)), ("attn_v", model.layers.map(\.value)),
            ("attn_out", model.layers.map(\.output)), ("ffn_gate", model.layers.map(\.gate)), ("ffn_up", model.layers.map(\.up)),
            ("ffn_down", model.layers.map(\.down)),
        ]
        if model.stage.head { groups.append(("output", [model.outputProjection])) }
        var results: [(label: String, type: String, seconds: Double, bytes: Int)] = []
        let input = try? { () throws -> MTLBuffer in
            let width = max(model.hyperparameters.feedForwardLength, model.hyperparameters.embeddingLength, model.hyperparameters.headCount * model.hyperparameters.valueDimension)
            guard let buffer = device.makeBuffer(length: width * 4, options: .storageModeShared) else { throw InferenceError.invalid("alloc") }
            let pointer = buffer.contents().assumingMemoryBound(to: Float.self)
            for i in 0..<width { pointer[i] = Float(i % 7) * 0.01 }
            return buffer
        }()
        guard let input else { return [] }
        for (label, matrices) in groups {
            let rows = matrices.map(\.rows).max() ?? 1
            guard let output = device.makeBuffer(length: rows * 4, options: .storageModeShared),
                  let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            for _ in 0..<iterations { for matrix in matrices { matvec(encoder, matrix, input, output) } }
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let seconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) / Double(iterations)
            let bytes = matrices.reduce(0) { $0 + $1.rowBytes * $1.rows }
            results.append((label, matrices.first?.type.name ?? "?", seconds, bytes))
        }
        return results
    }
}
#endif
