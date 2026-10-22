import Foundation

public struct PackState: Codable, Equatable {
    public var enabled: Bool
    public var installedVersion: String?
    public var installedAt: String?
    public var source: String?
    public var updatedAt: String?

    public init(
        enabled: Bool, installedVersion: String? = nil, installedAt: String? = nil, source: String? = nil,
        updatedAt: String? = nil
    ) {
        self.enabled = enabled
        self.installedVersion = installedVersion
        self.installedAt = installedAt
        self.source = source
        self.updatedAt = updatedAt
    }
}

struct PackStateFile: Codable {
    static let schema = "org.roachnet.pack-state.v1"
    var schema: String = PackStateFile.schema
    var packs: [String: PackState] = [:]
}

public struct PackRecord: Equatable {
    public let manifest: PackManifest
    public let state: PackState?
    public let bundled: Bool
    public let installRoot: String?

    public var isInstalled: Bool { bundled || state?.installedVersion != nil }
    public var isEnabled: Bool { isInstalled && (state?.enabled ?? false) }
}

public protocol PackExternalShelf: AnyObject {
    func installedRoot(forPack id: String, handler: PackInstallHandler) -> String?
    func removePack(id: String, handler: PackInstallHandler) throws
}

public final class PackRegistry {
    public let storageRoot: String
    public let appVersion: String
    public let platform: String
    private let lock = NSRecursiveLock()
    private var cachedState: PackStateFile?
    public let bundledPacks: [PackManifest]
    public var catalogPacks: [PackManifest] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCatalogPacks
        }
        set {
            lock.lock()
            storedCatalogPacks = newValue
            lock.unlock()
        }
    }
    private var storedCatalogPacks: [PackManifest] = []
    public weak var externalShelf: PackExternalShelf?
    public var onChange: ((String, String) -> Void)?

    public init(
        storageRoot: String, appVersion: String, platform: String = PackRegistry.currentPlatform,
        bundledPacks: [PackManifest] = PackCatalog.bundledCapabilityPacks
    ) {
        self.storageRoot = storageRoot
        self.appVersion = appVersion
        self.platform = platform
        self.bundledPacks = bundledPacks
    }

    public static var currentPlatform: String {
        #if os(macOS)
        return "macos"
        #elseif os(iOS)
        return "ios"
        #else
        return "linux"
        #endif
    }

    public var packsRoot: String { Path.join(storageRoot, "packs") }
    public var installedRoot: String { Path.join(packsRoot, "installed") }
    public var stagingRoot: String { Path.join(packsRoot, ".staging") }
    public var retiredRoot: String { Path.join(packsRoot, "retired") }
    var statePath: String { Path.join(packsRoot, "state.json") }
    public func installRoot(for id: String, version: String) -> String { Path.join(installedRoot, id, version) }

    public func checkedInstallRoot(for id: String, version: String) -> String? {
        guard PackManifest.isValidID(id), PackManifest.isSafeVersion(version) else { return nil }
        let root = installRoot(for: id, version: version)
        guard Path.fileSystemComponents(root) == Path.fileSystemComponents(installedRoot) + [id, version] else {
            return nil
        }
        return root
    }

    func readState() -> PackStateFile {
        lock.lock()
        defer { lock.unlock() }
        if let cachedState { return cachedState }
        var state = PackStateFile()
        if let data = FileManager.default.contents(atPath: statePath),
            let decoded = try? JSONDecoder().decode(PackStateFile.self, from: data),
            decoded.schema == PackStateFile.schema
        {
            state = decoded
        }
        cachedState = state
        return state
    }

    func writeState(_ state: PackStateFile) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Files.write(try encoder.encode(state), to: statePath, mode: Files.privateFileMode)
        cachedState = state
    }

    @discardableResult
    func mutateState<Result>(_ change: (inout PackStateFile) throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        var state = readState()
        let result = try change(&state)
        try writeState(state)
        return result
    }

    func ensureDefaults() throws {
        lock.lock()
        defer { lock.unlock() }
        var state = readState()
        var changed = false
        for pack in bundledPacks where state.packs[pack.id] == nil {
            state.packs[pack.id] = PackState(
                enabled: true, installedVersion: pack.version, installedAt: JS.isoNow(), source: "bundled",
                updatedAt: JS.isoNow())
            changed = true
        }
        if changed { try writeState(state) }
    }

    public func installedResourcePacks() -> [PackManifest] {
        guard Files.exists(installedRoot) else { return [] }
        var manifests: [PackManifest] = []
        let state = readState()
        for entry in Files.entries(installedRoot) where entry.isDirectory && !entry.name.hasPrefix(".") {
            guard let version = state.packs[entry.name]?.installedVersion,
                let root = checkedInstallRoot(for: entry.name, version: version)
            else { continue }
            let manifestPath = Path.join(root, "manifest.json")
            if let data = FileManager.default.contents(atPath: manifestPath),
                let manifest = try? PackManifest.decode(data)
            {
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.id < $1.id }
    }

    public func records() -> [PackRecord] {
        try? ensureDefaults()
        let state = readState()
        let bundled = bundledPacks.map {
            PackRecord(manifest: $0, state: state.packs[$0.id], bundled: true, installRoot: nil)
        }
        let installed = installedResourcePacks().map {
            PackRecord(
                manifest: $0, state: state.packs[$0.id], bundled: false,
                installRoot: installRoot(for: $0.id, version: $0.version))
        }
        var seen = Set((bundled + installed).map(\.manifest.id))
        var catalog: [PackRecord] = []
        for manifest in catalogPacks where !seen.contains(manifest.id) {
            seen.insert(manifest.id)
            catalog.append(externalRecord(manifest, state: state.packs[manifest.id]))
        }
        return bundled + installed + catalog
    }

    private func externalRecord(_ manifest: PackManifest, state: PackState?) -> PackRecord {
        guard let install = manifest.install, let shelf = externalShelf else {
            return PackRecord(manifest: manifest, state: nil, bundled: false, installRoot: nil)
        }
        let root = shelf.installedRoot(forPack: manifest.id, handler: install)
        guard let root else { return PackRecord(manifest: manifest, state: nil, bundled: false, installRoot: nil) }
        let known =
            state
            ?? PackState(
                enabled: true, installedVersion: manifest.version, installedAt: nil, source: "shelf",
                updatedAt: JS.isoNow())
        return PackRecord(manifest: manifest, state: known, bundled: false, installRoot: root)
    }

    public func record(_ id: String) -> PackRecord? { records().first { $0.manifest.id == id } }

    func manifest(for id: String) -> PackManifest? { record(id)?.manifest }

    public func checkCompatibility(_ manifest: PackManifest) throws {
        if let minimum = manifest.requires.roachnet, let required = SemanticVersion(minimum),
            let current = SemanticVersion(appVersion), current < required
        {
            throw PackError.incompatible("\(manifest.name) needs RoachNet \(minimum) or later; this is \(appVersion).")
        }
        if !manifest.requires.platforms.isEmpty, !manifest.requires.platforms.contains(platform) {
            throw PackError.incompatible("\(manifest.name) does not support \(platform).")
        }
    }

    public func resolveDependencies(of id: String, available: [PackManifest]? = nil) throws -> [PackManifest] {
        let catalog = Dictionary(
            (available ?? records().map(\.manifest)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [PackManifest] = []
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ current: String, path: [String]) throws {
            if visited.contains(current) { return }
            if visiting.contains(current) {
                throw PackError.dependencyCycle("Dependency cycle: \((path + [current]).joined(separator: " → ")).")
            }
            guard let manifest = catalog[current] else {
                throw PackError.dependencyMissing("\(path.last ?? id) needs \(current), which is not installed.")
            }
            visiting.insert(current)
            for dependency in manifest.dependencies {
                guard let found = catalog[dependency.id] else {
                    throw PackError.dependencyMissing(
                        "\(manifest.name) needs \(dependency.id), which is not installed.")
                }
                if let minimum = dependency.minimumVersion, let required = SemanticVersion(minimum),
                    let actual = SemanticVersion(found.version), actual < required
                {
                    throw PackError.dependencyMissing(
                        "\(manifest.name) needs \(dependency.id) \(minimum) or later; \(found.version) is installed.")
                }
                try visit(dependency.id, path: path + [current])
            }
            visiting.remove(current)
            visited.insert(current)
            if current != id { ordered.append(manifest) }
        }
        try visit(id, path: [])
        return ordered
    }

    public func enabledDependents(of id: String) -> [PackManifest] {
        records().filter { $0.isEnabled && $0.manifest.dependencies.contains { $0.id == id } }.map(\.manifest)
    }

    public func enable(_ id: String) throws -> PackRecord {
        guard let record = record(id) else { throw PackError.unknownPack("No pack named \(id).") }
        guard record.isInstalled else { throw PackError.unknownPack("\(record.manifest.name) is not installed.") }
        try checkCompatibility(record.manifest)
        let dependencies = try resolveDependencies(of: id)
        try mutateState { state in
            for dependency in dependencies where state.packs[dependency.id]?.enabled != true {
                guard
                    state.packs[dependency.id]?.installedVersion != nil
                        || bundledPacks.contains(where: { $0.id == dependency.id })
                else {
                    throw PackError.dependencyMissing(
                        "\(record.manifest.name) needs \(dependency.name), which is not installed.")
                }
                state.packs[dependency.id]?.enabled = true
                state.packs[dependency.id]?.updatedAt = JS.isoNow()
            }
            var current =
                state.packs[id]
                ?? PackState(
                    enabled: false, installedVersion: record.manifest.version, installedAt: JS.isoNow(),
                    source: record.bundled ? "bundled" : "local")
            current.enabled = true
            current.updatedAt = JS.isoNow()
            state.packs[id] = current
        }
        onChange?(id, "enabled")
        guard let updated = self.record(id) else {
            throw PackError.unknownPack("\(record.manifest.name) is no longer installed.")
        }
        return updated
    }

    public func disable(_ id: String) throws -> PackRecord {
        guard let record = record(id) else { throw PackError.unknownPack("No pack named \(id).") }
        let dependents = enabledDependents(of: id)
        if !dependents.isEmpty {
            throw PackError.dependentsEnabled(
                "Turn off \(dependents.map(\.name).joined(separator: ", ")) first; they depend on \(record.manifest.name)."
            )
        }
        try mutateState { state in
            var current = state.packs[id] ?? PackState(enabled: false)
            current.enabled = false
            current.updatedAt = JS.isoNow()
            state.packs[id] = current
        }
        onChange?(id, "disabled")
        guard let updated = self.record(id) else {
            throw PackError.unknownPack("\(record.manifest.name) is no longer installed.")
        }
        return updated
    }

    func markInstalled(_ manifest: PackManifest, source: String) throws {
        let all = records()
        let enabledIDs = Set(all.filter(\.isEnabled).map(\.manifest.id))
        let dependencies = try? resolveDependencies(of: manifest.id, available: [manifest] + all.map(\.manifest))
        let dependenciesOn = dependencies?.allSatisfy { enabledIDs.contains($0.id) } ?? false
        let previous: PackState? = try mutateState { state in
            let previous = state.packs[manifest.id]
            state.packs[manifest.id] = PackState(
                enabled: (previous?.enabled ?? true) && dependenciesOn,
                installedVersion: manifest.version,
                installedAt: previous?.installedAt ?? JS.isoNow(),
                source: source,
                updatedAt: JS.isoNow()
            )
            return previous
        }
        onChange?(manifest.id, previous?.installedVersion == nil ? "installed" : "updated")
    }

    public func uninstall(_ id: String, retainData: Bool = true) throws -> PackUninstallReport {
        guard let record = record(id) else { throw PackError.unknownPack("No pack named \(id).") }
        guard !record.bundled else {
            throw PackError.installFailed(
                "\(record.manifest.name) ships with RoachNet; turn it off instead of removing it.")
        }
        let dependents = enabledDependents(of: id)
        if !dependents.isEmpty {
            throw PackError.dependentsEnabled(
                "Turn off \(dependents.map(\.name).joined(separator: ", ")) first; they depend on \(record.manifest.name)."
            )
        }
        var report = PackUninstallReport(id: id, removedPaths: [], retainedDataRoots: [], retiredDataRoots: [])
        if let install = record.manifest.install, let shelf = externalShelf {
            if let root = shelf.installedRoot(forPack: id, handler: install) {
                try shelf.removePack(id: id, handler: install)
                report.removedPaths.append(root)
            }
        }
        let packRoot = Path.join(installedRoot, id)
        if Files.exists(packRoot) {
            Files.remove(packRoot)
            report.removedPaths.append(packRoot)
        }
        for root in record.manifest.dataRoots {
            let path = Path.join(storageRoot, root.path)
            guard Files.exists(path) else { continue }
            if retainData {
                report.retainedDataRoots.append(path)
            } else {
                try Files.mkdirp(retiredRoot)
                let stamp = JS.isoNow().replacingOccurrences(of: ":", with: "-")
                let target = Path.join(retiredRoot, "\(id)-\(stamp)-\(Path.basename(root.path))")
                try Files.rename(path, target)
                report.retiredDataRoots.append(target)
            }
        }
        try mutateState { state in _ = state.packs.removeValue(forKey: id) }
        onChange?(id, "uninstalled")
        return report
    }

    public func catalogJSON(includeSizes: Bool = false) -> JSON {
        try? ensureDefaults()
        let installer = PackInstaller(registry: self)
        return [
            "success": true,
            "schema": "org.roachnet.packs.v1",
            "appVersion": JSON(appVersion),
            "platform": JSON(platform),
            "packsRoot": JSON(packsRoot),
            "sizesIncluded": JSON(includeSizes),
            "packs": .array(records().map { recordJSON($0, includeSizes: includeSizes) }),
            "jobs": .array(installer.jobsJSON()),
        ]
    }

    public func recordJSON(_ record: PackRecord, includeSizes: Bool = true) -> JSON {
        let manifest = record.manifest
        var compatibility: JSON = ["ok": true]
        do { try checkCompatibility(manifest) } catch { compatibility = ["ok": false, "reason": JSON("\(error)")] }
        var missing: [String] = []
        do { _ = try resolveDependencies(of: manifest.id) } catch { missing = ["\(error)"] }
        let dataRoots = manifest.dataRoots.map { root -> JSON in
            let path = Path.join(storageRoot, root.path)
            return [
                "path": JSON(root.path), "description": JSON(root.description), "exists": JSON(Files.exists(path)),
                "bytes": includeSizes ? JSON(Files.directorySize(path)) : .null,
            ]
        }
        return [
            "id": JSON(manifest.id),
            "version": JSON(manifest.version),
            "kind": JSON(manifest.kind.rawValue),
            "name": JSON(manifest.name),
            "summary": JSON(manifest.summary),
            "publisher": JSON(manifest.publisher),
            "bundled": JSON(record.bundled),
            "installed": JSON(record.isInstalled),
            "available": JSON(!record.isInstalled),
            "handler": JSON(manifest.install?.handler),
            "enabled": JSON(record.isEnabled),
            "installedVersion": JSON(record.state?.installedVersion),
            "installedAt": JSON(record.state?.installedAt),
            "source": JSON(record.state?.source),
            "installRoot": JSON(record.installRoot),
            "downloadBytes": JSON(manifest.downloadBytes),
            "installedBytes": includeSizes ? JSON(record.installRoot.map(Files.directorySize) ?? 0) : .null,
            "requires": [
                "roachnet": JSON(manifest.requires.roachnet), "platforms": jsonStrings(manifest.requires.platforms),
            ],
            "dependencies": .array(
                manifest.dependencies.map { ["id": JSON($0.id), "minimumVersion": JSON($0.minimumVersion)] }),
            "dependents": jsonStrings(
                records().filter { $0.manifest.dependencies.contains { $0.id == manifest.id } }.map(\.manifest.id)),
            "capabilities": jsonStrings(manifest.capabilities.map(\.rawValue)),
            "resources": .array(
                manifest.resources.map {
                    [
                        "path": JSON($0.path), "bytes": JSON($0.bytes), "sha256": JSON($0.sha256),
                        "archive": JSON($0.archive),
                    ]
                }),
            "dataRoots": .array(dataRoots),
            "compatibility": compatibility,
            "unresolvedDependencies": jsonStrings(missing),
        ]
    }
}

public struct PackUninstallReport: Equatable {
    public let id: String
    public var removedPaths: [String]
    public var retainedDataRoots: [String]
    public var retiredDataRoots: [String]

    var json: JSON {
        [
            "success": true,
            "id": JSON(id),
            "removedPaths": jsonStrings(removedPaths),
            "retainedDataRoots": jsonStrings(retainedDataRoots),
            "retiredDataRoots": jsonStrings(retiredDataRoots),
        ]
    }
}

extension Files {
    public static func directorySize(_ path: String) -> Int {
        guard exists(path) else { return 0 }
        var total = 0
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let entry as String in enumerator {
                let attributes = try? FileManager.default.attributesOfItem(atPath: Path.join(path, entry))
                if (attributes?[.type] as? FileAttributeType) == .typeRegular {
                    total += (attributes?[.size] as? Int) ?? 0
                }
            }
        } else if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            total = (attributes[.size] as? Int) ?? 0
        }
        return total
    }
}
