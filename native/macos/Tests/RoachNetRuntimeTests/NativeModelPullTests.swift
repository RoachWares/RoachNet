import XCTest
@testable import RoachNetRuntime

/// Model pulls resume a partial `model.gguf` with `Range`. A server that ignores
/// the range sends the whole file, and that must replace the partial instead of
/// landing after it (with no checksum to catch it, the doubled file would install).
final class NativeModelPullTests: XCTestCase {
    private var root = ""
    private var server: LoopbackHTTPServer?
    private let requests = LockedBox<[String]>([])

    /// A minimal GGUF the store accepts: header, `general.architecture = llama`,
    /// no tensors, then filler so a resume has something to skip.
    private let payload: Data = {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func string(_ value: String) { u64(UInt64(value.utf8.count)); data.append(contentsOf: Array(value.utf8)) }
        u32(0x4655_4747)
        u32(3)
        u64(0)
        u64(1)
        string("general.architecture")
        u32(8)
        string("llama")
        while data.count % 32 != 0 { data.append(0) }
        for index in 0..<(64 * 1024) { data.append(UInt8((index * 13 + 5) & 0xff)) }
        return data
    }()
    private var sha: String { SHA256Digest.hex(payload) }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-model-pull-tests-" + JS.randomHex(6)
        try Files.mkdirp(root)
        setenv("ROACHNET_MODEL_PULL_ALLOW_LOOPBACK_HTTP", "1", 1)
    }

    override func tearDownWithError() throws {
        unsetenv("ROACHNET_MODEL_PULL_ALLOW_LOOPBACK_HTTP")
        server?.stop()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func store() -> NativeModelStore {
        let store = NativeModelStore(root: Path.join(root, "native"), catalogPath: Path.join(root, "no-catalog.json"))
        store.ollamaRoot = Path.join(root, "ollama")
        return store
    }

    /// `honorRange`: answer `Range` with 206 + Content-Range (416 past the end);
    /// otherwise always send the whole file with a 200.
    private func startServer(honorRange: Bool) throws -> String {
        let body = payload
        let log = requests
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: 1024) { request in
            let range = request.headers["range"]
            log.value.append(range ?? "full")
            if honorRange, let range, range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
                if start >= body.count {
                    return HTTPResponse(status: 416, headers: [("content-range", "bytes */\(body.count)")])
                }
                let slice = body.subdata(in: start..<body.count)
                var response = HTTPResponse(status: 206, headers: [
                    ("content-type", "application/octet-stream"),
                    ("content-length", String(slice.count)),
                    ("content-range", "bytes \(start)-\(body.count - 1)/\(body.count)"),
                ])
                response.body = slice
                return response
            }
            var response = HTTPResponse(status: 200, headers: [
                ("content-type", "application/octet-stream"),
                ("content-length", String(body.count)),
            ])
            response.body = body
            return response
        }
        try server.start()
        self.server = server
        return "http://127.0.0.1:\(server.port)/model.gguf"
    }

    private func leavePartial(_ bytes: Data) throws {
        let directory = Path.join(root, "native", "pulltest", "1")
        try Files.mkdirp(directory)
        try Files.write(bytes, to: Path.join(directory, "model.gguf.partial"))
    }

    private func installed() -> Data? {
        FileManager.default.contents(atPath: Path.join(root, "native", "pulltest", "1", "model.gguf"))
    }

    private func pull(_ url: String, sha256: String?) throws {
        let request: JSON = sha256.map { ["url": JSON(url), "sha256": JSON($0)] } ?? ["url": JSON(url)]
        _ = try store().pull("pulltest:1", request: request) { _ in true }
    }

    func testPullResumesAPartialWithRange() throws {
        let url = try startServer(honorRange: true)
        try leavePartial(payload.prefix(4096))
        try pull(url, sha256: sha)
        XCTAssertEqual(installed(), payload)
        XCTAssertEqual(requests.value, ["bytes=4096-"])
    }

    func testServerThatIgnoresRangeReplacesThePartial() throws {
        let url = try startServer(honorRange: false)
        try leavePartial(payload.prefix(4096))
        // No checksum: before the fix this installed 4 KB + the whole file.
        try pull(url, sha256: nil)
        XCTAssertEqual(installed(), payload)
        XCTAssertEqual(requests.value, ["bytes=4096-"])
    }

    func testServerThatIgnoresRangeStillVerifies() throws {
        let url = try startServer(honorRange: false)
        try leavePartial(payload.prefix(4096))
        try pull(url, sha256: sha)
        XCTAssertEqual(installed(), payload)
    }

    func testPartialLongerThanTheFileStartsOverOnce() throws {
        let url = try startServer(honorRange: true)
        try leavePartial(payload + Data(repeating: 0xEE, count: 512))
        try pull(url, sha256: nil)
        XCTAssertEqual(installed(), payload)
        XCTAssertEqual(requests.value, ["bytes=\(payload.count + 512)-", "full"])
    }

    // MARK: Download descriptors

    private func runtime(_ environment: [String: String] = [:]) -> NativeRuntime {
        NativeRuntime(config: RuntimeConfiguration(environment: ["ROACHNET_STORAGE_PATH": root].merging(environment) { $1 }))
    }

    func testDescriptorsOnlyComeFromTheAppsDownloadsBase() {
        let live = runtime()
        XCTAssertTrue(live.isAppsDownloadDescriptorUrl("https://apps.roachnet.org/downloads/maps/pmtiles/delaware_2026-10.json"))
        XCTAssertTrue(live.isAppsDownloadDescriptorUrl("https://APPS.roachnet.org/downloads/model-packs/kokoro.json"))
        for url in [
            "https://apps.roachnet.org/collections/maps.json",
            "https://apps.roachnet.org/downloads-mirror/a.json",
            "https://apps.roachnet.org/downloads/maps/pmtiles/delaware_2026-10.pmtiles",
            "http://apps.roachnet.org/downloads/a.json",
            "https://apps.roachnet.org:8443/downloads/a.json",
            "https://apps.roachnet.org.example.net/downloads/a.json",
            "https://example.net/downloads/a.json",
            "https://example.net/data.json",
            "ftp://apps.roachnet.org/downloads/a.json",
        ] {
            XCTAssertFalse(live.isAppsDownloadDescriptorUrl(url), url)
        }
        let local = runtime(["ROACHNET_APPS_DOWNLOADS_BASE_URL": "http://127.0.0.1:8099/downloads/"])
        XCTAssertTrue(local.isAppsDownloadDescriptorUrl("http://127.0.0.1:8099/downloads/a.json"))
        XCTAssertFalse(local.isAppsDownloadDescriptorUrl("http://127.0.0.1:8100/downloads/a.json"))
        XCTAssertFalse(local.isAppsDownloadDescriptorUrl("https://apps.roachnet.org/downloads/a.json"))
    }

    func testAJSONFileFromAnotherHostIsJustAFile() throws {
        let resolved = try runtime().resolveDownloadDescriptor(JSON("https://example.net/exports/places.json"))
        XCTAssertEqual(resolved.url, "https://example.net/exports/places.json")
        XCTAssertNil(resolved.descriptorUrl)
        XCTAssertTrue(resolved.parts.isEmpty)
    }
}
