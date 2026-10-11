import XCTest
@testable import RoachNetRuntime

/// The loopback API and the setup service answer only requests a web page
/// cannot make: no rebound Host, no cross-site Origin, JSON bodies only.
final class LoopbackGuardTests: XCTestCase {
    func testLoopbackHostsPassAndLookalikeNamesDoNot() {
        for host in [nil, "", "127.0.0.1", "127.0.0.1:38111", "localhost:38111", "[::1]:38111", "127.1.2.3:8080"] as [String?] {
            XCTAssertTrue(NativeRuntime.isTrustedLoopbackHost(host), String(describing: host))
        }
        // `127.example.net` used to pass a "127." prefix check, so a page could
        // rebind such a name to 127.0.0.1 and read every response.
        for host in ["127.example.net", "127.example.net:38111", "127.0.0.1.example.net", "127.0.0.256", "evil.example:38111", "0.0.0.0:38111"] {
            XCTAssertFalse(NativeRuntime.isTrustedLoopbackHost(host), host)
        }
    }

    func testCrossSiteOriginsAreRefused() {
        for origin in [nil, "http://127.0.0.1:38111", "http://localhost:5173", "http://[::1]:38111"] as [String?] {
            XCTAssertTrue(NativeRuntime.isTrustedLoopbackOrigin(origin), String(describing: origin))
        }
        for origin in ["null", "", "https://evil.example", "http://127.example.net:38111", "file://", "roachnet://app"] {
            XCTAssertFalse(NativeRuntime.isTrustedLoopbackOrigin(origin), origin)
        }
    }

    func testRouterRefusesCrossSiteAndReboundRequests() {
        let root = NSTemporaryDirectory() + "roachnet-loopback-guard-" + JS.randomHex(6)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = NativeRuntime(config: RuntimeConfiguration(environment: ["ROACHNET_STORAGE_PATH": root]))
        func status(_ headers: [String: String], method: String = "GET", target: String = "/api/health", body: String? = nil) -> Int {
            var request = HTTPRequest(method: method, target: target, headers: headers, body: body.map { Data($0.utf8) })
            return runtime.handle(&request).status
        }
        XCTAssertEqual(status(["host": "127.0.0.1:38111"]), 200)
        XCTAssertEqual(status([:]), 200, "in-process companion requests carry no Host")
        XCTAssertEqual(status(["host": "127.example.net:38111"]), 403)
        XCTAssertEqual(status(["host": "127.0.0.1:38111", "origin": "https://evil.example"], method: "POST", target: "/api/roachclaw/tool-policy/evaluate"), 403)
        XCTAssertEqual(status(["host": "127.0.0.1:38111", "origin": "null"]), 403)
        XCTAssertEqual(status(["host": "127.0.0.1:38111", "content-type": "text/plain"], method: "POST",
                              target: "/api/roachclaw/tool-policy/evaluate", body: "{}"), 415)
        XCTAssertEqual(status(["host": "127.0.0.1:38111", "origin": "http://127.0.0.1:38111"]), 200)
    }

    func testModelServerRefusesReboundAndCrossSiteRequestsLikeOllama() {
        func refused(_ headers: [String: String]) -> Int? {
            NativeModelServer.refusal(HTTPRequest(method: "POST", target: "/api/pull", headers: headers))?.status
        }
        XCTAssertNil(refused(["host": "127.0.0.1:36434"]), "native clients (curl, RoachClaw) send no Origin")
        XCTAssertNil(refused(["host": "localhost:36434", "origin": "http://localhost:3000"]))
        XCTAssertNil(refused(["host": "127.0.0.1:36434", "origin": "tauri://localhost"]), "Ollama's default app origins")
        XCTAssertEqual(refused(["host": "127.example.net:36434"]), 403)
        XCTAssertEqual(refused(["host": "127.0.0.1:36434", "origin": "https://evil.example"]), 403)
        XCTAssertEqual(refused(["host": "127.0.0.1:36434", "origin": "null"]), 403)
    }

    func testDescriptorsOnlyComeFromTheAppsDownloadsBase() throws {
        let root = NSTemporaryDirectory() + "roachnet-descriptor-pin-" + JS.randomHex(6)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let live = NativeRuntime(config: RuntimeConfiguration(environment: ["ROACHNET_STORAGE_PATH": root]))
        XCTAssertTrue(live.isAppsDownloadDescriptorUrl("https://apps.roachnet.org/downloads/maps/pmtiles/delaware_2026-10.json"))
        for url in [
            "https://apps.roachnet.org/collections/maps.json",
            "https://apps.roachnet.org/downloads-mirror/a.json",
            "http://apps.roachnet.org/downloads/a.json",
            "https://apps.roachnet.org.example.net/downloads/a.json",
            "https://example.net/data.json",
        ] {
            XCTAssertFalse(live.isAppsDownloadDescriptorUrl(url), url)
        }
        let resolved = try live.resolveDownloadDescriptor(JSON("https://example.net/exports/places.json"))
        XCTAssertEqual(resolved.url, "https://example.net/exports/places.json")
        XCTAssertNil(resolved.descriptorUrl)
        let local = NativeRuntime(config: RuntimeConfiguration(environment: [
            "ROACHNET_STORAGE_PATH": root, "ROACHNET_APPS_DOWNLOADS_BASE_URL": "http://127.0.0.1:8099/downloads/",
        ]))
        XCTAssertTrue(local.isAppsDownloadDescriptorUrl("http://127.0.0.1:8099/downloads/a.json"))
        XCTAssertFalse(local.isAppsDownloadDescriptorUrl("http://127.0.0.1:8100/downloads/a.json"))
    }
}
