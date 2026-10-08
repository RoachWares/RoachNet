import Foundation
import RoachInference

// roachnet-infer: developer tool for the native inference engine.
//   roachnet-infer info <model.gguf>
//   roachnet-infer tokenize <model.gguf> <text> [--no-special]
//   roachnet-infer logits <model.gguf> <text> [--top N]      (prompt logits of the last token)
//   roachnet-infer generate <model.gguf> <prompt> [--tokens N] [--temp T] [--seed S] [--chat]

let args = Array(CommandLine.arguments.dropFirst())
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
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error)")
}
