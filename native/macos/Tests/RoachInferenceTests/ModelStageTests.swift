import Foundation
import XCTest
@testable import RoachInference

/// A model split into stages (RoachNet Cluster) must compute exactly what the
/// whole model computes: stages cut into shard files, chained residual stream
/// to residual stream, token by token and in batched passes.
final class ModelStageTests: XCTestCase {
    func testStageDescriptionRoundTripsAndPicksTensors() {
        let stage = ModelStage(layers: 3..<9, embedding: false, head: true)
        XCTAssertEqual(stage.description, "3-9,head")
        XCTAssertEqual(ModelStage("3-9,head"), stage)
        XCTAssertNil(ModelStage("9-3"))
        XCTAssertTrue(stage.includes(tensor: "blk.3.attn_q.weight", tiedOutput: false))
        XCTAssertFalse(stage.includes(tensor: "blk.9.attn_q.weight", tiedOutput: false))
        XCTAssertFalse(stage.includes(tensor: "blk.30.ffn_up.weight", tiedOutput: false), "blk.3 is not blk.30")
        XCTAssertFalse(stage.includes(tensor: "token_embd.weight", tiedOutput: false))
        XCTAssertTrue(stage.includes(tensor: "token_embd.weight", tiedOutput: true), "a tied head projects with the embedding")
        XCTAssertTrue(stage.includes(tensor: "rope_freqs.weight", tiedOutput: false))
    }

    func testShardedStagesMatchTheWholeModel() throws {
        #if canImport(Metal)
        var ran = 0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rn-stages-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in ["smollm2-135m-q8_0", "qwen3-0.6b-q8_0"] {
            guard let path = try? TestModels.path(name) else { continue }
            let file = try GGUFFile(path: path)
            let whole = try MetalBackend(model: TransformerModel(file: file), contextLength: 128)
            let layers = whole.model.layers.count
            let cuts = [layers / 3, 2 * layers / 3]
            // The first stage reads the original file; the others open their own shard files.
            let first = try MetalBackend(model: TransformerModel(file: file, stage: ModelStage(layers: 0..<cuts[0], embedding: true, head: true)), contextLength: 128)
            var rest: [MetalBackend] = []
            for range in [cuts[0]..<cuts[1], cuts[1]..<layers] {
                let stage = ModelStage(layers: range, embedding: false, head: false)
                let shard = "\(folder)/\(name)-\(range.lowerBound).gguf"
                let written = try GGUFShard.write(file, stage: stage, to: shard)
                XCTAssertEqual(written, GGUFShard.size(of: file, stage: stage))
                XCTAssertLessThan(written, file.fileSize)
                let model = try TransformerModel(path: shard)
                XCTAssertEqual(model.stage, stage, "the stage comes from the shard's metadata")
                XCTAssertEqual(try ModelFootprint(file: GGUFFile(path: shard), contextLength: 128, stage: stage).weights,
                               try ModelFootprint(file: file, contextLength: 128, stage: stage).weights)
                rest.append(try XCTUnwrap(MetalBackend.makeVerified(model: model, contextLength: 128)))
            }
            func compare(_ label: String) {
                let a = whole.logits, b = first.logits
                var worst: Float = 0, magnitude: Float = 1e-6
                for i in 0..<a.count {
                    worst = max(worst, abs(a[i] - b[i]))
                    magnitude = max(magnitude, abs(a[i]))
                }
                XCTAssertLessThan(worst, 1e-4 * magnitude + 1e-4, "\(name) \(label)")
            }
            let tokens = whole.model.tokenizer.encode("The quick brown fox jumps over the lazy dog, twice over.").map { Int($0) }

            // A batched prompt through the pipeline.
            whole.forward(tokens: tokens, position: 0, output: .logits, each: nil)
            first.forward(tokens: tokens, position: 0, output: .none, each: nil)
            var residuals = first.batchResiduals(count: tokens.count)
            for stage in rest {
                residuals.withUnsafeBufferPointer { stage.forward(residuals: $0.baseAddress!, count: tokens.count, position: 0, output: .none, each: nil) }
                residuals = stage.batchResiduals(count: tokens.count)
            }
            let width = whole.model.hyperparameters.embeddingLength
            Array(residuals.suffix(width)).withUnsafeBufferPointer { first.applyHead(residual: $0.baseAddress!, output: .logits) }
            compare("after a batched prompt")

            // Then decode steps, one residual stream per hop.
            for (step, token) in tokens.prefix(3).enumerated() {
                let position = tokens.count + step
                whole.forward(token: token, position: position)
                first.forward(token: token, position: position, output: .none)
                var residual = Array(first.residualState)
                for stage in rest {
                    residual.withUnsafeBufferPointer { stage.forward(residual: $0.baseAddress!, position: position, output: .none) }
                    residual = Array(stage.residualState)
                }
                residual.withUnsafeBufferPointer { first.applyHead(residual: $0.baseAddress!, output: .logits) }
                compare("decode step \(step)")
            }
            ran += 1
        }
        if ran == 0 { throw XCTSkip("Set ROACHNET_TEST_MODELS to run stage tests.") }
        #else
        throw XCTSkip("Metal is not available on this platform.")
        #endif
    }
}
