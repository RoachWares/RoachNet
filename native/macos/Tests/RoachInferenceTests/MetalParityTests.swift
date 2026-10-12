import Foundation
import XCTest
@testable import RoachInference

/// Runs on Apple Silicon only: every hand-written Metal kernel path must
/// reproduce the CPU reference logits token by token.
final class MetalParityTests: XCTestCase {
    func testMetalMatchesCPUOnReferenceModels() throws {
        #if canImport(Metal)
        var ran = 0
        for name in ["stories15M-q4_0", "smollm2-135m-q8_0", "qwen2.5-0.5b-q4_k_m", "qwen3-0.6b-q8_0"] {
            guard let path = try? TestModels.path(name) else { continue }
            let model = try TransformerModel(path: path)
            let metal = try MetalBackend(model: model, contextLength: 64)
            let cpu = CPUBackend(model: model, contextLength: 64)
            let tokens = model.tokenizer.encode("The quick brown fox jumps over the lazy dog")
            for (position, token) in tokens.enumerated() {
                cpu.forward(token: Int(token), position: position)
                metal.forward(token: Int(token), position: position)
                let a = cpu.logits, b = metal.logits
                var worst: Float = 0
                var magnitude: Float = 1e-6
                for i in 0..<a.count {
                    worst = max(worst, abs(a[i] - b[i]))
                    magnitude = max(magnitude, abs(a[i]))
                }
                XCTAssertLessThan(worst, 2e-3 * magnitude + 1e-3, "\(name) position \(position)")
                XCTAssertEqual(a.indices.max { a[$0] < a[$1] }, b.indices.max { b[$0] < b[$1] }, "\(name) argmax at \(position)")
            }
            ran += 1
        }
        if ran == 0 { throw XCTSkip("Set ROACHNET_TEST_MODELS to run Metal parity tests.") }
        #else
        throw XCTSkip("Metal is not available on this platform.")
        #endif
    }

    /// Decode attention split across key chunks (long contexts) must match the
    /// single fused kernel.
    func testSplitAttentionMatchesFusedOnLongContexts() throws {
        #if canImport(Metal)
        var ran = 0
        for name in ["smollm2-135m-q8_0", "qwen3-0.6b-q8_0"] {
            guard let path = try? TestModels.path(name) else { continue }
            let model = try TransformerModel(path: path)
            let tokens = model.tokenizer.encode(String(repeating: "A long context needs many keys. ", count: 40)).prefix(300).map { Int($0) }
            let split = try MetalBackend(model: model, contextLength: 512)
            let fused = try MetalBackend(model: model, contextLength: 512)
            fused.splitAttention = false
            for backend in [split, fused] { backend.forward(tokens: tokens, position: 0, output: .none, each: nil) }
            for step in 0..<3 {
                split.forward(token: tokens[step], position: tokens.count + step)
                fused.forward(token: tokens[step], position: tokens.count + step)
                let a = fused.logits, b = split.logits
                var worst: Float = 0, magnitude: Float = 1e-6
                for i in 0..<a.count {
                    worst = max(worst, abs(a[i] - b[i]))
                    magnitude = max(magnitude, abs(a[i]))
                }
                XCTAssertLessThan(worst, 2e-3 * magnitude + 1e-3, "\(name) step \(step)")
                XCTAssertEqual(a.indices.max { a[$0] < a[$1] }, b.indices.max { b[$0] < b[$1] }, "\(name) argmax step \(step)")
            }
            ran += 1
        }
        if ran == 0 { throw XCTSkip("Set ROACHNET_TEST_MODELS to run Metal parity tests.") }
        #else
        throw XCTSkip("Metal is not available on this platform.")
        #endif
    }

    /// Batched prefill must leave the same logits, KV cache and hidden states
    /// as one token at a time: across several 32-token tiles, a padded last
    /// group, and a batch that starts partway into the context.
    func testBatchedPrefillMatchesTokenByToken() throws {
        #if canImport(Metal)
        var ran = 0
        for name in ["stories15M-q4_0", "smollm2-135m-q8_0", "qwen2.5-0.5b-q4_k_m", "qwen3-0.6b-q8_0"] {
            guard let path = try? TestModels.path(name) else { continue }
            let model = try TransformerModel(path: path)
            let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)
            let tokens = model.tokenizer.encode(text).prefix(71).map { Int($0) }
            let sequential = try MetalBackend(model: model, contextLength: 128)
            let batched = try MetalBackend(model: model, contextLength: 128)
            XCTAssertGreaterThan(batched.maxBatch, 0, name)
            func compare(_ label: String) {
                let a = sequential.logits, b = batched.logits
                var worst: Float = 0, magnitude: Float = 1e-6
                for i in 0..<a.count {
                    worst = max(worst, abs(a[i] - b[i]))
                    magnitude = max(magnitude, abs(a[i]))
                }
                XCTAssertLessThan(worst, 2e-3 * magnitude + 1e-3, "\(name) \(label)")
                XCTAssertEqual(a.indices.max { a[$0] < a[$1] }, b.indices.max { b[$0] < b[$1] }, "\(name) argmax \(label)")
            }
            for (position, token) in tokens.enumerated() {
                sequential.forward(token: token, position: position, output: position == tokens.count - 1 ? .logits : .none)
            }
            // 9 tokens (two groups, one padded), then the remaining 62 in one pass.
            batched.forward(tokens: Array(tokens[0..<9]), position: 0, output: .none, each: nil)
            batched.forward(tokens: Array(tokens[9...]), position: 9, output: .logits, each: nil)
            compare("after prefill")
            // The cache it left behind must decode the next token the same way.
            let next = tokens[3]
            sequential.forward(token: next, position: tokens.count)
            batched.forward(token: next, position: tokens.count)
            compare("first decode step")

            var states: [[Float]] = []
            let fresh = try MetalBackend(model: model, contextLength: 128)
            fresh.forward(tokens: Array(tokens[0..<6]), position: 0, output: .none) { _, hidden in states.append(Array(hidden)) }
            let reference = try MetalBackend(model: model, contextLength: 128)
            for (position, token) in tokens[0..<6].enumerated() {
                reference.forward(token: token, position: position, output: .hidden)
                let expected = Array(reference.hiddenState)
                let worst = zip(expected, states[position]).map { abs($0 - $1) }.max() ?? 0
                XCTAssertLessThan(worst, 1e-2, "\(name) hidden state \(position)")
            }
            ran += 1
        }
        if ran == 0 { throw XCTSkip("Set ROACHNET_TEST_MODELS to run Metal parity tests.") }
        #else
        throw XCTSkip("Metal is not available on this platform.")
        #endif
    }
}
