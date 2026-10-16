import XCTest
@testable import RoachNetRuntime

/// A download removes only what it wrote. Its name can't turn its path into a
/// folder ("." and ".." name folders), and a failed download leaves whatever
/// was at its path before: it used to remove that, folder and all (ROA-95).
final class DownloadNameTests: XCTestCase {
    private var root = ""
    private var server: LoopbackHTTPServer?
    private let payload = Data("a ZIM file".utf8)
    private var storage: String { Path.join(root, "storage") }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-download-names-" + JS.randomHex(6)
        try Files.mkdirp(Path.join(storage, "zim"))
        try Files.write(Data("keep".utf8), to: Path.join(storage, "keep.txt"))
        try Files.write(Data("keep".utf8), to: Path.join(storage, "zim", "other.zim"))
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(atPath: root)
    }

    /// A runtime whose apps downloads come from a local server. Its descriptor
    /// names `filename` (and `sha256`, when given); the file it points to is
    /// served, or answers 404.
    private func runtime(descriptorFilename: String, serveFile: Bool, sha256: String? = nil) throws -> (NativeRuntime, String) {
        server?.stop()
        let port = LockedBox<Int>(0)
        let body = payload
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: 1024) { request in
            if request.target == "/downloads/zim/item.json" {
                var descriptor: JSON = ["url": JSON("http://127.0.0.1:\(port.value)/item.zim"), "filename": JSON(descriptorFilename)]
                if let sha256 { descriptor["sha256"] = JSON(sha256) }
                let data = Data(descriptor.serialized().utf8)
                var response = HTTPResponse(status: 200, headers: [("content-type", "application/json"), ("content-length", String(data.count))])
                response.body = data
                return response
            }
            if request.target == "/item.zim", serveFile {
                var response = HTTPResponse(status: 200, headers: [("content-type", "application/octet-stream"), ("content-length", String(body.count))])
                response.body = body
                return response
            }
            return HTTPResponse(status: 404, headers: [("content-length", "0")])
        }
        try server.start()
        self.server = server
        port.value = Int(server.port)
        let runtime = NativeRuntime(config: RuntimeConfiguration(environment: [
            "ROACHNET_STORAGE_PATH": storage,
            "ROACHNET_APPS_DOWNLOADS_BASE_URL": "http://127.0.0.1:\(server.port)/downloads",
            "ROACHNET_NATIVE_API_DOWNLOAD_MAX_ATTEMPTS": "1",
        ]))
        return (runtime, "http://127.0.0.1:\(server.port)/downloads/zim/item.json")
    }

    private func finish(_ job: DownloadJob, on runtime: NativeRuntime) -> String {
        let deadline = Date().addingTimeInterval(20)
        while ["queued", "downloading", "installing"].contains(runtime.withState({ job.status })), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return runtime.withState { job.status }
    }

    func testANameMadeOfDotsGetsTheFallback() {
        let runtime = NativeRuntime(config: RuntimeConfiguration(environment: ["ROACHNET_STORAGE_PATH": storage]))
        for name in [".", "..", " .. ", "..."] {
            XCTAssertEqual(runtime.safeFileName(JSON(name), "fallback.zim"), "fallback.zim", name)
        }
        XCTAssertEqual(runtime.safeFileName(JSON("a..b.zim"), "fallback.zim"), "a..b.zim")
        XCTAssertEqual(runtime.safeFileName(JSON(".hidden.zim"), "fallback.zim"), ".hidden.zim")
    }

    func testADescriptorNamingAFolderStillDownloadsIntoTheDestination() throws {
        let destination = Path.join(storage, "zim")
        for name in ["..", "."] {
            let (runtime, descriptor) = try runtime(descriptorFilename: name, serveFile: true)
            let job = try XCTUnwrap(runtime.queueResolvedDownload(JSON(descriptor), destination, "zim"))
            XCTAssertEqual(Path.dirname(job.filepath), destination, name)
            XCTAssertEqual(finish(job, on: runtime), "completed", name)
            XCTAssertEqual(FileManager.default.contents(atPath: job.filepath), payload, name)
            XCTAssertTrue(Files.isFile(Path.join(storage, "keep.txt")), "storage is untouched after \(name)")
            XCTAssertTrue(Files.isFile(Path.join(destination, "other.zim")), "the destination is untouched after \(name)")
        }
    }

    func testAFailedDownloadLeavesAFolderAtItsPathAlone() throws {
        let (runtime, _) = try runtime(descriptorFilename: "item.zim", serveFile: false)
        // A job whose path is a folder, however it came to be.
        let folder = Path.join(storage, "zim")
        let job = DownloadJob(url: "http://127.0.0.1:\(server!.port)/item.zim", filepath: folder, filetype: "zim",
                              descriptorUrl: nil, expectedSha256: nil, parts: [])
        XCTAssertThrowsError(try runtime.downloadFile(job))
        XCTAssertTrue(Files.isFile(Path.join(folder, "other.zim")), "the folder and what's in it stay")
        XCTAssertFalse(Files.exists(job.partialFilepath), "the partial file is still cleaned up")
    }

    /// Downloading a file again that fails, or brings the wrong bytes, leaves
    /// the copy already there.
    func testAFailedDownloadLeavesTheFileAlreadyThere() throws {
        let destination = Path.join(storage, "zim")
        let installed = Path.join(destination, "item.zim")
        let earlier = Data("the copy already installed".utf8)
        let wrongSha = SHA256Digest.hex(Data("something else".utf8))
        for (serveFile, sha256) in [(false, nil), (true, wrongSha)] as [(Bool, String?)] {
            try Files.write(earlier, to: installed)
            let (runtime, descriptor) = try runtime(descriptorFilename: "item.zim", serveFile: serveFile, sha256: sha256)
            let job = try XCTUnwrap(runtime.queueResolvedDownload(JSON(descriptor), destination, "zim"))
            XCTAssertEqual(job.filepath, installed)
            XCTAssertEqual(finish(job, on: runtime), "failed", "serveFile: \(serveFile)")
            XCTAssertEqual(FileManager.default.contents(atPath: installed), earlier, serveFile ? "the wrong bytes don't replace it" : "a failed download doesn't remove it")
            XCTAssertFalse(Files.exists(job.partialFilepath))
        }
    }
}
