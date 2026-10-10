import Foundation

extension NativeRuntime {
    /// `POST /api/packs/install` with `{"packagePath": "..."}` for an offline
    /// package, or `{"manifestUrl": "..."}` / `{"manifest": {...}}` for a
    /// download. Owner-only: the companion proxy never forwards this route.
    func installPack(_ body: JSON) throws -> JSON {
        let installer = PackInstaller(registry: packRegistry)
        do {
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
            let job = try installer.installFromManifest(manifest, source: source)
            return ["success": true, "status": "queued", "job": job.json]
        } catch let error as PackError {
            throw requestError("\(error)", error.statusCode)
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
