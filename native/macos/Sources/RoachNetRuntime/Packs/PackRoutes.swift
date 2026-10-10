import Foundation

extension NativeRuntime {
    /// `POST /api/packs/install` with `{"packagePath": "..."}` for an offline
    /// package, or `{"manifestUrl": "..."}` / `{"manifest": {...}}` for a
    /// download. Owner-only: the companion proxy never forwards this route.
    func installPack(_ body: JSON) throws -> JSON {
        let installer = PackInstaller(registry: packRegistry)
        do {
            if body["id"].truthy {
                // A pack from the published catalog, by id.
                let id = body["id"].jsString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let manifest = packRegistry.catalogPacks.first(where: { $0.id == id }) else {
                    throw requestError("The catalog has no pack named \(id).", 404)
                }
                if let record = packRegistry.record(id), record.isInstalled {
                    return ["success": true, "status": "installed", "pack": packRegistry.recordJSON(record)]
                }
                try packRegistry.checkCompatibility(manifest)
                if let install = manifest.install, install.handler == PackInstallHandler.roachSpeechPack, let resource = manifest.resources.first {
                    // The RoachSpeech shelf installer already resolves the chunked
                    // descriptor, verifies the checksum and swaps the pack in.
                    let queued = try queueRoachSpeechPackDownload(["url": JSON(resource.url ?? ""), "packID": JSON(manifest.id), "kind": JSON(install.kind ?? "roachVoice")])
                    return ["success": true, "status": "queued", "packID": JSON(queued.packID), "download": queued.job?.json ?? .null]
                }
                let job = try installer.installFromManifest(manifest, source: "catalog", fetch: packResourceFetch)
                return ["success": true, "status": "queued", "job": job.json]
            }
            if body["packagePath"].truthy {
                let path = body["packagePath"].jsString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Files.exists(Path.join(path, "manifest.json")) else { throw requestError("No pack package at \(path).", 400) }
                let record = try installer.installLocalPackage(at: path, source: "local:\(path)")
                return ["success": true, "status": "installed", "pack": packRegistry.recordJSON(record)]
            }
            let manifest: PackManifest
            var source = "manifest"
            if body["manifestUrl"].truthy {
                let url = body["manifestUrl"].jsString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = WebURL(url), parsed.scheme == "https" || (parsed.scheme == "http" && CompanionProxy.isLoopback(parsed.bareHostname)) else {
                    throw requestError("Pack manifests are fetched over https.", 400)
                }
                let response = try HTTPClient.request(url, headers: ["accept": "application/json"], timeoutMs: 30_000, maxResponseBytes: 1024 * 1024)
                guard response.ok else { throw requestError("HTTP \(response.status) while fetching the pack manifest.", 502) }
                manifest = try PackManifest.decode(response.body)
                source = url
            } else if body["manifest"].isObject {
                manifest = try PackManifest.decode(body["manifest"].serializedData())
            } else {
                throw requestError("Send packagePath, manifestUrl or manifest.", 400)
            }
            let job = try installer.installFromManifest(manifest, source: source, fetch: packResourceFetch)
            return ["success": true, "status": "queued", "job": job.json]
        } catch let error as PackError {
            throw requestError("\(error)", error.statusCode)
        }
    }

    /// Resource downloads go through the runtime's downloader (descriptors,
    /// chunked parts, checksums, progress in the Downloads view).
    private func packResourceFetch(_ url: String, _ target: String, _ expectedBytes: Int, _ sha256: String) throws {
        try downloadNow(JSON(url), to: target, filetype: "roachpack", expectedSha256: sha256)
    }

    /// The published optional packs (`collections/packs.json`). Entries that
    /// fail validation are skipped and logged rather than taking the list down.
    func loadPackCatalog() -> [PackManifest] {
        let file = readJSONFile(["collections/packs.json", "website-apps-dist/collections/packs.json"], .null)
        guard file["schema"].jsString == "org.roachnet.packs-catalog.v1" else { return [] }
        var manifests: [PackManifest] = []
        for entry in file["packs"].array {
            do {
                manifests.append(try PackManifest.decode(entry.serializedData()))
            } catch {
                log("pack catalog entry skipped: \(error)")
            }
        }
        return manifests
    }

    func affectPack(_ pathname: String, _ body: JSON) throws -> JSON {
        let segments = pathname.split(separator: "/").map(String.init)
        guard segments.count == 4 else { throw requestError("Unknown pack route.", 404) }
        let id = segments[2], action = segments[3]
        do {
            switch action {
            case "enable": return ["success": true, "pack": packRegistry.recordJSON(try packRegistry.enable(id))]
            case "disable": return ["success": true, "pack": packRegistry.recordJSON(try packRegistry.disable(id))]
            case "uninstall":
                let retain = body["retainData"].isUndefined ? true : body["retainData"].truthy
                return try packRegistry.uninstall(id, retainData: retain).json
            default: throw requestError("Unknown pack action \(action).", 404)
            }
        } catch let error as PackError {
            throw requestError("\(error)", error.statusCode)
        }
    }
}

extension PackError {
    var statusCode: Int {
        switch self {
        case .unknownPack: return 404
        case .invalidManifest, .incompatible, .dependencyMissing, .dependencyCycle, .dependentsEnabled: return 409
        case .integrity, .installFailed: return 422
        }
    }
}

/// The RoachSpeech model-pack shelf as a pack shelf: a pack is installed when
/// `<storage>/RoachSpeech/ModelPacks/<id>/RoachSpeechPack.json` exists.
extension NativeRuntime: PackExternalShelf {
    public func installedRoot(forPack id: String, handler: PackInstallHandler) -> String? {
        guard handler.handler == PackInstallHandler.roachSpeechPack else { return nil }
        let root = Path.join(modelPacksRootPath(), id)
        return Files.exists(Path.join(root, "RoachSpeechPack.json")) ? root : nil
    }

    public func removePack(id: String, handler: PackInstallHandler) throws {
        guard handler.handler == PackInstallHandler.roachSpeechPack else { return }
        let root = Path.join(modelPacksRootPath(), id)
        guard Files.exists(root) else { return }
        Files.remove(root)
        upsertRoachSpeechPackRegistry(["packID": JSON(id), "kind": JSON(handler.kind ?? "roachVoice"), "status": "removed", "installPath": .null])
    }
}
