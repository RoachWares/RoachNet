import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Compression)
import Compression
#endif

/// RoachNet's own reader for pack ZIP archives.
///
/// The checks and the unpacking read the same central directory with the same
/// code, so nothing can be unpacked that the checks didn't see. That used to be
/// left to `ditto`, which also walks the local headers: it unpacked a file the
/// directory didn't list, which neither the checks nor the size count saw. An
/// archive is refused when it could be read more than one way: more than one
/// end record, ZIP and ZIP64 records that disagree, bytes the directory doesn't
/// account for, files that overlap, or a local header that disagrees with the
/// directory.
struct ZipArchive {
    struct Entry {
        let name: String
        let isDirectory: Bool
        /// A symbolic link, device, FIFO or socket by its Unix mode.
        let isLinkOrSpecial: Bool
        let isExecutable: Bool
        /// 0 (stored) or 8 (DEFLATE).
        let method: UInt64
        let flags: UInt64
        let crc32: UInt32
        let compressedBytes: UInt64
        let uncompressedBytes: UInt64
        let localOffset: UInt64
        /// Where the entry's data starts, past its local header.
        let dataOffset: UInt64
    }

    let path: String
    let entries: [Entry]

    init(path: String, maxEntries: Int = PackArchive.maxEntries) throws {
        self.path = path
        let label = Path.basename(path)
        func refused(_ what: String) -> PackError { PackError.integrity("Archive \(label) \(what).") }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw refused("could not be opened") }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw refused("is not a ZIP file") }
        func u16(_ bytes: [UInt8], _ at: Int) -> UInt64 { UInt64(bytes[at]) | UInt64(bytes[at + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt64 { u16(bytes, at) | u16(bytes, at + 2) << 16 }
        func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 { u32(bytes, at) | u32(bytes, at + 4) << 32 }
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }

        // The end-of-central-directory record sits in the last 64 KiB + 22 bytes,
        // and its comment runs exactly to the end of the file. An archive with
        // two such records (one hidden in the other's comment, say) is refused.
        let tailLength = min(size, 65_557)
        let tailStart = size - tailLength
        let tail = try read(tailStart, Int(tailLength))
        guard tail.count == Int(tailLength) else { throw refused("is truncated") }
        var candidates: [Int] = []
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06,
               index + 22 + Int(u16(tail, index + 20)) == tail.count {
                candidates.append(index)
            }
            index -= 1
        }
        guard let eocd = candidates.first else { throw refused("has no ZIP directory") }
        guard candidates.count == 1 else { throw refused("has more than one ZIP directory") }
        let eocdOffset = tailStart + UInt64(eocd)

        guard u16(tail, eocd + 4) == 0, u16(tail, eocd + 6) == 0 else { throw refused("spans several disks") }
        var count = u16(tail, eocd + 10)
        guard u16(tail, eocd + 8) == count else { throw refused("has a damaged ZIP directory") }
        var directorySize = u32(tail, eocd + 12)
        var directoryOffset = u32(tail, eocd + 16)
        var directoryEnd = eocdOffset
        // ZIP64: a locator just before the end record points at a ZIP64 end
        // record, which then holds the real counts and follows the directory.
        let locator = eocd - 20
        let hasZip64Locator = locator >= 0 && tail[locator] == 0x50 && tail[locator + 1] == 0x4B && tail[locator + 2] == 0x06 && tail[locator + 3] == 0x07
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF || hasZip64Locator {
            guard hasZip64Locator else { throw refused("has a damaged ZIP64 directory") }
            guard u32(tail, locator + 4) == 0, u32(tail, locator + 16) <= 1 else { throw refused("spans several disks") }
            let locatorOffset = tailStart + UInt64(locator)
            let recordOffset = u64(tail, locator + 8)
            guard recordOffset < locatorOffset, locatorOffset - recordOffset >= 56 else { throw refused("has a damaged ZIP64 directory") }
            let record = try read(recordOffset, 56)
            guard record.count == 56, record[0] == 0x50, record[1] == 0x4B, record[2] == 0x06, record[3] == 0x06 else {
                throw refused("has a damaged ZIP64 directory")
            }
            // The ZIP64 end record runs exactly to the locator.
            guard u64(record, 4) == locatorOffset - recordOffset - 12 else {
                throw refused("has data between its ZIP64 end record and locator")
            }
            guard u32(record, 16) == 0, u32(record, 20) == 0, u64(record, 24) == u64(record, 32) else { throw refused("spans several disks") }
            // Fields the classic end record doesn't max out must agree with the
            // ZIP64 record, or tools reading one or the other would differ.
            let (wide, size64, offset64) = (u64(record, 32), u64(record, 40), u64(record, 48))
            guard count == 0xFFFF || count == wide, directorySize == 0xFFFF_FFFF || directorySize == size64,
                  directoryOffset == 0xFFFF_FFFF || directoryOffset == offset64 else {
                throw refused("has ZIP and ZIP64 directories that disagree")
            }
            count = wide
            directorySize = size64
            directoryOffset = offset64
            directoryEnd = recordOffset
        }
        guard count <= UInt64(maxEntries) else { throw refused("has more than \(maxEntries) entries") }
        guard directorySize <= 256 << 20, directoryOffset <= size, directorySize <= size - directoryOffset else {
            throw refused("has a damaged ZIP directory")
        }
        guard directoryOffset + directorySize == directoryEnd else {
            throw refused("has data between its ZIP directory and the directory's end record")
        }
        guard count > 0 || directoryOffset == 0 else { throw refused("lists no files but holds data") }
        let directory = try read(directoryOffset, Int(directorySize))
        guard directory.count == Int(directorySize) else { throw refused("is truncated") }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 4_096)))
        var fileNames = Set<String>()
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, directory[cursor] == 0x50, directory[cursor + 1] == 0x4B,
                  directory[cursor + 2] == 0x01, directory[cursor + 3] == 0x02 else {
                throw refused("has a damaged ZIP directory")
            }
            let madeBy = u16(directory, cursor + 4) >> 8
            let flags = u16(directory, cursor + 8)
            let method = u16(directory, cursor + 10)
            let crc = UInt32(u32(directory, cursor + 16))
            var compressed = u32(directory, cursor + 20)
            var uncompressed = u32(directory, cursor + 24)
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            let external = u32(directory, cursor + 38)
            var localOffset = u32(directory, cursor + 42)
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw refused("has a damaged ZIP directory") }
            let wide = (uncompressed == 0xFFFF_FFFF, compressed == 0xFFFF_FFFF, localOffset == 0xFFFF_FFFF)
            if wide.0 || wide.1 || wide.2 {
                // The ZIP64 extra block holds, in order, whichever of the
                // uncompressed size, compressed size and local header offset are full.
                var found = false
                var extra = extraStart
                while extra + 4 <= extraStart + extraLength {
                    let tag = u16(directory, extra), length = Int(u16(directory, extra + 2))
                    guard extra + 4 + length <= extraStart + extraLength else { break }
                    if tag == 0x0001 {
                        var field = extra + 4
                        let end = field + length
                        let needed = 8 * [wide.0, wide.1, wide.2].filter { $0 }.count
                        guard field + needed <= end else { break }
                        if wide.0 { uncompressed = u64(directory, field); field += 8 }
                        if wide.1 { compressed = u64(directory, field); field += 8 }
                        if wide.2 { localOffset = u64(directory, field) }
                        found = true
                        break
                    }
                    extra += 4 + length
                }
                guard found else { throw refused("has a damaged ZIP64 entry") }
            }
            let nameBytes = Array(directory[nameStart..<extraStart])
            let name = String(decoding: nameBytes, as: UTF8.self)
            let isDirectory = name.hasSuffix("/")
            guard flags & 0x0001 == 0, flags & 0x0040 == 0, flags & 0x2000 == 0 else {
                throw refused("is encrypted (\"\(name)\"); packs can't be")
            }
            guard method == 0 || method == 8 else {
                throw refused("compresses \"\(name)\" with method \(method); RoachNet reads stored and DEFLATE entries only")
            }
            guard method == 8 || compressed == uncompressed else { throw refused("has a damaged entry (\"\(name)\")") }
            if isDirectory {
                guard uncompressed == 0 else { throw refused("has a folder that holds data (\"\(name)\")") }
            } else {
                // One name, one file, even on a volume that ignores case.
                guard fileNames.insert(name.lowercased()).inserted else { throw refused("names \"\(name)\" twice") }
            }

            // The local header must describe the same file: tools that walk the
            // local headers (ditto does) would otherwise read another archive.
            guard localOffset < directoryOffset, directoryOffset - localOffset >= UInt64(30 + nameLength) else {
                throw refused("has a damaged ZIP directory")
            }
            let local = try read(localOffset, 30 + nameLength)
            let differently = refused("describes a file differently in its directory and its local header (\"\(name)\")")
            guard local.count == 30 + nameLength, local[0] == 0x50, local[1] == 0x4B, local[2] == 0x03, local[3] == 0x04,
                  Int(u16(local, 26)) == nameLength, Array(local[30...]) == nameBytes,
                  u16(local, 8) == method, u16(local, 6) & 0x0009 == flags & 0x0009 else {
                throw differently
            }
            if flags & 0x0008 == 0, u32(local, 18) != 0xFFFF_FFFF, u32(local, 22) != 0xFFFF_FFFF {
                // Without a data descriptor the local header carries the sizes too.
                guard u32(local, 14) == UInt64(crc), u32(local, 18) == compressed, u32(local, 22) == uncompressed else { throw differently }
            }
            let dataOffset = localOffset + 30 + UInt64(nameLength) + u16(local, 28)
            guard dataOffset <= directoryOffset, compressed <= directoryOffset - dataOffset else {
                throw refused("has a damaged ZIP directory")
            }
            // Unix and macOS writers keep the file type in the high half of the external attributes.
            var special = false, executable = false
            if madeBy == 3 || madeBy == 19 {
                let mode = external >> 16
                let type = mode & 0o170000
                special = type != 0 && type != 0o100000 && type != 0o040000
                executable = mode & 0o100 != 0
            }
            entries.append(Entry(name: name, isDirectory: isDirectory, isLinkOrSpecial: special, isExecutable: executable,
                                 method: method, flags: flags, crc32: crc, compressedBytes: compressed,
                                 uncompressedBytes: uncompressed, localOffset: localOffset, dataOffset: dataOffset))
            cursor = next
        }
        guard cursor == directory.count else { throw refused("has more in its ZIP directory than it lists") }

        // Files sit one after another from the start of the archive to the
        // directory: nothing ahead of the first, nothing between two but a data
        // descriptor, and no two overlapping, so the archive reads one way.
        var expected: UInt64 = 0
        var slack: Set<UInt64> = [0]
        for entry in entries.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard entry.localOffset >= expected else { throw refused("has files that overlap") }
            guard slack.contains(entry.localOffset - expected) else {
                throw refused(expected == 0 ? "has data before its first file" : "has data between its files")
            }
            expected = entry.dataOffset + entry.compressedBytes
            slack = entry.flags & 0x0008 != 0 ? [12, 16, 20, 24] : [0]
        }
        guard directoryOffset >= expected, slack.contains(directoryOffset - expected) else {
            throw refused(entries.isEmpty ? "lists no files but holds data" : "has data between its last file and its ZIP directory")
        }
        self.entries = entries
    }

    // MARK: Unpacking

    /// Unpacks every entry into `destination`, an empty folder. Each file is
    /// read from where the directory says it starts and created new: never
    /// through a link, never over another file, exactly as long as the
    /// directory says and matching its CRC-32. Folders are 0755 and files 0644
    /// (0755 when the archive marks them executable). `__MACOSX/`, the
    /// resource-fork copies `ditto --sequesterRsrc` adds, is left out.
    func unpack(into destination: String) throws {
        let label = Path.basename(path)
        #if canImport(Compression)
        let source = open(path, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw PackError.integrity("Archive \(label) could not be opened.") }
        defer { close(source) }
        let capacity = 1 << 20
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer {
            input.deallocate()
            output.deallocate()
        }
        for entry in entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
            guard let first = parts.first, first != "__MACOSX" else { continue }
            if entry.isDirectory {
                try makeFolders(parts, in: destination)
                continue
            }
            try makeFolders(Array(parts.dropLast()), in: destination)
            let target = destination + "/" + parts.joined(separator: "/")
            let mode: mode_t = entry.isExecutable ? 0o755 : 0o644
            let file = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            guard file >= 0 else {
                if errno == EEXIST { throw PackError.integrity("Archive \(label) names \"\(entry.name)\" twice.") }
                throw PackError.installFailed("Unpacking \(entry.name) from \(label) failed: \(String(cString: strerror(errno))).")
            }
            defer { close(file) }
            let crc = entry.method == 0
                ? try copyStored(entry, from: source, to: file, buffer: input, capacity: capacity)
                : try inflate(entry, from: source, to: file, input: input, output: output, capacity: capacity)
            guard crc == entry.crc32 else { throw PackError.integrity("Archive \(label): \"\(entry.name)\" doesn't match its CRC-32.") }
            guard fchmod(file, mode) == 0 else { throw PackError.installFailed("Unpacking \(entry.name) from \(label) failed: \(String(cString: strerror(errno))).") }
        }
        #else
        // Without Apple's Compression (Linux CI), unzip unpacks; it reads the
        // same central directory, and `PackArchive.inspect` has measured that
        // every stream is exactly as long as the directory says.
        let result = Processes.run("/usr/bin/unzip", ["-qq", "-o", path, "-x", "__MACOSX/*", "-d", destination],
                                   timeoutMs: 600_000, environment: Processes.archiveToolEnvironment)
        guard result.status == 0 else { throw PackError.installFailed("Extracting \(label) failed: \(result.errorOutput)") }
        #endif
    }

    /// Creates each folder of `parts` under `root` that doesn't exist yet;
    /// one that does must be a real folder, not a file or a link.
    private func makeFolders(_ parts: [String], in root: String) throws {
        var folder = root
        for part in parts {
            folder += "/" + part
            if let info = Files.lstatInfo(folder) {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw PackError.integrity("Archive \(Path.basename(path)) puts a file and a folder at the same place (\"\(part)\").")
                }
                continue
            }
            guard mkdir(folder, 0o755) == 0, chmod(folder, 0o755) == 0 else {
                throw PackError.installFailed("Unpacking \(Path.basename(path)) failed: \(String(cString: strerror(errno))).")
            }
        }
    }

    private func writeAll(_ file: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ entry: Entry) throws {
        var done = 0
        while done < count {
            let wrote = write(file, bytes + done, count - done)
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else {
                throw PackError.installFailed("Unpacking \(entry.name) from \(Path.basename(path)) failed: \(String(cString: strerror(errno))).")
            }
            done += wrote
        }
    }

    private func readAt(_ source: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: UInt64, _ entry: Entry) throws -> Int {
        while true {
            let got = pread(source, buffer, count, off_t(offset))
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw PackError.integrity("Archive \(Path.basename(path)) is truncated (\"\(entry.name)\").") }
            return got
        }
    }

    private func copyStored(_ entry: Entry, from source: Int32, to file: Int32, buffer: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> UInt32 {
        var crc = CRC32()
        var offset = entry.dataOffset
        var left = entry.uncompressedBytes
        while left > 0 {
            let got = try readAt(source, buffer, Int(min(UInt64(capacity), left)), offset, entry)
            crc.update(UnsafeRawBufferPointer(start: buffer, count: got))
            try writeAll(file, buffer, got, entry)
            offset += UInt64(got)
            left -= UInt64(got)
        }
        return crc.value
    }

    #if canImport(Compression)
    /// Inflates a DEFLATE entry (Compression's ZLIB algorithm is headerless
    /// DEFLATE). The stream must end exactly at the entry's compressed size
    /// and inflate to exactly its uncompressed size: writing stops the moment
    /// it would pass that size, so an entry can't unpack to more than the
    /// archive declares.
    private func inflate(_ entry: Entry, from source: Int32, to file: Int32,
                         input: UnsafeMutablePointer<UInt8>, output: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> UInt32 {
        let label = Path.basename(path)
        let damaged = PackError.integrity("Archive \(label) has damaged compressed data (\"\(entry.name)\").")
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw damaged }
        defer { compression_stream_destroy(stream) }
        var crc = CRC32()
        var offset = entry.dataOffset
        var left = entry.compressedBytes
        var written: UInt64 = 0
        stream.pointee.src_size = 0
        while true {
            if stream.pointee.src_size == 0, left > 0 {
                let got = try readAt(source, input, Int(min(UInt64(capacity), left)), offset, entry)
                offset += UInt64(got)
                left -= UInt64(got)
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = got
            }
            let pending = stream.pointee.src_size
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = capacity
            let status = compression_stream_process(stream, left == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            let produced = capacity - stream.pointee.dst_size
            if produced > 0 {
                written += UInt64(produced)
                guard written <= entry.uncompressedBytes else {
                    throw PackError.integrity("Archive \(label): \"\(entry.name)\" unpacks to more than the archive says.")
                }
                crc.update(UnsafeRawBufferPointer(start: output, count: produced))
                try writeAll(file, output, produced, entry)
            }
            switch status {
            case COMPRESSION_STATUS_END:
                // Nothing may follow the end of the stream inside the entry.
                guard left == 0, stream.pointee.src_size == 0 else { throw damaged }
                guard written == entry.uncompressedBytes else {
                    throw PackError.integrity("Archive \(label): \"\(entry.name)\" unpacks to less than the archive says.")
                }
                return crc.value
            case COMPRESSION_STATUS_OK:
                // All input given, none taken, nothing out: the stream stops short.
                if left == 0, produced == 0, stream.pointee.src_size == pending { throw damaged }
            default:
                throw damaged
            }
        }
    }
    #endif
}

/// CRC-32 as ZIP and gzip use it (IEEE 802.3, reflected), eight bytes at a time.
struct CRC32 {
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            tables[index] = value
        }
        for slice in 1..<8 {
            for index in 0..<256 {
                let previous = tables[(slice - 1) * 256 + index]
                tables[slice * 256 + index] = (previous >> 8) ^ tables[Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    private var state: UInt32 = 0xFFFF_FFFF
    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        var crc = state
        var index = 0
        let count = bytes.count
        Self.tables.withUnsafeBufferPointer { table in
            while index + 8 <= count {
                let one = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: index, as: UInt32.self)) ^ crc
                let two = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self))
                crc = table[7 * 256 + Int(one & 0xFF)] ^ table[6 * 256 + Int((one >> 8) & 0xFF)]
                    ^ table[5 * 256 + Int((one >> 16) & 0xFF)] ^ table[4 * 256 + Int(one >> 24)]
                    ^ table[3 * 256 + Int(two & 0xFF)] ^ table[2 * 256 + Int((two >> 8) & 0xFF)]
                    ^ table[256 + Int((two >> 16) & 0xFF)] ^ table[Int(two >> 24)]
                index += 8
            }
            while index < count {
                crc = table[Int((crc ^ UInt32(base.load(fromByteOffset: index, as: UInt8.self))) & 0xFF)] ^ (crc >> 8)
                index += 1
            }
        }
        state = crc
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }
}
