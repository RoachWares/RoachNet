import XCTest
@testable import RoachNetApp

/// The Org desk renders whatever the runtime's approval payload carries, so the
/// label and money formatting must stay readable for keys nobody hand-picked.
final class OrgWorkspaceTests: XCTestCase {
    func testLabelsReadAsWordsForCamelAndSnakeCase() {
        XCTAssertEqual(OrgDeskFormat.label("agentName"), "Agent name")
        XCTAssertEqual(OrgDeskFormat.label("monthly_budget"), "Monthly budget")
        XCTAssertEqual(OrgDeskFormat.label("reason"), "Reason")
        XCTAssertEqual(OrgDeskFormat.label("monthlyBudget"), "Monthly budget")
    }

    func testDollarsDropCentsWhenWhole() {
        XCTAssertEqual(OrgDeskFormat.dollars(4000), "$40")
        XCTAssertEqual(OrgDeskFormat.dollars(4050), "$40.50")
        XCTAssertEqual(OrgDeskFormat.dollars(0), "$0")
    }

    func testApprovalDetailsFormatMoneyAndSkipIdentifiers() throws {
        let json = """
        {"id":"apr_1","type":"request_board_approval","status":"pending",
         "payload":{"title":"Hire a docs writer","agentName":"Quill","agentId":"ag_1",
                    "monthlyBudgetCents":"4000","approved":false,"headcount":2}}
        """
        let approval = try JSONDecoder().decode(OrgDeskApproval.self, from: Data(json.utf8))
        XCTAssertEqual(approval.headline, "Hire a docs writer")
        XCTAssertTrue(approval.isOpen)
        let details = Dictionary(uniqueKeysWithValues: approval.details)
        XCTAssertEqual(details["Agent name"], "Quill")
        XCTAssertEqual(details["Monthly budget"], "$40")
        XCTAssertEqual(details["Approved"], "No")
        XCTAssertEqual(details["Headcount"], "2")
        XCTAssertNil(details["Agent id"], "identifiers are noise on the desk")
    }

    func testHeadlineFallsBackToTypeTitle() throws {
        let json = #"{"id":"apr_2","type":"hire_agent","status":"revision_requested","payload":{}}"#
        let approval = try JSONDecoder().decode(OrgDeskApproval.self, from: Data(json.utf8))
        XCTAssertEqual(approval.headline, "Hire an agent")
        XCTAssertTrue(approval.isOpen)
    }

    func testDashboardOpenIssuesExcludeFinishedWork() throws {
        let json = """
        {"company":{"id":"co_1","name":"Studio"},
         "issuesByStatus":{"todo":3,"in_progress":2,"done":9,"cancelled":1}}
        """
        let dashboard = try JSONDecoder().decode(OrgDeskDashboard.self, from: Data(json.utf8))
        XCTAssertEqual(dashboard.openIssues, 5)
    }

    // ROA-31 boards. The payloads below are trimmed copies of what roachnet-runtime
    // 1.1 answers on /api/org/companies/:id/{issues,org-chart,routines,budgets,agents}.

    func testBoardsDecodeTheRuntimePayloads() throws {
        let issues = """
        {"issues":[{"assigneeAgentId":"agent_2","blockedByIssueIds":[],"id":"iss_1","identifier":"ROAC-3","number":3,
          "priority":"critical","status":"in_progress","statusVersion":2,"title":"Fix the map label overlap at z9",
          "updatedAt":"2026-10-11T23:04:12.801Z","workMode":"standard","blockers":[],"assigneeAgentName":"Linus"}],"total":5}
        """
        struct Issues: Decodable { let issues: [OrgDeskIssue]; let total: Int }
        let list = try JSONDecoder().decode(Issues.self, from: Data(issues.utf8))
        XCTAssertEqual(list.issues.first?.assigneeAgentName, "Linus")
        XCTAssertEqual(list.issues.first?.isOpen, true)

        let chart = """
        {"roots":[{"id":"a1","name":"Ada","role":"ceo","title":"CEO","status":"error","urlKey":"ada",
          "reports":[{"id":"a2","name":"Linus","role":"general","title":"Engineer","status":"idle","urlKey":"linus","reports":[]}]}]}
        """
        struct Chart: Decodable { let roots: [OrgDeskChartNode] }
        XCTAssertEqual(try JSONDecoder().decode(Chart.self, from: Data(chart.utf8)).roots.first?.reports.first?.name, "Linus")

        let routines = """
        {"routines":[{"assigneeAgentId":"a1","id":"rtn_1","status":"active","title":"Morning issue triage","priority":"medium",
          "lastTriggeredAt":"2026-10-11T23:04:13.145Z","variables":[],
          "triggers":[{"cronExpression":"0 9 * * 1-5","enabled":true,"id":"trg_1","kind":"schedule",
                       "nextRunAt":"2026-10-12T13:00:00.000Z","timezone":"America/New_York"}]}]}
        """
        struct Routines: Decodable { let routines: [OrgDeskRoutine] }
        let routine = try XCTUnwrap(try JSONDecoder().decode(Routines.self, from: Data(routines.utf8)).routines.first)
        XCTAssertEqual(OrgDeskWords.schedule(routine.schedule?.cronExpression), "Weekdays at 9:00")
        XCTAssertEqual(OrgDeskWords.schedule("*/5 * * * *"), "*/5 * * * *", "unknown schedules are shown as written")

        let budgets = """
        {"policies":[{"amountCents":7500,"hardStopEnabled":true,"id":"bud_1","isActive":true,"scopeId":"co_1","scopeType":"company",
          "warnPercent":80,"windowKind":"calendar_month_utc","observedCents":1875}],
         "incidents":[{"id":"inc_1","policyId":"bud_1","thresholdType":"soft","amountLimit":7500,"amountObserved":6100,"status":"open"}]}
        """
        struct Budgets: Decodable { let policies: [OrgDeskBudget]; let incidents: [OrgDeskIncident] }
        let decoded = try JSONDecoder().decode(Budgets.self, from: Data(budgets.utf8))
        XCTAssertEqual(decoded.policies.first?.share ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(decoded.incidents.first?.thresholdType, "soft")
    }

    func testAgentsInErrorSayWhatToDo() throws {
        let json = """
        {"agents":[{"id":"a1","name":"Ada","role":"ceo","title":"CEO","status":"error",
                    "errorReason":"Model call failed: model server returned 404"},
                   {"id":"a2","name":"Linus","status":"idle"}]}
        """
        struct Agents: Decodable { let agents: [OrgDeskAgent] }
        let agents = try JSONDecoder().decode(Agents.self, from: Data(json.utf8)).agents
        XCTAssertEqual(agents[0].problem, "Its model isn't on this Mac. Pull one in RoachClaw, then try again.")
        XCTAssertNil(agents[1].problem)
        XCTAssertEqual(OrgDeskWords.status("in_progress"), "In progress")
        XCTAssertEqual(OrgDeskWords.status("todo"), "To do")
    }
}
