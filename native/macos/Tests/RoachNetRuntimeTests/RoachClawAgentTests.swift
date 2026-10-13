import XCTest
@testable import RoachNetRuntime

/// RoachClaw's own agent spine: no upstream runtime, plan-only by default, and
/// a prompt packet built only from the scopes the person turned on.
final class RoachClawAgentTests: XCTestCase {
    func testStatusOwnsTheAgentSpineWithoutAnUpstreamRuntime() {
        let status = RoachClawAgent.status(storageRoot: "/tmp/roachnet-agent-test", defaultModel: "qwen2.5-coder:7b",
                                           resolvedDefaultModel: "", installedModels: ["qwen2.5-coder:7b"], ollamaAvailable: true)
        XCTAssertEqual(status["runtime"].stringValue, "roachclaw-native-agent")
        XCTAssertEqual(status["upstreamRuntimeDependency"].stringValue, "none")
        XCTAssertEqual(status["references"]["hermesAgent"]["role"].stringValue, "design-reference-only")
        XCTAssertEqual(status["references"]["hermesAgent"]["reviewedHead"].stringValue, RoachClawAgent.reviewedHermesHead)
        XCTAssertEqual(status["references"]["hermesAgent"]["vendoredCode"].boolValue, false)
        XCTAssertEqual(status["references"]["openClaw"]["role"].stringValue, "migration-reference-only")
        XCTAssertEqual(status["references"]["openClaw"]["bundledRuntime"].boolValue, false)
        XCTAssertEqual(status["ready"].boolValue, true)
        XCTAssertEqual(status["policy"]["defaultExecutionMode"].stringValue, "plan-only")
        XCTAssertTrue(status["policy"]["requiresApprovalFor"].arrayValue?.contains("shell.write") == true)
        XCTAssertEqual(status["budgets"]["planMaxTokens"].numberValue, 4096)

        let notReady = RoachClawAgent.status(storageRoot: "/tmp/roachnet-agent-test", defaultModel: "qwen2.5-coder:7b",
                                             resolvedDefaultModel: "", installedModels: [], ollamaAvailable: true)
        XCTAssertEqual(notReady["ready"].boolValue, false, "not ready until the default model is installed")
    }

    func testSkillRegistryIsRoachNetsOwn() {
        let ids = Set(RoachClawAgent.skills.compactMap { $0["id"].stringValue })
        for required in ["app-context-router", "dev-agent", "vault-research", "arcade-copilot", "release-gate-operator", "memory-curator"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
        XCTAssertTrue(RoachClawAgent.skills.allSatisfy { $0["runtime"].stringValue == "roachclaw-native" })
        XCTAssertFalse(RoachClawAgent.skills.contains { skill in
            ["id", "title", "description"].contains { (skill[$0].stringValue ?? "").lowercased().contains("hermes") }
        })
    }

    func testPromptUsesOnlyEnabledScopesWithinItsBudget() throws {
        let status = RoachClawAgent.status(storageRoot: "/tmp/roachnet-agent-test", defaultModel: "qwen2.5-coder:7b", resolvedDefaultModel: "")
        let body: JSON = [
            "prompt": "Help with the game and the open file.",
            "activeSurface": "RoachArcade",
            "context": [
                "dev": JSON(String(repeating: "open file: main.swift\n", count: 200)),
                "arcade": "running game: Test Cartridge\ncontroller: Xbox Series X",
                "vault": "selected book: Local Systems",
                "maps": "offline map: Indiana",
            ],
            "enabledScopes": ["dev", "arcade", "DEV", " Arcade "],
            "budgetCharacters": 1200,
        ]
        let packet = try RoachClawAgent.buildPrompt(body, status: status)
        let messages = packet["messages"].arrayValue ?? []
        XCTAssertEqual(messages.first?["role"].stringValue, "system")
        XCTAssertTrue(messages.first?["content"].stringValue?.contains("RoachClaw is RoachNet's native local agent") == true)
        let user = messages.last?["content"].stringValue ?? ""
        XCTAssertTrue(user.contains("Active surface: RoachArcade"))
        XCTAssertTrue(user.contains("running game: Test Cartridge"))
        XCTAssertFalse(user.contains("selected book: Local Systems"), "vault was not enabled")
        XCTAssertFalse(user.contains("offline map"), "maps was not enabled")
        XCTAssertTrue(user.contains("[truncated locally]"), "the long dev context is cut to its share of the budget")
        // Scope names are normalized and de-duplicated ("DEV" is dev, " Arcade " is arcade).
        XCTAssertEqual(packet["enabledScopes"].arrayValue?.compactMap(\.stringValue), ["dev", "arcade"])
        XCTAssertEqual(packet["includedScopes"].arrayValue?.compactMap(\.stringValue), ["dev", "arcade"])
        XCTAssertLessThanOrEqual(packet["contextCharacters"].numberValue ?? .infinity, 1200 + 100, "two scopes of at most 600 characters plus headings")
    }

    func testRunsArePlanOnlyAndAPromptIsRequired() throws {
        let status = RoachClawAgent.status(storageRoot: "/tmp/roachnet-agent-test", defaultModel: "m", resolvedDefaultModel: "")
        XCTAssertThrowsError(try RoachClawAgent.buildPrompt(["prompt": "  "], status: status))
        let run = try RoachClawAgent.createRun(["prompt": "Ship it", "execute": true], status: status)
        XCTAssertEqual(run["executed"].boolValue, false, "the spine never runs tools itself")
        XCTAssertEqual(run["executionMode"].stringValue, "approval-required")
        let plan = try RoachClawAgent.createRun(["prompt": "Ship it"], status: status)
        XCTAssertEqual(plan["executionMode"].stringValue, "plan-only")
    }
}
