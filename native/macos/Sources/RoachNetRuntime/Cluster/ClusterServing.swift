import Foundation
import RoachInference

extension NativeModelServer {
    /// Memory the loaded models hold now.
    func residentBytes() -> Int { residentTotal }

    /// How each split model is laid out, for the cluster status.
    func clusterPlacements() -> [JSON] {
        #if canImport(CryptoKit) && canImport(Metal)
        return lockedLoaded { loaded in
            loaded.values.compactMap { item in
                guard let backend = item.engine.session.backend as? ClusterBackend else { return nil }
                let local: JSON = ["name": JSON(backend.localName), "layers": JSON(backend.local.model.stage.description), "local": true]
                let hops: [JSON] = backend.hops.map { ["name": JSON($0.name), "layers": JSON($0.stage.description), "address": JSON($0.link.remote)] }
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
