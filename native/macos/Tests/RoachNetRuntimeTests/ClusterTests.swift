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

    func testPeerSuppliedDigestsAndNumbersAreChecked() throws {
        let good = String(repeating: "ab12", count: 16)
        XCTAssertTrue(ClusterNode.isSHA256Hex(good))
        XCTAssertTrue(ClusterNode.isSHA256Hex(good.uppercased()))
        for bad in ["", String(good.dropLast()), good + "0", "../" + String(good.dropFirst(3)), String(good.dropLast()) + "/",
                    String(good.dropLast()) + "g", String(good.dropLast()) + "\u{FF10}"] {
            XCTAssertFalse(ClusterNode.isSHA256Hex(bad), bad)
        }
        XCTAssertEqual(ClusterNode.integer(JSON(12), in: 0...100), 12)
        XCTAssertNil(ClusterNode.integer(JSON(-1), in: 0...100))
        XCTAssertNil(ClusterNode.integer(JSON(1.5), in: 0...100))
        XCTAssertNil(ClusterNode.integer(JSON(1e300), in: 0...100), "a huge number is refused, not trapped on")
        XCTAssertNil(ClusterNode.integer(JSON(Double.infinity), in: 0...100))
        XCTAssertNil(ClusterNode.integer(JSON("12"), in: 0...100))

        // A stage request naming a path instead of a digest is refused before any file is touched.
        let root = NSTemporaryDirectory() + "rn-cluster-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = NativeModelStore(root: Path.join(root, "native"), catalogPath: Path.join(root, "no-catalog.json"))
        let node = ClusterNode(stateRoot: Path.join(root, "state"), storageRoot: Path.join(root, "storage"), store: store, version: "test")
        let header: JSON = ["op": "prepare", "stage": "s1", "model": "m", "digest": "../../../../tmp/x", "layers": "0-1", "context": 64]
        XCTAssertThrowsError(try node.prepare(header, coordinator: "peer"))
        XCTAssertThrowsError(try node.receiveShard(header, Data([1, 2, 3]), coordinator: "peer"))
        var huge = header.object
        huge["digest"] = JSON(good)
        huge["offset"] = JSON(1e300)
        XCTAssertThrowsError(try node.receiveShard(.object(huge), Data([1, 2, 3]), coordinator: "peer"), "a huge offset is refused, not trapped on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Path.join(root, "storage", "cluster", "shards", "\(good)-0-1.gguf.part")))
    }

    #if canImport(dnssd)
    func testANearbyMacAddedByIPAddressCountsAsAdded() {
        // Made-up names and a documentation address (RFC 5737), not real devices.
        let found = ClusterBonjour.Found(name: "Studio", host: "Studio.local.", port: 7419, id: "0a1b2c3d", fingerprint: "fp")
        XCTAssertTrue(ClusterNode.isAdded(found, addresses: ["studio.local:7419"], ids: []), "same address, any case")
        XCTAssertTrue(ClusterNode.isAdded(found, addresses: ["192.0.2.20:7419"], ids: ["0a1b2c3d"]), "added by IP, matched by node ID")
        XCTAssertFalse(ClusterNode.isAdded(found, addresses: ["192.0.2.20:7419"], ids: ["ffff"]))
        let anonymous = ClusterBonjour.Found(name: "x", host: "x.local", port: 7419, id: "", fingerprint: "")
        XCTAssertFalse(ClusterNode.isAdded(anonymous, addresses: [], ids: [""]), "an empty ID never matches")
    }
    #endif

    func testRequestNumbersClampInsteadOfTrapping() {
        XCTAssertEqual(JSON(1e300).clampedInt(), Int(Int32.max))
        XCTAssertEqual(JSON(-1e300).clampedInt(), Int(Int32.min))
        XCTAssertEqual(JSON(-Double.infinity).clampedInt(0...10), 0)
        XCTAssertEqual(JSON(3.9).clampedInt(), 3)
        XCTAssertEqual(JSON(-3.9).clampedInt(), -3)
        XCTAssertEqual(JSON(9.3e18).clampedInt(0...Int.max), Int.max)
        XCTAssertNil(JSON("4").clampedInt())
        let options = NativeModelServer.options(["num_predict": JSON(1e300), "top_k": JSON(-1e300), "repeat_last_n": JSON(1e20), "seed": JSON(1e30)])
        XCTAssertEqual(options.maxTokens, Int(Int32.max))
        XCTAssertEqual(options.sampling.topK, Int(Int32.min))
        XCTAssertEqual(options.sampling.repeatLastN, Int(Int32.max))
        XCTAssertEqual(NativeModelServer.options(["seed": JSON(42)]).sampling.seed, 42)
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
