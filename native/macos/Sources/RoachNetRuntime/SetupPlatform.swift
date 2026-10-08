import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host facts and OS-tool wrappers used by the native installer.
public enum SetupPlatform {
    public static var isMacOS: Bool { Host.platform == "darwin" }

    /// True on Apple Silicon hardware even when the current process is translated.
    public static var hardwareIsAppleSilicon: Bool {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { return value == 1 }
        return Host.arch == "arm64"
        #else
        return false
        #endif
    }

    /// True when running under Rosetta translation.
    public static var isTranslated: Bool {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 { return value == 1 }
        #endif
        return false
    }

    public static var osVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    public static var osVersionString: String {
        let version = osVersion
        return version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }

    public static var memoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    public static var chipName: String { NativeRuntime.cpuBrand() }

    /// Free bytes for the volume containing `path` (nearest existing ancestor).
    public static func availableBytes(at path: String) -> Int64 {
        var probe = path
        while !Files.exists(probe) {
            let parent = Path.dirname(probe)
            if parent == probe { break }
            probe = parent
        }
        if !Files.exists(probe) { probe = Host.homeDirectory }
        #if os(macOS)
        let url = URL(fileURLWithPath: probe)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0
        {
            return important
        }
        #endif
        var info = statvfs()
        guard statvfs(probe, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_frsize)
    }

    public static func isWritableDirectoryTarget(_ path: String) -> Bool {
        var probe = path
        while !Files.exists(probe) {
            let parent = Path.dirname(probe)
            if parent == probe { return false }
            probe = parent
        }
        return access(probe, W_OK) == 0
    }

    /// Mounted disk images and other read-only installer media.
    public static func isLikelyInstallerMedia(_ path: String) -> Bool {
        let resolved = Path.resolve(path)
        guard resolved.hasPrefix("/Volumes/") else { return false }
        let volumeRoot = "/Volumes/" + (resolved.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
        return volumeRoot.lowercased().contains("roachnet setup") || access(volumeRoot, W_OK) != 0
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let digits = value >= 100 || unit == 0 ? 0 : 1
        return String(format: "%.\(digits)f %@", value, units[unit])
    }

    /// RAM-aware default for the first local RoachClaw model.
    public static func recommendedModel(memoryBytes: UInt64 = memoryBytes) -> (model: String, tier: String) {
        let gigabytes = Double(memoryBytes) / 1024 / 1024 / 1024
        if gigabytes >= 32 { return ("qwen2.5-coder:14b", "creator") }
        if gigabytes >= 16 { return ("qwen2.5-coder:7b", "balanced") }
        return ("qwen2.5-coder:1.5b", "compact")
    }

    // MARK: Tool wrappers

    @discardableResult
    static func tool(_ executable: String, _ arguments: [String], timeoutMs: Int = 300_000) -> Processes.Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Processes.Result(status: 127, output: "", errorOutput: "\(executable) is not available on this system")
        }
        return Processes.run(executable, arguments, timeoutMs: timeoutMs)
    }

    /// Copies a bundle or directory preserving symlinks and metadata, minus quarantine.
    static func copyDirectory(_ source: String, to destination: String) throws {
        Files.remove(destination)
        try Files.mkdirp(Path.dirname(destination))
        if isMacOS {
            let clone = tool("/usr/bin/ditto", ["--clone", "--noqtn", source, destination])
            if clone.status == 0 { return }
            Files.remove(destination)
            let plain = tool("/usr/bin/ditto", ["--noqtn", source, destination])
            if plain.status == 0 { return }
            throw RuntimeError("Failed to copy \(Path.basename(source)): \(plain.errorOutput.isEmpty ? clone.errorOutput : plain.errorOutput)")
        }
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    static func extractZip(_ archive: String, to destination: String) throws {
        try Files.mkdirp(destination)
        let result = isMacOS
            ? tool("/usr/bin/ditto", ["-x", "-k", archive, destination])
            : tool("/usr/bin/unzip", ["-q", "-o", archive, "-d", destination])
        if result.status != 0 { throw RuntimeError("Could not unpack \(Path.basename(archive)): \(result.errorOutput)") }
    }

    static func extractTarGz(_ archive: String, to destination: String) throws {
        try Files.mkdirp(destination)
        let tar = Files.exists("/usr/bin/tar") ? "/usr/bin/tar" : "/bin/tar"
        let result = tool(tar, ["-xzf", archive, "-C", destination])
        if result.status != 0 { throw RuntimeError("Could not unpack \(Path.basename(archive)): \(result.errorOutput)") }
    }

    /// Removes download quarantine so the contained app opens without
    /// translocation. Re-signs ad hoc only when the existing signature is
    /// missing or invalid, so Developer ID signatures are never replaced.
    static func prepareForLaunch(_ path: String, log: (String) -> Void) {
        guard isMacOS, Files.exists(path) else { return }
        tool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", path], timeoutMs: 300_000)
        tool("/usr/bin/xattr", ["-dr", "com.apple.provenance", path], timeoutMs: 300_000)
        guard path.hasSuffix(".app") else { return }
        let verify = tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", path], timeoutMs: 300_000)
        if verify.status == 0 {
            log("Kept the existing code signature on \(Path.basename(path)).")
            return
        }
        let sign = tool("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", path], timeoutMs: 300_000)
        log(sign.status == 0
            ? "Applied a local ad-hoc signature to \(Path.basename(path)) so this Mac can open it."
            : "Could not apply a local signature to \(Path.basename(path)); macOS may ask before opening it.")
    }

    static func open(_ path: String) {
        if isMacOS {
            tool("/usr/bin/open", [path], timeoutMs: 15_000)
        }
    }

    static func terminateProcesses(matching pattern: String) -> Bool {
        let pkill = Files.exists("/usr/bin/pkill") ? "/usr/bin/pkill" : "/bin/pkill"
        return tool(pkill, ["-f", pattern], timeoutMs: 5_000).status == 0
    }

    static func moveItem(_ source: String, _ destination: String) throws {
        try Files.mkdirp(Path.dirname(destination))
        if Foundation.rename(source, destination) == 0 { return }
        if errno != EXDEV { throw RuntimeError("Could not move \(source) to \(destination): \(String(cString: strerror(errno)))") }
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        Files.remove(source)
    }
}
