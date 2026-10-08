import Foundation
import XCTest
@testable import RoachInference

final class TransformerParityTests: XCTestCase {
    struct Case: Decodable {
        let model: String
        let prompt: String
        let top: Int32
        let topLogit: Float
        let greedy: [Int32]
        let agree: Int
        let endsWithEOG: Bool?
    }
    struct Fixture: Decodable { let cases: [Case] }

    func testPromptLogitsAndGreedyContinuationsMatchReference() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: TestModels.fixture("forward-expected.json"))
        var ran = 0
        for item in fixture.cases {
            guard let path = try? TestModels.path(item.model) else { continue }
            let engine = try InferenceEngine(modelPath: path, contextLength: 256)
            let prompt = engine.tokenizer.encode(item.prompt)
            let logits = try engine.session.prefill(prompt)
            let best = logits.indices.max { logits[$0] < logits[$1] }!
            XCTAssertEqual(Int32(best), item.top, "\(item.model) top token for \(item.prompt.debugDescription)")
            XCTAssertEqual(logits[best], item.topLogit, accuracy: 0.002, "\(item.model) top logit vs float64 reference")

            var options = GenerationOptions()
            options.sampling = .greedy
            options.maxTokens = item.greedy.count + (item.endsWithEOG == true ? 1 : 0)
            engine.session.reset()
            let result = try engine.generate(tokens: prompt, options: options)
            XCTAssertEqual(Array(result.tokens.prefix(item.agree)), Array(item.greedy.prefix(item.agree)), "\(item.model) greedy continuation")
            if item.endsWithEOG == true { XCTAssertEqual(result.stopReason, .endOfGeneration) }
            ran += 1
        }
        if ran == 0 { throw XCTSkip("Set ROACHNET_TEST_MODELS to run model-backed tests.") }
    }

    func testPrefixReuseKeepsCachedTokens() throws {
        let engine = try InferenceEngine(modelPath: TestModels.path("stories15M-q4_0"), contextLength: 128)
        var options = GenerationOptions()
        options.sampling = .greedy
        options.maxTokens = 4
        let first = try engine.generate(prompt: "Once upon a time", options: options)
        let second = try engine.generate(prompt: "Once upon a time", options: options)
        XCTAssertEqual(first.tokens, second.tokens)
        XCTAssertEqual(second.reusedPromptTokens, 4)
    }

    func testStopSequencesTrimOutputAndStreamMatchesResult() throws {
        let engine = try InferenceEngine(modelPath: TestModels.path("stories15M-q4_0"), contextLength: 128)
        var options = GenerationOptions()
        options.sampling = .greedy
        options.maxTokens = 40
        options.stop = ["Lily"]
        var streamed = ""
        let result = try engine.generate(prompt: "Once upon a time", options: options) { streamed += $0 }
        XCTAssertEqual(result.stopReason, .stopSequence)
        XCTAssertEqual(result.text, ", there was a little girl named ")
        XCTAssertEqual(streamed, result.text)
    }

    func testSeededSamplingIsReproducible() throws {
        let engine = try InferenceEngine(modelPath: TestModels.path("stories15M-q4_0"), contextLength: 128)
        var options = GenerationOptions()
        options.sampling.temperature = 0.9
        options.sampling.seed = 42
        options.maxTokens = 24
        let a = try engine.generate(prompt: "Once upon a time", options: options)
        let b = try engine.generate(prompt: "Once upon a time", options: options)
        XCTAssertEqual(a.tokens, b.tokens)
    }
}
