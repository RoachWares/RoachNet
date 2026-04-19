import XCTest
@testable import RoachNetApp

final class VaultContextSupportTests: XCTestCase {
    func testPreviewKindRecognizesVaultAssetTypes() {
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/note.md")), .markdown)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/log.txt")), .text)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/config.json")), .text)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/cover.png")), .image)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/track.flac")), .audio)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/movie.mp4")), .video)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/book.pdf")), .pdf)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/book.epub")), .book)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/folder", isDirectory: true)), .folder)
        XCTAssertEqual(VaultPreviewKind.resolve(for: URL(fileURLWithPath: "/tmp/archive.bin")), .generic)
    }

    func testTextExcerptLoadsMarkdownAndNormalizesWhitespace() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("Context.md")
        try """
        # Heading

          First line with context.

        Second line.
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let excerpt = RoachClawContextSupport.textExcerpt(for: fileURL, maxCharacters: 160)

        XCTAssertEqual(excerpt, "# Heading\nFirst line with context.\nSecond line.")
    }

    func testNormalizedExcerptTruncatesToBudget() {
        let source = String(repeating: "vault-context ", count: 80)

        let excerpt = RoachClawContextSupport.normalizedExcerpt(source, maxCharacters: 64)

        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt?.count == 65)
        XCTAssertTrue(excerpt?.hasSuffix("…") == true)
    }

    @MainActor
    func testDeveloperTerminalUsesPinnedWorkingDirectoryWhenSet() {
        let model = DevWorkspaceModel()
        model.projectsRootPath = "/tmp/workspace"
        model.terminalWorkingDirectoryOverride = "/tmp/workspace/project-a"

        XCTAssertEqual(model.currentWorkingDirectory(), "/tmp/workspace/project-a")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
