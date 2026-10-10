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
}
