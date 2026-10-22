#if canImport(CryptoKit) && canImport(Metal)
import Foundation
import RoachInference

extension ClusterNode {
    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func integer(_ value: JSON, in range: ClosedRange<Int>) -> Int? {
        guard let number = value.numberValue, number.isFinite, number.rounded() == number,
            number >= Double(range.lowerBound), number <= Double(range.upperBound)
        else { return nil }
        return Int(number)
    }

    static let shardDiskReserve: Int64 = 4 << 30

    func prepare(_ header: JSON, coordinator: String) throws -> JSON {
        guard let id = header["stage"].stringValue, let digest = header["digest"].stringValue,
            let stage = header["layers"].stringValue.flatMap(ModelStage.init), let model = header["model"].stringValue
        else {
            throw ClusterError.protocolError("A stage request is missing its details.")
        }
        guard ClusterNode.isSHA256Hex(digest) else {
            throw ClusterError.protocolError("A stage request's model digest isn't a SHA-256.")
        }
        if let existing = lock.withLock({ hosted[id] }) {
            return ["ok": true, "backend": JSON(existing.backend.name), "maxBatch": JSON(existing.backend.maxBatch)]
        }
        guard
            let context = header["context"].isUndefined
                ? 4_096 : ClusterNode.integer(header["context"], in: 1...1_048_576)
        else {
            throw ClusterError.protocolError("A stage request's context length is out of range.")
        }
        let shardPath = Path.join(shardRoot, "\(digest)-\(stage.description).gguf")
        var source: (path: String, stage: ModelStage?)?
        if let whole = store.list().first(where: { $0.manifest["sha256"].stringValue == digest }) {
            source = (whole.modelPath, stage)
        } else if Files.exists(shardPath) {
            source = (shardPath, nil)
        }
        guard let source else {
            let partial = shardPath + ".part"
            let have = (try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? NSNumber)?.intValue ?? 0
            return ["need": "shard", "offset": JSON(have)]
        }
        let file = try GGUFFile(path: source.path)
        let footprint = try ModelFootprint(file: file, contextLength: context, stage: stage)
        let free = freeBytes()
        guard footprint.total <= free else {
            throw requestError(
                "\(settings.name) needs \(SystemMemory.gigabytes(footprint.total)) for layers \(stage.layers.lowerBound)–\(stage.layers.upperBound) "
                    + "but has \(SystemMemory.gigabytes(free)) free for models.", 507)
        }
        let loaded = try TransformerModel(file: file, stage: source.stage)
        guard loaded.stage == stage else {
            throw ClusterError.protocolError("The shard holds layers \(loaded.stage), not \(stage).")
        }
        guard let backend = MetalBackend.makeVerified(model: loaded, contextLength: footprint.context) else {
            throw requestError("\(settings.name) can't run its stage on the GPU.", 500)
        }
        let hostedStage = HostedStage(
            id: id, model: model, stage: stage, coordinator: coordinator, backend: backend, footprint: footprint.total)
        lock.withLock { hosted[id] = hostedStage }
        RuntimeLog.write("cluster: running layers \(stage) of \(model) for \(coordinator.prefix(8)) (\(backend.name))")
        return ["ok": true, "backend": JSON(backend.name), "maxBatch": JSON(backend.maxBatch)]
    }

    func receiveShard(_ header: JSON, _ payload: Data, coordinator: String) throws -> JSON {
        guard let digest = header["digest"].stringValue,
            let stage = header["layers"].stringValue.flatMap(ModelStage.init)
        else {
            throw ClusterError.protocolError("A shard piece is missing its details.")
        }
        guard ClusterNode.isSHA256Hex(digest) else {
            throw ClusterError.protocolError("A shard digest isn't a SHA-256.")
        }
        try Files.mkdirp(shardRoot)
        let shardPath = Path.join(shardRoot, "\(digest)-\(stage.description).gguf")
        let partial = shardPath + ".part"
        guard let offset = header["offset"].isUndefined ? 0 : ClusterNode.integer(header["offset"], in: 0...(1 << 40))
        else {
            throw ClusterError.protocolError("A shard piece's offset is out of range.")
        }
        guard SetupPlatform.availableBytes(at: shardRoot) - Int64(payload.count) >= ClusterNode.shardDiskReserve else {
            throw requestError(
                "\(settings.name) hasn't enough free disk for the shard; it keeps \(SystemMemory.gigabytes(Int(ClusterNode.shardDiskReserve))) free.",
                507)
        }
        if offset == 0 { FileManager.default.createFile(atPath: partial, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: partial) else {
            throw ClusterError.protocolError("Couldn't write the shard.")
        }
        let size = try handle.seekToEnd()
        guard Int(size) == offset else {
            try? handle.close()
            throw ClusterError.protocolError("The shard piece at \(offset) doesn't follow the \(size) bytes received.")
        }
        try handle.write(contentsOf: payload)
        try handle.close()
        guard header["final"].truthy else { return ["ok": true] }
        let expected = header["shardDigest"].stringValue ?? ""
        guard try SHA256Digest.hexOfFile(atPath: partial) == expected else {
            try? FileManager.default.removeItem(atPath: partial)
            throw ClusterError.protocolError("The shard arrived damaged; it will be sent again.")
        }
        try? FileManager.default.removeItem(atPath: shardPath)
        try FileManager.default.moveItem(atPath: partial, toPath: shardPath)
        return try prepare(header, coordinator: coordinator)
    }

    func forward(_ header: JSON, _ payload: Data) throws -> (JSON, Data) {
        guard let stage = lock.withLock({ hosted[header["stage"].stringValue ?? ""] }) else {
            throw ClusterError.remote("\(settings.name) is no longer running that stage.")
        }
        let context = stage.backend.contextLength
        let width = stage.backend.model.hyperparameters.embeddingLength
        guard
            let position = header["position"].isUndefined
                ? 0 : ClusterNode.integer(header["position"], in: 0...context),
            let count = header["count"].isUndefined ? 1 : ClusterNode.integer(header["count"], in: 1...context),
            payload.count == count * width * 4, position + count <= context
        else {
            throw ClusterError.protocolError("A forward request doesn't fit the stage.")
        }
        stage.lock.lock()
        defer {
            stage.lastUsed = Date()
            stage.lock.unlock()
        }
        let backend = stage.backend
        var out = Data()
        payload.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Float.self).baseAddress!
            if count == 1 {
                backend.forward(residual: input, position: position, output: .none)
                out = Data(buffer: backend.residualState)
                return
            }
            var done = 0
            let step = max(1, backend.maxBatch)
            while done < count {
                let piece = min(step, count - done)
                backend.forward(
                    residuals: input + done * width, count: piece, position: position + done, output: .none, each: nil)
                backend.batchResiduals(count: piece).withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
                done += piece
            }
        }
        if let failure = backend.takeFailure() { throw ClusterError.remote("\(settings.name): \(failure)") }
        return (["ok": true], out)
    }

    func releaseIdleStages() {
        let cutoff = Date().addingTimeInterval(-1_800)
        lock.withLock {
            for (id, stage) in hosted where stage.lastUsed < cutoff && stage.lock.try() {
                stage.lock.unlock()
                hosted[id] = nil
            }
        }
    }
}
#endif
