import XCTest
@testable import RoachNetRuntime

/// Writes small stored (uncompressed) ZIP files with any entry name and Unix
/// mode, so the tests can build the archives a hostile pack would carry.
enum TestZip {
    struct Item {
        var name: String
        var data: Data = Data()
        var mode: UInt32 = 0o100644
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func make(_ items: [Item]) -> Data {
        var out = Data(), directory = Data()
        func u16(_ value: Int, _ into: inout Data) { into.append(UInt8(value & 0xFF)); into.append(UInt8((value >> 8) & 0xFF)) }
        func u32(_ value: UInt32, _ into: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { into.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        for item in items {
            let name = Data(item.name.utf8)
            let crc = crc32(item.data)
            let offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(item.data.count), &out); u32(UInt32(item.data.count), &out)
            u16(name.count, &out); u16(0, &out); out.append(name); out.append(item.data)
            u32(0x0201_4B50, &directory); u16(0x0314, &directory); u16(20, &directory); u16(0, &directory); u16(0, &directory)
            u16(0, &directory); u16(0x21, &directory); u32(crc, &directory); u32(UInt32(item.data.count), &directory)
            u32(UInt32(item.data.count), &directory); u16(name.count, &directory); u16(0, &directory); u16(0, &directory)
            u16(0, &directory); u16(0, &directory); u32(item.mode << 16, &directory); u32(offset, &directory); directory.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(items.count, &out); u16(items.count, &out)
        u32(UInt32(directory.count), &out); u32(directoryOffset, &out); u16(0, &out)
        return out
    }
}

final class PackArchiveTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-pack-archive-tests-" + JS.randomHex(6)
        try Files.mkdirp(root)
    }

    override func tearDownWithError() throws {
        Files.remove(root)
    }

    private func zip(_ name: String, _ items: [TestZip.Item]) throws -> String {
        let path = Path.join(root, name)
        try TestZip.make(items).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testEntryNamesThatLeaveTheFolderAreRefused() {
        for name in ["../escape.txt", "a/../../escape.txt", "/etc/escape.txt", "a\\..\\escape.txt", "C:escape.txt", ""] {
            XCTAssertNotNil(PackArchive.problem(withEntryName: name), name)
        }
        for name in ["themes/a.json", "./themes/", "a..b/c", "...", "themes/.hidden"] {
            XCTAssertNil(PackArchive.problem(withEntryName: name), name)
        }
    }

    func testZipDirectoryIsReadWithoutExtracting() throws {
        let path = try zip("good.zip", [
            .init(name: "themes/", mode: 0o040755),
            .init(name: "themes/a.json", data: Data("{}".utf8)),
        ])
        let entries = try PackArchive.zipEntries(atPath: path)
        XCTAssertEqual(entries.map(\.name), ["themes/", "themes/a.json"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, false])
        XCTAssertFalse(entries.contains(where: \.isLinkOrSpecial))
        XCTAssertEqual(entries[1].uncompressedBytes, 2)
        XCTAssertNoThrow(try PackArchive.inspect(path, format: "zip"))
    }

    func testZipWithEscapingNamesOrLinksIsRefusedBeforeExtraction() throws {
        let cases: [(String, TestZip.Item, String)] = [
            ("dots.zip", .init(name: "../escape.txt", data: Data("x".utf8)), ".."),
            ("absolute.zip", .init(name: "/tmp/escape.txt", data: Data("x".utf8)), "absolute"),
            ("link.zip", .init(name: "link", data: Data("/etc".utf8), mode: 0o120777), "link"),
            ("fifo.zip", .init(name: "pipe", mode: 0o010644), "link or a special file"),
        ]
        for (file, item, expected) in cases {
            let path = try zip(file, [.init(name: "ok.txt", data: Data("ok".utf8)), item])
            XCTAssertThrowsError(try PackArchive.inspect(path, format: "zip"), file) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(file): \(error)")
            }
        }
    }

    func testDamagedZipIsRefused() throws {
        let path = Path.join(root, "not.zip")
        try Data("not a zip at all, just text that is long enough".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try PackArchive.zipEntries(atPath: path))
        var bytes = [UInt8](TestZip.make([.init(name: "a.txt", data: Data("a".utf8))]))
        // Point the directory past the end of the file.
        let eocd = bytes.count - 22
        bytes[eocd + 16] = 0xFF; bytes[eocd + 17] = 0xFF; bytes[eocd + 18] = 0xFF; bytes[eocd + 19] = 0x7F
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try PackArchive.zipEntries(atPath: path))
    }

    func testTarListingFlagsLinksAndEscapes() throws {
        let source = Path.join(root, "src")
        try Files.mkdirp(Path.join(source, "themes"))
        try Files.write("{}", to: Path.join(source, "themes", "a.json"))
        let good = Path.join(root, "good.tar.gz")
        XCTAssertEqual(Processes.run("/usr/bin/tar", ["-czf", good, "-C", source, "themes"]).status, 0)
        XCTAssertNoThrow(try PackArchive.inspect(good, format: "tar.gz"))

        try FileManager.default.createSymbolicLink(atPath: Path.join(source, "themes", "link"), withDestinationPath: "/etc")
        let linked = Path.join(root, "linked.tar.gz")
        XCTAssertEqual(Processes.run("/usr/bin/tar", ["-czf", linked, "-C", source, "themes"]).status, 0)
        XCTAssertThrowsError(try PackArchive.inspect(linked, format: "tar.gz")) { XCTAssertTrue("\($0)".contains("link"), "\($0)") }
    }

    func testExtractedTreeWithALinkOrHardLinkIsRefused() throws {
        let tree = Path.join(root, "tree")
        try Files.mkdirp(Path.join(tree, "a"))
        try Files.write("x", to: Path.join(tree, "a", "file.txt"))
        XCTAssertNoThrow(try PackArchive.checkExtracted(tree, archiveName: "t.zip"))
        try FileManager.default.linkItem(atPath: Path.join(tree, "a", "file.txt"), toPath: Path.join(tree, "a", "twin.txt"))
        XCTAssertThrowsError(try PackArchive.checkExtracted(tree, archiveName: "t.zip")) { XCTAssertTrue("\($0)".contains("hard link"), "\($0)") }
        Files.remove(Path.join(tree, "a", "twin.txt"))
        try FileManager.default.createSymbolicLink(atPath: Path.join(tree, "a", "out"), withDestinationPath: "/etc")
        XCTAssertThrowsError(try PackArchive.checkExtracted(tree, archiveName: "t.zip")) { XCTAssertTrue("\($0)".contains("link"), "\($0)") }
    }

    func testMergeFillsFoldersButNeverReplacesAFile() throws {
        let source = Path.join(root, "from"), destination = Path.join(root, "to")
        try Files.mkdirp(Path.join(source, "model"))
        try Files.write("new", to: Path.join(source, "model", "extra.bin"))
        try Files.mkdirp(Path.join(destination, "model"))
        try Files.write("old", to: Path.join(destination, "model", "weights.bin"))
        try PackArchive.merge(source, into: destination, archiveName: "x.zip")
        XCTAssertEqual(Files.readText(Path.join(destination, "model", "extra.bin")), "new")
        XCTAssertEqual(Files.readText(Path.join(destination, "model", "weights.bin")), "old")

        try Files.mkdirp(Path.join(source, "model"))
        try Files.write("evil", to: Path.join(source, "model", "weights.bin"))
        XCTAssertThrowsError(try PackArchive.merge(source, into: destination, archiveName: "x.zip")) { XCTAssertTrue("\($0)".contains("would replace"), "\($0)") }
        XCTAssertEqual(Files.readText(Path.join(destination, "model", "weights.bin")), "old")
    }

    #if os(macOS)
    // MARK: Through the installer (ditto)

    private func registry() -> PackRegistry {
        PackRegistry(storageRoot: Path.join(root, "storage"), appVersion: "1.1.0", platform: "macos")
    }

    private func package(_ id: String, archive: Data, extra: [String: Data] = [:]) throws -> String {
        var resources = [PackResource(path: "assets/content.zip", sha256: SHA256Digest.hex(archive), bytes: archive.count, archive: "zip")]
        for (path, data) in extra.sorted(by: { $0.key < $1.key }) {
            resources.append(PackResource(path: path, sha256: SHA256Digest.hex(data), bytes: data.count))
        }
        let manifest = PackManifest(id: id, version: "1.0.0", kind: .resource, name: "Archive pack \(id)",
                                    requires: PackRequirements(roachnet: "1.1.0"), resources: resources)
        let folder = Path.join(root, "pkg-\(id)")
        try Files.mkdirp(Path.join(folder, "assets"))
        try Files.write(try manifest.encoded(), to: Path.join(folder, "manifest.json"))
        try archive.write(to: URL(fileURLWithPath: Path.join(folder, "assets", "content.zip")))
        for (path, data) in extra {
            try Files.mkdirp(Path.dirname(Path.join(folder, path)))
            try data.write(to: URL(fileURLWithPath: Path.join(folder, path)))
        }
        return folder
    }

    func testArchivePackUnpacksInsideItsFolderAndLeavesNoScratch() throws {
        let archive = TestZip.make([.init(name: "themes/", mode: 0o040755), .init(name: "themes/a.json", data: Data("{}".utf8))])
        let registry = registry()
        let record = try PackInstaller(registry: registry).installLocalPackage(at: try package("archive-pack", archive: archive))
        let installed = registry.installRoot(for: "archive-pack", version: "1.0.0")
        XCTAssertTrue(record.isInstalled)
        XCTAssertEqual(Files.readText(Path.join(installed, "assets", "themes", "a.json")), "{}")
        XCTAssertFalse(Files.exists(Path.join(installed, "assets", "content.zip")), "the archive itself is removed")
        XCTAssertFalse(Files.entries(Path.join(installed, "assets")).contains { $0.name.hasPrefix(".extract-") })
    }

    func testArchivePackWithALinkOrEscapeIsRefusedAndNothingLands() throws {
        let outside = Path.join(root, "outside")
        try Files.mkdirp(outside)
        let hostile: [(String, Data)] = [
            ("link-pack", TestZip.make([.init(name: "out", data: Data(outside.utf8), mode: 0o120777), .init(name: "out/x.txt", data: Data("x".utf8))])),
            ("dots-pack", TestZip.make([.init(name: "../../escape.txt", data: Data("x".utf8))])),
        ]
        let registry = registry()
        for (id, archive) in hostile {
            XCTAssertThrowsError(try PackInstaller(registry: registry).installLocalPackage(at: try package(id, archive: archive)), id)
            XCTAssertNil(registry.record(id)?.state, id)
            XCTAssertFalse(Files.exists(registry.installRoot(for: id, version: "1.0.0")), id)
        }
        XCTAssertEqual(Files.entries(outside).count, 0, "nothing was written outside")
        XCTAssertEqual(Files.entries(registry.stagingRoot).count, 0, "no staging folder is left behind")
    }

    func testArchiveCannotReplaceAnotherVerifiedResource() throws {
        let weights = Data("verified weights".utf8)
        let archive = TestZip.make([.init(name: "weights.bin", data: Data("swapped".utf8))])
        let registry = registry()
        // The archive unpacks into assets/, where assets/weights.bin already sits verified.
        XCTAssertThrowsError(try PackInstaller(registry: registry).installLocalPackage(at: try package("swap-pack", archive: archive, extra: ["assets/weights.bin": weights]))) {
            XCTAssertTrue("\($0)".contains("would replace"), "\($0)")
        }
        XCTAssertNil(registry.record("swap-pack")?.state)
    }
    #endif
}
