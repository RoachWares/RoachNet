import XCTest
@testable import RoachNetRuntime

/// Bring-your-own agents: each CLI's event stream, command line and session handling.
final class OrgCLIAgentTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "org-cli-tests-" + JS.randomHex(8)
        try Files.mkdirp(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func stream(_ kind: OrgCLIKind, _ lines: [String], billing: String? = nil, model: String? = nil) throws -> (OrgCLIStream, Tracer, String) {
        let tracer = Tracer(store: TraceStore(root: root))
        let trace = try XCTUnwrap(tracer.startTrace(kind: "org_run", name: "run"))
        let span = trace.observation(.span, kind.label)
        let parser = OrgCLIStream(kind: kind, trace: span, configuredModel: model, billing: billing) { _ in }
        for line in lines { parser.feed(Substring(line)) }
        parser.finish(failed: false, message: nil)
        span.end()
        trace.end(status: "ok")
        return (parser, tracer, trace.traceId)
    }

    // Shapes recorded from Claude Code 2.1.296 on the M2 Pro.
    func testClaudeStreamOnASubscription() throws {
        let (parser, tracer, traceId) = try stream(.claude, [
            #"{"type":"system","subtype":"hook_started","session_id":"s1"}"#,
            #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5","apiKeySource":"none","permissionMode":"dontAsk"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"roachnet-org GET /inbox"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":40,"cache_read_input_tokens":100,"output_tokens":9}},"session_id":"s1"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"{\"items\":[]}"}]},"session_id":"s1"}"#,
            #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":3,"cache_read_input_tokens":150,"output_tokens":4}},"session_id":"s1"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.48}}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1","total_cost_usd":0.39,"num_turns":2,"usage":{"input_tokens":5,"cache_creation_input_tokens":40,"cache_read_input_tokens":250,"output_tokens":13}}"#,
        ])
        XCTAssertEqual(parser.sessionId, "s1")
        XCTAssertEqual(parser.model, "claude-opus-5-5")
        XCTAssertEqual(parser.reply, "ok")
        XCTAssertEqual(parser.billing, "subscription_included")
        XCTAssertEqual(parser.totalUsage, TraceUsage(inputTokens: 295, outputTokens: 13, cachedInputTokens: 250))
        XCTAssertEqual(parser.costUsd, 0.39)
        XCTAssertEqual(parser.toolCalls, 1)
        XCTAssertFalse(parser.reportedFailure)
        XCTAssertEqual(parser.rateLimit["rateLimitType"].stringValue, "five_hour")

        let observations = tracer.store.observations(traceId)
        let generations = observations.filter { $0.type == .generation }
        XCTAssertEqual(generations.count, 2)
        XCTAssertEqual(generations.first?.usage, TraceUsage(inputTokens: 142, outputTokens: 9, cachedInputTokens: 100))
        XCTAssertTrue(generations.allSatisfy { $0.cost?.billingType == "subscription_included" && $0.cost?.totalUsd == 0 })
        let tool = try XCTUnwrap(observations.first { $0.type == .tool })
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.parentId, generations.first { $0.name == "turn 1" }?.id)
        XCTAssertNotNil(tool.endMs)
    }

    func testClaudeErrorResultFailsTheRun() throws {
        let (parser, _, _) = try stream(.claude, [
            #"{"type":"system","subtype":"init","session_id":"s2","apiKeySource":"ANTHROPIC_API_KEY"}"#,
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key · Please run /login","session_id":"s2","total_cost_usd":0}"#,
        ])
        XCTAssertTrue(parser.reportedFailure)
        XCTAssertEqual(parser.billing, "metered_api")
        XCTAssertEqual(OrgCLIAdapter.classify(parser.errorMessage!.lowercased(), kind: .claude).0, "not_signed_in")
    }

    // Shapes recorded from codex-cli 0.152.1 signed in with ChatGPT.
    func testCodexStream() throws {
        let (parser, tracer, traceId) = try stream(.codex, [
            #"{"type":"thread.started","thread_id":"01a12dcf-26a4"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Exceeded skills context budget."}}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"roachnet-org GET /inbox","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"roachnet-org GET /inbox","aggregated_output":"[]","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"ok"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":21619,"cached_input_tokens":20000,"output_tokens":5,"reasoning_output_tokens":0}}"#,
        ], billing: "subscription_included", model: "gpt-5.6-luna")
        XCTAssertEqual(parser.sessionId, "01a12dcf-26a4")
        XCTAssertEqual(parser.reply, "ok")
        XCTAssertEqual(parser.totalUsage, TraceUsage(inputTokens: 21619, outputTokens: 5, cachedInputTokens: 20000))
        XCTAssertEqual(parser.toolCalls, 1)
        let observations = tracer.store.observations(traceId)
        XCTAssertEqual(observations.first { $0.type == .generation }?.model, "gpt-5.6-luna")
        XCTAssertEqual(observations.first { $0.type == .tool }?.name, "shell")
        XCTAssertTrue(observations.contains { $0.type == .event && $0.level == .warning })
    }

    func testCodexOutdatedModelError() throws {
        let (parser, _, _) = try stream(.codex, [
            #"{"type":"thread.started","thread_id":"t"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"turn.failed","error":{"message":"The 'gpt-6-astra' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}"#,
        ])
        XCTAssertTrue(parser.reportedFailure)
        XCTAssertEqual(OrgCLIAdapter.classify(parser.errorMessage!.lowercased(), kind: .codex).0, "cli_outdated")
    }

    // Shapes from each vendor's headless docs (not installed on the gate Mac).
    func testGeminiStream() throws {
        let (parser, _, _) = try stream(.gemini, [
            #"{"type":"init","session_id":"g1","model":"gemini-2.5-pro"}"#,
            #"{"type":"message","role":"user","content":"hi"}"#,
            #"{"type":"tool_use","tool_name":"run_shell_command","tool_id":"x1","parameters":{"command":"roachnet-org GET /inbox"}}"#,
            #"{"type":"tool_result","tool_id":"x1","status":"success","output":"[]"}"#,
            #"{"type":"message","role":"assistant","content":"o","delta":true}"#,
            #"{"type":"message","role":"assistant","content":"k","delta":true}"#,
            #"{"type":"result","status":"success","stats":{"total_tokens":120,"input_tokens":100,"output_tokens":20,"cached":40}}"#,
        ], billing: "subscription_included")
        XCTAssertEqual(parser.sessionId, "g1")
        XCTAssertEqual(parser.reply, "ok")
        XCTAssertEqual(parser.totalUsage, TraceUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 40))
        XCTAssertEqual(parser.toolCalls, 1)
    }

    func testOpenCodeStreamWithReportedCost() throws {
        let (parser, tracer, traceId) = try stream(.opencode, [
            #"{"type":"step_start","sessionID":"ses_1","part":{"id":"p1","type":"step-start"}}"#,
            #"{"type":"tool_use","sessionID":"ses_1","part":{"id":"p2","callID":"c1","tool":"bash","state":{"status":"completed","input":{"command":"ls"},"output":"a b"}}}"#,
            #"{"type":"text","sessionID":"ses_1","part":{"id":"p3","type":"text","text":"ok"}}"#,
            #"{"type":"step_finish","sessionID":"ses_1","part":{"id":"p4","type":"step-finish","reason":"stop","cost":0.0123,"tokens":{"input":50,"output":10,"reasoning":2,"cache":{"read":30,"write":0}}}}"#,
        ], billing: "metered_api")
        XCTAssertEqual(parser.sessionId, "ses_1")
        XCTAssertEqual(parser.reply, "ok")
        XCTAssertEqual(parser.totalUsage, TraceUsage(inputTokens: 80, outputTokens: 12, cachedInputTokens: 30))
        XCTAssertEqual(parser.costUsd, 0.0123)
        XCTAssertEqual(tracer.store.trace(traceId)?.costUsd ?? 0, 0.0123, accuracy: 1e-9)
    }

    func testCursorStream() throws {
        let (parser, _, _) = try stream(.cursor, [
            #"{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp","session_id":"c-1","model":"Claude 4 Sonnet","permissionMode":"default"}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"k1","tool_call":{"readToolCall":{"args":{"path":"README.md"}}},"session_id":"c-1"}"#,
            #"{"type":"tool_call","subtype":"completed","call_id":"k1","tool_call":{"readToolCall":{"args":{"path":"README.md"},"result":{"success":{"content":"Hi","totalLines":1}}}},"session_id":"c-1"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"c-1"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"result":"ok","session_id":"c-1"}"#,
        ])
        XCTAssertEqual(parser.sessionId, "c-1")
        XCTAssertEqual(parser.billing, "subscription_included")
        XCTAssertEqual(parser.reply, "ok")
        XCTAssertEqual(parser.toolCalls, 1)
    }

    func testNonJSONLinesAreLoggedNotParsed() throws {
        var logged: [String] = []
        let parser = OrgCLIStream(kind: .codex, trace: nil, configuredModel: nil, billing: nil) { logged.append($0) }
        parser.feed("Reading additional input from stdin...")
        parser.feed("")
        XCTAssertEqual(logged, ["Reading additional input from stdin..."])
        XCTAssertNil(parser.reply)
    }

    func testCommandLines() {
        var request = OrgCLIRequest(kind: .claude, identity: "You are Ada.", task: "Do it.", model: "sonnet", resume: nil, cwd: "/work", agentHome: "/home/a",
                                    access: .standard, useMySetup: false, claudeAgent: "reviewer", reasoningEffort: nil)
        var invocation = OrgCLICommand.invocation(request)
        XCTAssertEqual(invocation.stdin, "Do it.")
        XCTAssertEqual(Array(invocation.arguments.prefix(4)), ["-p", "--output-format", "stream-json", "--verbose"])
        XCTAssertTrue(invocation.arguments.contains("--add-dir"))
        XCTAssertTrue(invocation.arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(invocation.arguments[invocation.arguments.firstIndex(of: "--agent")! + 1], "reviewer")
        XCTAssertEqual(invocation.arguments.last, "You are Ada.")
        request.access = .full
        XCTAssertTrue(OrgCLICommand.invocation(request).arguments.contains("--dangerously-skip-permissions"))
        request.access = .readOnly
        let readOnly = OrgCLICommand.invocation(request).arguments
        let readOnlyTools = readOnly[readOnly.firstIndex(of: "--allowedTools")! + 1].split(separator: ",").map(String.init)
        XCTAssertFalse(readOnlyTools.contains("Write") || readOnlyTools.contains("Edit"))
        XCTAssertEqual(readOnly[readOnly.firstIndex(of: "--permission-mode")! + 1], "dontAsk")

        request.kind = .codex
        request.access = .standard
        request.resume = "thread-9"
        invocation = OrgCLICommand.invocation(request)
        XCTAssertEqual(Array(invocation.arguments.prefix(3)), ["exec", "resume", "thread-9"])
        XCTAssertFalse(invocation.arguments.contains("-C"), "codex exec resume has no -C; the process cwd is the workspace")
        XCTAssertTrue(invocation.arguments.contains("sandbox_mode=\"workspace-write\""))
        XCTAssertTrue(invocation.arguments.contains("--ignore-user-config"))
        XCTAssertEqual(invocation.arguments.last, "-")
        XCTAssertTrue(invocation.stdin?.hasPrefix("You are Ada.") == true)

        request.kind = .gemini
        XCTAssertTrue(OrgCLICommand.invocation(request).arguments.contains("auto_edit"))
        request.kind = .opencode
        XCTAssertEqual(Array(OrgCLICommand.invocation(request).arguments.prefix(3)), ["run", "--format", "json"])
        request.kind = .cursor
        request.access = .full
        XCTAssertTrue(OrgCLICommand.invocation(request).arguments.contains("--force"))
    }

    func testSessionsArePerIssueAndPerWorkspace() {
        let sessions = OrgCLISessions(nil, kind: .claude)
        let saved = sessions.saving("iss_1", id: "s-1", cwd: "/work")
        let again = OrgCLISessions(saved, kind: .claude)
        XCTAssertEqual(again.lookup("iss_1", cwd: "/work"), "s-1")
        XCTAssertNil(again.lookup("iss_1", cwd: "/elsewhere"))
        XCTAssertNil(again.lookup("iss_2", cwd: "/work"))
        XCTAssertNil(OrgCLISessions(saved, kind: .codex).lookup("iss_1", cwd: "/work"), "a different CLI never resumes another's session")
        var many = saved
        for index in 0..<60 { many = OrgCLISessions(many, kind: .claude).saving("iss_\(index + 10)", id: "s", cwd: "/w") }
        var kept = 0
        for _ in many["sessions"].object { kept += 1 }
        XCTAssertEqual(kept, 50)
    }

    func testLoggedArgumentsLeaveThePromptOut() {
        let shown = OrgCLIAdapter.loggable(["-p", "--append-system-prompt", "You are Ada, secret plans…", "--model", "sonnet", String(repeating: "x", count: 300)])
        XCTAssertFalse(shown.contains("secret plans"))
        XCTAssertTrue(shown.contains("--model sonnet"))
        XCTAssertFalse(shown.contains("xxxx"))
    }

    func testHelperAndGuideAreWellFormed() {
        XCTAssertTrue(OrgCLIBriefing.helper.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(OrgCLIBriefing.helper.contains("x-roachnet-org-key: $ROACHNET_ORG_API_KEY"))
        XCTAssertTrue(OrgCLIBriefing.guide.hasPrefix("# RoachNet Org API"))
        XCTAssertTrue(OrgCLICommand.claudeTools(.readOnly, extra: []).contains("Bash(roachnet-org:*)"))
    }
}
