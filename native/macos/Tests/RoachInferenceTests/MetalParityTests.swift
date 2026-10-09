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
}
