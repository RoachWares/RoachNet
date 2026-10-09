#if canImport(Metal)
import Foundation
import Metal

/// GPU backend for Apple Silicon built only on our own Metal kernels
/// (`MetalKernelSource`). Weights stay quantized and are read in place from the
/// memory-mapped GGUF file; activations and the KV cache live in shared buffers.
public final class MetalBackend: TransformerBackend {
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
            let token = Int(model.tokenizer.bos ?? 0)
            reference.forward(token: token, position: 0)
            backend.forward(token: token, position: 0)
            let a = reference.logits, b = backend.logits
            var worst: Float = 0, magnitude: Float = 1e-6
            for i in 0..<a.count {
                worst = max(worst, abs(a[i] - b[i]))
                magnitude = max(magnitude, abs(a[i]))
            }
            guard worst <= 1e-2 * magnitude + 1e-3 else {
                FileHandle.standardError.write(Data("RoachInference: Metal parity check failed (max |Δ| \(worst)); using CPU.\n".utf8))
                return nil
            }
            return backend
        } catch {
            FileHandle.standardError.write(Data("RoachInference: Metal unavailable (\(error)); using CPU.\n".utf8))
            return nil
        }
    }

    public init(model: TransformerModel, contextLength: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw InferenceError.invalid("No Metal device.")
        }
        self.model = model
        self.contextLength = contextLength
        self.device = device
        self.queue = queue
        let hp = model.hyperparameters

        // Kernels whose rows are not whole 32-element chunks stay on the CPU path.
        for layer in model.layers {
            for matrix in [layer.query, layer.key, layer.value, layer.output, layer.gate, layer.up, layer.down] where matrix.columns % 32 != 0 {
                throw InferenceError.invalid("Matrix width \(matrix.columns) is not supported by the Metal kernels.")
            }
        }
        guard model.outputProjection.columns % 32 == 0 else {
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
        func scratch(_ count: Int) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(4, count * 4), options: .storageModeShared) else {
                throw InferenceError.invalid("Metal allocation failed.")
            }
            memset(buffer.contents(), 0, buffer.length)
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
        let width = max(hp.embeddingLength, hp.headCount * hp.valueDimension)
        x = try scratch(hp.embeddingLength)
        normed = try scratch(width)
        projected = try scratch(width)
        query = try scratch(hp.headCount * hp.headDimension)
        attention = try scratch(hp.headCount * hp.valueDimension)
        hidden = try scratch(hp.feedForwardLength)
        hiddenUp = try scratch(hp.feedForwardLength)
        scores = try scratch(hp.headCount * contextLength)
        logitsBuffer = try scratch(model.outputProjection.rows)
        keyCache = try scratch(hp.blockCount * contextLength * kvKeyWidth)
        valueCache = try scratch(hp.blockCount * contextLength * kvValueWidth)
    }

    public var logits: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: logitsBuffer.contents().assumingMemoryBound(to: Float.self), count: model.outputProjection.rows)
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

    public func forward(token: Int, position: Int) {
        let hp = model.hyperparameters
        let dim = hp.embeddingLength
        let heads = hp.headCount
        model.tokenEmbedding.dequantizeRow(token, into: x.contents().assumingMemoryBound(to: Float.self))

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

        for (index, layer) in model.layers.enumerated() {
            let buffers = layerBuffers[index]
            let keyLayer = index * contextLength * kvKeyWidth * 4
            let valueLayer = index * contextLength * kvValueWidth * 4
            let keyRow = keyLayer + position * kvKeyWidth * 4
            let valueRow = valueLayer + position * kvValueWidth * 4

            rmsNorm(encoder, x, buffers.attentionNorm, normed, count: dim)
            barrier()
            matvec(encoder, layer.query, normed, query, bias: buffers.queryBias)
            matvec(encoder, layer.key, normed, keyCache, outputOffset: keyRow, bias: buffers.keyBias)
            matvec(encoder, layer.value, normed, valueCache, outputOffset: valueRow, bias: buffers.valueBias)
            barrier()
            if let norm = buffers.queryNorm {
                rmsNorm(encoder, query, norm, query, count: hp.headDimension, rows: heads)
            }
            if let norm = buffers.keyNorm {
                rmsNorm(encoder, keyCache, inputOffset: keyRow, norm, keyCache, outputOffset: keyRow, count: hp.headDimension, rows: hp.headCountKV)
            }
            if buffers.queryNorm != nil || buffers.keyNorm != nil { barrier() }
            rope(encoder, query, offset: 0, heads: heads, position: position)
            rope(encoder, keyCache, offset: keyRow, heads: hp.headCountKV, position: position)
            barrier()

            encoder.setComputePipelineState(pipeline("attn_fused"))
            encoder.setBuffer(query, offset: 0, index: 0)
            encoder.setBuffer(keyCache, offset: keyLayer, index: 1)
            encoder.setBuffer(valueCache, offset: valueLayer, index: 2)
            encoder.setBuffer(scores, offset: 0, index: 3)
            encoder.setBuffer(attention, offset: 0, index: 4)
            encoder.setBytes(&attn, length: MemoryLayout<AttnArgs>.stride, index: 5)
            encoder.dispatchThreadgroups(MTLSize(width: heads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

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

        rmsNorm(encoder, x, outputNorm, normed, count: dim)
        barrier()
        matvec(encoder, model.outputProjection, normed, logitsBuffer)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastGPUSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
    }

    /// Times every layer's matrix of each kind on the GPU (profiling aid for
    /// `roachnet-infer bench`). Returns (label, type, seconds per pass, bytes per pass).
    public func profileMatvecs(iterations: Int = 20) -> [(label: String, type: String, seconds: Double, bytes: Int)] {
        var groups: [(String, [QuantizedMatrix])] = [
            ("attn_q", model.layers.map(\.query)), ("attn_k", model.layers.map(\.key)), ("attn_v", model.layers.map(\.value)),
            ("attn_out", model.layers.map(\.output)), ("ffn_gate", model.layers.map(\.gate)), ("ffn_up", model.layers.map(\.up)),
            ("ffn_down", model.layers.map(\.down)),
        ]
        groups.append(("output", [model.outputProjection]))
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
