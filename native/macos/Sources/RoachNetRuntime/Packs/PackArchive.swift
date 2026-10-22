import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum PackArchive {
    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let isLinkOrSpecial: Bool
        let uncompressedBytes: UInt64
    }

    static let maxEntries = 200_000
    static let maxUncompressedBytes: UInt64 = 64 << 30

    static func problem(withEntryName name: String) -> String? {
        if name.isEmpty { return "an entry has no name" }
        if name.utf8.count > 4_096 { return "an entry name is too long" }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) { return "\"\(name)\" contains a NUL character" }
        if Path.startsWithSlash(name) { return "\"\(name)\" is an absolute path" }
        if name.unicodeScalars.contains("\\") { return "\"\(name)\" uses a backslash" }
        if namesADrive(name) { return "\"\(name)\" names a drive" }
        if Path.fileSystemComponents(name).contains(where: Path.isDotDotComponent) {
            return "\"\(name)\" climbs out with .."
        }
        return nil
    }

    static func namesADrive(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars.prefix(2))
        if scalars.count == 2, scalars[1] == ":", scalars[0].properties.isAlphabetic { return true }
        return name.count >= 2 && name.dropFirst().first == ":" && name.first?.isLetter == true
    }

    static func inspect(_ archivePath: String, format: String, maxBytes: UInt64 = maxUncompressedBytes) throws {
        let label = Path.basename(archivePath)
        switch format {
        case "zip":
            let declared = try check(try zipEntries(atPath: archivePath), label: label, maxBytes: maxBytes)
            #if !canImport(Compression)
            try measureZip(archivePath, declared: declared, maxBytes: maxBytes)
            #else
            _ = declared
            #endif
        case "tar.gz", "tgz":
            guard try inflatedSize(of: archivePath, format: format, limit: maxBytes) <= maxBytes else {
                throw tooLarge(label, maxBytes)
            }
            try check(try tarEntries(atPath: archivePath), label: label, maxBytes: maxBytes)
        default:
            throw PackError.installFailed("Unsupported archive type \(format).")
        }
    }

    @discardableResult
    static func check(_ entries: [Entry], label: String, maxBytes: UInt64) throws -> UInt64 {
        guard entries.count <= maxEntries else {
            throw PackError.integrity("Archive \(label) has more than \(maxEntries) entries.")
        }
        var total: UInt64 = 0
        for entry in entries {
            if let problem = problem(withEntryName: entry.name) {
                throw PackError.integrity("Archive \(label) can't be unpacked: \(problem).")
            }
            if entry.isLinkOrSpecial {
                throw PackError.integrity(
                    "Archive \(label) can't be unpacked: \"\(entry.name)\" is a link or a special file.")
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
    static func measureZip(_ path: String, declared: UInt64, maxBytes: UInt64) throws {
        let measured = try inflatedSize(of: path, format: "zip", limit: maxBytes)
        guard measured <= maxBytes else { throw tooLarge(Path.basename(path), maxBytes) }
        guard measured == declared else {
            throw PackError.integrity(
                "Archive \(Path.basename(path)) unpacks to a different size than its directory says.")
        }
    }
    #endif

    static func sizeText(_ bytes: UInt64) -> String {
        bytes >= 1 << 30 ? "\(bytes >> 30) GB" : "\(max(1, bytes >> 20)) MB"
    }

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
        let finished = process.terminationStatus == 0 || (zip && process.terminationStatus == 1)
        if !stopped, !finished {
            throw PackError.integrity("Archive \(Path.basename(path)) couldn't be read to measure it.")
        }
        return total
    }

    static func tarEntries(atPath path: String) throws -> [Entry] {
        let names = Processes.run(
            "/usr/bin/tar", ["-tzf", path], timeoutMs: 600_000, environment: Processes.archiveToolEnvironment)
        let verbose = Processes.run(
            "/usr/bin/tar", ["-tvzf", path], timeoutMs: 600_000, environment: Processes.archiveToolEnvironment)
        guard names.status == 0, verbose.status == 0 else {
            throw PackError.integrity(
                "Archive \(Path.basename(path)) could not be read: \(names.errorOutput.isEmpty ? verbose.errorOutput : names.errorOutput)"
            )
        }
        let nameLines = names.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let typeLines = verbose.output.split(separator: "\n", omittingEmptySubsequences: true)
        guard nameLines.count == typeLines.count else {
            throw PackError.integrity("Archive \(Path.basename(path)) lists its entries inconsistently.")
        }
        return zip(nameLines, typeLines).map { name, line in
            let type = line.first ?? "?"
            return Entry(
                name: name, isDirectory: type == "d", isLinkOrSpecial: type != "-" && type != "d", uncompressedBytes: 0)
        }
    }

    static func zipEntries(atPath path: String) throws -> [Entry] {
        try ZipArchive(path: path).entries.map(\.summary)
    }

    static func unpack(
        _ archivePath: String, format: String, into destination: String, maxBytes: UInt64 = maxUncompressedBytes
    ) throws {
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
            let result = Processes.run(
                "/usr/bin/tar", ["-xzf", archivePath, "-C", destination], timeoutMs: 600_000,
                environment: Processes.archiveToolEnvironment)
            guard result.status == 0 else {
                throw PackError.installFailed("Extracting \(label) failed: \(result.errorOutput)")
            }
        default:
            throw PackError.installFailed("Unsupported archive type \(format).")
        }
        try checkExtracted(destination, archiveName: label)
    }

    static func checkExtracted(_ root: String, archiveName: String) throws {
        func walk(_ folder: String, _ relative: String) throws {
            guard chmod(folder, 0o755) == 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder)
            else {
                throw PackError.integrity(
                    "Archive \(archiveName) holds a folder RoachNet can't read (\(relative.isEmpty ? "." : relative)).")
            }
            for name in names {
                let path = Path.join(folder, name)
                let shown = relative.isEmpty ? name : relative + "/" + name
                guard let info = Files.lstatInfo(path) else {
                    throw PackError.integrity("Archive \(archiveName) holds something RoachNet can't read (\(shown)).")
                }
                let type = info.st_mode & S_IFMT
                if type == S_IFLNK {
                    throw PackError.integrity(
                        "Archive \(archiveName) contains a link (\(shown)); packs may only hold files and folders.")
                }
                if type == S_IFDIR {
                    try walk(path, shown)
                    continue
                }
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
        PackArchive.Entry(
            name: name, isDirectory: isDirectory, isLinkOrSpecial: isLinkOrSpecial, uncompressedBytes: uncompressedBytes
        )
    }
}
