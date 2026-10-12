#if canImport(CryptoKit) && canImport(Metal)
import Foundation
import RoachInference

/// RoachNet Cluster: Macs that share a pairing code run one model together.
/// Each holds a contiguous run of the model's layers (pipeline stages); the
/// Mac that was asked for the model keeps the embedding and the head, runs
/// the sampling, and hands the residual stream from stage to stage.
///
/// This class is both sides: it serves stages to other Macs on the cluster
/// port, and plans and opens stages on them when this Mac loads a model.
final class ClusterNode {
    struct Settings: Codable, Equatable {
        var enabled = false
        var name = ClusterNode.defaultName
        var nodeID = ClusterNode.randomHex(16)
        var secret: String?
        var port: UInt16 = ClusterNode.defaultPort
        var peers: [String] = []
        /// `auto`: split only models too big for this Mac. `always`: spread every model over the cluster.
        var mode = "auto"
    }

    static let defaultPort: UInt16 = 7419
    static var defaultName: String { Foundation.Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    let settingsPath: String
    let shardRoot: String
    let store: NativeModelStore
    weak var server: NativeModelServer?
    let version: String
    let lock = NSLock()
    private(set) var settings: Settings
    private var listener: ClusterListener?
    private(set) var listeningPort: UInt16?
    var hosted: [String: HostedStage] = [:]
    var digests: [String: String] = [:]
    private var reaper: DispatchSourceTimer?
    #if canImport(dnssd)
    private let bonjour = ClusterBonjour()
    #endif

    final class HostedStage {
        let id: String
        let model: String
        let stage: ModelStage
        let coordinator: String
        let backend: MetalBackend
        let footprint: Int
        let lock = NSLock()
        var lastUsed = Date()
        init(id: String, model: String, stage: ModelStage, coordinator: String, backend: MetalBackend, footprint: Int) {
            self.id = id; self.model = model; self.stage = stage; self.coordinator = coordinator; self.backend = backend; self.footprint = footprint
        }
    }

    init(stateRoot: String, storageRoot: String, store: NativeModelStore, version: String) {
        settingsPath = Path.join(stateRoot, "cluster.json")
        shardRoot = Path.join(storageRoot, "cluster", "shards")
        self.store = store
        self.version = version
        if let data = FileManager.default.contents(atPath: settingsPath), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
        if let port = ProcessInfo.processInfo.environment["ROACHNET_CLUSTER_PORT"].flatMap({ UInt16($0) }) { settings.port = port }
    }

    var key: ClusterKey? { settings.secret.flatMap { Data(base64Encoded: $0) }.map(ClusterKey.init(bytes:)) }
    var nodeIDData: Data { Data(hex: settings.nodeID) ?? Data(count: 16) }
    /// On, paired and with at least one other Mac to work with.
    var isActive: Bool { lock.withLock { settings.enabled && settings.secret != nil && !settings.peers.isEmpty } }
    var spreadsEveryModel: Bool { lock.withLock { settings.mode == "always" } }

    // MARK: Settings

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? Files.mkdirp(Path.dirname(settingsPath))
        FileManager.default.createFile(atPath: settingsPath, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Applies a settings change from the app: `enabled`, `name`, `mode`,
    /// `peers`, `code` (join that cluster) or `resetPairing` (start a new one).
    func update(_ change: JSON) throws {
        lock.lock()
        var next = settings
        if let enabled = change["enabled"].boolValue { next.enabled = enabled }
        if let name = change["name"].stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty { next.name = String(name.prefix(64)) }
        if let mode = change["mode"].stringValue {
            guard ["auto", "always"].contains(mode) else { lock.unlock(); throw requestError("mode is auto or always.", 400) }
            next.mode = mode
        }
        if !change["peers"].isUndefined {
            next.peers = Array(Set(change["peers"].array.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        }
        if let code = change["code"].stringValue {
            guard let key = ClusterKey(code: code) else { lock.unlock(); throw requestError("That pairing code isn't valid; it has 26 letters and digits.", 400) }
            next.secret = key.bytes.base64EncodedString()
        }
        if change["resetPairing"].truthy || (next.enabled && next.secret == nil) {
            next.secret = ClusterKey.random().bytes.base64EncodedString()
        }
        let restart = next.enabled != settings.enabled || next.secret != settings.secret || next.port != settings.port
        settings = next
        save()
        lock.unlock()
        if restart {
            stop()
            if next.enabled { start() }
        }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard settings.enabled, settings.secret != nil, listener == nil else { return }
        let host = ProcessInfo.processInfo.environment["ROACHNET_CLUSTER_HOST"] ?? "0.0.0.0"
        do {
            let listener = try ClusterListener(host: host, port: settings.port)
            listener.run { [weak self] link in self?.serve(link) }
            self.listener = listener
            listeningPort = listener.port
            RuntimeLog.write("cluster listening on \(host):\(listener.port) as \(settings.name)")
            #if canImport(dnssd)
            if ProcessInfo.processInfo.environment["ROACHNET_CLUSTER_BONJOUR"] != "0", let key {
                bonjour.advertise(name: settings.name, port: listener.port, id: settings.nodeID, fingerprint: key.fingerprint)
            }
            #endif
        } catch {
            RuntimeLog.write("cluster could not listen on port \(settings.port): \(error)")
        }
        if reaper == nil {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 300, repeating: 300)
            timer.setEventHandler { [weak self] in self?.releaseIdleStages() }
            timer.resume()
            reaper = timer
        }
    }

    func stop() {
        lock.lock()
        listener?.stop()
        listener = nil
        listeningPort = nil
        #if canImport(dnssd)
        bonjour.stop()
        #endif
        hosted.removeAll()
        lock.unlock()
    }

    // MARK: Status

    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// Memory this Mac can still give to models and stages.
    func freeBytes() -> Int {
        let stages = lock.withLock { hosted.values.reduce(0) { $0 + $1.footprint } }
        return max(0, SystemMemory.modelBudget - (server?.residentBytes() ?? 0) - stages)
    }

    func localStatus() -> JSON {
        let stages: [JSON] = lock.withLock {
            hosted.values.map { ["id": JSON($0.id), "model": JSON($0.model), "layers": JSON($0.stage.description), "coordinator": JSON($0.coordinator),
                                 "backend": JSON($0.backend.name)] }
        }
        return ["id": JSON(settings.nodeID), "name": JSON(settings.name), "version": JSON(version), "chip": JSON(ClusterNode.chipName()),
                "memory": ["total": JSON(SystemMemory.total), "budget": JSON(SystemMemory.modelBudget), "free": JSON(freeBytes())],
                "stages": .array(stages)]
    }

    /// Everything the app shows: this Mac, the others (asked live), and how models are split.
    func status(probe: Bool) -> JSON {
        let (current, port) = lock.withLock { (settings, listeningPort) }
        var peers: [JSON] = []
        if probe {
            peers = current.peers.map { address in
                do {
                    let link = try open(address, timeout: 3)
                    defer { link.close() }
                    var status = try link.request(["op": "status"], timeout: 5).0.object
                    status["address"] = JSON(address)
                    status["reachable"] = true
                    return .object(status)
                } catch {
                    return ["address": JSON(address), "reachable": false, "error": JSON("\(error)")]
                }
            }
        } else {
            peers = current.peers.map { ["address": JSON($0)] }
        }
        var out = localStatus().object
        out["enabled"] = JSON(current.enabled)
        out["mode"] = JSON(current.mode)
        out["port"] = JSON(Int(port ?? current.port))
        out["listening"] = JSON(port != nil)
        out["paired"] = JSON(current.secret != nil)
        out["code"] = key.map { JSON($0.code) } ?? .null
        out["fingerprint"] = key.map { JSON($0.fingerprint) } ?? .null
        out["peers"] = .array(peers)
        out["models"] = .array(server?.clusterPlacements() ?? [])
        return .object(out)
    }

    /// Macs advertising RoachNet Cluster on this network, besides this one.
    func nearby() -> [JSON] {
        #if canImport(dnssd)
        let (me, peers, fingerprint) = lock.withLock { (settings.nodeID, Set(settings.peers), key?.fingerprint) }
        return ClusterBonjour.browse().filter { $0.id != me }.map { found in
            ["name": JSON(found.name), "address": JSON(found.address), "sameCluster": JSON(fingerprint != nil && found.fingerprint == fingerprint),
             "added": JSON(peers.contains(found.address))]
        }
        #else
        return []
        #endif
    }

    // MARK: Connections

    func open(_ address: String, timeout: TimeInterval = 5) throws -> ClusterLink {
        guard let key else { throw ClusterError.notPaired }
        let link = try ClusterLink.connect(address, defaultPort: ClusterNode.defaultPort, timeout: timeout)
        link.setTimeout(10)
        do {
            try link.handshakeAsInitiator(key: key, nodeID: nodeIDData)
        } catch {
            link.close()
            throw error
        }
        return link
    }

    private func serve(_ link: ClusterLink) {
        guard let key else { link.close(); return }
        link.setTimeout(10)
        do {
            try link.handshakeAsResponder(key: key, nodeID: nodeIDData)
        } catch {
            RuntimeLog.write("cluster refused \(link.remote): \(error)")
            link.close()
            return
        }
        link.setTimeout(3_600)
        while true {
            guard let (header, payload) = try? link.receive() else { break }
            do {
                let (reply, data) = try handle(header, payload, from: link)
                try link.send(reply, data)
            } catch {
                let message = (error as? RuntimeError)?.message ?? "\(error)"
                guard (try? link.send(["error": JSON(message)])) != nil else { break }
            }
        }
        link.close()
    }

    private func handle(_ header: JSON, _ payload: Data, from link: ClusterLink) throws -> (JSON, Data) {
        switch header["op"].stringValue ?? "" {
        case "status": return (localStatus(), Data())
        case "prepare": return (try prepare(header, coordinator: link.peerID), Data())
        case "shard": return (try receiveShard(header, payload, coordinator: link.peerID), Data())
        case "forward": return try forward(header, payload)
        case "release":
            lock.withLock { hosted[header["stage"].stringValue ?? ""] = nil }
            return (["ok": true], Data())
        default: throw ClusterError.protocolError("Unknown cluster request.")
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

extension ClusterNode {
    static func randomHex(_ count: Int) -> String {
        (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
#endif
