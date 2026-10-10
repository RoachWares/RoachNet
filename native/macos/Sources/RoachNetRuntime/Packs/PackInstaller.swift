import Foundation

/// Installs resource packs transactionally: every file lands in a staging
/// folder, is verified against the manifest's SHA-256, and only then is the
/// whole pack renamed into place. A failure at any point removes the staging
/// folder and leaves the previously installed version untouched. A process
/// that dies mid-install leaves a staging folder that `sweepStaleStaging`
/// removes on the next start.
public final class PackInstaller {
    public let registry: PackRegistry
    private static let jobsLock = NSLock()
    private static var jobs: [PackInstallJob] = []

    public init(registry: PackRegistry) {
        self.registry = registry
    }

    // MARK: Local packages (offline install)

    /// Installs a pack from a folder on disk that holds `manifest.json` and
    /// every resource at its manifest path. Nothing is downloaded.
    @discardableResult
    public func installLocalPackage(at packagePath: String, source: String = "local") throws -> PackRecord {
        let manifestPath = Path.join(packagePath, "manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestPath) else {
            throw PackError.installFailed("No manifest.json in \(packagePath).")
        }
        let manifest = try PackManifest.decode(data)
        guard manifest.kind != .capability else {
            throw PackError.installFailed("\(manifest.name) is a capability pack; it ships with RoachNet and cannot be installed from a package.")
        }
        try registry.checkCompatibility(manifest)
        _ = try registry.resolveDependencies(of: manifest.id, available: registry.records().map(\.manifest) + [manifest])

        let staging = try makeStaging(for: manifest)
        do {
            for resource in manifest.resources {
                let sourcePath = Path.join(packagePath, resource.path)
                guard Files.exists(sourcePath) else { throw PackError.integrity("\(manifest.name) package is missing \(resource.path).") }
                let target = Path.join(staging, resource.path)
                try Files.mkdirp(Path.dirname(target))
                try FileManager.default.copyItem(atPath: sourcePath, toPath: target)
            }
            try verifyAndExtract(manifest, in: staging)
            try writeReceipt(manifest, in: staging, source: source)
            try commit(manifest, from: staging, source: source)
        } catch {
            Files.remove(staging)
            throw error
        }
        return registry.record(manifest.id)!
    }

    // MARK: Downloads

    /// Installs a pack whose manifest names download URLs. Runs on a
    /// background queue; progress is visible through `jobsJSON()`.
    @discardableResult
    public func installFromManifest(_ manifest: PackManifest, source: String, fetch: @escaping (String, String, Int) throws -> Void = PackInstaller.defaultFetch) throws -> PackInstallJob {
        try manifest.validate()
        guard manifest.kind != .capability else { throw PackError.installFailed("\(manifest.name) ships with RoachNet.") }
        try registry.checkCompatibility(manifest)
        _ = try registry.resolveDependencies(of: manifest.id, available: registry.records().map(\.manifest) + [manifest])
        for resource in manifest.resources where resource.url == nil {
            throw PackError.installFailed("\(manifest.name) resource \(resource.path) has no download URL.")
        }
        let job = PackInstallJob(packID: manifest.id, version: manifest.version, totalBytes: manifest.downloadBytes)
        Self.jobsLock.lock()
        Self.jobs = Array(([job] + Self.jobs).prefix(50))
        Self.jobsLock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let staging = try makeStaging(for: manifest)
                defer { if Files.exists(staging) { Files.remove(staging) } }
                job.update(status: "downloading")
                for resource in manifest.resources {
                    let target = Path.join(staging, resource.path)
                    try Files.mkdirp(Path.dirname(target))
                    try fetch(resource.url!, target, resource.bytes)
                    job.add(bytes: resource.bytes)
                }
                job.update(status: "verifying")
                try verifyAndExtract(manifest, in: staging)
                try writeReceipt(manifest, in: staging, source: source)
                try commit(manifest, from: staging, source: source)
                job.update(status: "installed")
            } catch {
                job.update(status: "failed", error: "\(error)")
            }
        }
        return job
    }

    public static func defaultFetch(_ url: String, _ target: String, _ expectedBytes: Int) throws {
        let response = try HTTPClient.request(url, headers: ["user-agent": "RoachNet/\(RuntimeConfiguration.shared.version) pack-installer"], timeoutMs: 600_000, maxResponseBytes: max(expectedBytes * 2, 64 * 1024 * 1024))
        guard response.ok else { throw PackError.installFailed("HTTP \(response.status) from \(url).") }
        try response.body.write(to: URL(fileURLWithPath: target), options: .atomic)
    }

    // MARK: Transaction steps

    func makeStaging(for manifest: PackManifest) throws -> String {
        try Files.mkdirp(registry.stagingRoot)
        let staging = Path.join(registry.stagingRoot, "\(manifest.id)-\(manifest.version)-\(JS.randomHex(6))")
        try Files.mkdirp(staging)
        return staging
    }

    /// Every resource must match its digest and size before anything moves.
    func verifyAndExtract(_ manifest: PackManifest, in staging: String) throws {
        for resource in manifest.resources {
            let path = Path.join(staging, resource.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? Int else {
                throw PackError.integrity("\(manifest.name): \(resource.path) was not written.")
            }
            guard size == resource.bytes else {
                throw PackError.integrity("\(manifest.name): \(resource.path) is \(size) bytes, expected \(resource.bytes).")
            }
            let digest = try SHA256Digest.hexOfFile(atPath: path)
            guard digest == resource.sha256.lowercased() else {
                throw PackError.integrity("\(manifest.name): \(resource.path) digest \(digest) does not match the manifest.")
            }
            if let archive = resource.archive {
                try extract(path, archive: archive, into: Path.dirname(path))
                Files.remove(path)
            }
        }
    }

    func extract(_ archivePath: String, archive: String, into directory: String) throws {
        let result: Processes.Result
        switch archive {
        case "tar.gz", "tgz":
            result = Processes.run("/usr/bin/tar", ["-xzf", archivePath, "-C", directory], timeoutMs: 600_000)
        case "zip":
            #if os(macOS)
            result = Processes.run("/usr/bin/ditto", ["-x", "-k", archivePath, directory], timeoutMs: 600_000)
            #else
            result = Processes.run("/usr/bin/unzip", ["-q", "-o", archivePath, "-d", directory], timeoutMs: 600_000)
            #endif
        default:
            throw PackError.installFailed("Unsupported archive type \(archive).")
        }
        guard result.status == 0 else { throw PackError.installFailed("Extracting \(Path.basename(archivePath)) failed: \(result.errorOutput)") }
        // An archive may not reach outside its folder.
        if let enumerator = FileManager.default.enumerator(atPath: directory) {
            for case let entry as String in enumerator where entry.split(separator: "/").contains("..") {
                throw PackError.integrity("Archive \(Path.basename(archivePath)) contains a path that escapes the pack folder.")
            }
        }
    }

    func writeReceipt(_ manifest: PackManifest, in staging: String, source: String) throws {
        try Files.write(try manifest.encoded(), to: Path.join(staging, "manifest.json"))
        var files: [JSON] = []
        if let enumerator = FileManager.default.enumerator(atPath: staging) {
            for case let entry as String in enumerator where entry != "manifest.json" && entry != "receipt.json" {
                let path = Path.join(staging, entry)
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
                files.append(["path": JSON(entry), "bytes": JSON((attributes[.size] as? Int) ?? 0), "sha256": JSON(try SHA256Digest.hexOfFile(atPath: path))])
            }
        }
        let receipt: JSON = [
            "schema": "org.roachnet.pack-receipt.v1",
            "id": JSON(manifest.id),
            "version": JSON(manifest.version),
            "source": JSON(source),
            "installedAt": JSON(JS.isoNow()),
            "files": .array(files),
        ]
        try Files.writePrettyJSON(receipt, to: Path.join(staging, "receipt.json"))
    }

    /// Atomic swap: the new version is renamed into `installed/<id>/<version>`,
    /// the state file is updated, and only then is the previous version removed.
    func commit(_ manifest: PackManifest, from staging: String, source: String) throws {
        let destination = registry.installRoot(for: manifest.id, version: manifest.version)
        let previousVersion = registry.readState().packs[manifest.id]?.installedVersion
        try Files.mkdirp(Path.dirname(destination))
        if Files.exists(destination) {
            // Re-installing the same version: move the old copy aside first.
            let aside = destination + ".previous-\(JS.randomHex(4))"
            try Files.rename(destination, aside)
            do { try Files.rename(staging, destination) } catch { try? Files.rename(aside, destination); throw error }
            Files.remove(aside)
        } else {
            try Files.rename(staging, destination)
        }
        try registry.markInstalled(manifest, source: source)
        if let previousVersion, previousVersion != manifest.version {
            Files.remove(registry.installRoot(for: manifest.id, version: previousVersion))
        }
    }

    /// Removes staging folders left by an interrupted install.
    @discardableResult
    public func sweepStaleStaging() -> [String] {
        guard Files.exists(registry.stagingRoot) else { return [] }
        var removed: [String] = []
        for entry in Files.entries(registry.stagingRoot) where entry.isDirectory {
            let path = Path.join(registry.stagingRoot, entry.name)
            Files.remove(path)
            removed.append(path)
        }
        return removed
    }

    public func jobsJSON() -> [JSON] {
        Self.jobsLock.lock(); defer { Self.jobsLock.unlock() }
        return Self.jobs.map(\.json)
    }

    public func job(for packID: String) -> PackInstallJob? {
        Self.jobsLock.lock(); defer { Self.jobsLock.unlock() }
        return Self.jobs.first { $0.packID == packID }
    }
}

public final class PackInstallJob {
    public let jobId = "pack_" + JS.randomHex(8)
    public let packID: String
    public let version: String
    public let totalBytes: Int
    private let lock = NSLock()
    private var status = "queued"
    private var receivedBytes = 0
    private var error: String?
    private var updatedAt = JS.isoNow()

    init(packID: String, version: String, totalBytes: Int) {
        self.packID = packID
        self.version = version
        self.totalBytes = totalBytes
    }

    func update(status: String, error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.error = error
        updatedAt = JS.isoNow()
    }

    func add(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        receivedBytes += bytes
        updatedAt = JS.isoNow()
    }

    public var currentStatus: String { lock.lock(); defer { lock.unlock() }; return status }
    public var failure: String? { lock.lock(); defer { lock.unlock() }; return error }

    public var json: JSON {
        lock.lock(); defer { lock.unlock() }
        let progress = totalBytes > 0 ? min(100, Int(Double(receivedBytes) / Double(totalBytes) * 100)) : (status == "installed" ? 100 : 0)
        return [
            "jobId": JSON(jobId), "packID": JSON(packID), "version": JSON(version), "status": JSON(status),
            "totalBytes": JSON(totalBytes), "receivedBytes": JSON(receivedBytes), "progress": JSON(progress),
            "error": JSON(error), "updatedAt": JSON(updatedAt),
        ]
    }
}
