import XCTest
@testable import RoachNetApp

/// The PMTiles + MVT reader behind the Maps pane.
final class RoachMapTilesTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/delaware-z0-8.pmtiles")
    }

    private func tileFor(lon: Double, lat: Double, z: Int) -> (x: Int, y: Int) {
        let world = RoachMercator.project(lon: lon, lat: lat)
        let n = Double(1 << z)
        return (Int(world.x * n), Int(world.y * n))
    }

    func testTileIdsFollowTheSpec() {
        XCTAssertEqual(RoachTileID.from(z: 0, x: 0, y: 0), 0)
        XCTAssertEqual(RoachTileID.from(z: 1, x: 0, y: 0), 1)
        XCTAssertEqual(RoachTileID.from(z: 1, x: 0, y: 1), 2)
        XCTAssertEqual(RoachTileID.from(z: 1, x: 1, y: 1), 3)
        XCTAssertEqual(RoachTileID.from(z: 1, x: 1, y: 0), 4)
        XCTAssertEqual(RoachTileID.from(z: 2, x: 0, y: 0), 5)
        XCTAssertEqual(RoachTileID.from(z: 12, x: 3423, y: 1763), 19_078_479)
    }

    func testVarintsAndZigzag() throws {
        var reader = RoachByteReader([0xac, 0x02, 0x01])
        XCTAssertEqual(try reader.varint(), 300)
        XCTAssertEqual(try reader.varint(), 1)
        XCTAssertThrowsError(try reader.varint())
        XCTAssertEqual(RoachByteReader.zigzag(0), 0)
        XCTAssertEqual(RoachByteReader.zigzag(1), -1)
        XCTAssertEqual(RoachByteReader.zigzag(2), 1)
        XCTAssertEqual(RoachByteReader.zigzag(3), -2)
    }

    func testGeometryCommandsFromTheMVTSpec() throws {
        // Point (25, 17); line (2,2)→(2,10)→(10,10); polygon (3,6)→(8,12)→(20,34)→close.
        XCTAssertEqual(try RoachMVT.geometry([9, 50, 34]), [[CGPoint(x: 25, y: 17)]])
        XCTAssertEqual(try RoachMVT.geometry([9, 4, 4, 18, 0, 16, 16, 0]),
                       [[CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 10), CGPoint(x: 10, y: 10)]])
        let polygon = try RoachMVT.geometry([9, 6, 12, 18, 10, 12, 24, 44, 15])
        XCTAssertEqual(polygon.first?.count, 4)
        XCTAssertEqual(polygon.first?.first, polygon.first?.last)
        XCTAssertThrowsError(try RoachMVT.geometry([10, 1]))
    }

    func testGzipRoundTripThroughSystemGzip() throws {
        let original = Data((0..<20_000).map { UInt8(($0 * 7) % 251) })
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("roachnet-gzip-\(UUID().uuidString)")
        try original.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let gzipped = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(try RoachGzip.decompress(gzipped), original)
        XCTAssertEqual(try RoachGzip.decompress(original), original, "non-gzip data passes through")
    }

    func testForgedGzipSizeDoesNotDecideTheReservation() throws {
        // ISIZE comes from the file: a 20-byte member claiming 4 GB gets at most what DEFLATE could produce.
        XCTAssertEqual(RoachGzip.reservation(inputBytes: 20, hint: 0xFFFF_FFF0), 20 * 1032)
        XCTAssertEqual(RoachGzip.reservation(inputBytes: 10 << 20, hint: 4 << 30), 8 << 20)
        XCTAssertEqual(RoachGzip.reservation(inputBytes: 100, hint: 50), 50)
        XCTAssertEqual(RoachGzip.reservation(inputBytes: 100, hint: -5), 0)
        // A stored DEFLATE block whose gzip trailer lies about the size still inflates to the right bytes.
        let payload = Data("roachnet tile".utf8)
        var member = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        member.append(contentsOf: [0x01, UInt8(payload.count), 0x00, ~UInt8(payload.count), 0xFF])
        member.append(payload)
        member.append(contentsOf: [0, 0, 0, 0, 0xF0, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(try RoachGzip.decompress(member), payload)
    }

    @MainActor
    func testTileFromAnOlderArchiveSetIsDropped() throws {
        let store = RoachTileStore()
        store.open([fixtureURL.path])
        let stale = store.generation
        store.open([fixtureURL.path, fixtureURL.path])
        XCTAssertGreaterThan(store.generation, stale)
        let key = RoachTileStore.Key(archive: 0, z: 0, x: 0, y: 0)
        let before = store.version
        store.store(key, RoachRenderedTile.empty, generation: stale)
        XCTAssertEqual(store.version, before, "a load from the previous archive set lands nowhere")
        store.store(key, RoachRenderedTile.empty, generation: store.generation)
        XCTAssertEqual(store.version, before + 1)
    }

    func testRejectsFilesThatAreNotPMTiles() {
        XCTAssertThrowsError(try RoachPMTilesHeader.parse(Data(repeating: 0, count: 127))) { error in
            XCTAssertEqual(error as? RoachMapTileError, .notPMTiles)
        }
        XCTAssertThrowsError(try RoachPMTilesHeader.parse(Data("PMTiles".utf8)))
    }

    func testFixturePackOpensAndDecodes() throws {
        let archive = try RoachPMTilesArchive(path: fixtureURL.path)
        XCTAssertTrue(archive.isVector)
        XCTAssertEqual(archive.header.minZoom, 0)
        XCTAssertEqual(archive.header.maxZoom, 8)
        XCTAssertLessThan(archive.header.minLon, -75.5)
        XCTAssertGreaterThan(archive.header.maxLat, 39.5)

        let world = try XCTUnwrap(try archive.tile(z: 0, x: 0, y: 0))
        let layers = try RoachMVT.decode(world)
        XCTAssertTrue(layers.contains { $0.name == "earth" && !$0.features.isEmpty }, "\(layers.map(\.name))")

        let (x, y) = tileFor(lon: -75.52, lat: 39.16, z: 8)  // Dover, Delaware
        let local = try XCTUnwrap(try archive.tile(z: 8, x: x, y: y))
        let localLayers = try RoachMVT.decode(local)
        let roads = localLayers.first { $0.name == "roads" }
        XCTAssertNotNil(roads)
        XCTAssertTrue(roads?.features.contains { $0.properties["kind"]?.string == "highway" } ?? false)
        let rendered = RoachRenderedTile.build(localLayers, zoom: 8)
        XCTAssertNotNil(rendered.paths[.highway])
        XCTAssertNotNil(rendered.paths[.earth])

        XCTAssertNil(try archive.tile(z: 9, x: 0, y: 0), "past max zoom")
        XCTAssertNil(try archive.tile(z: 8, x: 0, y: 0), "outside the pack")
    }

    /// Full-size packs use leaf directories; point ROACHNET_TEST_MAP_PACK at one to exercise them.
    func testFullPackStreetLevelTile() throws {
        guard let path = ProcessInfo.processInfo.environment["ROACHNET_TEST_MAP_PACK"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set ROACHNET_TEST_MAP_PACK to a state pack, e.g. delaware_2026-10.pmtiles")
        }
        let archive = try RoachPMTilesArchive(path: path)
        XCTAssertEqual(archive.header.maxZoom, 15)
        let center = (lon: archive.header.centerLon, lat: archive.header.centerLat)
        let (x, y) = tileFor(lon: center.lon, lat: center.lat, z: 14)
        let data = try XCTUnwrap(try archive.tile(z: 14, x: x, y: y))
        let layers = try RoachMVT.decode(data)
        XCTAssertFalse(layers.isEmpty)
        let rendered = RoachRenderedTile.build(layers, zoom: 14)
        XCTAssertFalse(rendered.isEmpty)
    }

    func testMercatorRoundTrip() {
        let point = RoachMercator.project(lon: -75.52, lat: 39.16)
        let back = RoachMercator.unproject(point)
        XCTAssertEqual(back.lon, -75.52, accuracy: 1e-9)
        XCTAssertEqual(back.lat, 39.16, accuracy: 1e-9)
        XCTAssertEqual(RoachMercator.project(lon: 0, lat: 0).x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(RoachMercator.project(lon: 0, lat: 0).y, 0.5, accuracy: 1e-12)
    }
}
