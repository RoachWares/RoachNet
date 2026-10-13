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
/// that are absolute or climb out with `..`, links, devices), unpacked into
/// an empty folder of its own, walked again with `lstat`, and only then moved
/// into place, never over a file that is already there.
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
    /// outside the folder or is not a plain file or folder.
    static func inspect(_ archivePath: String, format: String) throws {
        let label = Path.basename(archivePath)
        let entries: [Entry]
        switch format {
        case "zip": entries = try zipEntries(atPath: archivePath)
        case "tar.gz", "tgz": entries = try tarEntries(atPath: archivePath)
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
            guard !overflow, sum <= maxUncompressedBytes else {
                throw PackError.integrity("Archive \(label) unpacks to more than \(maxUncompressedBytes >> 30) GB.")
            }
            total = sum
        }
    }

    /// The names and types `tar` lists, in archive order.
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

    /// Reads a ZIP's central directory (ZIP64 included) without extracting anything.
    static func zipEntries(atPath path: String) throws -> [Entry] {
        let label = Path.basename(path)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw PackError.integrity("Archive \(label) could not be opened.") }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw PackError.integrity("Archive \(label) is not a ZIP file.") }

        // The end-of-central-directory record sits in the last 64 KiB + 22 bytes.
        let tailLength = min(size, 65_557)
        try handle.seek(toOffset: size - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        var eocd = -1
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw PackError.integrity("Archive \(label) has no ZIP directory.") }
        func u16(_ bytes: [UInt8], _ at: Int) -> UInt64 { UInt64(bytes[at]) | UInt64(bytes[at + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt64 { u16(bytes, at) | u16(bytes, at + 2) << 16 }
        func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 { u32(bytes, at) | u32(bytes, at + 4) << 32 }

        guard u16(tail, eocd + 4) == 0, u16(tail, eocd + 6) == 0 else { throw PackError.integrity("Archive \(label) spans several disks.") }
        var count = u16(tail, eocd + 10)
        var directorySize = u32(tail, eocd + 12)
        var directoryOffset = u32(tail, eocd + 16)
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: the locator sits just before the end record.
            let locator = eocd - 20
            guard locator >= 0, tail[locator] == 0x50, tail[locator + 1] == 0x4B, tail[locator + 2] == 0x06, tail[locator + 3] == 0x07 else {
                throw PackError.integrity("Archive \(label) has a damaged ZIP64 directory.")
            }
            let recordOffset = u64(tail, locator + 8)
            guard recordOffset < size, size - recordOffset >= 56 else { throw PackError.integrity("Archive \(label) has a damaged ZIP64 directory.") }
            try handle.seek(toOffset: recordOffset)
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count == 56, record[0] == 0x50, record[1] == 0x4B, record[2] == 0x06, record[3] == 0x06 else {
                throw PackError.integrity("Archive \(label) has a damaged ZIP64 directory.")
            }
            count = u64(record, 32)
            directorySize = u64(record, 40)
            directoryOffset = u64(record, 48)
        }
        guard count <= UInt64(maxEntries) else { throw PackError.integrity("Archive \(label) has more than \(maxEntries) entries.") }
        guard directorySize <= 256 << 20, directoryOffset <= size, directorySize <= size - directoryOffset else {
            throw PackError.integrity("Archive \(label) has a damaged ZIP directory.")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        guard directory.count == Int(directorySize) else { throw PackError.integrity("Archive \(label) is truncated.") }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 4_096)))
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, directory[cursor] == 0x50, directory[cursor + 1] == 0x4B,
                  directory[cursor + 2] == 0x01, directory[cursor + 3] == 0x02 else {
                throw PackError.integrity("Archive \(label) has a damaged ZIP directory.")
            }
            let madeBy = u16(directory, cursor + 4) >> 8
            var uncompressed = u32(directory, cursor + 24)
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            let external = u32(directory, cursor + 38)
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw PackError.integrity("Archive \(label) has a damaged ZIP directory.") }
            if uncompressed == 0xFFFF_FFFF {
                // The real size is the first field of the ZIP64 extra block.
                var extra = extraStart
                while extra + 4 <= extraStart + extraLength {
                    let tag = u16(directory, extra), length = Int(u16(directory, extra + 2))
                    if tag == 0x0001, length >= 8, extra + 12 <= extraStart + extraLength { uncompressed = u64(directory, extra + 4); break }
                    extra += 4 + length
                }
            }
            let name = String(decoding: directory[nameStart..<extraStart], as: UTF8.self)
            // Unix and macOS writers keep the file type in the high half of the external attributes.
            var special = false
            if madeBy == 3 || madeBy == 19 {
                let type = (external >> 16) & 0o170000
                special = type != 0 && type != 0o100000 && type != 0o040000
            }
            entries.append(Entry(name: name, isDirectory: name.hasSuffix("/"), isLinkOrSpecial: special, uncompressedBytes: uncompressed))
            cursor = next
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
