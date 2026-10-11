import XCTest
@testable import RoachNetRuntime

/// Downloads survive stalls and dropped connections by resuming with `Range`,
/// instead of failing at a fixed wall-clock deadline and throwing the bytes away.
final class DownloadResumeTests: XCTestCase {
    private var root = ""
    private var server: LoopbackHTTPServer?
    private let payload: Data = {
        var bytes = [UInt8](repeating: 0, count: 96 * 1024)
        for index in bytes.indices { bytes[index] = UInt8((index * 31 + 7) & 0xff) }
        return Data(bytes)
    }()
    private var sha: String { SHA256Digest.hex(payload) }
    private let requests = LockedBox<[String]>([])

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-download-tests-" + JS.randomHex(6)
        try Files.mkdirp(root)
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func runtime(attempts: Int = 4) -> NativeRuntime {
        NativeRuntime(config: RuntimeConfiguration(environment: [
            "ROACHNET_STORAGE_PATH": root,
            "ROACHNET_NATIVE_API_DOWNLOAD_STALL_TIMEOUT_MS": "1000",
            "ROACHNET_NATIVE_API_DOWNLOAD_MAX_ATTEMPTS": String(attempts),
        ]))
    }

    /// `stallAfter`: bytes sent before the server goes quiet on a full (non-range) request.
    /// `honorRange`: answer `Range` with 206 + Content-Range; otherwise always send the whole file.
    private func startServer(stallAfter: Int?, honorRange: Bool = true, stallRanges: Bool = false) throws -> String {
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
                if stallRanges, let stallAfter {
                    response.stream = { writer in
                        writer.write(slice.prefix(stallAfter))
                        Thread.sleep(forTimeInterval: 2.5)
                    }
                } else {
                    response.body = slice
                }
                return response
            }
            var response = HTTPResponse(status: 200, headers: [
                ("content-type", "application/octet-stream"),
                ("content-length", String(body.count)),
            ])
            if let stallAfter {
                response.stream = { writer in
                    writer.write(body.prefix(stallAfter))
                    Thread.sleep(forTimeInterval: 2.5)
                }
            } else {
                response.body = body
            }
            return response
        }
        try server.start()
        self.server = server
        return "http://127.0.0.1:\(server.port)/pack.pmtiles"
    }

    private func job(_ url: String) -> DownloadJob {
        DownloadJob(url: url, filepath: Path.join(root, "pack.pmtiles"), filetype: "pmtiles",
                    descriptorUrl: nil, expectedSha256: sha, parts: [])
    }

    func testContentRangeParsing() {
        XCTAssertEqual(StreamingDownload.parseContentRange("bytes 100-199/1000")?.start, 100)
        XCTAssertEqual(StreamingDownload.parseContentRange("bytes 100-199/1000")?.total, 1000)
        XCTAssertNil(StreamingDownload.parseContentRange("bytes 5-9/*")?.total)
        XCTAssertNil(StreamingDownload.parseContentRange("items 1-2/3"))
        XCTAssertNil(StreamingDownload.parseContentRange(nil))
    }

    func testStallResumesWithRangeAndVerifies() throws {
        let url = try startServer(stallAfter: 20 * 1024)
        let download = job(url)
        try runtime().downloadFile(download)
        XCTAssertEqual(download.status, "completed")
        XCTAssertEqual(FileManager.default.contents(atPath: download.filepath), payload)
        XCTAssertEqual(download.sha256, sha)
        XCTAssertGreaterThanOrEqual(download.attempts, 2)
        XCTAssertEqual(download.resumedFrom, 20 * 1024)
        XCTAssertTrue(requests.value.contains("bytes=20480-"), "second request should resume: \(requests.value)")
        XCTAssertFalse(Files.exists(download.partialFilepath))
        XCTAssertFalse(Files.exists("\(download.partialFilepath).json"))
    }

    func testServerThatIgnoresRangeStartsTheFileOver() throws {
        let url = try startServer(stallAfter: nil, honorRange: false)
        let download = job(url)
        // Leftover bytes from an earlier attempt at the same file.
        try Files.write(Data(repeating: 0xEE, count: 4096), to: download.partialFilepath)
        try Files.writePrettyJSON(["url": JSON(url), "sha256": JSON(sha)], to: "\(download.partialFilepath).json")
        try runtime().downloadFile(download)
        XCTAssertEqual(FileManager.default.contents(atPath: download.filepath), payload)
        XCTAssertEqual(requests.value.first, "bytes=4096-")
    }

    func testPartialFromAnotherSourceIsNotReused() throws {
        let url = try startServer(stallAfter: nil)
        let download = job(url)
        try Files.write(Data(repeating: 0xEE, count: 4096), to: download.partialFilepath)
        try Files.writePrettyJSON(["url": "https://example.invalid/other.pmtiles", "sha256": JSON(sha)], to: "\(download.partialFilepath).json")
        try runtime().downloadFile(download)
        XCTAssertEqual(FileManager.default.contents(atPath: download.filepath), payload)
        XCTAssertEqual(requests.value, ["full"])
    }

    func testGivingUpKeepsThePartialAndTheNextInstallResumes() throws {
        let url = try startServer(stallAfter: 16 * 1024, stallRanges: true)
        let first = job(url)
        XCTAssertThrowsError(try runtime(attempts: 2).downloadFile(first)) { error in
            XCTAssertTrue("\(error)".contains("install it again"), "\(error)")
        }
        XCTAssertTrue(first.partialKept)
        let kept = (try FileManager.default.attributesOfItem(atPath: first.partialFilepath)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(kept, 16 * 1024)
        XCTAssertFalse(Files.exists(first.filepath))

        server?.stop()
        requests.value = []
        let healthyUrl = try startServer(stallAfter: nil)
        // Same file, new port: the marker records the old URL, so point it at the new one
        // the way a re-queued install of the same descriptor would.
        try Files.writePrettyJSON(["url": JSON(healthyUrl), "sha256": JSON(sha)], to: "\(first.partialFilepath).json")
        let second = job(healthyUrl)
        try runtime().downloadFile(second)
        XCTAssertEqual(FileManager.default.contents(atPath: second.filepath), payload)
        XCTAssertEqual(second.resumedFrom.map(Int.init), kept)
        XCTAssertEqual(requests.value.first, "bytes=\(kept)-")
    }

    func testChecksumMismatchDiscardsEverything() throws {
        let url = try startServer(stallAfter: nil)
        let download = DownloadJob(url: url, filepath: Path.join(root, "pack.pmtiles"), filetype: "pmtiles",
                                   descriptorUrl: nil, expectedSha256: String(repeating: "0", count: 64), parts: [])
        XCTAssertThrowsError(try runtime().downloadFile(download))
        XCTAssertFalse(download.partialKept)
        XCTAssertFalse(Files.exists(download.filepath))
        XCTAssertFalse(Files.exists(download.partialFilepath))
    }
}
