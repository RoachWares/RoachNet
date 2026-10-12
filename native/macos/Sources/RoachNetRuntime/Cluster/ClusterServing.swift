import Foundation
import RoachInference

/// Counters for one hop of a split model (see ClusterBackend.Hop).
struct ClusterHopCounters: Equatable {
    var calls = 0
    var tokens = 0
    var nanoseconds: UInt64 = 0
    var sentBytes = 0
    var receivedBytes = 0

    static func - (after: ClusterHopCounters, before: ClusterHopCounters) -> ClusterHopCounters {
        ClusterHopCounters(calls: after.calls - before.calls, tokens: after.tokens - before.tokens,
                           nanoseconds: after.nanoseconds &- before.nanoseconds, sentBytes: after.sentBytes - before.sentBytes,
                           receivedBytes: after.receivedBytes - before.receivedBytes)
    }

    var json: JSON {
        ["round_trips": JSON(calls), "tokens": JSON(tokens), "ms": JSON(Double(nanoseconds) / 1e6),
         "ms_per_round_trip": JSON(calls > 0 ? Double(nanoseconds) / 1e6 / Double(calls) : 0),
         "sent_bytes": JSON(sentBytes), "received_bytes": JSON(receivedBytes)]
    }
}

extension NativeModelServer {
    /// Each hop's counters for a split model, by position; empty for a model on one Mac.
    func clusterCounters(_ item: LoadedModel) -> [ClusterHopCounters] {
        #if canImport(CryptoKit) && canImport(Metal)
        return (item.engine.session.backend as? ClusterBackend)?.hops.map(\.stats) ?? []
        #else
        return []
        #endif
    }

    /// Per-hop figures for one request, for its trace: the change in each hop's counters.
    func clusterTraceDetail(_ item: LoadedModel, since before: [ClusterHopCounters]) -> JSON? {
        #if canImport(CryptoKit) && canImport(Metal)
        guard let backend = item.engine.session.backend as? ClusterBackend, backend.hops.count == before.count else { return nil }
        return .array(zip(backend.hops, before).map { hop, earlier in
            var entry = (hop.stats - earlier).json.object
            entry["mac"] = JSON(hop.name)
            entry["layers"] = JSON(hop.stage.description)
            return .object(entry)
        })
        #else
        return nil
        #endif
    }

    /// Memory the loaded models hold now.
    func residentBytes() -> Int { residentTotal }

    /// How each split model is laid out, for the cluster status.
    func clusterPlacements() -> [JSON] {
        #if canImport(CryptoKit) && canImport(Metal)
        return lockedLoaded { loaded in
            loaded.values.compactMap { item in
                guard let backend = item.engine.session.backend as? ClusterBackend else { return nil }
                let local: JSON = ["name": JSON(backend.localName), "layers": JSON(backend.local.model.stage.description), "local": true]
                let hops: [JSON] = backend.hops.map {
                    ["name": JSON($0.name), "layers": JSON($0.stage.description), "address": JSON($0.link.remote), "stats": $0.stats.json]
                }
                return ["model": JSON(item.name), "contextLength": JSON(item.contextLength), "broken": JSON(backend.isBroken),
                        "stages": .array([local] + hops)]
            }
        }
        #else
        return []
        #endif
    }

    #if canImport(CryptoKit) && canImport(Metal)
    /// Loads a model split by `plan`: this Mac's stage here, the others' on
    /// their Macs (which are sent their shard first if they lack the model).
    /// Called with `lock` held.
    func loadAcrossCluster(_ name: String, entry: NativeModelStore.Entry, file: GGUFFile, footprint: ModelFootprint, plan: ClusterPlan,
                           cluster: ClusterNode, keepAlive seconds: TimeInterval, fileKey: String, requested: Int) throws -> LoadedModel {
        let localStage = plan.local.stage
        let model = try TransformerModel(file: file, stage: localStage)
        guard let local = MetalBackend.makeVerified(model: model, contextLength: footprint.context) else {
            throw requestError("This Mac can't run its part of \(name) on the GPU.", 500)
        }
        var hops: [ClusterBackend.Hop] = []
        do {
            for placement in plan.remote {
                hops.append(try cluster.openStage(placement, model: name, entry: entry, file: file, context: footprint.context))
            }
        } catch {
            hops.forEach { $0.release() }
            if let runtime = error as? RuntimeError { throw runtime }
            throw requestError("The cluster couldn't load \(name): \(error)", 502)
        }
        let backend = ClusterBackend(local: local, hops: hops, localName: cluster.settings.name)
        let engine = InferenceEngine(session: InferenceSession(model: model, backend: backend))
        let item = LoadedModel(name: name, engine: engine, contextLength: footprint.context, keepAlive: seconds)
        item.requestedContext = requested
        item.fileKey = fileKey
        item.footprint = try ModelFootprint(file: file, contextLength: footprint.context, stage: localStage)
        loaded[name] = item
        RuntimeLog.write("native engine loaded \(name) across the cluster (\(backend.name))")
        return item
    }
    #endif
}
