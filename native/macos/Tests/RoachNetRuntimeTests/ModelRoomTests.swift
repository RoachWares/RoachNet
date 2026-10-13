import XCTest
@testable import RoachInference
@testable import RoachNetRuntime

/// A model is loaded only where it fits: within the budget beside the models
/// that stay loaded and, on Linux, within the memory free right now. There,
/// going past a cgroup's limit ends with the OOM killer, not with swapping.
final class ModelRoomTests: XCTestCase {
    /// 600,000 bytes of weights and 50 bytes of cache a token, at 4,096 tokens: 804,800 bytes.
    private let model = ModelFootprint(weights: 600_000, cache: 204_800, scratch: 0, context: 4_096,
                                       trainedContext: 4_096, cachePerToken: 50)

    private func server() -> NativeModelServer {
        let root = NSTemporaryDirectory() + "rn-room-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return NativeModelServer(store: NativeModelStore(root: root, catalogPath: root + "/catalog.json"))
    }

    func testWithoutAHeadroomCapTheBudgetAloneDecides() throws {
        XCTAssertEqual(try server().makeRoom(for: "m", footprint: model, budget: 1_000_000, headroom: { nil }), model)
    }

    func testPlentyOfFreeMemoryChangesNothing() throws {
        XCTAssertEqual(try server().makeRoom(for: "m", footprint: model, budget: 1_000_000, headroom: { 2_000_000 }), model)
    }

    func testLittleFreeMemoryShortensTheContextFirst() throws {
        // 804,800 bytes don't fit in 750,000 free; at 2,048 tokens (702,400) they do.
        let fitted = try server().makeRoom(for: "m", footprint: model, budget: 1_000_000, headroom: { 750_000 })
        XCTAssertEqual(fitted.context, 2_048)
        XCTAssertLessThanOrEqual(fitted.total, 750_000)
    }

    func testTooLittleFreeMemoryRefusesTheLoadEvenWithinTheBudget() {
        // Even 2,048 tokens (702,400 bytes) don't fit in 400,000 free, though the budget allows 1,000,000.
        XCTAssertThrowsError(try server().makeRoom(for: "m", footprint: model, budget: 1_000_000, headroom: { 400_000 })) { error in
            let failure = error as? RuntimeError
            XCTAssertEqual(failure?.statusCode, 503)
            XCTAssertTrue(failure?.message.contains("is free on \(SystemMemory.thisMachine) right now") == true, "\(error)")
        }
    }

    func testTheBudgetStillRefusesAModelTooBigForIt() {
        XCTAssertThrowsError(try server().makeRoom(for: "m", footprint: model, budget: 500_000, headroom: { nil })) { error in
            XCTAssertEqual((error as? RuntimeError)?.statusCode, 507)
        }
    }

    func testOnlyLinuxCapsLoadsByFreeMemory() {
        #if canImport(Darwin)
        XCTAssertNil(SystemMemory.loadHeadroom())
        #else
        XCTAssertNotNil(SystemMemory.loadHeadroom())
        #endif
    }
}
