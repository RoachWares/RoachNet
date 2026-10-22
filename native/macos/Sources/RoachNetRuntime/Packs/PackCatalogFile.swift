import Foundation

public enum PackCatalogFile {
    public static let schema = "org.roachnet.packs-catalog.v1"

    public struct Parsed {
        public var manifests: [PackManifest]
        public var skipped: [String]
    }

    public static func parse(_ file: JSON) -> Parsed {
        guard file["schema"].jsString == schema else {
            return Parsed(
                manifests: [], skipped: file.isNullish ? [] : ["not a pack catalog (schema \(file["schema"].jsString))"]
            )
        }
        var parsed = Parsed(manifests: [], skipped: [])
        var seen = Set<String>()
        for entry in file["packs"].array {
            do {
                let manifest = try PackManifest.decode(entry.serializedData())
                guard manifest.kind != .capability else {
                    throw PackError.invalidManifest("\(manifest.id): capability packs are not accepted from a catalog")
                }
                guard seen.insert(manifest.id).inserted else {
                    throw PackError.invalidManifest("\(manifest.id) is listed twice")
                }
                parsed.manifests.append(manifest)
            } catch {
                parsed.skipped.append("\(error)")
            }
        }
        return parsed
    }

    public static func merge(bundled: [PackManifest], live: [PackManifest]) -> [PackManifest] {
        var seen = Set(bundled.map(\.id))
        var merged = bundled
        for manifest in live where !seen.contains(manifest.id) {
            seen.insert(manifest.id)
            merged.append(manifest)
        }
        return merged
    }
}
