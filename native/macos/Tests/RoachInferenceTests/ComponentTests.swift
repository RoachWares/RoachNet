import Foundation
import XCTest
@testable import RoachInference

final class ComponentTests: XCTestCase {
    func testHalfPrecisionConversions() {
        XCTAssertEqual(halfToFloat(0x3C00), 1)
        XCTAssertEqual(halfToFloat(0xC000), -2)
        XCTAssertEqual(halfToFloat(0x0000), 0)
        XCTAssertEqual(halfToFloat(0x7BFF), 65504)
        XCTAssertEqual(halfToFloat(0x0001), 5.960_464_5e-8, accuracy: 1e-12)
        XCTAssertEqual(halfToFloat(floatToHalf(0.333_333)), 0.333_251_95, accuracy: 1e-6)
    }

    func testQ8_0BlockDequantizesAndDots() {
        var block = [UInt8](repeating: 0, count: 34)
        let d = floatToHalf(0.5)
        block[0] = UInt8(d & 0xFF); block[1] = UInt8(d >> 8)
        for j in 0..<32 { block[2 + j] = UInt8(bitPattern: Int8(j - 16)) }
        var out = [Float](repeating: 0, count: 32)
        block.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { Quantization.dequantizeBlock(.q8_0, raw.baseAddress!, $0.baseAddress!) }
        }
        XCTAssertEqual(out[0], -8)
        XCTAssertEqual(out[31], 7.5)
        let x = [Float](repeating: 1, count: 32)
        let dot = block.withUnsafeBytes { raw in x.withUnsafeBufferPointer { Quantization.dot(.q8_0, raw.baseAddress!, $0.baseAddress!, count: 32) } }
        XCTAssertEqual(dot, out.reduce(0, +), accuracy: 1e-4)
    }

    func testQ4_0FastDotMatchesDequantizedDot() {
        var block = [UInt8](repeating: 0, count: 18 * 2)
        for b in 0..<2 {
            let d = floatToHalf(Float(b + 1) * 0.25)
            block[b * 18] = UInt8(d & 0xFF); block[b * 18 + 1] = UInt8(d >> 8)
            for j in 0..<16 { block[b * 18 + 2 + j] = UInt8((j * 7 + b) & 0xFF) }
        }
        let x = (0..<64).map { Float($0 % 7) - 3 }
        var dense = [Float](repeating: 0, count: 64)
        block.withUnsafeBytes { raw in dense.withUnsafeMutableBufferPointer { Quantization.dequantize(.q4_0, raw.baseAddress!, count: 64, into: $0.baseAddress!) } }
        let expected = zip(dense, x).map(*).reduce(0, +)
        let fast = block.withUnsafeBytes { raw in x.withUnsafeBufferPointer { Quantization.dot(.q4_0, raw.baseAddress!, $0.baseAddress!, count: 64) } }
        XCTAssertEqual(fast, expected, accuracy: 1e-4)
    }

    func testSamplerFiltersAndGreedy() {
        var sampler = Sampler(options: .greedy)
        XCTAssertEqual(sampler.sample([0.1, 3, 0.2], history: []), 1)
        var options = SamplingOptions()
        options.topK = 1
        options.seed = 7
        sampler = Sampler(options: options)
        for _ in 0..<20 { XCTAssertEqual(sampler.sample([0.1, 0.2, 5, 0.3], history: []), 2) }
        // Repetition penalty pushes the repeated token below the runner-up.
        options = .greedy
        options.repeatPenalty = 4
        sampler = Sampler(options: options)
        XCTAssertEqual(sampler.sample([1, 3, 2], history: [1]), 2)
    }

    func testPartialSortKeepsBest() {
        let values = [5, 1, 9, 3, 7, 2, 8]
        XCTAssertEqual(Array(values.partialSorted(by: >, limit: 3)), [9, 8, 7])
    }

    func testStreamingDecoderHoldsIncompleteSequences() {
        var decoder = StreamingDecoder()
        let bytes = Array("é🐛".utf8)
        XCTAssertEqual(decoder.append([bytes[0]]), "")
        XCTAssertEqual(decoder.append([bytes[1], bytes[2]]), "é")
        XCTAssertEqual(decoder.append(Array(bytes[3...])), "🐛")
        XCTAssertEqual(decoder.flush(), "")
    }

    func testChatTemplatesRender() {
        let messages = [ChatMessage(role: .user, content: "Hi")]
        XCTAssertEqual(ChatTemplate.chatML.render(messages, defaultSystem: "Be kind."),
                       "<|im_start|>system\nBe kind.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertEqual(ChatTemplate.llama3.render(messages),
                       "<|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n")
        XCTAssertEqual(ChatTemplate.mistral.render([ChatMessage(role: .system, content: "S"), ChatMessage(role: .user, content: "Hi")]), "[INST] S\n\nHi [/INST]")
        let qwen = "{%- else %}{{- '<|im_start|>system\\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\\n' }}"
        XCTAssertEqual(ChatTemplate.defaultSystemPrompt(in: qwen), "You are Qwen, created by Alibaba Cloud. You are a helpful assistant.")
    }
}
