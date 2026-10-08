import Foundation
import XCTest
@testable import RoachInference

/// Model-backed tests. Point ROACHNET_TEST_MODELS at a folder holding the
/// reference GGUF files (see docs/NATIVE_INFERENCE.md); they skip otherwise.
enum TestModels {
    static var directory: String? {
        guard let path = ProcessInfo.processInfo.environment["ROACHNET_TEST_MODELS"], !path.isEmpty else { return nil }
        return path
    }

    static func path(_ name: String) throws -> String {
        guard let directory else { throw XCTSkip("Set ROACHNET_TEST_MODELS to run model-backed tests.") }
        let path = (directory as NSString).appendingPathComponent(name + ".gguf")
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Missing test model \(name).gguf") }
        return path
    }

    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}

final class TokenizerParityTests: XCTestCase {
    struct Expected: Decodable {
        let corpus: [String]
        let expected: [String: [[Int32]]]
    }

    func check(_ model: String) throws {
        let fixture = try JSONDecoder().decode(Expected.self, from: TestModels.fixture("tokenize-expected.json"))
        let tokenizer = try Tokenizer(gguf: GGUFFile(path: TestModels.path(model)))
        let expected = try XCTUnwrap(fixture.expected[model])
        for (text, ids) in zip(fixture.corpus, expected) {
            XCTAssertEqual(tokenizer.encode(text, addSpecial: true, parseSpecial: true), ids, "\(model): \(text.debugDescription)")
            // Round trip (skip the leading BOS / prefix-space convention).
            if !text.isEmpty, tokenizer.model == .bytePairEncoding {
                XCTAssertEqual(tokenizer.decode(ids, special: true), text, "\(model) decode: \(text.debugDescription)")
            }
        }
    }

    func testSentencePieceMatchesReference() throws { try check("stories15M-q4_0") }
    func testSmolLMBytePairMatchesReference() throws { try check("smollm2-135m-q8_0") }
    func testQwen2BytePairMatchesReference() throws { try check("qwen2.5-0.5b-q4_k_m") }
}
