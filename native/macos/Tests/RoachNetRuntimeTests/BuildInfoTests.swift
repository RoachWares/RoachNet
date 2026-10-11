import XCTest
@testable import RoachNetRuntime

/// ROA-40: the source commit stamped into Info.plist must be a full SHA.
final class BuildInfoTests: XCTestCase {
    func testSourceCommitShape() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertTrue(RuntimeBuildInfo.isSourceCommit(sha))
        XCTAssertTrue(RuntimeBuildInfo.isSourceCommit(sha + "-dirty"))
        XCTAssertFalse(RuntimeBuildInfo.isSourceCommit(String(sha.prefix(12))), "short SHAs are ambiguous")
        XCTAssertFalse(RuntimeBuildInfo.isSourceCommit(sha.uppercased()))
        XCTAssertFalse(RuntimeBuildInfo.isSourceCommit(sha + "-modified"))
        XCTAssertFalse(RuntimeBuildInfo.isSourceCommit(""))
        XCTAssertFalse(RuntimeBuildInfo.isSourceCommit("<string>" + sha))
    }
}
