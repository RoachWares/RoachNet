import Foundation
import XCTest
import RoachInference
@testable import RoachNetRuntime

/// Request parsing and reply plumbing shared by every model API.
final class ModelAPITests: XCTestCase {
    func testToolGateNeverStreamsHalfACall() {
        var gate = ToolGate(active: true, template: .chatML)
        var shown = ""
        for piece in ["Checking", " now.", "\n<tool", "_call>\n{\"name\"", ": \"x\"}"] { shown += gate.feed(piece) }
        XCTAssertEqual(shown, "Checking now.\n")
        XCTAssertEqual(gate.remainder(final: "Checking now."), "")

        var llama = ToolGate(active: true, template: .llama3)
        XCTAssertEqual(llama.feed("  "), "")
        XCTAssertEqual(llama.feed("{\"name\""), "", "a bare call is held from its first brace")
        XCTAssertEqual(llama.remainder(final: "{\"answer\": 1}"), "{\"answer\": 1}", "and released when it was not a call")

        var off = ToolGate(active: false, template: .chatML)
        XCTAssertEqual(off.feed("<tool_call>"), "<tool_call>")
    }

    func testModelfileParses() throws {
        let parsed = try Modelfile.parse("""
        # a comment
        FROM qwen3:0.6b
        SYSTEM \"\"\"You are terse.
        Very terse.\"\"\"
        PARAMETER temperature 0.2
        PARAMETER stop "<|im_end|>"
        PARAMETER stop END
        PARAMETER num_ctx 8192
        MESSAGE user Hi
        MESSAGE assistant \"\"\"Hello.\"\"\"
        """)
        XCTAssertEqual(parsed.from, "qwen3:0.6b")
        XCTAssertEqual(parsed.system, "You are terse.\nVery terse.")
        XCTAssertEqual(parsed.parameters["temperature"].numberValue, 0.2)
        XCTAssertEqual(parsed.parameters["num_ctx"].numberValue, 8192)
        XCTAssertEqual(parsed.parameters["stop"].array.compactMap(\.stringValue), ["<|im_end|>", "END"])
        XCTAssertEqual(parsed.messages.map { $0["content"].stringValue ?? "" }, ["Hi", "Hello."])
        XCTAssertThrowsError(try Modelfile.parse("ADAPTER ./lora.gguf"))
        XCTAssertThrowsError(try Modelfile.parse("FROBNICATE yes"))
    }

    func testOpenAIRequestKeepsToolsChoiceAndSchema() throws {
        let body = try JSON.parse(#"""
        {"model": "m", "stream": true, "stream_options": {"include_usage": true},
         "messages": [{"role": "developer", "content": "Be brief"},
                      {"role": "user", "content": [{"type": "text", "text": "Oslo?"}]},
                      {"role": "assistant", "content": null, "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "weather", "arguments": "{\"city\":\"Oslo\"}"}}]},
                      {"role": "tool", "tool_call_id": "c1", "content": "4C"}],
         "tools": [{"type": "function", "function": {"name": "weather", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}}}],
         "tool_choice": {"type": "function", "function": {"name": "weather"}},
         "response_format": {"type": "json_schema", "json_schema": {"name": "r", "schema": {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}}},
         "reasoning_effort": "none", "max_completion_tokens": 64}
        """#)
        let request = try ModelRequest.openAIChat(body)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(request.messages[1].content, "Oslo?")
        XCTAssertEqual(request.messages[2].toolCalls.first?.arguments, #"{"city":"Oslo"}"#)
        XCTAssertEqual(request.toolChoice, .named("weather"))
        XCTAssertEqual(request.think, false)
        XCTAssertEqual(request.options["num_predict"].numberValue, 64)
        XCTAssertTrue(request.stream && request.includeUsage)
        XCTAssertEqual(request.format, .schema(.object(properties: ["ok": .boolean], order: ["ok"], required: ["ok"], additional: false)))
    }

    func testCompletionsTakeOnePromptAndRefuseBatches() throws {
        XCTAssertEqual(try ModelRequest.openAICompletions(["model": "m", "prompt": "Once upon"]).rawPrompt, "Once upon")
        XCTAssertEqual(try ModelRequest.openAICompletions(["model": "m", "prompt": ["Once upon"]]).rawPrompt, "Once upon")
        XCTAssertEqual(try ModelRequest.openAICompletions(["model": "m"]).rawPrompt, "")
        for prompt: JSON in [["a", "b"], [1, 2, 3], [[1, 2, 3]]] {
            XCTAssertThrowsError(try ModelRequest.openAICompletions(["model": "m", "prompt": prompt]), "\(prompt)") { error in
                XCTAssertEqual((error as? RuntimeError)?.statusCode, 400)
            }
        }
    }

    func testAnthropicAndResponsesInputsBecomeTurns() throws {
        let anthropic = try ModelRequest.anthropicMessages(JSON.parse(#"""
        {"model": "m", "max_tokens": 50, "system": [{"type": "text", "text": "Sys"}],
         "messages": [{"role": "user", "content": "Oslo?"},
                      {"role": "assistant", "content": [{"type": "text", "text": "Checking."}, {"type": "tool_use", "id": "t1", "name": "weather", "input": {"city": "Oslo"}}]},
                      {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "4C"}]}]}],
         "tools": [{"name": "weather", "input_schema": {"type": "object"}}], "tool_choice": {"type": "any"}, "thinking": {"type": "enabled", "budget_tokens": 1024}}
        """#))
        XCTAssertEqual(anthropic.messages.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(anthropic.messages[3].toolName, "weather")
        XCTAssertEqual(anthropic.messages[3].content, "4C")
        XCTAssertEqual(anthropic.toolChoice, .required)
        XCTAssertEqual(anthropic.think, true)
        XCTAssertEqual(anthropic.options["num_predict"].numberValue, 50)

        let responses = try ModelRequest.responses(JSON.parse(#"""
        {"model": "m", "instructions": "Sys", "input": [{"role": "user", "content": [{"type": "input_text", "text": "Oslo?"}]},
          {"type": "function_call", "call_id": "c9", "name": "weather", "arguments": "{}"},
          {"type": "function_call_output", "call_id": "c9", "output": "4C"}],
         "tools": [{"type": "function", "name": "weather", "parameters": {"type": "object"}}],
         "text": {"format": {"type": "json_object"}}, "max_output_tokens": 20}
        """#))
        XCTAssertEqual(responses.messages.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(responses.messages[3].toolName, "weather")
        XCTAssertEqual(responses.tools.map(\.name), ["weather"])
        XCTAssertEqual(responses.format, .json)
    }

    func testSchemaConversionFollowsRefsAndUnions() throws {
        let node = try ModelRequest.schema(JSON.parse(#"""
        {"$defs": {"Color": {"enum": ["red", "blue"]}},
         "type": "object", "properties": {"color": {"$ref": "#/$defs/Color"}, "n": {"type": ["integer", "null"]}, "free": {"type": "object"}},
         "required": ["color"]}
        """#))
        guard case .object(let properties, _, let required, let additional) = node else { return XCTFail("not an object") }
        XCTAssertEqual(properties["color"], .literals([#""red""#, #""blue""#]))
        XCTAssertEqual(properties["n"], .union([.number(integer: true), .null]))
        XCTAssertEqual(properties["free"], .object(properties: [:], order: [], required: [], additional: true))
        XCTAssertEqual(required, ["color"])
        XCTAssertFalse(additional)
    }

    func testUnionsOfValuesMergeAndSchemasTooWideOrLargeAreRefused() throws {
        // A oneOf of consts is one list of values, however long.
        let colors = (0..<100).map { #"{"const": "c\#($0)"}"# }.joined(separator: ",")
        guard case .literals(let values) = try ModelRequest.schema(JSON.parse(#"{"oneOf": [\#(colors)]}"#)) else {
            return XCTFail("the values weren't merged")
        }
        XCTAssertEqual(values.count, 100)
        XCTAssertEqual(values.last, #""c99""#)

        // More object variants than RoachInference follows at once: refused, not quietly cut.
        let variants = (0...JSONConstraint.maxStates).map {
            #"{"type": "object", "properties": {"k\#($0)": {"type": "boolean"}}, "required": ["k\#($0)"]}"#
        }
        XCTAssertThrowsError(try ModelRequest.schema(JSON.parse(#"{"anyOf": [\#(variants.joined(separator: ","))]}"#))) { error in
            XCTAssertEqual((error as? RuntimeError)?.statusCode, 400)
            XCTAssertTrue("\(error)".contains("anyOf/oneOf"), "\(error)")
        }
        XCTAssertNoThrow(try ModelRequest.schema(JSON.parse(#"{"anyOf": [\#(variants.dropLast().joined(separator: ","))]}"#)))

        // A definition that refers to itself twice doubles at every level.
        let tree = ##"{"$defs": {"T": {"type": "object", "properties": {"l": {"$ref": "#/$defs/T"}, "r": {"$ref": "#/$defs/T"}}}}, "$ref": "#/$defs/T"}"##
        XCTAssertThrowsError(try ModelRequest.schema(JSON.parse(tree))) { error in
            XCTAssertEqual((error as? RuntimeError)?.statusCode, 400)
            XCTAssertTrue("\(error)".contains("too large"), "\(error)")
        }
    }

    func testForcedCallSchemaAndThinkingFirst() {
        let tool = ToolSpec(name: "weather", parameters: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#)
        let constraint = JSONConstraint(schema: NativeModelServer.callSchema([tool]))
        XCTAssertFalse(constraint.allows(#"{"name": "rm""#))
        XCTAssertTrue(constraint.allows(#"{"name": "weather", "arguments": {"city": "Oslo"}}"#))
        XCTAssertFalse(constraint.allows(#"{"name": "weather", "arguments": {}}"#))

        let after = AfterThinkingConstraint(JSONConstraint(requireObject: true))
        XCTAssertTrue(after.allows("<think>anything [ at all"))
        after.accept("<think>reasoning</th")
        XCTAssertFalse(after.canEnd)
        XCTAssertFalse(after.allows("ink>\nnot json"))
        XCTAssertTrue(after.allows("ink>\n{"))
        after.accept("ink>\n{")
        after.accept("}")
        XCTAssertTrue(after.isComplete)

        // A token may stop partway through a character while the model
        // reasons, but not where the answer starts (ROA-93).
        let lead: [UInt8] = [0xE2]
        let reasoning = AfterThinkingConstraint(JSONConstraint(requireObject: true))
        XCTAssertTrue(reasoning.admits(Array("<think>a quote: ".utf8) + lead, after: StreamingDecoder()))
        XCTAssertFalse(reasoning.admits(Array("<think>done</think>".utf8) + lead, after: StreamingDecoder()))
        XCTAssertFalse(reasoning.admits(Array("<think>done</think>\n".utf8) + lead, after: StreamingDecoder()))
        XCTAssertTrue(reasoning.admits(Array("<think>done</think>{\"q\": \"".utf8) + lead, after: StreamingDecoder()))
    }

    func testSmallHelpers() {
        let short = NativeModelServer.shortened([3, 4, 12], to: 2)
        XCTAssertEqual(short[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(short[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(NativeModelServer.unfenced("```json\n{\"a\": 1}\n```"), "{\"a\": 1}")
        XCTAssertEqual(NativeModelServer.argumentsObject(#"{"a":1}"#)["a"].numberValue, 1)
        XCTAssertEqual(NativeModelServer.argumentsObject("oops").stringValue, "oops")

        let anthropic = try? JSON.parse(String(decoding: NativeModelServer.failure("/v1/messages", status: 404, message: "no").body, as: UTF8.self))
        XCTAssertEqual(anthropic?["error"]["type"].stringValue, "not_found_error")
        let openAI = try? JSON.parse(String(decoding: NativeModelServer.failure("/v1/chat/completions", status: 400, message: "bad").body, as: UTF8.self))
        XCTAssertEqual(openAI?["error"]["message"].stringValue, "bad")
        let ollama = try? JSON.parse(String(decoding: NativeModelServer.failure("/api/chat", status: 404, message: "gone").body, as: UTF8.self))
        XCTAssertEqual(ollama?["error"].stringValue, "gone")
    }
}
