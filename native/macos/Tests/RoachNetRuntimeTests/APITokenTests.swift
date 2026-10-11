import XCTest
@testable import RoachNetRuntime

/// ROA-39: with ROACHNET_API_TOKEN set, the loopback API answers only callers
/// that bring that token or an `rn_` RoachClaw API token whose scopes cover
/// the route.
final class APITokenTests: XCTestCase {
    private var root = ""

    override func setUp() {
        root = NSTemporaryDirectory() + "roachnet-api-token-" + JS.randomHex(8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func runtime(token: String?) -> NativeRuntime {
        var environment = ["ROACHNET_STORAGE_PATH": root]
        if let token { environment["ROACHNET_API_TOKEN"] = token }
        return NativeRuntime(config: RuntimeConfiguration(environment: environment))
    }

    private func status(_ runtime: NativeRuntime, _ headers: [String: String] = [:], method: String = "GET",
                        target: String = "/api/system/info", inProcess: Bool = false) -> Int {
        var request = HTTPRequest(method: method, target: target, headers: ["host": "127.0.0.1:38111"].merging(headers) { $1 })
        request.inProcess = inProcess
        return runtime.handle(&request).status
    }

    func testNoTokenConfiguredChangesNothing() {
        XCTAssertEqual(status(runtime(token: nil)), 200)
    }

    func testRequestsNeedTheLaunchToken() {
        let token = String(repeating: "ab", count: 32)
        let live = runtime(token: token)
        XCTAssertEqual(status(live), 401, "no token")
        XCTAssertEqual(status(live, ["authorization": "Bearer wrong"]), 401)
        XCTAssertEqual(status(live, ["authorization": "Bearer \(token)"]), 200)
        XCTAssertEqual(status(live, ["x-roachnet-api-token": token]), 200)
        XCTAssertEqual(status(live, target: "/api/health"), 200, "health stays public for launch checks")
        XCTAssertEqual(status(live, inProcess: true), 200, "the companion proxy calls in-process")
        XCTAssertEqual(status(live, ["x-roachnet-org-key": "rnorg_not-a-key"], target: "/api/org/companies"), 401,
                       "an Org key is checked by Org itself, not waved through")
    }

    func testRoachClawAPITokensAreValidatedAndScoped() {
        let launch = String(repeating: "cd", count: 32)
        let live = runtime(token: launch)
        let minted = live.createRoachClawApiToken(["name": "Raycast", "scopes": ["chat"]])
        let raw = minted["token"].jsString
        XCTAssertTrue(raw.hasPrefix("rn_"))
        XCTAssertEqual(status(live, ["authorization": "Bearer \(raw)"], target: "/api/companion/chat/sessions"), 200, "chat scope opens chat routes")
        XCTAssertEqual(status(live, ["authorization": "Bearer \(raw)"]), 403, "but not the rest of the API")
        XCTAssertEqual(status(live, ["authorization": "Bearer \(raw)"], method: "POST", target: "/api/roachclaw/tokens"), 403,
                       "a chat token cannot mint more tokens")
        XCTAssertEqual(status(live, ["authorization": "Bearer rn_unknown"]), 401)

        let id = minted["record"]["id"].jsString
        _ = try? live.deleteRoachClawApiToken(id)
        XCTAssertEqual(status(live, ["authorization": "Bearer \(raw)"], target: "/api/companion/chat/sessions"), 401, "a deleted token stops working")
    }
}

/// ROA-39: RoachTail peer tokens stop working after a long idle stretch.
final class PeerIdleTests: XCTestCase {
    func testPeerTokensExpireWhenUnused() {
        let now = JS.nowMs()
        let day = 86_400_000.0
        let recent: JSON = ["id": "p1", "lastSeenAt": JSON(JS.iso(Date(timeIntervalSince1970: (now - 3 * day) / 1000)))]
        let stale: JSON = ["id": "p2", "lastSeenAt": JSON(JS.iso(Date(timeIntervalSince1970: (now - 120 * day) / 1000)))]
        let neverSeen: JSON = ["id": "p3", "createdAt": JSON(JS.iso(Date(timeIntervalSince1970: (now - 120 * day) / 1000)))]
        XCTAssertFalse(CompanionProxy.peerTokenIsIdle(recent, limitMs: 90 * day, nowMs: now))
        XCTAssertTrue(CompanionProxy.peerTokenIsIdle(stale, limitMs: 90 * day, nowMs: now))
        XCTAssertTrue(CompanionProxy.peerTokenIsIdle(neverSeen, limitMs: 90 * day, nowMs: now))
        XCTAssertFalse(CompanionProxy.peerTokenIsIdle(stale, limitMs: 0, nowMs: now), "0 turns the limit off")
    }
}
