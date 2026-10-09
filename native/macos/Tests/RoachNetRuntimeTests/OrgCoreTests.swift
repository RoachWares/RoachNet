import XCTest
@testable import RoachNetRuntime

final class OrgCoreTests: XCTestCase {
    private func date(_ iso: String) -> Date { Date(timeIntervalSince1970: (JS.parseDate(iso) ?? 0) / 1_000) }

    func testHMACMatchesRFC4231() {
        XCTAssertEqual(HMACSHA256.hex(key: "Jefe", message: "what do ya want for nothing?"),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        let longKey = [UInt8](repeating: 0xaa, count: 131)
        XCTAssertEqual(Encoding.hex(HMACSHA256.mac(key: longKey, message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    func testCronSteps() throws {
        let cron = try OrgCron("*/15 * * * *")
        XCTAssertEqual(cron.next(after: date("2026-10-08T10:07:30.000Z")).map(JS.iso), "2026-10-08T10:15:00.000Z")
        XCTAssertEqual(cron.next(after: date("2026-10-08T10:15:00.000Z")).map(JS.iso), "2026-10-08T10:30:00.000Z")
    }

    func testCronWeekdaysInTimeZone() throws {
        let cron = try OrgCron("0 9 * * mon-fri", timezone: "America/New_York")
        // Saturday 2026-10-10 noon UTC -> Monday 2026-10-12 09:00 EDT = 13:00 UTC.
        XCTAssertEqual(cron.next(after: date("2026-10-10T12:00:00.000Z")).map(JS.iso), "2026-10-12T13:00:00.000Z")
    }

    func testCronShortcutsAndMonthly() throws {
        XCTAssertEqual(try OrgCron("@daily").next(after: date("2026-10-08T23:59:00.000Z")).map(JS.iso), "2026-10-09T00:00:00.000Z")
        XCTAssertEqual(try OrgCron("0 0 1 * *").next(after: date("2026-10-08T00:00:00.000Z")).map(JS.iso), "2026-11-01T00:00:00.000Z")
        XCTAssertEqual(try OrgCron("30 6 29 2 *").next(after: date("2026-10-08T00:00:00.000Z")).map(JS.iso), "2028-02-29T06:30:00.000Z")
    }

    func testCronDayOfMonthOrWeekday() throws {
        // Vixie semantics: the 13th OR any Friday.
        let cron = try OrgCron("0 0 13 * 5")
        XCTAssertEqual(cron.next(after: date("2026-10-08T00:00:00.000Z")).map(JS.iso), "2026-10-09T00:00:00.000Z")
        XCTAssertEqual(cron.next(after: date("2026-10-11T00:00:00.000Z")).map(JS.iso), "2026-10-13T00:00:00.000Z")
    }

    func testCronRejectsBadInput() {
        XCTAssertThrowsError(try OrgCron("61 * * * *"))
        XCTAssertThrowsError(try OrgCron("* * * *"))
        XCTAssertThrowsError(try OrgCron("*/0 * * * *"))
        XCTAssertThrowsError(try OrgCron("0 0 * * *", timezone: "Mars/Olympus"))
    }

    func testActionExtraction() {
        let fenced = "Sure.\n```json\n{\"action\":\"comment\",\"body\":\"has } brace\"}\n```"
        XCTAssertEqual(OrgAgentLoopAdapter.extractAction(fenced)?["body"].stringValue, "has } brace")
        XCTAssertNil(OrgAgentLoopAdapter.extractAction("no json here {not json}"))
        XCTAssertEqual(OrgAgentLoopAdapter.extractAction("{\"x\":1} then {\"action\":\"finish\"}")?["action"].stringValue, "finish")
    }

    func testSlugsAndPrefixes() {
        XCTAssertEqual(OrgIDs.slug("Chief Executive Officer!"), "chief-executive-officer")
        XCTAssertEqual(OrgIDs.issuePrefix("Roach Wares"), "ROAC")
        XCTAssertEqual(OrgIDs.issuePrefix("123"), "ORG")
    }

    func testModelsRoundTrip() throws {
        let stamp = JS.isoNow()
        var state = OrgCompanyState(company: OrgCompany(id: "co_1", name: "Test", issuePrefix: "TST", createdAt: stamp, updatedAt: stamp))
        state.agents.append(OrgAgent(id: "agent_1", companyId: "co_1", name: "CEO", urlKey: "ceo", adapterConfig: ["model": "qwen3:0.6b", "nested": [1, 2]], createdAt: stamp, updatedAt: stamp))
        let encoded = OrgCodec.json(state)
        let decoded = try OrgCodec.decode(OrgCompanyState.self, from: encoded)
        XCTAssertEqual(decoded.agents.first?.adapterConfig["nested"][1].numberValue, 2)
        XCTAssertEqual(decoded.company.issuePrefix, "TST")
    }
}
