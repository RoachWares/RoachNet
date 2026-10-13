import XCTest
@testable import RoachNetRuntime

/// Writes small stored (uncompressed) ZIP files with any entry name and Unix
/// mode, so the tests can build the archives a hostile pack would carry.
enum TestZip {
    struct Item {
        var name: String
        var data: Data = Data()
        var mode: UInt32 = 0o100644
        var method: Int = 0
        var flags: Int = 0
        /// false: a local file the directory doesn't list (only tools that walk the local headers see it).
        var listed = true
        /// false: no local record of its own; `directoryOffset` points into another file's data.
        var written = true
        var directoryOffset: Int?
        /// The name's bytes as written, when they aren't `name` in UTF-8.
        var rawName: Data?
        /// The extra block in the directory, and in the local header unless `localExtra` is set.
        var extra = Data()
        var localExtra: Data?
        /// The local header's flags, when they aren't `flags`.
        var localFlags: Int?

        var nameBytes: Data { rawName ?? Data(name.utf8) }
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

    private static func u16(_ value: Int, _ into: inout Data) { into.append(UInt8(value & 0xFF)); into.append(UInt8((value >> 8) & 0xFF)) }
    private static func u32(_ value: UInt32, _ into: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { into.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }

    /// The local file header and data `make` writes for `item`.
    static func localRecord(_ item: Item) -> Data {
        var out = Data()
        let name = item.nameBytes
        let extra = item.localExtra ?? item.extra
        u32(0x0403_4B50, &out); u16(20, &out); u16(item.localFlags ?? item.flags, &out); u16(item.method, &out); u16(0, &out); u16(0x21, &out)
        u32(crc32(item.data), &out); u32(UInt32(item.data.count), &out); u32(UInt32(item.data.count), &out)
        u16(name.count, &out); u16(extra.count, &out); out.append(name); out.append(extra); out.append(item.data)
        return out
    }

    /// `prefix` is written ahead of the first file, with every offset after it shifted to match.
    static func make(_ items: [Item], prefix: Data = Data()) -> Data {
        var out = prefix, directory = Data()
        var listed = 0
        for item in items {
            let offset = out.count
            if item.written { out.append(localRecord(item)) }
            guard item.listed else { continue }
            listed += 1
            let name = item.nameBytes
            u32(0x0201_4B50, &directory); u16(0x0314, &directory); u16(20, &directory); u16(item.flags, &directory); u16(item.method, &directory)
            u16(0, &directory); u16(0x21, &directory); u32(crc32(item.data), &directory); u32(UInt32(item.data.count), &directory)
            u32(UInt32(item.data.count), &directory); u16(name.count, &directory); u16(item.extra.count, &directory); u16(0, &directory)
            u16(0, &directory); u16(0, &directory); u32(item.mode << 16, &directory)
            u32(UInt32(item.directoryOffset ?? offset), &directory); directory.append(name); directory.append(item.extra)
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(listed, &out); u16(listed, &out)
        u32(UInt32(directory.count), &out); u32(directoryOffset, &out); u16(0, &out)
        return out
    }

    /// One DEFLATE entry (method 8) whose size fields claim `claimedSize`,
    /// whatever `stream` inflates to.
    static func deflated(name: String, stream: Data, crc: UInt32, claimedSize: UInt32) -> Data {
        var out = Data(), directory = Data()
        func u16(_ value: Int, _ into: inout Data) { into.append(UInt8(value & 0xFF)); into.append(UInt8((value >> 8) & 0xFF)) }
        func u32(_ value: UInt32, _ into: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { into.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        let nameData = Data(name.utf8)
        u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(8, &out); u16(0, &out); u16(0x21, &out)
        u32(crc, &out); u32(UInt32(stream.count), &out); u32(claimedSize, &out)
        u16(nameData.count, &out); u16(0, &out); out.append(nameData); out.append(stream)
        u32(0x0201_4B50, &directory); u16(0x0314, &directory); u16(20, &directory); u16(0, &directory); u16(8, &directory)
        u16(0, &directory); u16(0x21, &directory); u32(crc, &directory); u32(UInt32(stream.count), &directory)
        u32(claimedSize, &directory); u16(nameData.count, &directory); u16(0, &directory); u16(0, &directory)
        u16(0, &directory); u16(0, &directory); u32(0o100644 << 16, &directory); u32(0, &directory); directory.append(nameData)
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(1, &out); u16(1, &out)
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

    /// An Info-ZIP Unicode path field (0x7075): version 1, the CRC-32 of the header's name, the name in UTF-8.
    private func unicodePath(_ unicode: String, for header: String) -> Data {
        let crc = TestZip.crc32(Data(header.utf8))
        var body = Data([1])
        for shift in stride(from: 0, to: 32, by: 8) { body.append(UInt8((crc >> UInt32(shift)) & 0xFF)) }
        body.append(Data(unicode.utf8))
        return Data([0x75, 0x70, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]) + body
    }

    func testZipNamesSayHowTheyAreEncoded() throws {
        let cafe = "café.json"
        let json = Data("{}".utf8)
        // Without bit 11 the ZIP spec reads a name past ASCII as CP437 and
        // macOS's tools as UTF-8, so it is refused: plain, with a Unicode path
        // field that only some tools read, and in legacy CP437 bytes.
        for (file, item) in [
            ("legacy.zip", TestZip.Item(name: cafe, data: json)),
            ("legacy-field.zip", TestZip.Item(name: cafe, data: json, extra: unicodePath(cafe, for: cafe))),
            ("cp437.zip", TestZip.Item(name: "x", data: json, rawName: Data([0x63, 0x61, 0x66, 0x82, 0x2E, 0x6A]))),
        ] {
            XCTAssertThrowsError(try ZipArchive(path: try zip(file, [item])), file) { error in
                XCTAssertTrue("\(error)".contains("UTF-8"), "\(error)")
            }
        }
        // Bit 11 says UTF-8 and the name is read that way, with or without a field that repeats it.
        for (file, item) in [
            ("marked.zip", TestZip.Item(name: cafe, data: json, flags: 0x0800)),
            ("marked-field.zip", TestZip.Item(name: cafe, data: json, flags: 0x0800, extra: unicodePath(cafe, for: cafe))),
        ] {
            XCTAssertEqual(try ZipArchive(path: try zip(file, [item])).entries.map(\.name), [cafe], file)
        }
        // Bit 11 on bytes that aren't UTF-8, or in the directory but not the local header.
        for (file, item) in [
            ("broken.zip", TestZip.Item(name: "x", data: json, flags: 0x0800, rawName: Data([0x63, 0x61, 0x66, 0xE9, 0x2E, 0x6A]))),
            ("unmarked-local.zip", TestZip.Item(name: cafe, data: json, flags: 0x0800, localFlags: 0)),
        ] {
            XCTAssertThrowsError(try ZipArchive(path: try zip(file, [item])), file)
        }
        // A Unicode path field that names the file differently, in the directory
        // or only in the local header: unzip would unpack it under that name.
        for (file, item) in [
            ("renamed.zip", TestZip.Item(name: "a.json", data: json, extra: unicodePath("../b.json", for: "a.json"))),
            ("renamed-local.zip", TestZip.Item(name: "a.json", data: json, localExtra: unicodePath("../b.json", for: "a.json"))),
        ] {
            XCTAssertThrowsError(try ZipArchive(path: try zip(file, [item])), file)
        }
        // Plain ASCII names need neither, and other extra fields are left alone.
        let stamped = TestZip.Item(name: "a.json", data: json, extra: Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(try ZipArchive(path: try zip("stamped.zip", [stamped])).entries.map(\.name), ["a.json"])
    }

    /// Names are compared as the paths they unpack to. unzip writes "a/./b"
    /// over "a/b" without asking, so the reader refuses both before either
    /// unpacker runs, and a file can't sit where a folder is.
    func testZipNamesThatUnpackToTheSamePlaceAreRefused() throws {
        let json = Data("{}".utf8)
        let cases: [(String, [TestZip.Item])] = [
            ("dot.zip", [.init(name: "a/b.json", data: json), .init(name: "a/./b.json", data: json)]),
            ("slashes.zip", [.init(name: "a/b.json", data: json), .init(name: "a//b.json", data: json)]),
            ("leading-dot.zip", [.init(name: "b.json", data: json), .init(name: "./b.json", data: json)]),
            ("file-then-folder.zip", [.init(name: "a", data: json), .init(name: "a/b.json", data: json)]),
            ("file-and-folder-entry.zip", [.init(name: "a", data: json), .init(name: "a/", mode: 0o040755)]),
            ("case-folder.zip", [.init(name: "A", data: json), .init(name: "a/b.json", data: json)]),
            // One name in two Unicode normalization forms: one file on APFS, two on ext4.
            ("normalization.zip", [.init(name: "caf\u{E9}.json", data: json, flags: 0x0800),
                                   .init(name: "cafe\u{301}.json", data: json, flags: 0x0800)]),
            // Names that differ only by Unicode case folding, not by lowercasing:
            // APFS folds the final sigma to sigma, so these are one file there too.
            ("sigma.zip", [.init(name: "\u{3C3}.json", data: json, flags: 0x0800),
                           .init(name: "\u{3C2}.json", data: json, flags: 0x0800)]),
            ("sigma-folder.zip", [.init(name: "\u{3A3}", data: json, flags: 0x0800),
                                  .init(name: "\u{3C2}/b.json", data: json, flags: 0x0800)]),
        ]
        for (file, items) in cases {
            XCTAssertThrowsError(try ZipArchive(path: try zip(file, items)), file)
        }
        // A folder listed next to the files inside it, even twice, is fine.
        let folders: [TestZip.Item] = [.init(name: "a/", mode: 0o040755), .init(name: "a/b.json", data: json), .init(name: "a/./", mode: 0o040755)]
        XCTAssertEqual(try ZipArchive(path: try zip("folders.zip", folders)).entries.count, 3)
    }

    /// Both unpackers must write the same files. unzip writes a file entry
    /// named "." as "_" and leaves out only names that start with "__MACOSX/",
    /// so the reader refuses a file entry that names no file and any other
    /// spelling of that folder rather than skipping them where nothing checks.
    func testZipEntriesTheUnpackersWouldWriteDifferentlyAreRefused() throws {
        let json = Data("{}".utf8)
        let cases: [(String, [TestZip.Item], String)] = [
            ("dot.zip", [.init(name: ".", data: json), .init(name: "a.json", data: json)], "names no file"),
            ("dot-dot.zip", [.init(name: "./.", data: json)], "names no file"),
            ("dotted-rsrc.zip", [.init(name: "a.json", data: json), .init(name: "./__MACOSX/._a.json", data: json)], "__MACOSX"),
            ("rsrc-file.zip", [.init(name: "__MACOSX", data: json)], "__MACOSX"),
            ("rsrc-case.zip", [.init(name: "__macosx/._a.json", data: json)], "__MACOSX"),
            ("control.zip", [.init(name: "a\u{1}.json", data: json)], "control character"),
        ]
        for (file, items, expected) in cases {
            XCTAssertThrowsError(try PackArchive.inspect(try zip(file, items), format: "zip"), file) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(file): \(error)")
            }
        }
        // ditto's own resource-fork copies are left out, and a folder entry
        // that names the destination itself ("./") makes nothing.
        let path = try zip("rsrc.zip", [
            .init(name: "./", mode: 0o040755),
            .init(name: "a.json", data: json),
            .init(name: "__MACOSX/", mode: 0o040755),
            .init(name: "__MACOSX/._a.json", data: Data([0, 5, 22, 7])),
        ])
        let out = Path.join(root, "out-rsrc")
        try Files.mkdirp(out)
        try PackArchive.unpack(path, format: "zip", into: out)
        XCTAssertEqual(Files.entries(out).map(\.name), ["a.json"])
        // A tar listing is held to the same rule.
        let noFile = PackArchive.Entry(name: "./.", isDirectory: false, isLinkOrSpecial: false, uncompressedBytes: 1)
        XCTAssertThrowsError(try PackArchive.check([noFile], label: "listing", maxBytes: 64))
        let itself = PackArchive.Entry(name: "./", isDirectory: true, isLinkOrSpecial: false, uncompressedBytes: 0)
        XCTAssertNoThrow(try PackArchive.check([itself], label: "listing", maxBytes: 64))
    }

    /// unzip (the Linux unpacker) writes each stream whole: per-file sizes are
    /// checked after it, because two files can trade bytes and keep the total.
    func testFilesAnotherToolUnpackedMustHaveTheDirectorysSizes() throws {
        let archive = try ZipArchive(path: try zip("sizes.zip", [
            .init(name: "a/", mode: 0o040755),
            .init(name: "a/one.txt", data: Data("12345".utf8)),
            .init(name: "two.txt", data: Data("1234567".utf8)),
        ]))
        let destination = Path.join(root, "unpacked")
        try Files.mkdirp(Path.join(destination, "a"))
        try Files.write("12345", to: Path.join(destination, "a", "one.txt"))
        try Files.write("1234567", to: Path.join(destination, "two.txt"))
        XCTAssertNoThrow(try archive.checkUnpackedSizes(in: destination))

        try Files.write("1234567", to: Path.join(destination, "a", "one.txt"))
        try Files.write("12345", to: Path.join(destination, "two.txt"))
        XCTAssertThrowsError(try archive.checkUnpackedSizes(in: destination), "same total, different split")

        try Files.write("12345", to: Path.join(destination, "a", "one.txt"))
        Files.remove(Path.join(destination, "two.txt"))
        XCTAssertThrowsError(try archive.checkUnpackedSizes(in: destination), "missing file")
        try FileManager.default.createSymbolicLink(atPath: Path.join(destination, "two.txt"), withDestinationPath: Path.join(destination, "a", "one.txt"))
        XCTAssertThrowsError(try archive.checkUnpackedSizes(in: destination), "a link in the file's place")
    }

    func testEntryNamesThatLeaveTheFolderAreRefused() {
        for name in ["../escape.txt", "a/../../escape.txt", "/etc/escape.txt", "a\\..\\escape.txt", "C:escape.txt", "",
                     "a\u{1}.txt", "tab\there.txt", "del\u{7F}.txt"] {
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

    func testZipThatToolsCouldReadTwoWaysIsRefused() throws {
        let good = TestZip.make([.init(name: "aaaaaa.txt", data: Data("a".utf8))])
        XCTAssertEqual(try PackArchive.zipEntries(atPath: try zip(bytes: good, "good.zip")).map(\.name), ["aaaaaa.txt"])
        func refused(_ bytes: Data, _ file: String, _ expected: String) throws {
            let path = try zip(bytes: bytes, file)
            XCTAssertThrowsError(try PackArchive.zipEntries(atPath: path), file) { XCTAssertTrue("\($0)".contains(expected), "\(file): \($0)") }
        }

        // A second, empty end record in the real one's comment: ditto reads the
        // real directory, a backward scan for the signature finds the empty one.
        var hidden = good
        hidden[hidden.count - 2] = 22
        hidden.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        try refused(hidden, "hidden-end.zip", "more than one ZIP directory")

        // The local header says ../aaa.txt where the directory says aaaaaa.txt (ditto unpacks the local name).
        var renamed = good
        renamed.replaceSubrange(30..<40, with: Data("../aaa.txt".utf8))
        try refused(renamed, "renamed.zip", "differently")

        // Bytes between the directory and its end record.
        var gap = good
        gap.insert(contentsOf: [UInt8](repeating: 0x41, count: 8), at: gap.count - 22)
        try refused(gap, "gap.zip", "between its ZIP directory")

        // Data ahead of the first file (a stub, or another archive).
        try refused(TestZip.make([.init(name: "aaaaaa.txt", data: Data("a".utf8))], prefix: Data(repeating: 0x42, count: 16)), "prefix.zip", "before its first file")
    }

    /// Archives real tools write must read as one directory and unpack to
    /// exactly the files that went in. `ROACHNET_TEST_ZIPS` (colon-separated
    /// paths) adds archives from elsewhere, such as built speech packs.
    func testZipsThatSystemToolsWriteAreRead() throws {
        let made = Path.join(root, "made"), folder = Path.join(root, "made", "pack")
        try Files.mkdirp(Path.join(folder, "sub", "empty"))
        try Files.write("a", to: Path.join(folder, "a.txt"))
        try Files.write("", to: Path.join(folder, "zero.txt"))
        try Files.write("#!/bin/sh\n", to: Path.join(folder, "run.sh"))
        XCTAssertEqual(chmod(Path.join(folder, "run.sh"), 0o755), 0)
        try Data((0..<200_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }).write(to: URL(fileURLWithPath: Path.join(folder, "sub", "b.bin")))
        try Data(count: 300_000).write(to: URL(fileURLWithPath: Path.join(folder, "sub", "zeros.bin")))

        var archives: [String] = []
        #if os(macOS)
        let ditto = Path.join(root, "ditto.zip")
        XCTAssertEqual(Processes.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder, ditto]).status, 0)
        archives.append(ditto)
        #endif
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") {
            let plain = Path.join(root, "zip.zip"), streamed = Path.join(root, "streamed.zip")
            XCTAssertEqual(Processes.run("/usr/bin/zip", ["-q", "-r", plain, "pack"], cwd: made).status, 0)
            // Written to a pipe, zip can't seek back, so every file gets a data descriptor.
            XCTAssertEqual(Processes.run("/bin/sh", ["-c", "/usr/bin/zip -q -r - pack | cat > '\(streamed)'"], cwd: made).status, 0)
            archives += [plain, streamed]
        }
        XCTAssertFalse(archives.isEmpty)
        for archive in archives {
            let out = Path.join(root, "out-" + Path.basename(archive))
            try Files.mkdirp(out)
            XCTAssertNoThrow(try PackArchive.unpack(archive, format: "zip", into: out), archive)
            XCTAssertEqual(contents(of: Path.join(out, "pack")), contents(of: folder), archive)
            XCTAssertFalse(Files.exists(Path.join(out, "__MACOSX")), archive)
            XCTAssertEqual(Files.lstatInfo(Path.join(out, "pack", "run.sh")).map { $0.st_mode & 0o777 }, 0o755, archive)
            XCTAssertEqual(Files.lstatInfo(Path.join(out, "pack", "a.txt")).map { $0.st_mode & 0o777 }, 0o644, archive)
        }

        for path in (ProcessInfo.processInfo.environment["ROACHNET_TEST_ZIPS"] ?? "").split(separator: ":").map(String.init) {
            let entries = try PackArchive.zipEntries(atPath: path)
            XCTAssertFalse(entries.isEmpty, path)
            let out = Path.join(root, "out-" + Path.basename(path))
            try Files.mkdirp(out)
            XCTAssertNoThrow(try PackArchive.unpack(path, format: "zip", into: out), path)
            let files = entries.filter { !$0.isDirectory && !$0.name.hasPrefix("__MACOSX/") }
            for entry in files {
                let size = Files.lstatInfo(Path.join(out, entry.name)).map { UInt64($0.st_size) }
                XCTAssertEqual(size, entry.uncompressedBytes, entry.name)
            }
            Files.remove(out)
        }
    }

    /// Every file and folder under `folder`, with each file's bytes.
    private func contents(of folder: String) -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder)
        while let relative = enumerator?.nextObject() as? String {
            let path = Path.join(folder, relative)
            var isFolder: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            result[relative + (isFolder.boolValue ? "/" : "")] = isFolder.boolValue ? Data() : (FileManager.default.contents(atPath: path) ?? Data())
        }
        return result
    }

    private func zip(bytes: Data, _ name: String) throws -> String {
        let path = Path.join(root, name)
        try bytes.write(to: URL(fileURLWithPath: path))
        return path
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

    func testTarIsMeasuredBeforeItIsUnpacked() throws {
        // 3 MB of zeros packs into a few kilobytes, and `tar -t` lists no sizes the same way everywhere.
        let source = Path.join(root, "big")
        try Files.mkdirp(source)
        try Data(count: 3 << 20).write(to: URL(fileURLWithPath: Path.join(source, "zeros.bin")))
        let archive = Path.join(root, "big.tar.gz")
        XCTAssertEqual(Processes.run("/usr/bin/tar", ["-czf", archive, "-C", source, "zeros.bin"]).status, 0)

        let whole = try PackArchive.inflatedSize(of: archive, format: "tar.gz", limit: 64 << 20)
        XCTAssertGreaterThanOrEqual(whole, 3 << 20)
        let capped = try PackArchive.inflatedSize(of: archive, format: "tar.gz", limit: 1 << 20)
        XCTAssertGreaterThan(capped, 1 << 20)
        XCTAssertLessThan(capped, whole, "the count stops at the limit")
        XCTAssertThrowsError(try PackArchive.inspect(archive, format: "tar.gz", maxBytes: 1 << 20)) {
            XCTAssertTrue("\($0)".contains("more than 1 MB"), "\($0)")
        }
        XCTAssertNoThrow(try PackArchive.inspect(archive, format: "tar.gz", maxBytes: 64 << 20))

        let notGzip = Path.join(root, "plain.tar.gz")
        try Files.write("not gzip at all", to: notGzip)
        XCTAssertThrowsError(try PackArchive.inflatedSize(of: notGzip, format: "tar.gz", limit: 1 << 20))
    }

    func testZipWhoseSizesDisagreeWithItsDataIsRefused() throws {
        // ditto and unzip write a stream's whole length whatever the ZIP's size
        // fields claim. RoachNet's reader writes no more than an entry declares,
        // so a 3 MB stream that claims 100 bytes can't land.
        let input = Path.join(root, "zeros.bin")
        try Data(count: 3 << 20).write(to: URL(fileURLWithPath: input))
        XCTAssertEqual(Processes.run("/usr/bin/gzip", ["-n", "-k", "-f", input]).status, 0)
        // gzip -n: a 10-byte header, the raw DEFLATE stream, then CRC-32 and size.
        let gzip = try Data(contentsOf: URL(fileURLWithPath: input + ".gz"))
        let trailer = [UInt8](gzip.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let stream = gzip.subdata(in: 10..<(gzip.count - 8))
        /// Why unpacking failed ("" when it didn't), and how much of the file landed.
        func unpacked(_ name: String, crc: UInt32, claimedSize: UInt32) throws -> (String, Int) {
            let path = Path.join(root, name + ".zip"), out = Path.join(root, name)
            try TestZip.deflated(name: "zeros.bin", stream: stream, crc: crc, claimedSize: claimedSize).write(to: URL(fileURLWithPath: path))
            try Files.mkdirp(out)
            var failure = ""
            do { try PackArchive.unpack(path, format: "zip", into: out) } catch { failure = "\(error)" }
            let written = (try? FileManager.default.attributesOfItem(atPath: Path.join(out, "zeros.bin")))?[.size] as? Int ?? 0
            return (failure, written)
        }

        let understated = Path.join(root, "probe.zip")
        try TestZip.deflated(name: "zeros.bin", stream: stream, crc: crc, claimedSize: 100).write(to: URL(fileURLWithPath: understated))
        XCTAssertEqual(try PackArchive.zipEntries(atPath: understated).map(\.uncompressedBytes), [100], "the directory claims 100 bytes")
        XCTAssertGreaterThanOrEqual(try PackArchive.inflatedSize(of: understated, format: "zip", limit: 64 << 20), 3 << 20, "unzip -p writes the whole stream")

        // On Linux, where unzip unpacks, the measured size must match instead.
        let (more, written) = try unpacked("understated", crc: crc, claimedSize: 100)
        XCTAssertTrue(more.contains("more than the archive says") || more.contains("different size"), more)
        XCTAssertLessThanOrEqual(written, 100, "nothing past the declared size is written")

        let (less, _) = try unpacked("overstated", crc: crc, claimedSize: (3 << 20) + 10)
        XCTAssertTrue(less.contains("less than the archive says") || less.contains("different size"), less)

        let (corrupt, _) = try unpacked("bad-crc", crc: crc ^ 1, claimedSize: 3 << 20)
        XCTAssertFalse(corrupt.isEmpty, "a CRC-32 that doesn't match is refused")
        let (good, size) = try unpacked("exact", crc: crc, claimedSize: 3 << 20)
        XCTAssertEqual(good, "")
        XCTAssertEqual(size, 3 << 20)
    }

    func testZipFilesTheDirectoryDoesNotListOrThatOverlapAreRefused() throws {
        // ditto walks the local headers: it unpacked hidden.txt, which the
        // directory (and so the checks and unzip's size count) never listed.
        let hidden = TestZip.make([
            .init(name: "a.txt", data: Data("listed a".utf8)),
            .init(name: "hidden.txt", data: Data(repeating: 0x68, count: 4_096), listed: false),
            .init(name: "c.txt", data: Data("listed c".utf8)),
        ])
        try refusedZip(hidden, "hidden.zip", "between its files")
        let trailing = TestZip.make([.init(name: "a.txt", data: Data("a".utf8)), .init(name: "hidden.txt", data: Data("h".utf8), listed: false)])
        try refusedZip(trailing, "trailing.zip", "between its last file")

        // Two directory entries over the same bytes: b.txt's local record sits
        // inside a.txt's data (how a non-recursive zip bomb repeats one kernel).
        let inner = TestZip.Item(name: "b.txt", data: Data("b".utf8))
        let overlapping = TestZip.make([
            .init(name: "a.txt", data: TestZip.localRecord(inner)),
            .init(name: "b.txt", data: inner.data, written: false, directoryOffset: 30 + 5),
        ])
        try refusedZip(overlapping, "overlap.zip", "overlap")
    }

    func testZipFeaturesPacksDoNotUseAreRefused() throws {
        try refusedZip(TestZip.make([.init(name: "a.txt", data: Data("a".utf8), flags: 1)]), "encrypted.zip", "encrypted")
        try refusedZip(TestZip.make([.init(name: "a.txt", data: Data("a".utf8), method: 12)]), "bzip2.zip", "method 12")
        try refusedZip(TestZip.make([.init(name: "Read.txt", data: Data("1".utf8)), .init(name: "read.TXT", data: Data("2".utf8))]), "twice.zip", "twice")
        try refusedZip(TestZip.make([.init(name: "folder/", data: Data("x".utf8), mode: 0o040755)]), "folder.zip", "folder that holds data")
    }

    private func refusedZip(_ bytes: Data, _ file: String, _ expected: String) throws {
        let path = try zip(bytes: bytes, file)
        XCTAssertThrowsError(try PackArchive.zipEntries(atPath: path), file) { XCTAssertTrue("\($0)".contains(expected), "\(file): \($0)") }
        let out = Path.join(root, "out-" + file)
        try Files.mkdirp(out)
        XCTAssertThrowsError(try PackArchive.unpack(path, format: "zip", into: out), file)
        XCTAssertEqual(Files.entries(out).count, 0, "\(file): nothing is unpacked")
    }

    func testCRC32MatchesTheStandard() {
        var check = CRC32()
        check.update(Data("123456789".utf8))
        XCTAssertEqual(check.value, 0xCBF4_3926)
        let data = Data((0..<100_003).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 7) })
        var whole = CRC32()
        whole.update(data)
        XCTAssertEqual(whole.value, TestZip.crc32(data))
        var parts = CRC32()
        parts.update(data.prefix(7))
        parts.update(data.dropFirst(7))
        XCTAssertEqual(parts.value, whole.value)
    }

    func testFolderThatCannotBeReadIsStillCheckedAndModesComeOutPlain() throws {
        let tree = Path.join(root, "modes"), locked = Path.join(root, "modes", "locked")
        try Files.mkdirp(locked)
        try Files.write("x", to: Path.join(tree, "tool"))
        try Files.write("y", to: Path.join(tree, "data"))
        try Files.write("z", to: Path.join(locked, "inner.txt"))
        XCTAssertEqual(chmod(Path.join(tree, "tool"), 0o4755), 0)
        XCTAssertEqual(chmod(Path.join(tree, "data"), 0o666), 0)
        XCTAssertEqual(chmod(locked, 0o000), 0)
        XCTAssertNoThrow(try PackArchive.checkExtracted(tree, archiveName: "m.tar.gz"))
        XCTAssertEqual(Files.lstatInfo(Path.join(tree, "tool")).map { $0.st_mode & 0o7777 }, 0o755)
        XCTAssertEqual(Files.lstatInfo(Path.join(tree, "data")).map { $0.st_mode & 0o7777 }, 0o644)
        XCTAssertEqual(Files.lstatInfo(locked).map { $0.st_mode & 0o7777 }, 0o755)

        // A link inside a folder nobody could read is still found (it used to look empty).
        try FileManager.default.createSymbolicLink(atPath: Path.join(locked, "out"), withDestinationPath: "/etc")
        XCTAssertEqual(chmod(locked, 0o000), 0)
        XCTAssertThrowsError(try PackArchive.checkExtracted(tree, archiveName: "m.tar.gz")) { XCTAssertTrue("\($0)".contains("link"), "\($0)") }
        chmod(locked, 0o755)
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
    // MARK: Through the installer

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
