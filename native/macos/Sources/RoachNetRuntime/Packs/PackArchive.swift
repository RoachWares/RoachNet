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
/// already there. A ZIP is unpacked by RoachNet's own reader (`ZipArchive`),
/// so it unpacks exactly as it was checked.
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
        switch format {
        case "zip":
            // RoachNet's own reader writes exactly the sizes the directory
            // declares, so the declared total is the real one.
            let declared = try check(try zipEntries(atPath: archivePath), label: label, maxBytes: maxBytes)
            #if !canImport(Compression)
            try measureZip(archivePath, declared: declared, maxBytes: maxBytes)
            #else
            _ = declared
            #endif
        case "tar.gz", "tgz":
            // `tar -t` doesn't list sizes the same way on every system, so the
            // gzip stream is measured first: it holds every file's bytes, and
            // the count stops at the limit instead of inflating all of it.
            guard try inflatedSize(of: archivePath, format: format, limit: maxBytes) <= maxBytes else { throw tooLarge(label, maxBytes) }
            try check(try tarEntries(atPath: archivePath), label: label, maxBytes: maxBytes)
        default:
            throw PackError.installFailed("Unsupported archive type \(format).")
        }
    }

    /// Refuses entries that could land outside the folder or aren't plain
    /// files and folders, and a declared total past `maxBytes`, which it returns.
    @discardableResult
    static func check(_ entries: [Entry], label: String, maxBytes: UInt64) throws -> UInt64 {
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
            guard !overflow, sum <= maxBytes else { throw tooLarge(label, maxBytes) }
            total = sum
        }
        return total
    }

    static func tooLarge(_ label: String, _ maxBytes: UInt64) -> PackError {
        PackError.integrity("Archive \(label) unpacks to more than \(sizeText(maxBytes)).")
    }

    #if !canImport(Compression)
    /// Where unzip unpacks (Linux CI), every stream must inflate to what the
    /// directory declares: unzip writes an entry's whole stream whatever its
    /// size fields say.
    static func measureZip(_ path: String, declared: UInt64, maxBytes: UInt64) throws {
        let measured = try inflatedSize(of: path, format: "zip", limit: maxBytes)
        guard measured <= maxBytes else { throw tooLarge(Path.basename(path), maxBytes) }
        guard measured == declared else {
            throw PackError.integrity("Archive \(Path.basename(path)) unpacks to a different size than its directory says.")
        }
    }
    #endif

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
        process.environment = Processes.archiveToolEnvironment
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
        let names = Processes.run("/usr/bin/tar", ["-tzf", path], timeoutMs: 600_000, environment: Processes.archiveToolEnvironment)
        let verbose = Processes.run("/usr/bin/tar", ["-tvzf", path], timeoutMs: 600_000, environment: Processes.archiveToolEnvironment)
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
    /// anything; `ZipArchive` refuses an archive that could be read two ways.
    static func zipEntries(atPath path: String) throws -> [Entry] {
        try ZipArchive(path: path).entries.map(\.summary)
    }

    // MARK: Unpacking

    /// Checks an archive as `inspect` does and unpacks it into `destination`,
    /// an empty folder, then walks what came out (`checkExtracted`). A ZIP is
    /// unpacked by RoachNet's own reader (`ZipArchive`), so what is written is
    /// exactly what was checked; a .tar.gz by `tar`, which both lists and
    /// unpacks it.
    static func unpack(_ archivePath: String, format: String, into destination: String, maxBytes: UInt64 = maxUncompressedBytes) throws {
        let label = Path.basename(archivePath)
        switch format {
        case "zip":
            let archive = try ZipArchive(path: archivePath)
            let declared = try check(archive.entries.map(\.summary), label: label, maxBytes: maxBytes)
            #if !canImport(Compression)
            try measureZip(archivePath, declared: declared, maxBytes: maxBytes)
            #else
            _ = declared
            #endif
            try archive.unpack(into: destination)
        case "tar.gz", "tgz":
            try inspect(archivePath, format: format, maxBytes: maxBytes)
            let result = Processes.run("/usr/bin/tar", ["-xzf", archivePath, "-C", destination], timeoutMs: 600_000,
                                       environment: Processes.archiveToolEnvironment)
            guard result.status == 0 else { throw PackError.installFailed("Extracting \(label) failed: \(result.errorOutput)") }
        default:
            throw PackError.installFailed("Unsupported archive type \(format).")
        }
        try checkExtracted(destination, archiveName: label)
    }

    // MARK: After extracting

    /// Everything under `root` must be a plain folder or a file with no other
    /// names (no symbolic links, hard links, devices, FIFOs or sockets). A
    /// folder that can't be read fails the check rather than passing as empty
    /// (tar applies an archive's folder modes, 0000 included), and modes come
    /// out plain: folders 0755, files 0644, or 0755 when executable.
    static func checkExtracted(_ root: String, archiveName: String) throws {
        func walk(_ folder: String, _ relative: String) throws {
            guard chmod(folder, 0o755) == 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                throw PackError.integrity("Archive \(archiveName) holds a folder RoachNet can't read (\(relative.isEmpty ? "." : relative)).")
            }
            for name in names {
                let path = Path.join(folder, name)
                let shown = relative.isEmpty ? name : relative + "/" + name
                guard let info = Files.lstatInfo(path) else {
                    throw PackError.integrity("Archive \(archiveName) holds something RoachNet can't read (\(shown)).")
                }
                let type = info.st_mode & S_IFMT
                if type == S_IFLNK {
                    throw PackError.integrity("Archive \(archiveName) contains a link (\(shown)); packs may only hold files and folders.")
                }
                if type == S_IFDIR { try walk(path, shown); continue }
                guard type == S_IFREG else {
                    throw PackError.integrity("Archive \(archiveName) contains a special file (\(shown)).")
                }
                if info.st_nlink > 1 {
                    throw PackError.integrity("Archive \(archiveName) contains a hard link (\(shown)).")
                }
                guard chmod(path, info.st_mode & 0o100 != 0 ? 0o755 : 0o644) == 0 else {
                    throw PackError.integrity("Archive \(archiveName) holds a file RoachNet can't set up (\(shown)).")
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

extension ZipArchive.Entry {
    var summary: PackArchive.Entry {
        PackArchive.Entry(name: name, isDirectory: isDirectory, isLinkOrSpecial: isLinkOrSpecial, uncompressedBytes: uncompressedBytes)
    }
}
