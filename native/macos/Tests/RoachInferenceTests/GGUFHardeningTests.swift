import Foundation
import XCTest
@testable import RoachInference

/// A GGUF can come from any URL or import, so every number in it is checked
/// before it is used: a broken or hostile file is refused, never a crash.
final class GGUFHardeningTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-gguf-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Writes GGUF v3 bytes field by field.
    struct Builder {
        var data = Data()
        mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ value: String) { u64(UInt64(value.utf8.count)); data.append(contentsOf: Array(value.utf8)) }
        mutating func header(tensors: UInt64, kvs: UInt64) { u32(0x4655_4747); u32(3); u64(tensors); u64(kvs) }
        mutating func kvString(_ key: String, _ value: String) { string(key); u32(8); string(value) }
        mutating func kvU32(_ key: String, _ value: UInt32) { string(key); u32(4); u32(value) }
        mutating func kvU64(_ key: String, _ value: UInt64) { string(key); u32(10); u64(value) }
        mutating func pad(to size: Int) { while data.count < size { data.append(0) } }
    }

    private func file(_ builder: Builder, padding: Int = 4_096) throws -> String {
        var builder = builder
        builder.pad(to: builder.data.count + padding)
        let path = root + "/model-\(UUID().uuidString).gguf"
        try builder.data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func assertRefused(_ builder: Builder, _ label: String, file line: UInt = #line) throws {
        let path = try file(builder)
        XCTAssertThrowsError(try GGUFFile(path: path), label, line: line)
    }

    func testOutOfRangeCountsAreRefused() throws {
        var tensors = Builder(); tensors.header(tensors: .max, kvs: 0)
        try assertRefused(tensors, "tensor count past Int")
        var kvs = Builder(); kvs.header(tensors: 0, kvs: 1 << 63)
        try assertRefused(kvs, "metadata count past Int")
        var key = Builder(); key.header(tensors: 0, kvs: 1); key.u64(.max)
        try assertRefused(key, "a key longer than the file")
        var array = Builder(); array.header(tensors: 0, kvs: 1); array.string("a"); array.u32(9); array.u32(4); array.u64(1 << 62)
        try assertRefused(array, "an array longer than the file")
    }

    func testDeeplyNestedArraysAreRefused() throws {
        var nested = Builder(); nested.header(tensors: 0, kvs: 1); nested.string("deep"); nested.u32(9)
        for _ in 0..<6 { nested.u32(9); nested.u64(1) }
        nested.u32(4); nested.u64(1); nested.u32(7)
        let path = try file(nested)
        XCTAssertThrowsError(try GGUFFile(path: path)) { XCTAssertTrue("\($0)".contains("nest"), "\($0)") }
    }

    func testTensorShapesAndOffsetsAreBoundsChecked() throws {
        func tensorFile(dims: [UInt64], offset: UInt64) -> Builder {
            var builder = Builder(); builder.header(tensors: 1, kvs: 1); builder.kvString("general.architecture", "llama")
            builder.string("w"); builder.u32(UInt32(dims.count)); for dim in dims { builder.u64(dim) }
            builder.u32(0); builder.u64(offset)
            return builder
        }
        try assertRefused(tensorFile(dims: [1 << 62], offset: 0), "a dimension past any model")
        try assertRefused(tensorFile(dims: [1 << 40, 1 << 40], offset: 0), "a shape whose product overflows")
        try assertRefused(tensorFile(dims: [16], offset: .max), "an offset past Int")
        try assertRefused(tensorFile(dims: [16], offset: 1 << 40), "an offset past the file")
        try assertRefused(tensorFile(dims: [1 << 20, 1 << 10], offset: 0), "data past the end of the file")
        XCTAssertNoThrow(try GGUFFile(path: try file(tensorFile(dims: [16], offset: 0))), "a small tensor inside the file loads")
        XCTAssertNil(GGUFTensorInfo.checkedByteCount(shape: [1 << 40, 1 << 40], type: .f32))
        XCTAssertEqual(GGUFTensorInfo.checkedByteCount(shape: [32, 2], type: .q8_0), 68)
    }

    func testImplausibleHyperparametersAreRefusedBeforeAnyArithmetic() throws {
        func model(_ overrides: [String: UInt32]) throws -> GGUFFile {
            var values: [String: UInt32] = ["embedding_length": 64, "block_count": 1, "feed_forward_length": 128,
                                            "attention.head_count": 4, "context_length": 256]
            for (key, value) in overrides { values[key] = value }
            var builder = Builder(); builder.header(tensors: 0, kvs: UInt64(values.count + 1))
            builder.kvString("general.architecture", "llama")
            for (key, value) in values.sorted(by: { $0.key < $1.key }) { builder.kvU32("llama.\(key)", value) }
            return try GGUFFile(path: try file(builder))
        }
        XCTAssertNoThrow(try ModelHyperparameters(gguf: try model([:]), vocabularySize: 100))
        for (key, value) in [("attention.head_count", UInt32(0)), ("attention.head_count_kv", 0), ("embedding_length", .max),
                             ("block_count", 100_000), ("context_length", 0)] {
            XCTAssertThrowsError(try ModelHyperparameters(gguf: try model([key: value]), vocabularySize: 100), key) { error in
                XCTAssertTrue("\(error)".contains("Implausible"), "\(key): \(error)")
            }
        }
    }

    func testLlama3RopeScalingMatchesTheReference() {
        let scaling = Llama3RopeScaling(factor: 8, lowFrequencyFactor: 1, highFrequencyFactor: 4, originalContext: 8_192)
        XCTAssertEqual(scaling.divisor(forInverseFrequency: 1), 1, "short wavelengths are kept")
        XCTAssertEqual(scaling.divisor(forInverseFrequency: 2 * .pi / 10_000), 8, "long wavelengths are divided by the factor")
        XCTAssertEqual(scaling.divisor(forInverseFrequency: 2 * .pi / 4_096), 2.4, accuracy: 1e-9, "the band between is blended")
    }
}
