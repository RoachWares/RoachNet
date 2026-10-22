import Foundation
import RoachInference

final class NativeModelStore {
    struct Source {
        let url: String
        let sha256: String?
        let size: Int64?
        let family: String?
        let parameterSize: String?
        let quantization: String?
    }

    struct Entry {
        let name: String
        let directory: String
        let manifest: JSON
        var externalModelPath: String? = nil
        var modelPath: String { externalModelPath ?? Path.join(directory, "model.gguf") }
        var isExternal: Bool { externalModelPath != nil }
    }

    let root: String
    var ollamaRoot: String?
    let catalogPath: String
    private let lock = NSLock()
    private var activePulls: Set<String> = []
    var stallTimeoutMs = 90_000
    var maxAttempts = 6
    var retryPause: (Int) -> Double = { attempt in min(30, pow(2, Double(attempt))) }
    static let transientStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    init(root: String, catalogPath: String) {
        self.root = root
        self.catalogPath = catalogPath
    }

    static func normalize(_ raw: String) throws -> (name: String, model: String, tag: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("hf.co/") || value.hasPrefix("huggingface.co/") {
            value = "hf/" + value.split(separator: "/", maxSplits: 1).last!.replacingOccurrences(of: "/", with: "--")
        }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let model = parts.first ?? ""
        let tag = parts.count > 1 ? parts[1] : "latest"
        let safe = "^[a-z0-9][a-z0-9._-]{0,127}(/[a-z0-9][a-z0-9._-]{0,127})?$"
        guard JS.matches(safe, model), JS.matches("^[a-z0-9][a-z0-9._-]{0,63}$", tag), !model.contains("..") else {
            throw requestError("Model name \(raw.debugDescription) is not valid.", 400)
        }
        return ("\(model):\(tag)", model, tag)
    }

    func directory(for name: String) throws -> String {
        let normalized = try NativeModelStore.normalize(name)
        return Path.join(root, normalized.model, normalized.tag)
    }

    func entry(_ name: String) -> Entry? {
        if let native = nativeEntry(name) { return native }
        let normalized = (try? NativeModelStore.normalize(name).name) ?? name
        return ollamaEntries().first { $0.name == normalized }
    }

    private func nativeEntry(_ name: String) -> Entry? {
        guard let directory = try? directory(for: name),
            let manifest = JSON.read(contentsOf: Path.join(directory, "manifest.json"))
        else { return nil }
        return NativeModelStore.entry(directory: directory, manifest: manifest, fallbackName: name)
    }

    static func entry(directory: String, manifest: JSON, fallbackName: String) -> Entry? {
        let name = manifest["name"].stringValue ?? fallbackName
        if Files.exists(Path.join(directory, "model.gguf")) {
            return Entry(name: name, directory: directory, manifest: manifest)
        }
        if let file = manifest["modelFile"].stringValue, Files.exists(file) {
            return Entry(name: name, directory: directory, manifest: manifest, externalModelPath: file)
        }
        return nil
    }

    func createDerived(_ rawName: String, from base: Entry, profile: JSON) throws -> Entry {
        let name = try NativeModelStore.normalize(rawName).name
        guard name != base.name else { throw requestError("A model can't be created from itself.", 400) }
        if let existing = nativeEntry(name), existing.manifest["derivedFrom"].isUndefined {
            throw requestError("\(name) is a downloaded model; pick another name.", 409)
        }
        let directory = try directory(for: name)
        try Files.mkdirp(directory)
        var manifest = base.manifest.object
        manifest["name"] = JSON(name)
        manifest["source"] = "create"
        manifest["derivedFrom"] = JSON(base.manifest["derivedFrom"].stringValue ?? base.name)
        manifest.remove("modelFile")
        var merged = base.manifest["profile"].object
        for (key, value) in profile.object { merged[key] = value }
        manifest["profile"] = .object(merged)
        manifest["modifiedAt"] = JSON(JS.isoNow())
        let destination = Path.join(directory, "model.gguf")
        try? FileManager.default.removeItem(atPath: destination)
        var external: String? = nil
        if (try? FileManager.default.linkItem(atPath: base.modelPath, toPath: destination)) == nil {
            manifest["modelFile"] = JSON(base.modelPath)
            external = base.modelPath
        }
        try Files.writePrettyJSON(.object(manifest), to: Path.join(directory, "manifest.json"))
        return Entry(name: name, directory: directory, manifest: .object(manifest), externalModelPath: external)
    }

    func setProfile(_ entry: Entry, _ profile: JSON) throws -> Entry {
        var manifest = entry.manifest.object
        var merged = manifest["profile"].object
        for (key, value) in profile.object { merged[key] = value }
        manifest["profile"] = .object(merged)
        manifest["modifiedAt"] = JSON(JS.isoNow())
        try Files.writePrettyJSON(.object(manifest), to: Path.join(entry.directory, "manifest.json"))
        return Entry(
            name: entry.name, directory: entry.directory, manifest: .object(manifest),
            externalModelPath: entry.externalModelPath)
    }

    func copy(_ entry: Entry, as rawName: String) throws -> Entry {
        let name = try NativeModelStore.normalize(rawName).name
        guard name != entry.name else { throw requestError("A model can't be copied onto itself.", 400) }
        if entry.isExternal || !entry.manifest["derivedFrom"].isUndefined {
            return try createDerived(name, from: entry, profile: .object(JSONObject()))
        }
        let directory = try directory(for: name)
        try Files.mkdirp(directory)
        let destination = Path.join(directory, "model.gguf")
        try? FileManager.default.removeItem(atPath: destination)
        if (try? FileManager.default.linkItem(atPath: entry.modelPath, toPath: destination)) == nil {
            try FileManager.default.copyItem(atPath: entry.modelPath, toPath: destination)
        }
        var manifest = entry.manifest.object
        manifest["name"] = JSON(name)
        manifest["modifiedAt"] = JSON(JS.isoNow())
        try Files.writePrettyJSON(.object(manifest), to: Path.join(directory, "manifest.json"))
        return Entry(name: name, directory: directory, manifest: .object(manifest))
    }

    static func fileIdentity(_ path: String) -> String {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
            let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber
        else { return resolved }
        return "\(device.int64Value):\(inode.int64Value)"
    }

    func list() -> [Entry] {
        var entries: [Entry] = []
        let fm = FileManager.default
        let enumerator = fm.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix("manifest.json") else { continue }
            let directory = Path.dirname(Path.join(root, relative))
            if let manifest = JSON.read(contentsOf: Path.join(directory, "manifest.json")),
                let name = manifest["name"].stringValue,
                let entry = NativeModelStore.entry(directory: directory, manifest: manifest, fallbackName: name)
            {
                entries.append(entry)
            }
        }
        let native = Set(entries.map(\.name))
        entries += ollamaEntries().filter { !native.contains($0.name) }
        return entries.sorted { $0.name < $1.name }
    }

    func ollamaEntries() -> [Entry] {
        guard let ollamaRoot, Files.isDirectory(Path.join(ollamaRoot, "manifests")) else { return [] }
        let manifests = Path.join(ollamaRoot, "manifests")
        var entries: [Entry] = []
        guard let enumerator = FileManager.default.enumerator(atPath: manifests) else { return [] }
        while let relative = enumerator.nextObject() as? String {
            let parts = relative.split(separator: "/").map(String.init)
            guard parts.count == 4, let manifest = JSON.read(contentsOf: Path.join(manifests, relative)) else {
                continue
            }
            guard
                let layer = manifest["layers"].array.first(where: {
                    $0["mediaType"].stringValue == "application/vnd.ollama.image.model"
                }),
                let digest = layer["digest"].stringValue, digest.hasPrefix("sha256:")
            else { continue }
            let blob = Path.join(ollamaRoot, "blobs", "sha256-" + digest.dropFirst(7))
            guard Files.exists(blob) else { continue }
            let model = parts[1] == "library" ? parts[2] : "\(parts[1])/\(parts[2])"
            guard let name = try? NativeModelStore.normalize("\(model):\(parts[3])").name else { continue }
            guard let file = try? GGUFFile(path: blob),
                ModelHyperparameters.supportedArchitectures.contains(file.architecture)
            else { continue }
            let synthesized: JSON = [
                "name": JSON(name), "source": "ollama", "sha256": JSON(String(digest.dropFirst(7))),
                "size": layer["size"] || 0, "format": "gguf", "architecture": JSON(file.architecture),
                "family": JSON(file.architecture),
                "parameterSize": "", "quantization": JSON(NativeModelStore.dominantQuantization(file)),
                "modifiedAt": JSON(
                    JS.iso(
                        (try? FileManager.default.attributesOfItem(atPath: blob)[.modificationDate] as? Date) ?? Date())
                ),
            ]
            entries.append(
                Entry(name: name, directory: Path.dirname(blob), manifest: synthesized, externalModelPath: blob))
        }
        return entries
    }

    func delete(_ name: String) throws {
        guard let entry = nativeEntry(name) else {
            if self.entry(name)?.isExternal == true {
                throw requestError("model '\(name)' belongs to an Ollama model folder; remove it there", 409)
            }
            throw requestError("model '\(name)' not found", 404)
        }
        try FileManager.default.removeItem(atPath: entry.directory)
    }

    func catalog() -> [JSON] {
        JSON.read(contentsOf: catalogPath)?["models"].array ?? []
    }

    func resolveSource(_ rawName: String, request: JSON) throws -> Source {
        let normalized = try NativeModelStore.normalize(rawName).name
        if let url = request["url"].stringValue ?? request["from"].stringValue, !url.isEmpty {
            let loopbackTestURL =
                ProcessInfo.processInfo.environment["ROACHNET_MODEL_PULL_ALLOW_LOOPBACK_HTTP"] == "1"
                && (url.hasPrefix("http://127.0.0.1:") || url.hasPrefix("http://localhost:"))
            guard url.hasPrefix("https://") || loopbackTestURL else {
                throw requestError("Model URLs must use https.", 400)
            }
            return Source(
                url: url, sha256: request["sha256"].stringValue?.lowercased(), size: nil, family: nil,
                parameterSize: nil, quantization: nil)
        }
        for item in catalog() {
            let names = [item["name"].stringValue ?? ""] + item["aliases"].array.compactMap(\.stringValue)
            if names.contains(where: { (try? NativeModelStore.normalize($0).name) == normalized }),
                let url = item["url"].stringValue
            {
                return Source(
                    url: url, sha256: item["sha256"].stringValue, size: item["size"].numberValue.map { Int64($0) },
                    family: item["family"].stringValue, parameterSize: item["parameterSize"].stringValue,
                    quantization: item["quantization"].stringValue)
            }
        }
        let lowered = rawName.trimmingCharacters(in: .whitespaces)
        if lowered.lowercased().hasPrefix("hf.co/") || lowered.lowercased().hasPrefix("huggingface.co/") {
            let path = String(lowered.split(separator: "/", maxSplits: 1).last ?? "")
            let pieces = path.split(separator: ":", maxSplits: 1).map(String.init)
            let repo = pieces[0]
            let quant = (pieces.count > 1 ? pieces[1] : "Q4_K_M").lowercased()
            guard JS.matches("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo) else {
                throw requestError("Invalid Hugging Face repository.", 400)
            }
            let tree = try HTTPClient.fetchJSON(
                "https://huggingface.co/api/models/\(repo)/tree/main", timeoutMs: 20_000)
            let files = tree.array.filter { ($0["path"].stringValue ?? "").lowercased().hasSuffix(".gguf") }
            guard
                let match = files.first(where: {
                    let path = ($0["path"].stringValue ?? "").lowercased()
                    return path.contains(quant) && !JS.matches("-\\d{5}-of-\\d{5}\\.gguf$", path)
                }), let file = match["path"].stringValue
            else {
                throw requestError("No single-file \(quant.uppercased()) GGUF found in \(repo).", 404)
            }
            return Source(
                url: "https://huggingface.co/\(repo)/resolve/main/\(file)", sha256: match["lfs"]["oid"].stringValue,
                size: match["lfs"]["size"].numberValue.map { Int64($0) }, family: nil, parameterSize: nil,
                quantization: quant.uppercased())
        }
        throw requestError(
            "pull model manifest: file does not exist (\(rawName) is not in the RoachNet model catalog)", 404)
    }

    func pull(_ rawName: String, request: JSON, progress: @escaping (JSON) -> Bool) throws -> Entry {
        let name = try NativeModelStore.normalize(rawName).name
        lock.lock()
        guard !activePulls.contains(name) else {
            lock.unlock()
            throw requestError("A pull for \(name) is already running.", 409)
        }
        activePulls.insert(name)
        lock.unlock()
        defer {
            lock.lock()
            activePulls.remove(name)
            lock.unlock()
        }

        _ = progress(["status": "pulling manifest"])
        let source = try resolveSource(rawName, request: request)
        let directory = try directory(for: name)
        try Files.mkdirp(directory)
        let partial = Path.join(directory, "model.gguf.partial")
        let final = Path.join(directory, "model.gguf")
        if let existing = entry(name), let sha = source.sha256, existing.manifest["sha256"].stringValue == sha {
            _ = progress(["status": "success"])
            return existing
        }

        var hasher = SHA256Digest()
        var offset: Int64 = 0
        if Files.exists(partial), let handle = FileHandle(forReadingAtPath: partial) {
            while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(chunk)
                offset += Int64(chunk.count)
            }
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: partial, contents: nil)
        }
        guard let output = FileHandle(forWritingAtPath: partial) else {
            throw RuntimeError("Could not write \(partial).")
        }
        defer { try? output.close() }
        try output.seekToEnd()

        let digest = "sha256:" + (source.sha256 ?? "unknown")
        let total = source.size
        var lastReport = Date.distantPast
        var cancelled = false
        if total == nil || offset < total! {
            guard let url = URL(string: source.url) else { throw requestError("Invalid model URL.", 400) }
            func restartPartial() throws {
                try output.truncate(atOffset: 0)
                hasher = SHA256Digest()
                offset = 0
            }
            var restartedAfter416 = false
            var attempt = 0
            while true {
                attempt += 1
                let download = StreamingDownload(
                    url: url, headers: [:], maxBytes: 200 << 30, resumeFrom: offset,
                    onResponse: { restart in
                        if restart { try restartPartial() }
                    },
                    onChunk: { data, state in
                        output.write(data)
                        hasher.update(data)
                        offset = state.receivedBytes
                        let now = Date()
                        if now.timeIntervalSince(lastReport) > 0.25 {
                            lastReport = now
                            let completed = state.receivedBytes
                            let expected = total ?? state.expectedBytes
                            if !progress([
                                "status": JSON("pulling \(String(digest.suffix(12)))"), "digest": JSON(digest),
                                "total": expected.map { JSON(Double($0)) } ?? nil, "completed": JSON(Double(completed)),
                            ]) {
                                cancelled = true
                                throw RuntimeError("Pull cancelled.", statusCode: 499)
                            }
                        }
                    }
                )
                do {
                    _ = try download.run(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: 6 * 3600 * 1000)
                    break
                } catch {
                    if cancelled { throw RuntimeError("Pull cancelled.", statusCode: 499) }
                    if let runtimeError = error as? RuntimeError, runtimeError.statusCode == 416, offset > 0,
                        !restartedAfter416
                    {
                        restartedAfter416 = true
                        try restartPartial()
                        continue
                    }
                    guard let runtimeError = error as? RuntimeError,
                        NativeModelStore.transientStatuses.contains(runtimeError.statusCode),
                        attempt < maxAttempts
                    else { throw error }
                    let pause = retryPause(attempt)
                    if !progress([
                        "status": JSON("retrying (attempt \(attempt + 1) of \(maxAttempts)): \(runtimeError.message)"),
                        "digest": JSON(digest), "total": total.map { JSON(Double($0)) } ?? nil,
                        "completed": JSON(Double(offset)),
                    ]) {
                        throw RuntimeError("Pull cancelled.", statusCode: 499)
                    }
                    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                }
            }
        }
        try output.synchronize()

        _ = progress(["status": "verifying sha256 digest"])
        let actual = hasher.finalizeHex()
        if let expected = source.sha256, expected.lowercased() != actual {
            try? FileManager.default.removeItem(atPath: partial)
            throw RuntimeError("Downloaded model failed verification: expected sha256 \(expected), got \(actual).")
        }
        let file = try GGUFFile(path: partial)
        guard ModelHyperparameters.supportedArchitectures.contains(file.architecture) else {
            try? FileManager.default.removeItem(atPath: partial)
            throw RuntimeError("Model architecture \(file.architecture) is not supported by the native engine yet.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? NSNumber)?.int64Value ?? 0
        _ = progress(["status": "writing manifest"])
        try? FileManager.default.removeItem(atPath: final)
        try FileManager.default.moveItem(atPath: partial, toPath: final)
        let manifest: JSON = [
            "name": JSON(name),
            "source": JSON(source.url),
            "sha256": JSON(actual),
            "size": JSON(Double(size)),
            "format": "gguf",
            "architecture": JSON(file.architecture),
            "family": JSON(source.family ?? file.architecture),
            "parameterSize": JSON(source.parameterSize ?? ""),
            "quantization": JSON(source.quantization ?? NativeModelStore.dominantQuantization(file)),
            "modifiedAt": JSON(JS.isoNow()),
        ]
        try Files.writePrettyJSON(manifest, to: Path.join(directory, "manifest.json"))
        _ = progress(["status": "success"])
        return Entry(name: name, directory: directory, manifest: manifest)
    }

    func importFile(_ path: String, as rawName: String) throws -> Entry {
        let name = try NativeModelStore.normalize(rawName).name
        let file = try GGUFFile(path: path)
        guard ModelHyperparameters.supportedArchitectures.contains(file.architecture) else {
            throw requestError(
                "Model architecture \(file.architecture) is not supported by the native engine yet.", 400)
        }
        let directory = try directory(for: name)
        try Files.mkdirp(directory)
        let destination = Path.join(directory, "model.gguf")
        try? FileManager.default.removeItem(atPath: destination)
        if (try? FileManager.default.linkItem(atPath: path, toPath: destination)) == nil {
            try FileManager.default.copyItem(atPath: path, toPath: destination)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber)?.int64Value ?? 0
        let manifest: JSON = [
            "name": JSON(name), "source": JSON("file"), "sha256": JSON(try SHA256Digest.hexOfFile(atPath: destination)),
            "size": JSON(Double(size)), "format": "gguf", "architecture": JSON(file.architecture),
            "family": JSON(file.architecture),
            "parameterSize": "", "quantization": JSON(NativeModelStore.dominantQuantization(file)),
            "modifiedAt": JSON(JS.isoNow()),
        ]
        try Files.writePrettyJSON(manifest, to: Path.join(directory, "manifest.json"))
        return Entry(name: name, directory: directory, manifest: manifest)
    }

    static func dominantQuantization(_ file: GGUFFile) -> String {
        var bytes: [String: Int] = [:]
        for tensor in file.tensors.values where tensor.shape.count > 1 {
            bytes[tensor.type.name, default: 0] += tensor.byteCount
        }
        return bytes.max { $0.value < $1.value }?.key ?? "unknown"
    }
}
