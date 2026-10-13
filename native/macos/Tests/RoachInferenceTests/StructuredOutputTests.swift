import Foundation
import XCTest
@testable import RoachInference

/// The constrained-sampling grammar, tool-call parsing and thinking split.
final class StructuredOutputTests: XCTestCase {
    private func accepts(_ constraint: JSONConstraint, _ text: String) -> Bool {
        for character in text {
            let piece = String(character)
            guard constraint.allows(piece) else { return false }
            constraint.accept(piece)
        }
        return true
    }

    func testAnyJSONAcceptsValidAndRefusesInvalid() {
        XCTAssertTrue(accepts(JSONConstraint(), #"{"a": [1, -2.5e3, true, null, "x\"y"]}"#))
        XCTAssertFalse(accepts(JSONConstraint(), #"{"a" 1}"#))
        XCTAssertFalse(accepts(JSONConstraint(), #"[1,,2]"#))
        XCTAssertFalse(accepts(JSONConstraint(), "tru e"))
    }

    func testObjectModeRequiresAnObject() {
        XCTAssertFalse(accepts(JSONConstraint(requireObject: true), "[1]"))
        let constraint = JSONConstraint(requireObject: true)
        XCTAssertTrue(accepts(constraint, #"{"ok": true}"#))
        XCTAssertTrue(constraint.isComplete)
    }

    func testSchemaHoldsKeysTypesAndRequiredFields() {
        let schema = JSONSchemaNode.object(properties: ["name": .string, "age": .number(integer: true), "tag": .literals([#""a""#, #""b""#])],
                                           order: ["name", "age", "tag"], required: ["name", "age"], additional: false)
        XCTAssertTrue(accepts(JSONConstraint(schema: schema), #"{"name": "Ro", "age": 3, "tag": "b"}"#))
        XCTAssertFalse(accepts(JSONConstraint(schema: schema), #"{"nope": 1}"#), "unknown keys are refused")
        XCTAssertFalse(accepts(JSONConstraint(schema: schema), #"{"name": "Ro", "age": 3.5}"#), "integers have no fraction")
        XCTAssertFalse(accepts(JSONConstraint(schema: schema), #"{"name": "Ro", "tag": "c"}"#), "enums hold")
        XCTAssertFalse(accepts(JSONConstraint(schema: schema), #"{"name": "Ro"}"#), "required keys must come before the end")
        let arrays = JSONSchemaNode.array(items: .boolean, minItems: 1, maxItems: 2)
        XCTAssertFalse(accepts(JSONConstraint(schema: arrays), "[]"))
        XCTAssertFalse(accepts(JSONConstraint(schema: arrays), "[true, false, true]"))
        XCTAssertTrue(accepts(JSONConstraint(schema: arrays), "[true, false]"))
    }

    func testUnionBranchesThatStartAlikeStayOpenUntilTheOutputDecides() {
        // Two object variants both open with `{`; the second key decides which one it is.
        let card = JSONSchemaNode.object(properties: ["kind": .literals([#""card""#]), "last4": .string], order: ["kind", "last4"],
                                         required: ["kind", "last4"], additional: false)
        let bank = JSONSchemaNode.object(properties: ["kind": .literals([#""bank""#]), "iban": .string], order: ["kind", "iban"],
                                         required: ["kind", "iban"], additional: false)
        let payment = JSONSchemaNode.union([card, bank])
        XCTAssertTrue(accepts(JSONConstraint(schema: payment), #"{"kind": "card", "last4": "4242"}"#))
        XCTAssertTrue(accepts(JSONConstraint(schema: payment), #"{"kind": "bank", "iban": "NL00"}"#), "the second variant is reachable")
        XCTAssertFalse(accepts(JSONConstraint(schema: payment), #"{"kind": "card", "iban": "NL00"}"#), "branches don't mix")
        let done = JSONConstraint(schema: payment)
        XCTAssertTrue(accepts(done, #"{"kind": "bank", "iban": "x"}"#))
        XCTAssertTrue(done.isComplete)

        // Strings and numbers in one union, and unions inside arrays.
        let mixed = JSONSchemaNode.array(items: .union([.number(integer: true), .string, .literals(["null"])]), minItems: 0, maxItems: nil)
        XCTAssertTrue(accepts(JSONConstraint(schema: mixed), #"[1, "two", null, 3]"#))
        XCTAssertFalse(accepts(JSONConstraint(schema: mixed), #"[1.5]"#))
        // Arrays of different item types both start with `[`.
        let lists = JSONSchemaNode.union([.array(items: .number(integer: true), minItems: 0, maxItems: nil), .array(items: .string, minItems: 0, maxItems: nil)])
        XCTAssertTrue(accepts(JSONConstraint(schema: lists), #"["a", "b"]"#))
        XCTAssertTrue(accepts(JSONConstraint(schema: lists), "[1, 2]"))
        XCTAssertFalse(accepts(JSONConstraint(schema: lists), #"[1, "b"]"#))
    }

    func testOpenReadingsBoundAddsBranchesAndKeepsEveryOneReachable() {
        let variant = { (kind: String) -> JSONSchemaNode in
            .object(properties: ["kind": .literals(["\"\(kind)\""]), "note": .union([.string, .null])],
                    order: ["kind", "note"], required: ["kind"], additional: false)
        }
        XCTAssertEqual(JSONConstraint.mostOpenReadings(.string), 1)
        XCTAssertEqual(JSONConstraint.mostOpenReadings(variant("a")), 2, "an object is inside one value at a time")
        XCTAssertEqual(JSONConstraint.mostOpenReadings(.union([variant("a"), variant("b"), .null])), 5, "a union's branches add up")
        XCTAssertEqual(JSONConstraint.mostOpenReadings(.array(items: .union([.string, .boolean]), minItems: 0, maxItems: nil)), 2)

        // As many object variants as are followed at once, all opening with `{"k`: the last stays reachable.
        let width = JSONConstraint.maxStates
        let many = JSONSchemaNode.union((0..<width).map { index -> JSONSchemaNode in
            .object(properties: ["k\(index)": .boolean], order: ["k\(index)"], required: ["k\(index)"], additional: false)
        })
        XCTAssertEqual(JSONConstraint.mostOpenReadings(many), width)
        XCTAssertTrue(accepts(JSONConstraint(schema: many), "{\"k\(width - 1)\": true}"), "the last branch is still open")
        XCTAssertTrue(accepts(JSONConstraint(schema: many), #"{"k0": false}"#))
    }

    /// A token can stop partway through a character. It may come only where a
    /// character that starts that way can come: otherwise no token can finish
    /// it, and the held bytes end the output as "�" (ROA-93).
    func testATokenStopsInsideACharacterOnlyWhereThatCharacterCanCome() {
        let lead: [UInt8] = [0xE2]      // the first of the three bytes of "“"
        let rest: [UInt8] = [0x80, 0x9C]
        let fresh = StreamingDecoder()
        let schema = JSONSchemaNode.object(properties: ["color": .string], order: ["color"], required: ["color"], additional: false)

        // Before the value: whitespace may come, a character it can't finish may not.
        let json = JSONConstraint(schema: schema)
        XCTAssertTrue(json.admits(Array("  ".utf8), after: fresh))
        XCTAssertFalse(json.admits(Array("  ".utf8) + lead, after: fresh))
        XCTAssertFalse(json.admits(lead, after: fresh))

        // Inside a string any character can come, in pieces too.
        json.accept("{\"color\": \"")
        XCTAssertTrue(json.admits(lead, after: fresh))
        XCTAssertTrue(json.admits(Array("red ".utf8) + lead, after: fresh))
        var held = StreamingDecoder()
        _ = held.append(lead)
        XCTAssertTrue(json.admits(rest, after: held))
        // Not once the string has closed, nor inside an escape, where only ASCII comes.
        XCTAssertFalse(json.admits(Array("red\"".utf8) + lead, after: fresh))
        XCTAssertFalse(json.admits(Array("red\"}".utf8) + lead, after: fresh))
        XCTAssertFalse(json.admits(Array("a\\".utf8) + lead, after: fresh))
        XCTAssertFalse(json.admits(Array("a\\u00".utf8) + lead, after: fresh))

        // In a fixed value or a known key, such a character can come where an option goes on with it.
        let e = Array("\u{E9}".utf8)    // "é": C3 A9
        let values = JSONConstraint(schema: .literals(["\"caf\u{E9}\"", #""cola""#]))
        values.accept("\"")
        XCTAssertTrue(values.admits(Array("caf".utf8) + [e[0]], after: fresh))
        XCTAssertFalse(values.admits(Array("co".utf8) + [e[0]], after: fresh))
        XCTAssertFalse(values.admits(lead, after: fresh), "no option goes on with that character")
        values.accept("caf")
        XCTAssertTrue(values.admits([e[0]], after: fresh))
        var heldE = StreamingDecoder()
        _ = heldE.append([e[0]])
        XCTAssertTrue(values.admits([e[1]] + Array("\"".utf8), after: heldE))
        let keys = JSONConstraint(schema: .object(properties: ["caf\u{E9}": .string], order: ["caf\u{E9}"], required: [], additional: false))
        keys.accept("{\"")
        XCTAssertTrue(keys.admits(Array("caf".utf8) + [e[0]], after: fresh))
        XCTAssertFalse(keys.admits(Array("x".utf8) + [e[0]], after: fresh))
    }

    func testCompleteValueEndsGeneration() {
        let constraint = JSONConstraint(schema: .number(integer: true))
        XCTAssertTrue(accepts(constraint, "42"))
        XCTAssertFalse(constraint.isComplete, "a number can go on")
        XCTAssertTrue(constraint.canEnd)

        // One fixed value that is the start of another (`1` among `1` and `10`) can still be the whole output.
        let values = JSONConstraint(schema: .literals(["1", "10"]))
        XCTAssertTrue(accepts(values, "1"))
        XCTAssertFalse(values.isComplete, "10 is still possible")
        XCTAssertTrue(values.canEnd)
        let partial = JSONConstraint(schema: .literals([#""ab""#, #""abc""#]))
        XCTAssertTrue(accepts(partial, #""a"#))
        XCTAssertFalse(partial.canEnd, "\"a is not one of the values")
    }

    func testToolCallsParseInEachFamilysFormat() {
        let qwen = ChatTools.parse("Let me check.\n<tool_call>\n{\"name\": \"weather\", \"arguments\": {\"city\": \"Oslo\"}}\n</tool_call>", known: ["weather"])
        XCTAssertEqual(qwen.content, "Let me check.")
        XCTAssertEqual(qwen.calls.map(\.name), ["weather"])
        XCTAssertEqual(qwen.calls.first?.arguments, #"{"city":"Oslo"}"#)

        let llama = ChatTools.parse(#"{"name": "weather", "parameters": {"city": "Rome"}}"#, known: ["weather"])
        XCTAssertEqual(llama.content, "")
        XCTAssertEqual(llama.calls.first?.arguments, #"{"city":"Rome"}"#)

        let mistral = ChatTools.parse(#"[TOOL_CALLS] [{"name": "a", "arguments": {}}, {"name": "b", "arguments": {"x": 1}}]"#, known: [])
        XCTAssertEqual(mistral.calls.map(\.name), ["a", "b"])
        let bare = ChatTools.parse(#"[{"name": "a", "arguments": {}}]"#, known: ["a"])
        XCTAssertEqual(bare.calls.map(\.name), ["a"], "Mistral's control token renders as nothing")

        let unknown = ChatTools.parse("<tool_call>{\"name\": \"rm\", \"arguments\": {}}</tool_call>", known: ["weather"])
        XCTAssertTrue(unknown.calls.isEmpty, "only the tools the client offered")
        let plainJSON = ChatTools.parse(#"{"answer": 4}"#, known: ["weather"])
        XCTAssertTrue(plainJSON.calls.isEmpty)
        XCTAssertEqual(plainJSON.content, #"{"answer": 4}"#)
    }

    func testThinkingSplitsAcrossPieces() {
        var splitter = ThinkingSplitter()
        var parts: [ThinkingSplitter.Part] = []
        for piece in ["<thi", "nk>\nHmm", " ok</th", "ink>\n\nHello", " there"] { parts += splitter.feed(piece) }
        parts += splitter.finish()
        let thinking = parts.compactMap { if case .thinking(let t) = $0 { return t } else { return nil } }.joined()
        let content = parts.compactMap { if case .content(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertEqual(thinking, "\nHmm ok")
        XCTAssertEqual(content, "Hello there")

        var plain = ThinkingSplitter()
        XCTAssertEqual(plain.feed("Hi") + plain.finish(), [.content("Hi")])
    }

    func testChatMLToolsAndThinkingSwitch() {
        let tools = [ToolSpec(name: "weather", description: "Weather now", parameters: #"{"type":"object","properties":{"city":{"type":"string"}}}"#)]
        let messages = [RichMessage(role: .user, content: "Oslo?"),
                        RichMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "weather", arguments: #"{"city":"Oslo"}"#)]),
                        RichMessage(role: .tool, content: "4C", toolName: "weather")]
        let prompt = ChatTools.render(.chatML, messages: messages, tools: tools, defaultSystem: nil, think: false, supportsThinking: true)
        XCTAssertTrue(prompt.contains("<tools>\n{\"type\": \"function\""))
        XCTAssertTrue(prompt.contains("<tool_call>\n{\"name\": \"weather\", \"arguments\": {\"city\":\"Oslo\"}}\n</tool_call>"))
        XCTAssertTrue(prompt.contains("<tool_response>\n4C\n</tool_response>"))
        XCTAssertTrue(prompt.hasSuffix("<think>\n\n</think>\n\n"))
        XCTAssertTrue(InferenceEngine.thinks(templateSource: "{%- if enable_thinking is defined %}"))
        XCTAssertFalse(InferenceEngine.thinks(templateSource: "{{ messages }}"))
    }
}

final class FootprintTests: XCTestCase {
    func testFootprintFromMetadataAlone() throws {
        let file = try GGUFFile(path: TestModels.path("stories15M-q4_0"))
        let footprint = try ModelFootprint(file: file, contextLength: 128)
        XCTAssertEqual(footprint.weights, file.fileSize)
        XCTAssertEqual(footprint.context, 128)
        XCTAssertEqual(footprint.cache, footprint.cachePerToken * 128)
        XCTAssertGreaterThan(footprint.scratch, 0)
        XCTAssertEqual(footprint.with(context: 64).cache * 2, footprint.cache)
        XCTAssertEqual(try ModelFootprint(file: file, contextLength: 128, cacheType: .f32).cache,
                       try ModelFootprint(file: file, contextLength: 128, cacheType: .f16).cache * 2, "a half cache takes half the memory")
        XCTAssertEqual(try ModelFootprint(file: file, contextLength: 1 << 20).context, footprint.trainedContext, "never past the trained context")
    }
}
