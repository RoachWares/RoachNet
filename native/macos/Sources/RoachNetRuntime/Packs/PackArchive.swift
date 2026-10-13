import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Keeps a pack archive inside the folder it unpacks into.
///
/// The archive's SHA-256 only proves it is the archive the manifest named, not
/// that it is well behaved, and manifests can come from a URL or a folder the
/// person picked. So an archive is read before anything is extracted (names
/// that are absolute or climb out with `..`, links, devices, and how much it
/// unpacks to), unpacked into an empty folder of its own, walked again with
/// `lstat`, and only then moved into place, never over a file that is
/// already there.
enum PackArchive {
    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        /// A symbolic or hard link, or a device, FIFO or socket.
        let isLinkOrSpecial: Bool
        let uncompressedBytes: UInt64
    }

    static let maxEntries = 200_000
    static let maxUncompressedBytes: UInt64 = 64 << 30

    // MARK: Names

    /// Why an entry name may not be unpacked, or nil when it is fine.
    static func problem(withEntryName name: String) -> String? {
        if name.isEmpty { return "an entry has no name" }
        if name.utf8.count > 4_096 { return "an entry name is too long" }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) { return "\"\(name)\" contains a NUL character" }
        if name.hasPrefix("/") { return "\"\(name)\" is an absolute path" }
        if name.contains("\\") { return "\"\(name)\" uses a backslash" }
        if name.count >= 2, name.dropFirst().first == ":", name.first?.isLetter == true { return "\"\(name)\" names a drive" }
        if name.split(separator: "/", omittingEmptySubsequences: true).contains("..") { return "\"\(name)\" climbs out with .." }
        return nil
    }

    // MARK: Before extracting

    /// Reads what the archive holds and refuses it when any entry could land
    /// outside the folder or is not a plain file or folder, or when it would
    /// unpack to more than `maxBytes`.
    static func inspect(_ archivePath: String, format: String, maxBytes: UInt64 = maxUncompressedBytes) throws {
        let label = Path.basename(archivePath)
        let tooLarge = PackError.integrity("Archive \(label) unpacks to more than \(sizeText(maxBytes)).")
        let entries: [Entry]
        switch format {
        case "zip": entries = try zipEntries(atPath: archivePath)
        case "tar.gz", "tgz":
            // `tar -t` doesn't list sizes the same way on every system, so the
            // gzip stream is measured first: it holds every file's bytes, and
            // the count stops at the limit instead of inflating all of it.
            guard try inflatedSize(of: archivePath, format: format, limit: maxBytes) <= maxBytes else { throw tooLarge }
            entries = try tarEntries(atPath: archivePath)
        default: throw PackError.installFailed("Unsupported archive type \(format).")
        }
        guard entries.count <= maxEntries else { throw PackError.integrity("Archive \(label) has more than \(maxEntries) entries.") }
        var total: UInt64 = 0
        for entry in entries {
            if let problem = problem(withEntryName: entry.name) {
                throw PackError.integrity("Archive \(label) can't be unpacked: \(problem).")
            }
            if entry.isLinkOrSpecial {
                throw PackError.integrity("Archive \(label) can't be unpacked: \"\(entry.name)\" is a link or a special file.")
            }
            let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedBytes)
            guard !overflow, sum <= maxBytes else { throw tooLarge }
            total = sum
        }
        if format == "zip" {
            // A ZIP's size fields can understate what ditto and unzip write
            // (both write the whole stream), so the real size is measured too.
            guard try inflatedSize(of: archivePath, format: format, limit: maxBytes) <= maxBytes else { throw tooLarge }
        }
    }

    static func sizeText(_ bytes: UInt64) -> String {
        bytes >= 1 << 30 ? "\(bytes >> 30) GB" : "\(max(1, bytes >> 20)) MB"
    }

    /// How many bytes an archive inflates to, found by inflating it into a
    /// pipe and counting (`gzip -dc` for a .tar.gz, `unzip -p` for a zip).
    /// Counting stops once it passes `limit`, so an archive that inflates to
    /// terabytes costs only the time to inflate `limit` bytes, and nothing is
    /// written to disk.
    static func inflatedSize(of path: String, format: String, limit: UInt64) throws -> UInt64 {
        let zip = format == "zip"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zip ? "/usr/bin/unzip" : "/usr/bin/gzip")
        process.arguments = zip ? ["-p", path] : ["-dc", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let reader = pipe.fileHandleForReading
        var total: UInt64 = 0
        var stopped = false
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += UInt64(chunk.count)
            if total > limit {
                stopped = true
                process.terminate()
                break
            }
        }
        try? reader.close()
        process.waitUntilExit()
        // unzip's 1 means warnings only: everything was still read.
        let finished = process.terminationStatus == 0 || (zip && process.terminationStatus == 1)
        if !stopped, !finished {
            throw PackError.integrity("Archive \(Path.basename(path)) couldn't be read to measure it.")
        }
        return total
    }

    /// The names and types `tar` lists, in archive order. Sizes are left at
    /// zero; `inspect` measures the whole stream instead.
    static func tarEntries(atPath path: String) throws -> [Entry] {
        let names = Processes.run("/usr/bin/tar", ["-tzf", path], timeoutMs: 600_000)
        let verbose = Processes.run("/usr/bin/tar", ["-tvzf", path], timeoutMs: 600_000)
        guard names.status == 0, verbose.status == 0 else {
            throw PackError.integrity("Archive \(Path.basename(path)) could not be read: \(names.errorOutput.isEmpty ? verbose.errorOutput : names.errorOutput)")
        }
        let nameLines = names.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let typeLines = verbose.output.split(separator: "\n", omittingEmptySubsequences: true)
        guard nameLines.count == typeLines.count else {
            throw PackError.integrity("Archive \(Path.basename(path)) lists its entries inconsistently.")
        }
        return zip(nameLines, typeLines).map { name, line in
            // `tar -tv` starts each line with the entry type: `-` file, `d` folder;
            // `l`, `h`, `c`, `b`, `p` are links and special files.
            let type = line.first ?? "?"
            return Entry(name: name, isDirectory: type == "d", isLinkOrSpecial: type != "-" && type != "d", uncompressedBytes: 0)
        }
    }

    /// Reads a ZIP's central directory (ZIP64 included) without extracting
    /// anything, and refuses an archive that tools could read two ways: more
    /// than one end record, data between the directory and its end record or
    /// before the first file, or a local file header whose name differs from
    /// the directory's (ditto unpacks the local name).
    static func zipEntries(atPath path: String) throws -> [Entry] {
        let label = Path.basename(path)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw PackError.integrity("Archive \(label) could not be opened.") }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw PackError.integrity("Archive \(label) is not a ZIP file.") }
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
        var candidates: [Int] = []
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06,
               index + 22 + Int(u16(tail, index + 20)) == tail.count {
                candidates.append(index)
            }
            index -= 1
        }
        guard let eocd = candidates.first else { throw PackError.integrity("Archive \(label) has no ZIP directory.") }
        guard candidates.count == 1 else { throw PackError.integrity("Archive \(label) has more than one ZIP directory.") }
        let eocdOffset = tailStart + UInt64(eocd)

        guard u16(tail, eocd + 4) == 0, u16(tail, eocd + 6) == 0 else { throw PackError.integrity("Archive \(label) spans several disks.") }
        var count = u16(tail, eocd + 10)
        var directorySize = u32(tail, eocd + 12)
        var directoryOffset = u32(tail, eocd + 16)
        var directoryEnd = eocdOffset
        // ZIP64: a locator just before the end record points at a ZIP64 end
        // record, which then holds the real counts and follows the directory.
        let locator = eocd - 20
        let hasZip64Locator = locator >= 0 && tail[locator] == 0x50 && tail[locator + 1] == 0x4B && tail[locator + 2] == 0x06 && tail[locator + 3] == 0x07
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF || hasZip64Locator {
            guard hasZip64Locator else { throw PackError.integrity("Archive \(label) has a damaged ZIP64 directory.") }
            let recordOffset = u64(tail, locator + 8)
            guard recordOffset < size, size - recordOffset >= 56 else { throw PackError.integrity("Archive \(label) has a damaged ZIP64 directory.") }
            let record = try read(recordOffset, 56)
            guard record.count == 56, record[0] == 0x50, record[1] == 0x4B, record[2] == 0x06, record[3] == 0x06 else {
                throw PackError.integrity("Archive \(label) has a damaged ZIP64 directory.")
            }
            // Fields the classic end record doesn't max out must agree with the
            // ZIP64 record, or tools reading one or the other would differ.
            let (wide, size64, offset64) = (u64(record, 32), u64(record, 40), u64(record, 48))
            guard count == 0xFFFF || count == wide, directorySize == 0xFFFF_FFFF || directorySize == size64,
                  directoryOffset == 0xFFFF_FFFF || directoryOffset == offset64 else {
                throw PackError.integrity("Archive \(label) has ZIP and ZIP64 directories that disagree.")
            }
            count = wide
            directorySize = size64
            directoryOffset = offset64
            directoryEnd = recordOffset
        }
        guard count <= UInt64(maxEntries) else { throw PackError.integrity("Archive \(label) has more than \(maxEntries) entries.") }
        guard directorySize <= 256 << 20, directoryOffset <= size, directorySize <= size - directoryOffset else {
            throw PackError.integrity("Archive \(label) has a damaged ZIP directory.")
        }
        guard directoryOffset + directorySize == directoryEnd else {
            throw PackError.integrity("Archive \(label) has data between its ZIP directory and the directory's end record.")
        }
        guard count > 0 || directoryOffset == 0 else {
            throw PackError.integrity("Archive \(label) lists no files but holds data.")
        }
        let directory = try read(directoryOffset, Int(directorySize))
        guard directory.count == Int(directorySize) else { throw PackError.integrity("Archive \(label) is truncated.") }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 4_096)))
        var firstLocalHeader = UInt64.max
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, directory[cursor] == 0x50, directory[cursor + 1] == 0x4B,
                  directory[cursor + 2] == 0x01, directory[cursor + 3] == 0x02 else {
                throw PackError.integrity("Archive \(label) has a damaged ZIP directory.")
            }
            let madeBy = u16(directory, cursor + 4) >> 8
            let compressed = u32(directory, cursor + 20)
            var uncompressed = u32(directory, cursor + 24)
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            let external = u32(directory, cursor + 38)
            var localOffset = u32(directory, cursor + 42)
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw PackError.integrity("Archive \(label) has a damaged ZIP directory.") }
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                // The ZIP64 extra block holds, in order, whichever of the
                // uncompressed size, compressed size and local header offset are full.
                var extra = extraStart
                while extra + 4 <= extraStart + extraLength {
                    let tag = u16(directory, extra), length = Int(u16(directory, extra + 2))
                    guard extra + 4 + length <= extraStart + extraLength else { break }
                    if tag == 0x0001 {
                        var field = extra + 4
                        let end = extra + 4 + length
                        if uncompressed == 0xFFFF_FFFF, field + 8 <= end { uncompressed = u64(directory, field); field += 8 }
                        if compressed == 0xFFFF_FFFF, field + 8 <= end { field += 8 }
                        if localOffset == 0xFFFF_FFFF, field + 8 <= end { localOffset = u64(directory, field) }
                        break
                    }
                    extra += 4 + length
                }
            }
            let nameBytes = Array(directory[nameStart..<extraStart])
            let name = String(decoding: nameBytes, as: UTF8.self)
            // ditto unpacks the name in the local header, so it must be the one checked here.
            guard localOffset < directoryOffset, directoryOffset - localOffset >= UInt64(30 + nameLength) else {
                throw PackError.integrity("Archive \(label) has a damaged ZIP directory.")
            }
            let local = try read(localOffset, 30 + nameLength)
            guard local.count == 30 + nameLength, local[0] == 0x50, local[1] == 0x4B, local[2] == 0x03, local[3] == 0x04,
                  Int(u16(local, 26)) == nameLength, Array(local[30...]) == nameBytes else {
                throw PackError.integrity("Archive \(label) names a file differently in its directory and its local header (\"\(name)\").")
            }
            firstLocalHeader = min(firstLocalHeader, localOffset)
            // Unix and macOS writers keep the file type in the high half of the external attributes.
            var special = false
            if madeBy == 3 || madeBy == 19 {
                let type = (external >> 16) & 0o170000
                special = type != 0 && type != 0o100000 && type != 0o040000
            }
            entries.append(Entry(name: name, isDirectory: name.hasSuffix("/"), isLinkOrSpecial: special, uncompressedBytes: uncompressed))
            cursor = next
        }
        guard count == 0 || firstLocalHeader == 0 else {
            throw PackError.integrity("Archive \(label) has data before its first file.")
        }
        return entries
    }

    // MARK: After extracting

    /// Everything under `root` must be a plain folder or a file with no other
    /// names (no symbolic links, hard links, devices, FIFOs or sockets).
    static func checkExtracted(_ root: String, archiveName: String) throws {
        func walk(_ folder: String, _ relative: String) throws {
            for entry in Files.entries(folder) {
                let path = Path.join(folder, entry.name)
                let shown = relative.isEmpty ? entry.name : relative + "/" + entry.name
                if entry.isSymbolicLink {
                    throw PackError.integrity("Archive \(archiveName) contains a link (\(shown)); packs may only hold files and folders.")
                }
                if entry.isDirectory { try walk(path, shown); continue }
                guard entry.isFile, let info = Files.lstatInfo(path) else {
                    throw PackError.integrity("Archive \(archiveName) contains a special file (\(shown)).")
                }
                if info.st_nlink > 1 {
                    throw PackError.integrity("Archive \(archiveName) contains a hard link (\(shown)).")
                }
            }
        }
        try walk(root, "")
    }

    /// Moves what `source` holds into `destination`, merging folders, and
    /// refuses to replace anything already there (another resource, say).
    static func merge(_ source: String, into destination: String, archiveName: String, relative: String = "") throws {
        for entry in Files.entries(source) {
            let from = Path.join(source, entry.name)
            let to = Path.join(destination, entry.name)
            let shown = relative.isEmpty ? entry.name : relative + "/" + entry.name
            guard let existing = Files.lstatInfo(to) else {
                try Files.rename(from, to)
                continue
            }
            if entry.isDirectory, existing.st_mode & S_IFMT == S_IFDIR {
                try merge(from, into: to, archiveName: archiveName, relative: shown)
            } else {
                throw PackError.integrity("Archive \(archiveName) would replace \(shown), which the pack already has.")
            }
        }
    }
}
