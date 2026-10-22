import Foundation
import RoachNetCore

struct ImportedObsidianVault: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var path: String
    var importedAt: String

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

enum VaultWorkspaceStore {
    private static func manifestURL(storagePath: String) -> URL {
        URL(fileURLWithPath: RoachNetDeveloperPaths.workspaceRoot(storagePath: storagePath))
            .appendingPathComponent("obsidian", isDirectory: true)
            .appendingPathComponent("vaults.json")
    }

    static func loadImportedVaults(storagePath: String) -> [ImportedObsidianVault] {
        let manifest = manifestURL(storagePath: storagePath)
        guard
            let data = try? Data(contentsOf: manifest),
            let decoded = try? JSONDecoder().decode([ImportedObsidianVault].self, from: data)
        else {
            return []
        }

        return
            decoded
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func saveImportedVaults(_ vaults: [ImportedObsidianVault], storagePath: String) throws {
        let manifest = manifestURL(storagePath: storagePath)
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            vaults.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        try data.write(to: manifest, options: Data.WritingOptions.atomic)
    }

    static func importVault(from sourcePath: String, storagePath: String) throws -> ImportedObsidianVault {
        let normalizedPath = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        var current = loadImportedVaults(storagePath: storagePath)

        if let existing = current.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath
        }) {
            return existing
        }

        let vault = ImportedObsidianVault(
            id: UUID().uuidString,
            name: URL(fileURLWithPath: normalizedPath).lastPathComponent,
            path: normalizedPath,
            importedAt: ISO8601DateFormatter().string(from: Date())
        )
        current.append(vault)
        try saveImportedVaults(current, storagePath: storagePath)
        return vault
    }

    static func noteURLs(in vault: ImportedObsidianVault, limit: Int? = nil) -> [URL] {
        noteURLs(in: vault.url, limit: limit)
    }

    static func noteURLs(in rootURL: URL, limit: Int? = nil) -> [URL] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var noteURLs: [URL] = []
        for case let candidate as URL in enumerator {
            if candidate.lastPathComponent == ".obsidian" {
                enumerator.skipDescendants()
                continue
            }

            let extensionName = candidate.pathExtension.lowercased()
            guard extensionName == "md" || extensionName == "markdown" else {
                continue
            }

            noteURLs.append(candidate)
            if let limit, noteURLs.count >= limit {
                break
            }
        }

        return noteURLs.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func noteCount(in vault: ImportedObsidianVault) -> Int {
        noteURLs(in: vault).count
    }

    static func isObsidianCompatible(vault: ImportedObsidianVault) -> Bool {
        FileManager.default.fileExists(
            atPath: vault.url.appendingPathComponent(".obsidian", isDirectory: true).path
        )
    }

    static func containingImportedVault(for fileURL: URL, importedVaults: [ImportedObsidianVault])
        -> ImportedObsidianVault?
    {
        let normalizedFilePath = fileURL.standardizedFileURL.path
        return importedVaults.first { vault in
            normalizedFilePath.hasPrefix(vault.url.standardizedFileURL.path + "/")
        }
    }
}
