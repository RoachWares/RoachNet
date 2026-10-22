import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct OrgInstanceProblem {
    var detail: String

    var message: String {
        "RoachClaw Org can't read its list of people: instance.json couldn't be read (\(detail)). Nothing was written over it, and people and device links can't be changed until it is fixed. Restore it from a backup, or move it out of the Org folder to start the list of people again, then restart RoachNet."
    }

    var json: JSON { ["file": "instance.json", "detail": JSON(detail), "message": JSON(message)] }
}

final class OrgStore {
    static let runCap = 1_000
    static let wakeCap = 1_000
    static let costEventCap = 50_000
    static let routineRunCap = 2_000
    static let revisionCap = 2_000
    static let activityMemoryCap = 2_000

    let root: String
    let lock = NSRecursiveLock()
    private(set) var instance: OrgInstanceState
    private var companies: [String: OrgCompanyState] = [:]
    private var recentActivity: [String: [OrgActivity]] = [:]
    private(set) var instanceProblem: OrgInstanceProblem?

    init(root: String) {
        self.root = root
        try? FileManager.default.createDirectory(
            atPath: Path.join(root, "companies"), withIntermediateDirectories: true)
        chmod(root, 0o700)
        var instanceIsNew = false
        switch OrgStore.loadInstance(at: Path.join(root, "instance.json")) {
        case .missing:
            instance = OrgInstanceState()
            instanceIsNew = true
        case .loaded(let decoded):
            instance = decoded
        case .failed(let detail):
            instance = OrgInstanceState()
            instanceProblem = OrgInstanceProblem(detail: detail)
        }
        let companiesRoot = Path.join(root, "companies")
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: companiesRoot)) ?? [] {
            let statePath = Path.join(companiesRoot, entry, "state.json")
            guard let data = FileManager.default.contents(atPath: statePath) else { continue }
            do {
                let state = try OrgCodec.decoder.decode(OrgCompanyState.self, from: data)
                companies[state.company.id] = state
                recentActivity[state.company.id] = loadActivity(companyId: state.company.id)
            } catch {
                RuntimeLog.write("org: could not load \(statePath): \(error)")
            }
        }
        if let instanceProblem { RuntimeLog.write("org: \(instanceProblem.message)") }
        if instanceIsNew { try? persistInstance() }
    }

    private enum InstanceLoad {
        case missing
        case loaded(OrgInstanceState)
        case failed(String)
    }

    private static func loadInstance(at path: String) -> InstanceLoad {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var fd = open(path, flags)
        if fd < 0 && errno == EINTR { fd = open(path, flags) }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .failed(code == ELOOP ? OrgStore.describeLink(path) : OrgStore.describe(code))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed(OrgStore.describe(errno)) }
        switch mode_t(truncatingIfNeeded: info.st_mode) & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: return .failed("it is a folder")
        default: return .failed("it isn't a regular file")
        }
        let data: Data
        switch OrgStore.readWhole(fd) {
        case .success(let bytes): data = bytes
        case .failure(let failure): return .failed(OrgStore.describe(failure.code))
        }
        if data.isEmpty { return .failed("it is empty") }
        do {
            return .loaded(try OrgCodec.decoder.decode(OrgInstanceState.self, from: data))
        } catch {
            let parses = (try? JSON.parse(data)) != nil
            return .failed(parses ? "it doesn't have the shape this build expects" : "it isn't valid JSON")
        }
    }

    private struct POSIXCode: Error { let code: Int32 }

    private static func describeLink(_ path: String) -> String {
        var link = stat()
        guard lstat(path, &link) == 0, mode_t(truncatingIfNeeded: link.st_mode) & S_IFMT == S_IFLNK else {
            return OrgStore.describe(ELOOP)
        }
        var target = stat()
        if stat(path, &target) == 0 { return "it is a link, not a regular file" }
        switch errno {
        case ENOENT, ENOTDIR: return "it is a link to something that isn't there"
        case ELOOP: return "it is a link that loops"
        default: return "it is a link, not a regular file"
        }
    }

    private static func readWhole(_ fd: Int32) -> Result<Data, POSIXCode> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return .success(data)
            } else if errno != EINTR {
                return .failure(POSIXCode(code: errno))
            }
        }
    }

    private static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "permission denied"
        case EISDIR: return "it is a folder"
        case ELOOP: return "it is a link that loops"
        case EIO: return "the disk reported an input/output error"
        default: return String(cString: strerror(code)).lowercased()
        }
    }

    func companyDirectory(_ id: String) -> String { Path.join(root, "companies", id) }
    private func statePath(_ id: String) -> String { Path.join(companyDirectory(id), "state.json") }
    private func activityPath(_ id: String) -> String { Path.join(companyDirectory(id), "activity.jsonl") }
    func runLogPath(_ companyId: String, _ runId: String) -> String {
        Path.join(companyDirectory(companyId), "runs", "\(runId).log")
    }
    private func secretPath(_ companyId: String, _ key: String) -> String {
        Path.join(companyDirectory(companyId), "secrets", key)
    }

    static func writeAtomically(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        let directory = Path.dirname(path)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = "\(path).tmp-\(getpid())-\(JS.randomHex(6))"
        guard
            FileManager.default.createFile(
                atPath: temporary, contents: data, attributes: [.posixPermissions: Int(mode)])
        else {
            throw RuntimeError("Could not write \(path).")
        }
        if rename(temporary, path) != 0 {
            unlink(temporary)
            throw RuntimeError("Could not replace \(path).")
        }
    }

    private func persistInstance() throws {
        try OrgStore.writeAtomically(try OrgCodec.encoder.encode(instance), to: Path.join(root, "instance.json"))
    }

    private func persistCompany(_ state: inout OrgCompanyState) throws {
        state.runs.orgCap(OrgStore.runCap)
        state.wakeRequests.orgCap(OrgStore.wakeCap)
        state.costEvents.orgCap(OrgStore.costEventCap)
        state.routineRuns.orgCap(OrgStore.routineRunCap)
        state.configRevisions.orgCap(OrgStore.revisionCap)
        try OrgStore.writeAtomically(try OrgCodec.encoder.encode(state), to: statePath(state.company.id))
    }

    var companyIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return companies.values.sorted { $0.company.createdAt < $1.company.createdAt }.map { $0.company.id }
    }

    func company(_ id: String) -> OrgCompanyState? {
        lock.lock()
        defer { lock.unlock() }
        return companies[id]
    }

    func allCompanies() -> [OrgCompanyState] {
        lock.lock()
        defer { lock.unlock() }
        return companies.values.sorted { $0.company.createdAt < $1.company.createdAt }
    }

    func insertCompany(_ state: OrgCompanyState) throws {
        lock.lock()
        defer { lock.unlock() }
        var copy = state
        try persistCompany(&copy)
        companies[copy.company.id] = copy
        recentActivity[copy.company.id] = recentActivity[copy.company.id] ?? []
    }

    @discardableResult
    func mutateCompany<T>(_ id: String, _ body: (inout OrgCompanyState) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard var state = companies[id] else { throw orgNotFound("Company") }
        let result = try body(&state)
        state.company.updatedAt = JS.isoNow()
        try persistCompany(&state)
        companies[id] = state
        return result
    }

    @discardableResult
    func mutateInstance<T>(_ body: (inout OrgInstanceState) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let instanceProblem { throw orgUnavailable(instanceProblem.message) }
        var state = instance
        let result = try body(&state)
        instance = state
        try persistInstance()
        return result
    }

    func appendActivity(_ activity: OrgActivity) {
        lock.lock()
        defer { lock.unlock() }
        var list = recentActivity[activity.companyId] ?? []
        list.append(activity)
        list.orgCap(OrgStore.activityMemoryCap)
        recentActivity[activity.companyId] = list
        guard let data = try? OrgCodec.encoder.encode(activity) else { return }
        let path = activityPath(activity.companyId)
        if !Files.exists(path) {
            try? FileManager.default.createDirectory(atPath: Path.dirname(path), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            handle.closeFile()
        }
    }

    func activity(companyId: String, limit: Int) -> [OrgActivity] {
        lock.lock()
        defer { lock.unlock() }
        return Array((recentActivity[companyId] ?? []).suffix(max(1, limit)).reversed())
    }

    private func loadActivity(companyId: String) -> [OrgActivity] {
        guard let data = FileManager.default.contents(atPath: activityPath(companyId)) else { return [] }
        let lines = data.split(separator: UInt8(ascii: "\n")).suffix(OrgStore.activityMemoryCap)
        return lines.compactMap { try? OrgCodec.decoder.decode(OrgActivity.self, from: Data($0)) }
    }

    func appendRunLog(companyId: String, runId: String, stream: String, text: String) {
        guard !text.isEmpty else { return }
        let path = runLogPath(companyId, runId)
        lock.lock()
        defer { lock.unlock() }
        if !Files.exists(path) {
            try? FileManager.default.createDirectory(atPath: Path.dirname(path), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let entry: JSON = ["ts": JSON(JS.isoNow()), "stream": JSON(stream), "text": JSON(String(text.prefix(64_000)))]
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((entry.serialized() + "\n").utf8))
            handle.closeFile()
        }
    }

    func runLog(companyId: String, runId: String) -> [JSON] {
        guard let data = FileManager.default.contents(atPath: runLogPath(companyId, runId)) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSON.parse(Data($0)) }
    }

    func removeRunLogs(companyId: String, keeping runIds: Set<String>) {
        let directory = Path.join(companyDirectory(companyId), "runs")
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where entry.hasSuffix(".log") {
            if !runIds.contains(String(entry.dropLast(4))) { unlink(Path.join(directory, entry)) }
        }
    }

    static func validSecretKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 64
            && key.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
                    || $0 == "-" || $0 == "."
            } && !key.hasPrefix(".")
    }

    func writeSecret(companyId: String, key: String, value: String) throws {
        guard OrgStore.validSecretKey(key) else {
            throw orgInvalid("Secret keys may use letters, digits, '.', '_' and '-'.")
        }
        let directory = Path.join(companyDirectory(companyId), "secrets")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        chmod(directory, 0o700)
        try OrgStore.writeAtomically(Data(value.utf8), to: secretPath(companyId, key))
    }

    func readSecret(companyId: String, key: String) -> String? {
        guard OrgStore.validSecretKey(key), let data = FileManager.default.contents(atPath: secretPath(companyId, key))
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func deleteSecret(companyId: String, key: String) {
        guard OrgStore.validSecretKey(key) else { return }
        unlink(secretPath(companyId, key))
    }
}
