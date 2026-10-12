#if canImport(CryptoKit) && canImport(Metal)
import Foundation
import RoachInference

/// Where each part of a model runs.
struct ClusterPlan: Equatable {
    struct Placement: Equatable {
        /// `nil` is this Mac.
        var address: String?
        var name: String
        var stage: ModelStage
        var bytes: Int
    }
    var placements: [Placement]
    var local: Placement { placements[0] }
    var remote: [Placement] { Array(placements.dropFirst()) }
}

enum ClusterPlanner {
    struct Node {
        var address: String?
        var name: String
        var free: Int
    }

    /// Lays the layers out in order: this Mac first (it keeps the embedding and
    /// the head), then the other Macs in the order given. `spread` divides the
    /// layers in proportion to each Mac's free memory; otherwise each Mac takes
    /// as many as fit before the next one starts. Returns nil when one Mac is
    /// enough, and throws when the cluster together is too small.
    static func plan(layerBytes: [Int], embedding: Int, head: Int, cachePerLayer: Int, scratch: Int,
                     local: Node, peers: [Node], spread: Bool) throws -> ClusterPlan? {
        let costs = layerBytes.map { $0 + cachePerLayer }
        let fixed = embedding + head + scratch
        let localRoom = local.free - fixed
        if !spread, costs.reduce(0, +) <= localRoom { return nil }
        var nodes = [Node(address: nil, name: local.name, free: max(0, localRoom))]
        nodes += peers.map { Node(address: $0.address, name: $0.name, free: max(0, $0.free - scratch)) }
        guard nodes.count > 1 else { return nil }
        let total = nodes.reduce(0) { $0 + $1.free }
        guard costs.reduce(0, +) <= total else {
            throw requestError("The model needs about \(SystemMemory.gigabytes(costs.reduce(0, +) + fixed)) and the cluster's Macs have "
                               + "\(SystemMemory.gigabytes(total + fixed)) free between them.", 507)
        }
        var counts = [Int](repeating: 0, count: nodes.count)
        if spread {
            // Shares of the layers by free memory, rounded, every Mac at least one.
            var assigned = 0
            for index in nodes.indices {
                let share = index == nodes.count - 1 ? layerBytes.count - assigned
                    : max(1, Int((Double(layerBytes.count) * Double(nodes[index].free) / Double(max(1, total))).rounded()))
                counts[index] = min(share, layerBytes.count - assigned - (nodes.count - 1 - index))
                assigned += counts[index]
            }
        } else {
            var layer = 0
            for index in nodes.indices {
                var used = 0
                while layer < costs.count, used + costs[layer] <= nodes[index].free {
                    used += costs[layer]
                    counts[index] += 1
                    layer += 1
                }
            }
        }
        // Check the split against each Mac's room; move layers on where one is over.
        var start = 0
        var placements: [ClusterPlan.Placement] = []
        for (index, node) in nodes.enumerated() where counts[index] > 0 {
            let range = start..<(start + counts[index])
            let bytes = range.reduce(0) { $0 + costs[$1] }
            guard bytes <= node.free else {
                throw requestError("\(node.name) hasn't room for its share of the model's layers.", 507)
            }
            placements.append(.init(address: node.address, name: node.name,
                                    stage: ModelStage(layers: range, embedding: index == 0, head: index == 0), bytes: bytes + (index == 0 ? fixed : scratch)))
            start = range.upperBound
        }
        if placements.first?.address != nil {
            // This Mac holds no layers but still keeps the embedding and the head.
            placements.insert(.init(address: nil, name: local.name, stage: ModelStage(layers: 0..<0, embedding: true, head: true), bytes: fixed), at: 0)
        }
        guard start == layerBytes.count, placements.count > 1 else { return nil }
        return ClusterPlan(placements: placements)
    }
}

/// The coordinator's side of a split model: this Mac's stage runs here, the
/// residual stream goes to each other Mac's stage in turn, and the head runs
/// here again. The session above it can't tell it from a single Mac.
final class ClusterBackend: TransformerBackend, BatchForwarding, FallibleBackend {
    final class Hop {
        let link: ClusterLink
        let stageID: String
        let name: String
        let stage: ModelStage
        init(link: ClusterLink, stageID: String, name: String, stage: ModelStage) {
            self.link = link; self.stageID = stageID; self.name = name; self.stage = stage
        }

        func forward(_ residuals: [Float], count: Int, position: Int) throws -> [Float] {
            let payload = residuals.withUnsafeBufferPointer { Data(buffer: $0) }
            let (_, data) = try link.request(["op": "forward", "stage": JSON(stageID), "position": JSON(position), "count": JSON(count)],
                                            payload, timeout: 120)
            guard data.count == residuals.count * 4 else { throw ClusterError.protocolError("\(name) sent back the wrong amount of data.") }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        func release() {
            _ = try? link.request(["op": "release", "stage": JSON(stageID)], timeout: 5)
            link.close()
        }
    }

    let local: MetalBackend
    let hops: [Hop]
    let localName: String
    private var failure: Error?
    /// Set when a Mac in the pipeline failed; the model is planned again on its next load.
    private(set) var isBroken = false

    init(local: MetalBackend, hops: [Hop], localName: String) {
        self.local = local
        self.hops = hops
        self.localName = localName
    }

    deinit { for hop in hops { hop.release() } }

    var name: String {
        let parts = ["\(localName) \(local.model.stage.layers.lowerBound)–\(local.model.stage.layers.upperBound)"]
            + hops.map { "\($0.name) \($0.stage.layers.lowerBound)–\($0.stage.layers.upperBound)" }
        return "cluster: " + parts.joined(separator: ", ")
    }

    var contextLength: Int { local.contextLength }
    var logits: UnsafeBufferPointer<Float> { local.logits }
    var hiddenState: UnsafeBufferPointer<Float> { local.hiddenState }
    var maxBatch: Int { local.maxBatch }

    func takeFailure() -> Error? {
        defer { failure = nil }
        return failure ?? local.takeFailure()
    }

    private func pipeline(_ residuals: [Float], count: Int, position: Int) -> [Float]? {
        var current = residuals
        do {
            for hop in hops { current = try hop.forward(current, count: count, position: position) }
            return current
        } catch {
            failure = requestError("The cluster stopped mid-reply: \(error)", 502)
            isBroken = true
            return nil
        }
    }

    func forward(token: Int, position: Int, output: ForwardOutput) {
        guard failure == nil else { return }
        local.forward(token: token, position: position, output: .none)
        guard let last = pipeline(Array(local.residualState), count: 1, position: position) else { return }
        last.withUnsafeBufferPointer { local.applyHead(residual: $0.baseAddress!, output: output) }
    }

    func forward(tokens: [Int], position: Int, output: ForwardOutput, each: ((Int, UnsafeBufferPointer<Float>) -> Void)?) {
        guard failure == nil, !tokens.isEmpty else { return }
        local.forward(tokens: tokens, position: position, output: .none, each: nil)
        guard let streams = pipeline(local.batchResiduals(count: tokens.count), count: tokens.count, position: position) else { return }
        let width = local.model.hyperparameters.embeddingLength
        streams.withUnsafeBufferPointer { buffer in
            if let each {
                for t in 0..<tokens.count {
                    local.applyHead(residual: buffer.baseAddress! + t * width, output: .hidden)
                    each(t, local.hiddenState)
                }
            }
            local.applyHead(residual: buffer.baseAddress! + (tokens.count - 1) * width, output: output)
        }
    }
}

/// The coordinating side: planning a split and opening the other Macs' stages.
extension ClusterNode {
    /// The SHA-256 of a model file, which is how another Mac recognizes the
    /// same model already on its disk. Remembered once worked out.
    func digest(of entry: NativeModelStore.Entry) throws -> String {
        if let known = entry.manifest["sha256"].stringValue, known.count == 64 { return known }
        if let cached = lock.withLock({ digests[entry.modelPath] }) { return cached }
        let value = try SHA256Digest.hexOfFile(atPath: entry.modelPath)
        lock.withLock { digests[entry.modelPath] = value }
        return value
    }

    func plan(file: GGUFFile, footprint: ModelFootprint, budget: Int, spread: Bool) throws -> ClusterPlan? {
        let peers: [ClusterPlanner.Node] = lock.withLock { settings.peers }.compactMap { address in
            guard let link = try? open(address, timeout: 3) else { return nil }
            defer { link.close() }
            guard let status = try? link.request(["op": "status"], timeout: 5).0 else { return nil }
            return ClusterPlanner.Node(address: address, name: status["name"].stringValue ?? address, free: Int(status["memory"]["free"].numberValue ?? 0))
        }
        guard !peers.isEmpty else { return nil }
        let sizes = ModelFootprint.layerBytes(file)
        let cachePerLayer = footprint.cache / max(1, sizes.layers.count)
        return try ClusterPlanner.plan(layerBytes: sizes.layers, embedding: sizes.embedding, head: sizes.head, cachePerLayer: cachePerLayer,
                                       scratch: footprint.scratch, local: .init(address: nil, name: settings.name, free: budget),
                                       peers: peers, spread: spread)
    }

    /// Opens one stage on another Mac, sending it the shard when it doesn't
    /// already have the model.
    func openStage(_ placement: ClusterPlan.Placement, model name: String, entry: NativeModelStore.Entry, file: GGUFFile,
                   context: Int) throws -> ClusterBackend.Hop {
        guard let address = placement.address else { throw ClusterError.protocolError("This Mac's stage isn't remote.") }
        let link = try open(address)
        let id = ClusterNode.randomHex(12)
        let digest = try self.digest(of: entry)
        let header: JSON = ["op": "prepare", "stage": JSON(id), "model": JSON(name), "digest": JSON(digest),
                            "layers": JSON(placement.stage.description), "context": JSON(context)]
        do {
            var (reply, _) = try link.request(header, timeout: 300)
            if reply["need"].stringValue == "shard" {
                reply = try sendShard(over: link, header: header, file: file, digest: digest, stage: placement.stage,
                                      from: Int(reply["offset"].numberValue ?? 0))
            }
            guard reply["ok"].truthy else { throw ClusterError.remote("\(placement.name) couldn't start its stage.") }
            RuntimeLog.write("cluster: \(placement.name) runs layers \(placement.stage) of \(name) (\(reply["backend"].stringValue ?? "?"))")
            return ClusterBackend.Hop(link: link, stageID: id, name: placement.name, stage: placement.stage)
        } catch {
            link.close()
            throw error
        }
    }

    /// The shard file for a stage, cut once and kept for the next Mac that needs it.
    func shard(_ file: GGUFFile, digest: String, stage: ModelStage) throws -> (path: String, digest: String) {
        try Files.mkdirp(shardRoot)
        let path = Path.join(shardRoot, "out-\(digest)-\(stage.description).gguf")
        let digestPath = path + ".sha256"
        if Files.exists(path), let known = try? String(contentsOfFile: digestPath, encoding: .utf8) { return (path, known) }
        try GGUFShard.write(file, stage: stage, to: path)
        let value = try SHA256Digest.hexOfFile(atPath: path)
        try value.write(toFile: digestPath, atomically: true, encoding: .utf8)
        return (path, value)
    }

    private func sendShard(over link: ClusterLink, header: JSON, file: GGUFFile, digest: String, stage: ModelStage, from offset: Int) throws -> JSON {
        let (path, shardDigest) = try shard(file, digest: digest, stage: stage)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ClusterError.protocolError("Couldn't read the shard.") }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var position = offset <= size ? offset : 0
        try handle.seek(toOffset: UInt64(position))
        RuntimeLog.write("cluster: sending a \(SystemMemory.gigabytes(size)) shard (layers \(stage)) to \(link.remote)")
        while true {
            let piece = try handle.read(upToCount: 4 << 20) ?? Data()
            let final = position + piece.count >= size
            var message = header.object
            message["op"] = "shard"
            message["offset"] = JSON(position)
            message["final"] = JSON(final)
            if final { message["shardDigest"] = JSON(shardDigest) }
            let (reply, _) = try link.request(.object(message), piece, timeout: final ? 600 : 120)
            position += piece.count
            if final { return reply }
        }
    }
}
#endif
