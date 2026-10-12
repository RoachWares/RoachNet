import CryptoKit
import Darwin
import Foundation
import Security

/// `hdiutil`, macOS's disk image tool. The image is AES-256 encrypted APFS in
/// a sparse bundle (it grows as files are added, up to `maxBytes`).
public struct HdiutilDiskImageTool: VaultDiskImageTool {
    public init() {}

    public func create(image: URL, passphrase: String, volumeName: String, maxBytes: Int64) throws {
        let megabytes = max(64, maxBytes / 1_048_576)
        try run(["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-encryption", "AES-256", "-stdinpass",
                 "-volname", volumeName, "-size", "\(megabytes)m", image.path], stdin: passphrase)
    }

    public func attach(image: URL, passphrase: String, mountpoint: URL) throws {
        do {
            try run(["attach", "-nobrowse", "-owners", "on", "-noautoopen", "-mountpoint", mountpoint.path, "-stdinpass", image.path],
                    stdin: passphrase)
        } catch VaultEncryptionError.tool(let detail) where detail.contains("Authentication error") || detail.contains("authentication") {
            throw VaultEncryptionError.wrongKey
        }
    }

    public func detach(mountpoint: URL, force: Bool) throws {
        do {
            try run(["detach"] + (force ? ["-force"] : []) + [mountpoint.path], stdin: nil)
        } catch VaultEncryptionError.tool(let detail) where detail.lowercased().contains("busy") {
            throw VaultEncryptionError.busy(detail)
        }
    }

    public func isMounted(_ mountpoint: URL) -> Bool { VaultMounts.isMountPoint(mountpoint) }

    private func run(_ arguments: [String], stdin: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VaultEncryptionError.tool(detail.isEmpty ? "hdiutil \(arguments.first ?? "") failed (\(process.terminationStatus))." : detail)
        }
    }
}

enum VaultMounts {
    /// True when `url` is the root of a mounted volume (its own mount point).
    static func isMountPoint(_ url: URL) -> Bool {
        // realpath, not NSString.resolvingSymlinksInPath: that one drops /private
        // from /private/var/..., while the kernel records the mount under /private.
        guard let resolved = realpath(url.path, nil) else { return false }
        let path = String(cString: resolved)
        free(resolved)
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == path
    }
}

/// The key in the login Keychain, for this storage folder only.
public struct KeychainVaultKeyStore: VaultKeyStore {
    public let service = "com.roachwares.roachnet.vault-encryption"
    public let account: String

    public init(storageRoot: URL) {
        let digest = SHA256.hash(data: Data(storageRoot.path.utf8)).map { String(format: "%02x", $0) }.joined()
        account = "vault-" + digest.prefix(16)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func save(_ key: String) throws {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "RoachNet Vault key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultEncryptionError.tool("Couldn't save the key in the Keychain (\(status)).") }
    }

    public func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}

/// The recovery key: 256 random bits written as 52 Crockford base32
/// characters in groups of four. It is the disk image's passphrase, so
/// whoever has it can open the Vault, and without it (and without this Mac's
/// Keychain copy) nobody can.
public enum VaultRecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 52

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "No system randomness")
        var bits = 0, value = 0, out = ""
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }

    /// Accepts what a person types: any case, spaces or dashes, O for 0 and I or L for 1.
    public static func normalize(_ typed: String) -> String? {
        guard let out = normalizeFragment(typed), out.count == length else { return nil }
        return out
    }

    /// The same clean-up for part of a key, of any length.
    public static func normalizeFragment(_ typed: String) -> String? {
        var out = ""
        for character in typed.uppercased() {
            switch character {
            case " ", "-", "\n", "\t": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(character) else { return nil }
                out.append(character)
            }
        }
        return out
    }

    public static func grouped(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 4).map { start in
            let begin = key.index(key.startIndex, offsetBy: start)
            return String(key[begin..<key.index(begin, offsetBy: min(4, key.count - start))])
        }.joined(separator: "-")
    }
}

/// Every file, folder and link under a root, for checking a copy against its original.
struct VaultInventory: Equatable {
    struct Entry: Equatable {
        enum Kind: Equatable { case file, directory, link }
        var kind: Kind
        var size: Int64
        var modified: Date?
        var sha256: String?
        var linkTarget: String?
    }

    /// Files the system or Finder makes on their own; copied when present, never compared.
    static let ignored: Set<String> = [".DS_Store", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
                                       ".metadata_never_index", VaultEncryptionLayout.lockedMarkerName]

    var entries: [String: Entry] = [:]
    var fileCount: Int { entries.values.filter { $0.kind == .file }.count }
    var byteCount: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    static func scan(_ root: URL, hashing: Bool) throws -> VaultInventory {
        var inventory = VaultInventory()
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        // A folder that can't be read must stop the move, not be skipped quietly.
        final class Failures { var first: URL? }
        let failures = Failures()
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, _ in
            if failures.first == nil { failures.first = url }
            return true
        }) else {
            throw VaultEncryptionError.copyMismatch(root.lastPathComponent)
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            // Resolve the folders above the entry, never the entry itself (it may be a link).
            let full = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent
            let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            if relative.split(separator: "/").contains(where: { ignored.contains(String($0)) }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                inventory.entries[relative] = Entry(kind: .link, size: 0, modified: nil, sha256: nil,
                                                    linkTarget: try? manager.destinationOfSymbolicLink(atPath: url.path))
            } else if values.isDirectory == true {
                inventory.entries[relative] = Entry(kind: .directory, size: 0, modified: nil, sha256: nil, linkTarget: nil)
            } else {
                let size = Int64(values.fileSize ?? 0)
                inventory.entries[relative] = Entry(kind: .file, size: size, modified: values.contentModificationDate,
                                                    sha256: hashing ? try sha256(of: url) : nil, linkTarget: nil)
            }
        }
        if let unreadable = failures.first {
            throw VaultEncryptionError.tool("RoachNet couldn't read \(unreadable.lastPathComponent) in the Vault, so nothing was moved.")
        }
        return inventory
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The first path whose copy differs from the original, or nil when every entry matches.
    func firstDifference(from copy: VaultInventory) -> String? {
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let other = copy.entries[path] else { return path }
            if entry.kind != other.kind || entry.size != other.size || entry.linkTarget != other.linkTarget { return path }
            if let mine = entry.sha256, let theirs = other.sha256, mine != theirs { return path }
        }
        return copy.entries.keys.first { entries[$0] == nil }
    }

    /// True when the original changed after `earlier` was taken (sizes, dates or the set of paths).
    func changed(since earlier: VaultInventory) -> Bool {
        guard entries.count == earlier.entries.count else { return true }
        for (path, entry) in entries {
            guard let before = earlier.entries[path], before.kind == entry.kind, before.size == entry.size,
                  before.modified == entry.modified, before.linkTarget == entry.linkTarget else { return true }
        }
        return false
    }
}
