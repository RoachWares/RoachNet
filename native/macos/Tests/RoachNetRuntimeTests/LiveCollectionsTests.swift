import XCTest
@testable import RoachNetRuntime

/// Live content collections replace the bundled copies only after they pass the checks.
final class LiveCollectionsTests: XCTestCase {
    private var root = ""
    private var server: LoopbackHTTPServer?
    private let served = LockedBox<String>("")

    private let bundledMaps: JSON = [
        "spec_version": "2026-02-11",
        "collections": [[
            "slug": "pacific", "name": "Pacific Region",
            "resources": [["id": "hawaii", "title": "Hawaii", "size_mb": 70,
                           "url": "https://github.com/RoachWares/RoachNet-Maps/raw/refs/heads/master/pmtiles/hawaii_2025-12.pmtiles"]],
        ]],
    ]
    private let liveMaps: JSON = [
        "spec_version": "2026-10-11",
        "collections": [
            ["slug": "pacific", "name": "Pacific Region",
             "resources": [["id": "hawaii", "title": "Hawaii", "size_mb": 71,
                            "sha256": JSON(String(repeating: "a", count: 64)),
                            "url": "https://github.com/RoachWares/RoachNet-Maps/releases/download/maps-2026-10/hawaii_2026-10.pmtiles"]]],
            ["slug": "us-territories", "name": "US Territories", "minimumRoachNet": "1.1.0",
             "resources": [["id": "guam", "title": "Guam", "size_mb": 9,
                            "url": "https://github.com/RoachWares/RoachNet-Maps/releases/download/maps-2026-10/guam_2026-10.pmtiles"]]],
        ],
    ]

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-collections-tests-" + JS.randomHex(6)
        try Files.mkdirp(Path.join(root, "repo", "collections"))
        try Files.writePrettyJSON(bundledMaps, to: Path.join(root, "repo", "collections", "maps.json"))
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func runtime(base: String?) -> NativeRuntime {
        var environment = ["ROACHNET_STORAGE_PATH": Path.join(root, "storage"), "ROACHNET_REPO_ROOT": Path.join(root, "repo")]
        environment["ROACHNET_COLLECTIONS_BASE_URL"] = base ?? ""
        return NativeRuntime(config: RuntimeConfiguration(environment: environment))
    }

    private func startServer() throws -> String {
        let box = served
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: 1024) { _ in
            HTTPResponse(status: 200, headers: [("content-type", "application/json")], body: Data(box.value.utf8))
        }
        try server.start()
        self.server = server
        return "http://127.0.0.1:\(server.port)/collections"
    }

    func testValidatorRejectsWhatShouldNotBeQueued() {
        XCTAssertNil(ContentCollectionValidator.problem(.maps, liveMaps))
        XCTAssertNotNil(ContentCollectionValidator.problem(.maps, ["collections": []]))
        XCTAssertNotNil(ContentCollectionValidator.problem(.maps, ["spec_version": "x"]))
        let plainHTTP: JSON = ["collections": [["slug": "pacific", "name": "Pacific",
                                                "resources": [["id": "hawaii", "url": "http://example.com/hawaii.pmtiles"]]]]]
        XCTAssertEqual(ContentCollectionValidator.problem(.maps, plainHTTP), "map pacific: hawaii: url is not https")
        let dotfile: JSON = ["collections": [["slug": "pacific", "name": "Pacific",
                                              "resources": [["id": "x", "url": "https://example.com/.zshrc"]]]]]
        XCTAssertNotNil(ContentCollectionValidator.problem(.maps, dotfile))
        let badSlug: JSON = ["collections": [["slug": "../etc", "name": "Bad", "resources": []]]]
        XCTAssertNotNil(ContentCollectionValidator.problem(.maps, badSlug))
        let wikipedia: JSON = ["options": [["id": "none", "url": nil], ["id": "top-mini", "url": "https://download.kiwix.org/zim/wikipedia/x.zim"]]]
        XCTAssertNil(ContentCollectionValidator.problem(.wikipedia, wikipedia))
        // Only `none` may skip the URL; any other option without one would read as installed.
        let urlless: JSON = ["options": [["id": "none", "url": nil], ["id": "all-maxi", "url": nil]]]
        XCTAssertEqual(ContentCollectionValidator.problem(.wikipedia, urlless), "Wikipedia all-maxi has no URL")
        let missing: JSON = ["options": [["id": "top-mini"]]]
        XCTAssertEqual(ContentCollectionValidator.problem(.wikipedia, missing), "Wikipedia top-mini has no URL")
    }

    func testBundledCopyIsUsedUntilALiveOneArrives() throws {
        served.value = liveMaps.serialized()
        let base = try startServer()
        let runtime = runtime(base: base)
        XCTAssertEqual(runtime.mapCollections().first?["resources"].array.first?["size_mb"].jsNumber, 70)

        XCTAssertTrue(runtime.fetchCollection(.maps, from: "\(base)/maps.json"))
        let collections = runtime.mapCollections()
        XCTAssertEqual(collections.count, 2)
        XCTAssertEqual(collections.first?["resources"].array.first?["size_mb"].jsNumber, 71)
        XCTAssertEqual(collections.last?["minimumRoachNet"].stringValue, "1.1.0")
        let mode = (try FileManager.default.attributesOfItem(atPath: runtime.collectionCachePath(.maps))[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(runtime.collectionsStatus().array.first?["source"].stringValue, "live")
    }

    func testABadLiveFileKeepsTheLastGoodOne() throws {
        let base = try startServer()
        let runtime = runtime(base: base)
        served.value = liveMaps.serialized()
        XCTAssertTrue(runtime.fetchCollection(.maps, from: "\(base)/maps.json"))

        served.value = #"{"collections": [{"slug": "pacific", "name": "P", "resources": [{"id": "x", "url": "http://evil.example/x.pmtiles"}]}]}"#
        XCTAssertFalse(runtime.fetchCollection(.maps, from: "\(base)/maps.json"))
        served.value = "not json"
        XCTAssertFalse(runtime.fetchCollection(.maps, from: "\(base)/maps.json"))
        XCTAssertEqual(runtime.mapCollections().count, 2, "the earlier live copy stays in use")
    }

    func testTamperedCacheFallsBackToBundled() throws {
        let runtime = runtime(base: "https://apps.roachnet.org/collections")
        try Files.mkdirp(Path.dirname(runtime.collectionCachePath(.maps)))
        try Files.write(#"{"collections": [{"slug": "pacific", "name": "P", "resources": [{"id": "x", "url": "file:///etc/passwd"}]}]}"#,
                        to: runtime.collectionCachePath(.maps))
        XCTAssertEqual(runtime.mapCollections().first?["resources"].array.first?["id"].stringValue, "hawaii")
    }

    func testEmptyBaseURLMeansBundledOnly() throws {
        let runtime = runtime(base: nil)
        XCTAssertNil(runtime.collectionsBaseURL)
        try Files.mkdirp(Path.dirname(runtime.collectionCachePath(.maps)))
        try Files.writePrettyJSON(liveMaps, to: runtime.collectionCachePath(.maps))
        XCTAssertEqual(runtime.mapCollections().count, 1)
    }

    func testPlainHTTPBaseIsRefusedExceptOnLoopback() {
        XCTAssertNil(runtime(base: "http://apps.roachnet.org/collections").collectionsBaseURL)
        XCTAssertEqual(runtime(base: "http://127.0.0.1:9/collections/").collectionsBaseURL, "http://127.0.0.1:9/collections")
    }

    func testLegacyMapFileCountsAsInstalled() throws {
        let runtime = runtime(base: nil)
        let maps = Path.join(root, "storage", "maps", "pmtiles")
        try Files.mkdirp(maps)
        try Files.write(Data([0x50]), to: Path.join(maps, "hawaii_2025-12.pmtiles"))
        XCTAssertEqual(runtime.mapCollections().first?["installed_count"].jsNumber, 1)
    }
}
