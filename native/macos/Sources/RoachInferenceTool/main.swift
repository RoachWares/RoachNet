import Foundation
import RoachInference

// roachnet-infer: developer tool for the native inference engine.
//   roachnet-infer info <model.gguf>
//   roachnet-infer tokenize <model.gguf> <text> [--no-special]
//   roachnet-infer logits <model.gguf> <text> [--top N]      (prompt logits of the last token)
//   roachnet-infer generate <model.gguf> <prompt> [--tokens N] [--temp T] [--seed S] [--chat]
//   roachnet-infer dot-vectors <model.gguf> <out.bin>   (kernel test vectors: one row per tensor type)

let args = Array(CommandLine.arguments.dropFirst())
func floatToHalfBits(_ value: Float) -> UInt16 {
    #if arch(arm64)
    return Float16(value).bitPattern
    #else
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exponent = Int((bits >> 23) & 0xFF) - 112
    if exponent <= 0 { return sign }
    return sign | UInt16(exponent << 10) | UInt16((bits >> 13) & 0x3FF)
    #endif
}
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard args.count >= 2 else { fail("usage: roachnet-infer info|tokenize|logits|generate <model.gguf> [text]") }
let command = args[0], path = args[1]

do {
    switch command {
    case "info":
        let file = try GGUFFile(path: path)
        print("architecture: \(file.architecture)")
        print("name: \(file.modelName ?? "-")")
        print("tensors: \(file.tensors.count)")
        var types: [String: Int] = [:]
        for tensor in file.tensors.values { types[tensor.type.name, default: 0] += 1 }
        print("types: \(types.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for key in file.metadata.keys.sorted() where !key.hasPrefix("tokenizer.ggml.tokens") && !key.hasPrefix("tokenizer.ggml.scores")
            && !key.hasPrefix("tokenizer.ggml.token_type") && !key.hasPrefix("tokenizer.ggml.merges") && key != "tokenizer.chat_template" {
            print("  \(key) = \(file.metadata[key]!)")
        }
    case "tokenize":
        let file = try GGUFFile(path: path)
        let tokenizer = try Tokenizer(gguf: file)
        guard args.count >= 3 else { fail("missing text") }
        let ids = tokenizer.encode(args[2], addSpecial: !args.contains("--no-special"), parseSpecial: true)
        print(ids.map(String.init).joined(separator: " "))
    case "logits":
        guard args.count >= 3 else { fail("missing text") }
        let model = try TransformerModel(path: path)
        let session = InferenceSession(model: model, contextLength: 512)
        let tokens = model.tokenizer.encode(args[2])
        let start = Date()
        let logits = try session.prefill(tokens)
        let elapsed = Date().timeIntervalSince(start)
        let top = Int(option("--top") ?? "10") ?? 10
        let ranked = logits.indices.sorted { logits[$0] > logits[$1] }.prefix(top)
        print("tokens: \(tokens.map(String.init).joined(separator: " "))")
        for id in ranked { print(String(format: "%d %.6f", id, logits[id])) }
        print(String(format: "prefill: %.2fs (%.1f tok/s)", elapsed, Double(tokens.count) / elapsed))
    case "generate":
        guard args.count >= 3 else { fail("missing prompt") }
        let engine = try InferenceEngine(modelPath: path, contextLength: Int(option("--ctx") ?? "1024"))
        var options = GenerationOptions()
        options.maxTokens = Int(option("--tokens") ?? "32") ?? 32
        options.sampling.temperature = Float(option("--temp") ?? "0") ?? 0
        if options.sampling.temperature == 0 { options.sampling = .greedy }
        if let seed = option("--seed") { options.sampling.seed = UInt64(seed) }
        let onText: (String) -> Void = { piece in
            FileHandle.standardOutput.write(Data(piece.utf8))
        }
        let result = args.contains("--chat")
            ? try engine.chat([ChatMessage(role: .user, content: args[2])], options: options, onText: onText)
            : try engine.generate(prompt: args[2], options: options, onText: onText)
        print("")
        print("ids: \(result.tokens.map(String.init).joined(separator: " "))")
        print(String(format: "prompt %d tok in %.2fs, generated %d tok at %.1f tok/s (%@)",
                     result.promptTokenCount, result.promptDuration, result.tokens.count, result.tokensPerSecond, result.stopReason.rawValue))
    case "bench":
        // roachnet-infer bench <model.gguf> [--tokens N]: Metal per-token wall/GPU time and per-matrix bandwidth.
        #if canImport(Metal)
        let model = try TransformerModel(path: path)
        let positions = Int(option("--tokens") ?? "64") ?? 64
        // --context N: decode after N tokens already in the cache (filled by a batched prefill).
        let context = Int(option("--context") ?? "0") ?? 0
        let backend = try MetalBackend(model: model, contextLength: context + positions + 1)
        let filler = Int(model.tokenizer.bos ?? 1)
        var filled = 0
        while filled < context {
            let count = min(context - filled, max(1, backend.maxBatch))
            backend.forward(tokens: Array(repeating: filler, count: count), position: filled, output: .none, each: nil)
            filled += count
        }
        var wall = 0.0, gpu = 0.0
        for step in 0..<positions {
            let start = Date()
            backend.forward(token: filler, position: context + step)
            if step >= 4 { wall += Date().timeIntervalSince(start); gpu += backend.lastGPUSeconds }
        }
        let measured = Double(max(1, positions - 4))
        print(String(format: "forward at context %d: wall %.2f ms/token (%.1f tok/s), gpu %.2f ms/token",
                     context, wall / measured * 1000, measured / wall, gpu / measured * 1000))
        var matvecTotal = 0.0, byteTotal = 0
        for row in backend.profileMatvecs() {
            matvecTotal += row.seconds; byteTotal += row.bytes
            print(String(format: "  %-9@ %-5@ %7.3f ms  %6.1f GB/s", row.label as NSString, row.type as NSString, row.seconds * 1000, Double(row.bytes) / row.seconds / 1e9))
        }
        print(String(format: "  matvec total %.2f ms for %.0f MB (%.1f GB/s); other kernels ~%.2f ms", matvecTotal * 1000, Double(byteTotal) / 1e6, Double(byteTotal) / matvecTotal / 1e9, (gpu / measured - matvecTotal) * 1000))
        #else
        fail("Metal is not available on this platform.")
        #endif
    case "prefill":
        // roachnet-infer prefill <model.gguf> [--tokens N]: prompt evaluation, batched against a token at a time.
        #if canImport(Metal)
        let model = try TransformerModel(path: path)
        let count = Int(option("--tokens") ?? "512") ?? 512
        let backend = try MetalBackend(model: model, contextLength: count + 8)
        var tokens = model.tokenizer.encode(String(repeating: "RoachNet keeps your models, data and agents on your own Mac. ", count: count / 8 + 1)).map { Int($0) }
        tokens = Array(tokens.prefix(count))
        func batched() -> Double {
            let start = Date()
            var index = 0
            while index < tokens.count {
                let end = min(tokens.count, index + max(1, backend.maxBatch))
                backend.forward(tokens: Array(tokens[index..<end]), position: index, output: end == tokens.count ? .logits : .none, each: nil)
                index = end
            }
            return Date().timeIntervalSince(start)
        }
        _ = batched()
        let fast = min(batched(), batched())
        let start = Date()
        for (position, token) in tokens.enumerated() { backend.forward(token: token, position: position, output: position == tokens.count - 1 ? .logits : .none) }
        let slow = Date().timeIntervalSince(start)
        print(String(format: "%d tokens: batched %.0f tok/s (%.0f ms, batch %d), one at a time %.0f tok/s (%.0f ms): %.1fx",
                     tokens.count, Double(tokens.count) / fast, fast * 1000, backend.maxBatch, Double(tokens.count) / slow, slow * 1000, slow / fast))
        if args.contains("--profile") {
            // --profile: each kind of matrix product alone, for one batched pass of the prompt.
            var seconds = 0.0, flops = 0.0
            for row in backend.profileMatmuls(tokens: min(tokens.count, max(4, backend.maxBatch))) {
                seconds += row.seconds; flops += row.flops
                print(String(format: "  %-9@ %-5@ %8.2f ms  %5.2f TFLOPS", row.label as NSString, row.type as NSString, row.seconds * 1000, row.flops / row.seconds / 1e12))
            }
            print(String(format: "  matmul total %.1f ms (%.2f TFLOPS) of %.1f ms batched", seconds * 1000, flops / seconds / 1e12, fast * 1000))
        }
        #else
        fail("Metal is not available on this platform.")
        #endif
    case "dot-vectors":
        // Format per record: u32 type, u32 cols, u32 rowBytes, f32 expected, row bytes, cols × f32 x.
        guard args.count >= 3 else { fail("missing output path") }
        let file = try GGUFFile(path: path)
        var seen = Set<UInt32>()
        var out = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        for name in file.tensorNames {
            let info = try file.tensor(name)
            guard info.shape.count == 2, !seen.contains(info.type.rawValue), info.rowLength % 32 == 0 else { continue }
            seen.insert(info.type.rawValue)
            let row = file.pointer(to: info) + info.rowBytes * (info.rowCount / 2)
            let x = (0..<info.rowLength).map { Float(sin(Double($0) * 0.37)) }
            let expected = x.withUnsafeBufferPointer { Quantization.dot(info.type, row, $0.baseAddress!, count: info.rowLength) }
            append(info.type.rawValue); append(UInt32(info.rowLength)); append(UInt32(info.rowBytes)); append(expected)
            out.append(Data(bytes: row, count: info.rowBytes))
            for value in x { append(value) }
            print("\(info.type.name) \(name) cols=\(info.rowLength) expected=\(expected)")
        }
        if args.contains("--synthetic") {
            // Every type, from seeded random blocks with sane scale fields.
            var rng = SeededGenerator(seed: 1234)
            let scaleOffsets: [GGMLType: [Int]] = [.q4_0: [0], .q4_1: [0, 2], .q5_0: [0], .q5_1: [0, 2], .q8_0: [0],
                                                   .q2_K: [80, 82], .q3_K: [108], .q4_K: [0, 2], .q5_K: [0, 2], .q6_K: [208]]
            for type in GGMLType.allCases {
                let cols = 512
                let rowBytes = type.rowBytes(cols)
                var bytes = (0..<rowBytes).map { _ in UInt8.random(in: 0...255, using: &rng) }
                switch type {
                case .f32:
                    for i in 0..<cols { withUnsafeBytes(of: Float.random(in: -1...1, using: &rng)) { for (k, b) in $0.enumerated() { bytes[i * 4 + k] = b } } }
                case .f16:
                    for i in 0..<cols { let h = floatToHalfBits(Float.random(in: -1...1, using: &rng)); bytes[i * 2] = UInt8(h & 0xFF); bytes[i * 2 + 1] = UInt8(h >> 8) }
                case .bf16:
                    for i in 0..<cols { let b = UInt16(Float.random(in: -1...1, using: &rng).bitPattern >> 16); bytes[i * 2] = UInt8(b & 0xFF); bytes[i * 2 + 1] = UInt8(b >> 8) }
                case .q8_K:
                    for blk in 0..<(cols / 256) { withUnsafeBytes(of: Float(0.01)) { for (k, b) in $0.enumerated() { bytes[blk * type.blockBytes + k] = b } } }
                default:
                    for blk in 0..<(cols / type.blockSize) {
                        for offset in scaleOffsets[type] ?? [] {
                            let h = floatToHalfBits(Float.random(in: 0.001...0.05, using: &rng))
                            bytes[blk * type.blockBytes + offset] = UInt8(h & 0xFF)
                            bytes[blk * type.blockBytes + offset + 1] = UInt8(h >> 8)
                        }
                    }
                }
                let x = (0..<cols).map { Float(cos(Double($0) * 0.21)) }
                let expected = bytes.withUnsafeBytes { raw in x.withUnsafeBufferPointer { Quantization.dot(type, raw.baseAddress!, $0.baseAddress!, count: cols) } }
                append(type.rawValue); append(UInt32(cols)); append(UInt32(rowBytes)); append(expected)
                out.append(contentsOf: bytes)
                for value in x { append(value) }
                print("\(type.name) synthetic expected=\(expected)")
            }
        }
        try out.write(to: URL(fileURLWithPath: args[2]))
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error)")
}
