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
            // FP32 keys and values match the reference to rounding; the
            // default half cache stays within FP16 rounding of it.
            for cache in [KVCacheType.f32, .f16] {
                let metal = try MetalBackend(model: model, contextLength: 64, cacheType: cache)
                let cpu = CPUBackend(model: model, contextLength: 64)
                let tolerance: Float = cache == .f32 ? 2e-3 : 1e-2
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
                    XCTAssertLessThan(worst, tolerance * magnitude + 1e-3, "\(name) \(cache) position \(position)")
                    let top = a.indices.max { a[$0] < a[$1] }!, chosen = b.indices.max { b[$0] < b[$1] }!
                    if cache == .f32 {
                        XCTAssertEqual(top, chosen, "\(name) \(cache) argmax at \(position)")
                    } else {
                        // FP16 rounding may only swap tokens the reference itself scores as a near-tie.
                        XCTAssertGreaterThanOrEqual(a[chosen], a[top] - (tolerance * magnitude + 1e-3), "\(name) \(cache) argmax at \(position)")
                    }
                }
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

    /// Request slots: a sibling shares weights and kernels but not the cache,
    /// and a prefix copied from another slot decodes exactly as if computed.
    func testSiblingSlotsKeepTheirOwnCacheAndAdoptPrefixes() throws {
        #if canImport(Metal)
        var ran = 0
        for name in ["smollm2-135m-q8_0", "qwen3-0.6b-q8_0"] {
            guard let path = try? TestModels.path(name) else { continue }
            let model = try TransformerModel(path: path)
            let first = InferenceSession(model: model, contextLength: 256)
            guard first.backend is MetalBackend, let second = first.sibling() else { continue }
            XCTAssertTrue(second.backend is MetalBackend, name)
            XCTAssertFalse(first.backend === second.backend, name)
            let shared = model.tokenizer.encode(String(repeating: "A system prompt every agent shares. ", count: 4))
            let tailA = model.tokenizer.encode(" Question one: what is two plus two?", addSpecial: false, parseSpecial: false)
            let tailB = model.tokenizer.encode(" Question two: name a colour.", addSpecial: false, parseSpecial: false)

            let expectedB = try InferenceSession(model: model, contextLength: 256).prefill(shared + tailB)
            _ = try first.prefill(shared + tailA)
            XCTAssertTrue(second.adoptPrefix(of: first, count: shared.count), name)
            XCTAssertEqual(second.cachedTokens, shared, name)
            let gotB = try second.prefill(shared + tailB)
            var worst: Float = 0, magnitude: Float = 1e-6
            for i in 0..<expectedB.count {
                worst = max(worst, abs(expectedB[i] - gotB[i]))
                magnitude = max(magnitude, abs(expectedB[i]))
            }
            XCTAssertLessThan(worst, 2e-3 * magnitude + 1e-3, "\(name): an adopted prefix decodes like a computed one")
            // The first slot's own conversation is untouched by the second's.
            let againA = try first.prefill(shared + tailA)
            let freshA = try InferenceSession(model: model, contextLength: 256).prefill(shared + tailA)
            XCTAssertEqual(againA.indices.max { againA[$0] < againA[$1] }, freshA.indices.max { freshA[$0] < freshA[$1] }, name)
            XCTAssertFalse(second.adoptPrefix(of: InferenceSession(model: try TransformerModel(path: path), contextLength: 256), count: 4),
                           "only sessions over the same loaded model share caches")
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
            // At full precision (FP32 cache and prompt tiles) both paths agree
            // to rounding. By default (FP16 cache, FP16 weight tiles in the
            // prompt products) they agree to FP16 rounding.
            for (cache, matmul) in [(KVCacheType.f32, "float"), (.f16, "")] {
                setenv("ROACHNET_METAL_MATMUL", matmul, 1)
                defer { unsetenv("ROACHNET_METAL_MATMUL") }
                let label = "\(name) \(cache)"
                let tolerance: Float = cache == .f32 ? 2e-3 : 1e-2
                let sequential = try MetalBackend(model: model, contextLength: 128, cacheType: cache)
                let batched = try MetalBackend(model: model, contextLength: 128, cacheType: cache)
                XCTAssertGreaterThan(batched.maxBatch, 0, label)
                func compare(_ step: String) {
                    let a = sequential.logits, b = batched.logits
                    var worst: Float = 0, magnitude: Float = 1e-6
                    for i in 0..<a.count {
                        worst = max(worst, abs(a[i] - b[i]))
                        magnitude = max(magnitude, abs(a[i]))
                    }
                    XCTAssertLessThan(worst, tolerance * magnitude + 1e-3, "\(label) \(step)")
                    let top = a.indices.max { a[$0] < a[$1] }!, chosen = b.indices.max { b[$0] < b[$1] }!
                    XCTAssertGreaterThanOrEqual(a[chosen], a[top] - (cache == .f32 ? 0 : tolerance * magnitude + 1e-3), "\(label) argmax \(step)")
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
                let fresh = try MetalBackend(model: model, contextLength: 128, cacheType: cache)
                fresh.forward(tokens: Array(tokens[0..<6]), position: 0, output: .none) { _, hidden in states.append(Array(hidden)) }
                let reference = try MetalBackend(model: model, contextLength: 128, cacheType: cache)
                for (position, token) in tokens[0..<6].enumerated() {
                    reference.forward(token: token, position: position, output: .hidden)
                    let expected = Array(reference.hiddenState)
                    let worst = zip(expected, states[position]).map { abs($0 - $1) }.max() ?? 0
                    let magnitude = expected.map(abs).max() ?? 0
                    XCTAssertLessThan(worst, cache == .f32 ? 1e-2 : 2e-2 + 5e-3 * magnitude, "\(label) hidden state \(position)")
                }
            }
            ran += 1
        }
        if ran == 0 { throw XCTSkip("Set ROACHNET_TEST_MODELS to run Metal parity tests.") }
        #else
        throw XCTSkip("Metal is not available on this platform.")
        #endif
    }
}
