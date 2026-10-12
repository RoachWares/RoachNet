import CryptoKit
import Darwin
import Foundation
import Security

// Optional encryption at rest for the Vault folder (`<storage>/Vault`).
//
// Off unless the person turns it on in Settings. When on, the Vault's files
// live inside an encrypted APFS sparse disk image (AES-256, made and opened by
// macOS's own `hdiutil`), and the image is mounted over `<storage>/Vault`
// while the Vault is unlocked. Nothing here implements a cipher: the disk
// image, the Keychain and CryptoKit's SHA-256 (for checking copies) do the work.
//
// While locked, `<storage>/Vault` is an empty read-only folder holding only
// `.roachnet-vault-locked`, so nothing can write into it by mistake and the
// runtime can tell the Vault is locked.
//
// Moving files in either direction copies first, checks every file of the
// copy against the original (path, size and SHA-256), and only then swaps
// folders. The original is kept until the person removes it. A state file in
// `<storage>/.vault-encryption` records each step, so a move cut off by a
// crash or power loss is finished or undone on the next launch, and never
// leaves the Vault half moved.

public struct VaultEncryptionLayout: Equatable, Sendable {
    public static let lockedMarkerName = ".roachnet-vault-locked"
    public static let volumeName = "RoachNet Vault"

    public let storageRoot: URL

    public init(storagePath: String) {
        storageRoot = URL(fileURLWithPath: NSString(string: storagePath).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    public var vault: URL { storageRoot.appendingPathComponent("Vault", isDirectory: true) }
    public var control: URL { storageRoot.appendingPathComponent(".vault-encryption", isDirectory: true) }
    public var image: URL { control.appendingPathComponent("Vault.sparsebundle", isDirectory: true) }
    public var stateFile: URL { control.appendingPathComponent("state.json") }
    public var stagingMount: URL { control.appendingPathComponent("staging-mount", isDirectory: true) }
    public var lockedMarker: URL { vault.appendingPathComponent(VaultEncryptionLayout.lockedMarkerName) }
    public func unencryptedCopy(_ stamp: String) -> URL { control.appendingPathComponent("Vault-unencrypted-\(stamp)", isDirectory: true) }
    public func decryptedCopy(_ stamp: String) -> URL { control.appendingPathComponent("Vault-decrypted-\(stamp)", isDirectory: true) }
    public func retiredImage(_ stamp: String) -> URL { control.appendingPathComponent("Vault-encrypted-\(stamp).sparsebundle", isDirectory: true) }
}

/// What the state file records between steps.
public struct VaultEncryptionState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Copying the Vault into a new image; the original is untouched until `swapping`.
        case encrypting
        /// The Vault lives in the image.
        case encrypted
        /// Copying the image's files out; the image is untouched until `swapping`.
        case decrypting
        /// Plain again; the old image is kept until removed.
        case decrypted
    }

    public enum Step: String, Codable, Sendable {
        case copying, verified, swapping, done
    }

    public var version = 1
    public var phase: Phase
    public var step: Step
    public var stamp: String
    public var startedAt: Date
    /// After encrypting: the unencrypted original, kept until removed.
    public var unencryptedCopyPath: String?
    /// After decrypting: the old image, kept until removed.
    public var retiredImagePath: String?
    public var fileCount: Int?
    public var byteCount: Int64?
}

public enum VaultEncryptionError: LocalizedError, Equatable, Sendable {
    case notEncrypted
    case alreadyEncrypted
    case locked
    case notLocked
    case noVault
    case wrongKey
    case noSavedKey
    case notEnoughSpace(needed: Int64, free: Int64)
    case copyMismatch(String)
    case vaultChangedDuringCopy
    case busy(String)
    case tool(String)
    case interrupted

    public var errorDescription: String? {
        switch self {
        case .notEncrypted: return "The Vault isn't encrypted."
        case .alreadyEncrypted: return "The Vault is already encrypted."
        case .locked: return "Unlock the Vault first."
        case .notLocked: return "The Vault is already unlocked."
        case .noVault: return "There's no Vault folder to encrypt yet."
        case .wrongKey: return "That key doesn't open this Vault."
        case .noSavedKey: return "This Mac has no saved key for the Vault. Unlock it with the recovery key."
        case .notEnoughSpace(let needed, let free):
            return "This needs about \(VaultEncryptionManager.describe(bytes: needed)) free; the drive has \(VaultEncryptionManager.describe(bytes: free))."
        case .copyMismatch(let path): return "The copy of \(path) didn't match the original, so nothing was changed."
        case .vaultChangedDuringCopy: return "Files in the Vault changed while it was being copied. Close anything using the Vault and try again."
        case .busy(let detail): return "Something still has Vault files open, so it can't be locked. \(detail)"
        case .tool(let detail): return detail
        case .interrupted: return "A Vault move was cut off. Finish or undo it before anything else."
        }
    }
}

/// Makes and opens the encrypted disk image. The real one runs `hdiutil`;
/// passphrases go over stdin, never on the command line.
public protocol VaultDiskImageTool: Sendable {
    func create(image: URL, passphrase: String, volumeName: String, maxBytes: Int64) throws
    func attach(image: URL, passphrase: String, mountpoint: URL) throws
    func detach(mountpoint: URL, force: Bool) throws
    func isMounted(_ mountpoint: URL) -> Bool
}

/// Where the Vault key is kept on this Mac, if the person chooses to keep it.
public protocol VaultKeyStore {
    func save(_ key: String) throws
    func load() -> String?
    func delete()
}
