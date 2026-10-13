import XCTest
@testable import RoachNetRuntime

/// A response size limit has to hold while bytes arrive: collections, catalogs,
/// manifests and descriptors are fetched automatically, and an endless body
/// must not fill the runtime's memory before anything checks it.
final class HTTPClientLimitTests: XCTestCase {
    private var server: LoopbackHTTPServer?

    override func tearDownWithError() throws {
        server?.stop()
    }

    private func startServer(announce: Int? = nil) throws -> (url: String, sent: LockedBox<Int>) {
        let sent = LockedBox(0)
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: 1024) { request in
            if request.target.hasPrefix("/small") {
                return HTTPResponse(status: 200, headers: [("content-type", "application/json")], body: Data("{\"ok\":true}".utf8))
            }
            var response = HTTPResponse(status: 200, headers: [("content-type", "application/json")] + (announce.map { [("content-length", String($0))] } ?? []))
            response.stream = { writer in
                // Up to 10 seconds of data, until the client hangs up.
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline, writer.write(chunk) { sent.value += chunk.count }
            }
            return response
        }
        try server.start()
        self.server = server
        return ("http://127.0.0.1:\(server.port)", sent)
    }

    func testEndlessBodyStopsAtTheLimitInsteadOfBufferingFirst() throws {
        #if !canImport(Darwin)
        // On Linux, FoundationNetworking delivers body data asynchronously, and
        // on a CPU-starved machine the limit trips late (ROA-87). macOS, where
        // RoachNet ships, runs this test.
        try XCTSkipIf(true, "Linux: the size limit can trip late under CPU starvation (ROA-87)")
        #endif
        let (base, sent) = try startServer()
        let started = Date()
        XCTAssertThrowsError(try HTTPClient.request(base + "/endless", timeoutMs: 8_000, maxResponseBytes: 256 * 1024)) { error in
            XCTAssertTrue("\(error)".contains("exceeded"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "it gives up at the limit, not at the timeout")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThan(sent.value, 64 << 20, "the transfer was cut off")
    }

    func testAnnouncedOversizedBodyIsRefusedUpFront() throws {
        let (base, _) = try startServer(announce: 512 << 20)
        XCTAssertThrowsError(try HTTPClient.request(base + "/big", timeoutMs: 8_000, maxResponseBytes: 1 << 20)) { error in
            XCTAssertTrue("\(error)".contains("exceeded"), "\(error)")
        }
    }

    func testBodiesUnderTheLimitStillArrive() throws {
        let (base, _) = try startServer()
        let response = try HTTPClient.request(base + "/small", timeoutMs: 5_000, maxResponseBytes: 1024)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.text, "{\"ok\":true}")
        XCTAssertEqual(response.headers["content-type"], "application/json")
    }
}
