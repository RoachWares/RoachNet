#if canImport(CryptoKit) && canImport(Metal)
import Foundation
import RoachInference
import XCTest
@testable import RoachNetRuntime

final class ClusterTests: XCTestCase {
    func testPairingCodesRoundTripAndForgiveTyping() throws {
        let key = ClusterKey.random()
        XCTAssertEqual(key.code.count, 26 + 6, "26 characters in groups of four")
        XCTAssertEqual(ClusterKey(code: key.code), key)
        XCTAssertEqual(ClusterKey(code: key.code.lowercased().replacingOccurrences(of: "-", with: " ")), key)
        XCTAssertNil(ClusterKey(code: "1234"))
        XCTAssertNil(ClusterKey(code: String(key.code.dropLast(2)) + "UU"), "U isn't in the alphabet")
        XCTAssertNotEqual(ClusterKey.random().fingerprint, key.fingerprint)
    }

    func testChannelsSealBothWaysAndRefuseReplayOrTampering() throws {
        let key = ClusterKey.random()
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        var initiator = ClusterChannel(key: key, initiatorNonce: a, responderNonce: b, initiator: true)
        var responder = ClusterChannel(key: key, initiatorNonce: a, responderNonce: b, initiator: false)
        let first = try initiator.seal(Data("hello".utf8))
        XCTAssertEqual(try responder.open(first), Data("hello".utf8))
        XCTAssertThrowsError(try responder.open(first), "a replayed frame fails")
        let back = try responder.seal(Data("hi".utf8))
        var tampered = back
        tampered[tampered.startIndex] ^= 1
        var copy = initiator
        XCTAssertThrowsError(try copy.open(tampered))
        XCTAssertEqual(try initiator.open(back), Data("hi".utf8))
        var stranger = ClusterChannel(key: .random(), initiatorNonce: a, responderNonce: b, initiator: false)
        XCTAssertThrowsError(try stranger.open(try initiator.seal(Data("x".utf8))))
    }

    func testPlansKeepOneMacWhenItFitsAndSplitInOrderWhenNot() throws {
        let layers = [Int](repeating: 100, count: 10)
        let laptop = ClusterPlanner.Node(address: nil, name: "Laptop", free: 1_000)
        let studio = ClusterPlanner.Node(address: "studio.local", name: "Studio", free: 2_000)
        // Fits here: no plan.
        XCTAssertNil(try ClusterPlanner.plan(layerBytes: layers, embedding: 50, head: 50, cachePerLayer: 0, scratch: 10,
                                             local: .init(address: nil, name: "Laptop", free: 5_000), peers: [studio], spread: false))
        // Too big here: as many layers as fit, the rest on the studio.
        let plan = try XCTUnwrap(ClusterPlanner.plan(layerBytes: layers, embedding: 50, head: 50, cachePerLayer: 10, scratch: 10,
                                                     local: laptop, peers: [studio], spread: false))
        XCTAssertEqual(plan.placements.map(\.stage.layers), [0..<8, 8..<10])
        XCTAssertTrue(plan.local.stage.embedding && plan.local.stage.head)
        XCTAssertFalse(plan.remote[0].stage.embedding || plan.remote[0].stage.head)
        // Spread: shares by free memory, every Mac at least one layer.
        let spread = try XCTUnwrap(ClusterPlanner.plan(layerBytes: layers, embedding: 50, head: 50, cachePerLayer: 0, scratch: 10,
                                                       local: .init(address: nil, name: "Laptop", free: 1_110), peers: [studio], spread: true))
        XCTAssertEqual(spread.placements.map(\.stage.layers.count), [3, 7])
        // Too big for both: refused with the sizes.
        XCTAssertThrowsError(try ClusterPlanner.plan(layerBytes: layers, embedding: 50, head: 50, cachePerLayer: 1_000, scratch: 10,
                                                     local: laptop, peers: [studio], spread: false))
    }

    func testAddressesParse() {
        XCTAssertEqual(ClusterLink.parse("studio.local", defaultPort: 7419).0, "studio.local")
        XCTAssertEqual(ClusterLink.parse("studio.local", defaultPort: 7419).1, 7419)
        XCTAssertEqual(ClusterLink.parse("192.168.1.20:9000", defaultPort: 7419).1, 9000)
        XCTAssertEqual(ClusterLink.parse("[fe80::1]:7000", defaultPort: 7419).0, "fe80::1")
        XCTAssertEqual(ClusterLink.parse("[fe80::1]:7000", defaultPort: 7419).1, 7000)
    }
}
#endif
