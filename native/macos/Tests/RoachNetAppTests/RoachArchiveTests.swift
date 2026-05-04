import XCTest
@testable import RoachNetApp

final class RoachArchiveTests: XCTestCase {
    func testSearchResultDecodesFlexibleArchiveMetadata() throws {
        let json = """
        {
          "id": "aa-demo",
          "title": "Preservation Demo",
          "author": "Anna Example",
          "publication_year": "1999",
          "extension": "epub",
          "source": "aa_derived_mirror_metadata",
          "file_url": "file:///tmp/preservation-demo.epub",
          "metadata_url": "https://annas-archive.gl/md5/demo"
        }
        """
        let result = try JSONDecoder().decode(RoachArchiveSearchResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.id, "aa-demo")
        XCTAssertEqual(result.title, "Preservation Demo")
        XCTAssertEqual(result.authors, ["Anna Example"])
        XCTAssertEqual(result.format, "epub")
        XCTAssertEqual(result.downloadURL, "file:///tmp/preservation-demo.epub")
    }

    func testTorrentManifestDecodesAnnaArchiveShape() throws {
        let json = """
        {
          "url": "https://annas-archive.gl/dyn/small_file/torrents/managed_by_aa/demo.torrent",
          "top_level_group_name": "managed_by_aa",
          "group_name": "aa_derived_mirror_metadata",
          "display_name": "aa_derived_mirror_metadata__demo.torrent",
          "added_to_torrents_list_at": "2026-04-06",
          "is_metadata": true,
          "btih": "0123456789abcdef",
          "magnet_link": "magnet:?xt=urn:btih:0123456789abcdef",
          "data_size": 300018193590,
          "seeders": 7,
          "leechers": 1
        }
        """
        let item = try JSONDecoder().decode(RoachArchiveTorrentItem.self, from: Data(json.utf8))

        XCTAssertTrue(item.isMetadata)
        XCTAssertEqual(item.groupName, "aa_derived_mirror_metadata")
        XCTAssertEqual(item.seeders, 7)
        XCTAssertEqual(item.id, "0123456789abcdef")
    }

    @MainActor
    func testLocalMetadataSearchFindsBookRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoachArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let metadataRoot = root.appendingPathComponent("Metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let metadata = """
        {"id":"demo-1","title":"Offline Library Systems","authors":["B. Roach"],"year":2026,"format":"pdf","source":"aa_derived_mirror_metadata"}
        {"id":"demo-2","title":"Unrelated Shelf","authors":["Someone Else"],"year":2025,"format":"epub","source":"local"}
        """
        try metadata.write(to: metadataRoot.appendingPathComponent("books.jsonl"), atomically: true, encoding: .utf8)

        let store = RoachArchiveStore()
        store.configure(storagePath: root.path)
        store.endpointURLString = ""
        store.metadataDirectoryPath = metadataRoot.path
        store.query = "offline library"
        await store.search()

        XCTAssertEqual(store.results.map(\.title), ["Offline Library Systems"])
        XCTAssertNil(store.errorLine)
    }
}
