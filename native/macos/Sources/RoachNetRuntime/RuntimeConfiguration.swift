import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX `write`, which `Files.write` would otherwise shadow.
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buffer, count)
    #else
    return Glibc.write(fd, buffer, count)
    #endif
}

/// POSIX `rename`, which `Files.rename` would otherwise shadow.
private func posixRename(_ from: String, _ to: String) -> Int32 {
    #if canImport(Darwin)
    return Darwin.rename(from, to)
    #else
    return Glibc.rename(from, to)
    #endif
}

/// Environment-derived runtime configuration (same variables the app and
/// installer already pass to the runtime process).
public final class RuntimeConfiguration {
    public static var shared = RuntimeConfiguration(environment: ProcessInfo.processInfo.environment)

    public let environment: [String: String]
    public let repoRoot: String
    public let version: String
    public let storageRoot: String
    public let runtimeStateRoot: String
    public let logRoot: String
    public let logPath: String
    public let statePath: String
    public let processInfoPath: String
    public let roachTailStatePath: String
    public let legacyRoachTailStatePath: String
    public let roachClawStateRoot: String
    public let legacyRoachClawStateRoot: String
    public let ollamaBaseUrl: String
    public let openClawBaseUrl: String
    public let defaultModel: String
    public let githubReleasesApiUrl: String
    public let githubReleasesUrl: String
    public let appsDownloadsBaseUrl: String
    public let roachClawReferenceRepository: String
    public let roachClawReferenceCommit: String
    public let roachClawReferenceLatestCommit: String

    public let roachTailJoinCodeTTLms: Int
    public let roachTailAuthKeyTTLms: Int
    public let maxRequestBodyBytes: Int
    public let downloadTimeoutMs: Int
    public let downloadStallTimeoutMs: Int
    public let downloadMaxAttempts: Int
    public let maxDownloadBytes: Int
    public let serviceHealthProbeTimeoutMs: Int
    public let runtimeProbeCacheMs: Int
    public let uploadLimitPolicies: [JSON]

    public init(environment: [String: String]) {
        self.environment = environment
        let repoRoot = RuntimeConfiguration.resolveRepoRoot(environment)
        self.repoRoot = repoRoot
        self.version = RuntimeConfiguration.resolveVersion(environment, repoRoot: repoRoot)

        let storageRoot = Path.normalizeUserPath(environment["ROACHNET_STORAGE_PATH"], fallback: Path.join(Host.homeDirectory, "RoachNet", "storage"))
        self.storageRoot = storageRoot
        let runtimeStateRoot = Path.normalizeUserPath(environment["ROACHNET_RUNTIME_STATE_ROOT"], fallback: Path.join(storageRoot, ".runtime"))
        self.runtimeStateRoot = runtimeStateRoot
        logRoot = Path.join(storageRoot, "logs")
        logPath = Path.join(logRoot, "roachnet-native-api.log")
        statePath = Path.join(runtimeStateRoot, "roachnet-native-api-state.json")
        processInfoPath = Path.join(logRoot, "roachnet-runtime-processes.json")
        roachTailStatePath = Path.join(runtimeStateRoot, "roachtail", "state.json")
        legacyRoachTailStatePath = Path.join(storageRoot, "vault", "roachtail", "state.json")
        roachClawStateRoot = Path.join(runtimeStateRoot, "roachclaw")
        legacyRoachClawStateRoot = Path.join(storageRoot, "vault", "roachclaw")

        func value(_ key: String, _ fallback: String) -> String {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? fallback : trimmed
        }
        func raw(_ key: String, _ fallback: String) -> String {
            let rawValue = environment[key] ?? ""
            return rawValue.isEmpty ? fallback : rawValue
        }
        func positiveInt(_ key: String, _ fallback: Int) -> Int {
            let number = JSCoercion.number(fromString: environment[key] ?? "")
            if environment[key] == nil { return fallback }
            return JSCoercion.isSafeInteger(number) && number > 0 ? Int(number) : fallback
        }

        ollamaBaseUrl = raw("OLLAMA_BASE_URL", "http://127.0.0.1:36434")
        openClawBaseUrl = raw("OPENCLAW_BASE_URL", "http://127.0.0.1:13001")
        defaultModel = raw("ROACHNET_ROACHCLAW_DEFAULT_MODEL", "qwen2.5-coder:1.5b")
        githubReleasesApiUrl = value("ROACHNET_GITHUB_RELEASES_API_URL", "https://api.github.com/repos/RoachWares/RoachNet/releases")
        githubReleasesUrl = value("ROACHNET_RELEASES_URL", "https://github.com/RoachWares/RoachNet/releases")
        appsDownloadsBaseUrl = value("ROACHNET_APPS_DOWNLOADS_BASE_URL", "https://apps.roachnet.org/downloads")
        roachClawReferenceRepository = value("ROACHNET_ROACHCLAW_REFERENCE_REPOSITORY", "https://github.com/pewdiepie-archdaemon/odysseus")
        roachClawReferenceCommit = value("ROACHNET_ROACHCLAW_REFERENCE_COMMIT", "d9ebdd6fbba31b5f3c2cbae90f650f183958660e")
        roachClawReferenceLatestCommit = value("ROACHNET_ROACHCLAW_REFERENCE_LATEST_COMMIT", roachClawReferenceCommit)

        roachTailJoinCodeTTLms = positiveInt("ROACHTAIL_JOIN_CODE_TTL_MS", 10 * 60 * 1000)
        roachTailAuthKeyTTLms = positiveInt("ROACHTAIL_AUTH_KEY_TTL_MS", 24 * 60 * 60 * 1000)
        maxRequestBodyBytes = positiveInt("ROACHNET_NATIVE_API_MAX_BODY_BYTES", 1024 * 1024)
        // Overall budget for one download job. Big maps and ZIMs take hours on a slow line, so
        // the real guard is the stall timer: the job only fails when bytes stop arriving.
        downloadTimeoutMs = positiveInt("ROACHNET_NATIVE_API_DOWNLOAD_TIMEOUT_MS", 24 * 60 * 60 * 1000)
        downloadStallTimeoutMs = positiveInt("ROACHNET_NATIVE_API_DOWNLOAD_STALL_TIMEOUT_MS", 90 * 1000)
        downloadMaxAttempts = positiveInt("ROACHNET_NATIVE_API_DOWNLOAD_MAX_ATTEMPTS", 6)
        maxDownloadBytes = positiveInt("ROACHNET_NATIVE_API_MAX_DOWNLOAD_BYTES", 512 * 1024 * 1024 * 1024)
        serviceHealthProbeTimeoutMs = positiveInt("ROACHNET_SERVICE_HEALTH_PROBE_TIMEOUT_MS", 1_500)
        runtimeProbeCacheMs = positiveInt("ROACHNET_RUNTIME_PROBE_CACHE_MS", 1_000)

        let chat = positiveInt("ROACHNET_CHAT_UPLOAD_MAX_BYTES", 10 * 1024 * 1024)
        let gallery = positiveInt("ROACHNET_GALLERY_UPLOAD_MAX_BYTES", 100 * 1024 * 1024)
        let galleryTransform = positiveInt("ROACHNET_GALLERY_TRANSFORM_UPLOAD_MAX_BYTES", 25 * 1024 * 1024)
        let vault = positiveInt("ROACHNET_VAULT_IMPORT_MAX_BYTES", 25 * 1024 * 1024)
        let memory = positiveInt("ROACHNET_MEMORY_IMPORT_MAX_BYTES", 10 * 1024 * 1024)
        let email = positiveInt("ROACHNET_EMAIL_ATTACHMENT_MAX_BYTES", 25 * 1024 * 1024)
        let speech = positiveInt("ROACHNET_STT_AUDIO_MAX_BYTES", 25 * 1024 * 1024)
        let calendar = positiveInt("ROACHNET_CALENDAR_IMPORT_MAX_BYTES", 10 * 1024 * 1024)
        uploadLimitPolicies = [
            ["id": "json-body", "label": "JSON request body", "lane": "native-api", "env": "ROACHNET_NATIVE_API_MAX_BODY_BYTES", "bytes": JSON(maxRequestBodyBytes), "enforcement": "readRequestBody"],
            ["id": "chat-upload", "label": "Chat attachment", "lane": "roachclaw-chat", "env": "ROACHNET_CHAT_UPLOAD_MAX_BYTES", "bytes": JSON(chat), "enforcement": "chat-file-intake"],
            ["id": "gallery-upload", "label": "Gallery import", "lane": "vault-gallery", "env": "ROACHNET_GALLERY_UPLOAD_MAX_BYTES", "bytes": JSON(gallery), "enforcement": "vault-media-intake"],
            ["id": "gallery-transform", "label": "Gallery transform input", "lane": "vault-gallery", "env": "ROACHNET_GALLERY_TRANSFORM_UPLOAD_MAX_BYTES", "bytes": JSON(galleryTransform), "enforcement": "image-transform-intake"],
            ["id": "vault-import", "label": "Vault file import", "lane": "vault", "env": "ROACHNET_VAULT_IMPORT_MAX_BYTES", "bytes": JSON(vault), "enforcement": "drag-drop-vault-intake"],
            ["id": "memory-import", "label": "Memory import", "lane": "roachbrain", "env": "ROACHNET_MEMORY_IMPORT_MAX_BYTES", "bytes": JSON(memory), "enforcement": "memory-provider-intake"],
            ["id": "email-attachment", "label": "Email attachment", "lane": "roachclaw-mail", "env": "ROACHNET_EMAIL_ATTACHMENT_MAX_BYTES", "bytes": JSON(email), "enforcement": "mail-compose-intake"],
            ["id": "speech-audio", "label": "RoachSpeech audio", "lane": "roachspeech", "env": "ROACHNET_STT_AUDIO_MAX_BYTES", "bytes": JSON(speech), "enforcement": "speech-transcript-intake"],
            ["id": "calendar-import", "label": "Calendar import", "lane": "roachclaw-calendar", "env": "ROACHNET_CALENDAR_IMPORT_MAX_BYTES", "bytes": JSON(calendar), "enforcement": "ics-import-intake"],
            ["id": "download", "label": "Download job", "lane": "installer-app-store", "env": "ROACHNET_NATIVE_API_MAX_DOWNLOAD_BYTES", "bytes": JSON(maxDownloadBytes), "enforcement": "download-to-partial-file"],
            ["id": "timeout", "label": "Download timeout", "lane": "installer-app-store", "env": "ROACHNET_NATIVE_API_DOWNLOAD_TIMEOUT_MS", "milliseconds": JSON(downloadTimeoutMs), "enforcement": "download-timeout"],
            ["id": "stall", "label": "Download stall timeout", "lane": "installer-app-store", "env": "ROACHNET_NATIVE_API_DOWNLOAD_STALL_TIMEOUT_MS", "milliseconds": JSON(downloadStallTimeoutMs), "enforcement": "download-resume-after-stall"],
        ]
    }

    public func env(_ key: String) -> String? { environment[key] }

    /// `process.env[key]?.trim()` returning nil when empty.
    public func trimmedEnv(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func resolveRepoRoot(_ environment: [String: String]) -> String {
        if let explicit = environment["ROACHNET_REPO_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return Path.resolve(explicit)
        }
        // Executable lives at <repo>/native/macos/.build/... during development
        // and inside RoachNet.app when bundled; walk up looking for package.json.
        let executable = RuntimeBuildInfo.executablePath
        // Bundled layout: RoachNet.app/Contents/Helpers/roachnet-runtime with data in
        // Contents/Resources/RoachNetRuntimeData, so the helper works with no env.
        let bundledData = Path.join(Path.dirname(Path.dirname(executable)), "Resources", "RoachNetRuntimeData")
        var candidates: [String] = [bundledData, FileManager.default.currentDirectoryPath]
        var cursor = Path.dirname(executable)
        for _ in 0..<8 {
            candidates.append(cursor)
            cursor = Path.dirname(cursor)
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: Path.join(candidate, "collections")) {
            return candidate
        }
        return FileManager.default.currentDirectoryPath
    }

    private static func resolveVersion(_ environment: [String: String], repoRoot: String) -> String {
        if let explicit = environment["ROACHNET_APP_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let package = JSON.read(contentsOf: Path.join(repoRoot, "package.json")), let version = package["version"].stringValue {
            return version
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return bundled
        }
        return RuntimeBuildInfo.version
    }
}

/// Lock-protected value handed to a background callback; reads after a
/// timeout never race the late writer.
public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    public init(_ value: Value) { storage = value }
    public var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

public enum RuntimeBuildInfo {
    /// The running helper's real path (symlinks resolved, PATH lookups handled).
    public static var executablePath: String {
        let launchedAs = Bundle.main.executablePath ?? Path.resolve(CommandLine.arguments.first ?? "")
        return Files.realpath(launchedAs) ?? launchedAs
    }
    /// Fallback when neither package metadata nor an app bundle is present.
    public static let version = "1.1.0"
    public static let executableName = "roachnet-runtime"

    /// The source commit this build came from (ROA-40): `ROACHNET_SOURCE_COMMIT`,
    /// else the `RoachNetSourceCommit` key the build script writes into the
    /// enclosing app's Info.plist (`…/Contents/Helpers/roachnet-runtime` →
    /// `…/Contents/Info.plist`). nil for a plain `swift build`.
    public static var sourceCommit: String? {
        if let explicit = ProcessInfo.processInfo.environment["ROACHNET_SOURCE_COMMIT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), isSourceCommit(explicit) {
            return explicit
        }
        var directory = Path.dirname(executablePath)
        for _ in 0..<3 {
            let plistPath = Path.join(directory, "Info.plist")
            if let data = FileManager.default.contents(atPath: plistPath),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let commit = plist["RoachNetSourceCommit"] as? String, isSourceCommit(commit) {
                return commit
            }
            directory = Path.dirname(directory)
        }
        return nil
    }

    /// A full 40-character lowercase hex SHA, optionally followed by "-dirty".
    public static func isSourceCommit(_ value: String) -> Bool {
        let sha = value.hasSuffix("-dirty") ? String(value.dropLast(6)) : value
        return sha.count == 40 && sha.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

// MARK: - Logging and files

public enum RuntimeLog {
    private static let lock = NSLock()

    public static func write(_ line: String) {
        let config = RuntimeConfiguration.shared
        let entry = "[\(JS.isoNow())] \(line)\n"
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: config.logRoot, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: config.logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            _ = FileManager.default.createFile(atPath: config.logPath, contents: Data(entry.utf8))
        }
    }
}

public enum Files {
    public static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    public static func mkdirp(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Atomic write (temp file + rename), creating parents.
    /// With a `mode`, the temp file is created with that mode, so a private
    /// file is never readable by others, not even between write and chmod.
    public static func write(_ data: Data, to path: String, mode: Int? = nil) throws {
        try mkdirp(Path.dirname(path))
        guard let mode else {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return
        }
        let temp = Path.join(Path.dirname(path), ".\(Path.basename(path)).\(JS.randomHex(12)).tmp")
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        guard fd >= 0 else { throw RuntimeError("Could not create \(temp): \(String(cString: strerror(errno)))") }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            while written < buffer.count {
                let count = posixWrite(fd, base + written, buffer.count - written)
                if count <= 0 { return false }
                written += count
            }
            return true
        }
        fchmod(fd, mode_t(mode))
        close(fd)
        guard ok, posixRename(temp, path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temp)
            throw RuntimeError("Could not write \(path): \(message)")
        }
    }

    public static func write(_ text: String, to path: String, mode: Int? = nil) throws {
        try write(Data(text.utf8), to: path, mode: mode)
    }

    /// `writeFileSync(path, JSON.stringify(value, null, 2))`
    public static func writePrettyJSON(_ value: JSON, to path: String, mode: Int? = nil) throws {
        try write(value.prettySerialized(), to: path, mode: mode)
    }

    /// Owner-only mode for files that hold tokens, hashes or join codes.
    public static let privateFileMode = 0o600

    /// `rmSync(path, { force: true, recursive })`
    public static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public static func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public struct DirectoryEntry {
        public let name: String
        public let isDirectory: Bool
        public let isFile: Bool
        public let isSymbolicLink: Bool
    }

    /// `readdirSync(path, { withFileTypes: true })` (lstat semantics).
    public static func entries(_ path: String) -> [DirectoryEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.map { name in
            let full = Path.join(path, name)
            var info = stat()
            let result = lstat(full, &info)
            let type = result == 0 ? (info.st_mode & S_IFMT) : 0
            return DirectoryEntry(
                name: name,
                isDirectory: type == S_IFDIR,
                isFile: type == S_IFREG,
                isSymbolicLink: type == S_IFLNK
            )
        }
    }

    public static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    public static func statInfo(_ path: String) -> stat? {
        var info = stat()
        return stat(path, &info) == 0 ? info : nil
    }

    public static func modificationISO(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return JS.iso(date)
    }

    public static func realpath(_ path: String) -> String? {
        #if canImport(Darwin)
        let resolved = Darwin.realpath(path, nil)
        #else
        let resolved = Glibc.realpath(path, nil)
        #endif
        guard let resolved else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func rename(_ from: String, _ to: String) throws {
        guard Foundation.rename(from, to) == 0 else {
            throw RuntimeError("rename \(from) -> \(to) failed: \(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - Async TTL cache

/// Coalesces concurrent loads of the same key and caches results for a TTL.
/// Failures are not cached (matches `createAsyncTTLCache`).
public final class TTLCache<Value> {
    private final class Pending {
        let group = DispatchGroup()
        var result: Result<Value, Error>?
    }

    private enum Entry {
        case value(Value, expiresAt: Double)
        case pending(Pending)
    }

    private let ttlMs: Double
    private let loader: (String) throws -> Value
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(ttlMs: Int, loader: @escaping (String) throws -> Value) {
        self.ttlMs = Double(max(1, ttlMs))
        self.loader = loader
    }

    public func get(_ key: String) throws -> Value {
        lock.lock()
        if let entry = entries[key] {
            switch entry {
            case .value(let value, let expiresAt) where expiresAt > JS.nowMs():
                lock.unlock()
                return value
            case .pending(let pending):
                lock.unlock()
                pending.group.wait()
                return try pending.result!.get()
            default:
                break
            }
        }
        let pending = Pending()
        pending.group.enter()
        entries[key] = .pending(pending)
        lock.unlock()

        let result = Result { try loader(key) }
        pending.result = result

        lock.lock()
        if case .pending(let current)? = entries[key], current === pending {
            switch result {
            case .success(let value): entries[key] = .value(value, expiresAt: JS.nowMs() + ttlMs)
            case .failure: entries.removeValue(forKey: key)
            }
        }
        lock.unlock()
        pending.group.leave()
        return try result.get()
    }

    public func invalidate(_ key: String) {
        lock.lock()
        if case .value? = entries[key] { entries.removeValue(forKey: key) }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Processes

public enum Processes {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// `ps -p <pid> -o command=`
    public static func command(for pid: Int32) -> String {
        guard pid > 0 else { return "" }
        #if os(Linux)
        if let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") {
            return String(decoding: data.map { $0 == 0 ? 32 : $0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        #endif
        let result = run("/bin/ps", ["-p", String(pid), "-o", "command="], timeoutMs: 1_000)
        return result.status == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    public struct Result {
        public let status: Int32
        public let output: String
        public let errorOutput: String
    }

    /// Runs a system tool and waits for it. Only used for OS-provided binaries
    /// (`ps`, `ditto`, `open`).
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, timeoutMs: Int = 120_000,
                           environment: [String: String]? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", errorOutput: error.localizedDescription)
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let outData = LockedBox(Data())
        let errData = LockedBox(Data())
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            outData.value = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        if finished.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(2))
        }
        _ = readers.wait(timeout: .now() + .seconds(2))
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outData.value, as: UTF8.self),
            errorOutput: String(decoding: errData.value, as: UTF8.self)
        )
    }

    /// The runtime's environment without the variables that change how unzip,
    /// tar and gzip read an archive (`UNZIP=-:` would let unzip keep `..` in
    /// names, for instance), for every call that reads one.
    public static var archiveToolEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for name in ["UNZIP", "UNZIPOPT", "ZIPINFO", "ZIPINFOOPT", "TAR_OPTIONS", "TAR_READER_OPTIONS", "TAR_WRITER_OPTIONS", "GZIP"] {
            environment.removeValue(forKey: name)
        }
        return environment
    }
}
