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
                try installer.requireInstalledDependencies(of: manifest)
                if let install = manifest.install, install.handler == PackInstallHandler.roachSpeechPack, let resource = manifest.resources.first {
                    // The RoachSpeech shelf installer resolves the chunked descriptor,
                    // checks the archive against the catalog's SHA-256 (the descriptor
                    // must agree with it) and swaps the pack in.
                    let queued = try queueRoachSpeechPackDownload(["url": JSON(resource.url ?? ""), "packID": JSON(manifest.id), "kind": JSON(install.kind ?? "roachVoice")],
                                                                  expectedSha256: resource.sha256)
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

    /// The published optional packs. The copy bundled with the app
    /// (`collections/packs.json`) is the floor; the live catalog at
    /// `ROACHNET_PACK_CATALOG_URL` (default: apps.roachnet.org) adds packs
    /// published after this build. The live copy is fetched in the background,
    /// cached on disk, and never blocks a request. Offline keeps the cache.
    func loadPackCatalog() -> [PackManifest] {
        let bundled = parsePackCatalog(readJSONFile(["collections/packs.json", "website-apps-dist/collections/packs.json"], .null), source: "bundled")
        let cached = parsePackCatalog(readJSONFile([packCatalogCachePath], .null), source: "cached")
        return mergePackCatalogs(bundled: bundled, live: cached)
    }

    var packCatalogCachePath: String { Path.join(config.storageRoot, "packs", "catalog-cache.json") }

    /// Where the live catalog lives; empty disables remote catalogs entirely.
    var packCatalogURL: String? {
        let raw = (config.environment["ROACHNET_PACK_CATALOG_URL"] ?? "https://apps.roachnet.org/collections/packs.json").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let parsed = WebURL(raw), parsed.scheme == "https" || (parsed.scheme == "http" && CompanionProxy.isLoopback(parsed.bareHostname)) else { return nil }
        return raw
    }

    func parsePackCatalog(_ file: JSON, source: String) -> [PackManifest] {
        let parsed = PackCatalogFile.parse(file)
        for reason in parsed.skipped { log("pack catalog (\(source)) entry skipped: \(reason)") }
        return parsed.manifests
    }

    func mergePackCatalogs(bundled: [PackManifest], live: [PackManifest]) -> [PackManifest] {
        PackCatalogFile.merge(bundled: bundled, live: live)
    }

    /// Fetches the live catalog once per hour (or on demand), validates it,
    /// caches it owner-only and swaps it into the registry.
    func refreshPackCatalog(force: Bool = false) {
        guard let url = packCatalogURL else { return }
        if !force, let attributes = try? FileManager.default.attributesOfItem(atPath: packCatalogCachePath),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 3600 {
            return
        }
        BlockingWork.start("roachnet.pack-catalog", qos: .utility) { [self] in
            do {
                let response = try HTTPClient.request(url, headers: ["accept": "application/json", "user-agent": "RoachNet/\(config.version) pack-catalog"], timeoutMs: 15_000, maxResponseBytes: 2 * 1024 * 1024)
                guard response.ok else { throw RuntimeError("HTTP \(response.status) from \(url)") }
                let file = try JSON.parse(response.body)
                let live = parsePackCatalog(file, source: "live")
                guard file["schema"].jsString == "org.roachnet.packs-catalog.v1" else { throw RuntimeError("not a pack catalog") }
                try Files.mkdirp(Path.dirname(packCatalogCachePath))
                try Files.writePrettyJSON(file, to: packCatalogCachePath, mode: Files.privateFileMode)
                let bundled = parsePackCatalog(readJSONFile(["collections/packs.json", "website-apps-dist/collections/packs.json"], .null), source: "bundled")
                packRegistry.catalogPacks = mergePackCatalogs(bundled: bundled, live: live)
                log("pack catalog refreshed from \(url): \(live.count) live pack(s)")
            } catch {
                log("pack catalog refresh skipped: \(error)")
            }
        }
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
