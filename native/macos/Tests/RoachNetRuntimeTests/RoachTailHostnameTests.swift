import XCTest
@testable import RoachNetRuntime

final class RoachTailHostnameTests: XCTestCase {
    func testApplyAppendsMarkedBlockLikeTheJavaScriptHelper() {
        let hosts = "127.0.0.1 localhost\n::1 localhost\n"
        XCTAssertEqual(
            RoachTailHostname.apply(to: hosts, hostname: "RoachNet"),
            "127.0.0.1 localhost\n::1 localhost\n\n# >>> RoachNet local alias >>>\n127.0.0.1 RoachNet\n::1 RoachNet\n# <<< RoachNet local alias <<<\n"
        )
        XCTAssertEqual(RoachTailHostname.apply(to: "", hostname: "RoachNet"), RoachTailHostname.block(for: "RoachNet") + "\n")
    }

    func testApplyReplacesAnExistingBlockInsteadOfDuplicatingIt() {
        let first = RoachTailHostname.apply(to: "127.0.0.1 localhost\n", hostname: "OldName")
        let second = RoachTailHostname.apply(to: first + "\n\n\n# trailing comment\n", hostname: "RoachNet")
        XCTAssertEqual(second.components(separatedBy: RoachTailHostname.blockBegin).count, 2)
        XCTAssertFalse(second.contains("OldName"))
        XCTAssertTrue(second.contains("# trailing comment\n\n# >>> RoachNet local alias >>>"))
    }

    func testHasAliasIgnoresCommentsAndNonLoopbackAddresses() {
        XCTAssertTrue(RoachTailHostname.hasAlias("127.0.0.1\tlocalhost roachnet\n", hostname: "RoachNet"))
        XCTAssertTrue(RoachTailHostname.hasAlias("[::1] RoachNet", hostname: "roachnet"))
        XCTAssertFalse(RoachTailHostname.hasAlias("# 127.0.0.1 RoachNet\n", hostname: "RoachNet"))
        XCTAssertFalse(RoachTailHostname.hasAlias("10.0.0.5 RoachNet\n", hostname: "RoachNet"))
    }

    func testHostnameHonoursOverride() {
        XCTAssertEqual(RoachTailHostname.hostname(environment: [:]), "RoachNet")
        XCTAssertEqual(RoachTailHostname.hostname(environment: ["ROACHNET_LOCAL_HOSTNAME": "  Lab "]), "Lab")
    }
}
