import XCTest
@testable import RoachNetCore

final class RoachBrainWikiStoreTests: XCTestCase {
    func testCaptureCompilesMemoriesIntoLocalMarkdownWiki() throws {
        let storageURL = try makeTemporaryDirectory()

        _ = try RoachBrainStore.capture(
            storagePath: storageURL.path,
            title: "Vault research loop",
            body: "Use one source, one synthesis page, and one verification signal before filing the result.",
            source: "Unit Test",
            tags: ["roachclaw", "vault"],
            pinned: true
        )

        let status = RoachBrainWikiStore.status(storagePath: storageURL.path)

        XCTAssertEqual(status.memoryCount, 1)
        XCTAssertEqual(status.pageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.indexPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.logPath))

        let index = try String(contentsOfFile: status.indexPath, encoding: .utf8)
        XCTAssertTrue(index.contains("[[pages/vault-research-loop|Vault research loop]]"))

        let context = RoachBrainWikiStore.contextBlock(
            storagePath: storageURL.path,
            query: "verification signal",
            matches: RoachBrainStore.search(storagePath: storageURL.path, query: "verification signal")
        )
        XCTAssertTrue(context.contains("AutoResearch discipline"))
        XCTAssertTrue(context.contains("[[pages/vault-research-loop]]"))
    }

    func testOperatorProtocolForbidsUnverifiedClaims() {
        let protocolText = RoachBrainWikiStore.operatorProtocolBlock()

        XCTAssertTrue(protocolText.contains("Answer normal conversation normally"))
        XCTAssertTrue(protocolText.contains("Never claim a command ran"))
        XCTAssertTrue(protocolText.contains("exact command"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoachBrainWikiStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
