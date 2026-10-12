import Foundation

/// Turns Vault encryption on and off, locks and unlocks the Vault, and
/// finishes or undoes a move that was cut off. Every step that changes the
/// Vault is recorded in the state file before it runs.
public final class VaultEncryptionManager {
    public enum Status: Equatable, Sendable {
        /// Never turned on (or turned off): the Vault is a plain folder.
        case off
        case unlocked
        case locked
        /// A move was cut off; `resumeInterrupted()` finishes or undoes it.
        case interrupted
    }

    public enum Progress: Equatable, Sendable {
        case checking
        case creatingImage
        case copying(done: Int64, total: Int64)
        case verifying
        case swapping
        case done
    }

    public let layout: VaultEncryptionLayout
    let tool: VaultDiskImageTool
    let keyStore: VaultKeyStore
    let files = FileManager.default
    /// Room kept free on the storage drive on top of the copy itself.
    let spareBytes: Int64
    /// The image may grow to this before it needs resizing; it only takes the space its files use.
    let imageCeiling: Int64

    public init(layout: VaultEncryptionLayout, tool: VaultDiskImageTool = HdiutilDiskImageTool(),
                keyStore: VaultKeyStore? = nil, spareBytes: Int64 = 1 << 30, imageCeiling: Int64 = 1 << 40) {
        self.layout = layout
        self.tool = tool
        self.keyStore = keyStore ?? KeychainVaultKeyStore(storageRoot: layout.storageRoot)
        self.spareBytes = spareBytes
        self.imageCeiling = imageCeiling
    }

    public convenience init(storagePath: String) {
        self.init(layout: VaultEncryptionLayout(storagePath: storagePath))
    }

    // MARK: Status

    public func state() -> VaultEncryptionState? {
        guard let data = files.contents(atPath: layout.stateFile.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VaultEncryptionState.self, from: data)
    }

    public func status() -> Status {
        guard let state = state() else { return .off }
        switch (state.phase, state.step) {
        case (.encrypted, .done): return tool.isMounted(layout.vault) ? .unlocked : .locked
        case (.decrypted, .done): return .off
        default: return .interrupted
        }
    }

    public var hasSavedKey: Bool { keyStore.load() != nil }

    /// The unencrypted original kept after encrypting, until it is removed.
    public var unencryptedCopy: URL? {
        state()?.unencryptedCopyPath.map { URL(fileURLWithPath: $0, isDirectory: true) }.flatMap { files.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// The old encrypted image kept after turning encryption off, until it is removed.
    public var retiredImage: URL? {
        state()?.retiredImagePath.map { URL(fileURLWithPath: $0, isDirectory: true) }.flatMap { files.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Size and free space before turning encryption on or off.
    public func preflight() throws -> (files: Int, bytes: Int64, needed: Int64, free: Int64) {
        let inventory = try VaultInventory.scan(layout.vault, hashing: false)
        let needed = inventory.byteCount + inventory.byteCount / 5 + spareBytes
        let free = Self.availableBytes(at: layout.storageRoot)
        return (inventory.fileCount, inventory.byteCount, needed, free)
    }

    // MARK: Turning it on

    /// Copies the Vault into a new encrypted image whose passphrase is
    /// `recoveryKey`, checks the copy, then puts the image in the Vault's
    /// place. The unencrypted original is kept (see `unencryptedCopy`).
    public func encrypt(recoveryKey: String, keepKeyOnThisMac: Bool, progress: (Progress) -> Void = { _ in }) throws {
        guard state() == nil || state()?.phase == .decrypted && state()?.step == .done else {
            throw status() == .interrupted ? VaultEncryptionError.interrupted : VaultEncryptionError.alreadyEncrypted
        }
        guard retiredImage == nil else {
            throw VaultEncryptionError.tool("Remove the old encrypted copy from the last time encryption was on first.")
        }
        guard let key = VaultRecoveryKey.normalize(recoveryKey) else { throw VaultEncryptionError.wrongKey }
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: layout.vault.path, isDirectory: &isFolder), isFolder.boolValue,
              !tool.isMounted(layout.vault), !files.fileExists(atPath: layout.lockedMarker.path) else {
            throw VaultEncryptionError.noVault
        }
        progress(.checking)
        let check = try preflight()
        guard check.free >= check.needed else { throw VaultEncryptionError.notEnoughSpace(needed: check.needed, free: check.free) }
        try makeControlFolder()
        guard !files.fileExists(atPath: layout.image.path) else { throw VaultEncryptionError.interrupted }

        var record = VaultEncryptionState(phase: .encrypting, step: .copying, stamp: Self.stamp(), startedAt: Date())
        try save(record)
        do {
            progress(.creatingImage)
            try tool.create(image: layout.image, passphrase: key, volumeName: VaultEncryptionLayout.volumeName,
                            maxBytes: max(imageCeiling, check.bytes * 2))
            try files.createDirectory(at: layout.stagingMount, withIntermediateDirectories: true)
            try tool.attach(image: layout.image, passphrase: key, mountpoint: layout.stagingMount)
            files.createFile(atPath: layout.stagingMount.appendingPathComponent(".metadata_never_index").path, contents: nil)
            let total = check.bytes
            try Self.copyContents(of: layout.vault, into: layout.stagingMount) { done in progress(.copying(done: done, total: total)) }
            progress(.verifying)
            let original = try VaultInventory.scan(layout.vault, hashing: true)
            let copy = try VaultInventory.scan(layout.stagingMount, hashing: true)
            if let difference = original.firstDifference(from: copy) { throw VaultEncryptionError.copyMismatch(difference) }
            if try VaultInventory.scan(layout.vault, hashing: false).changed(since: original) { throw VaultEncryptionError.vaultChangedDuringCopy }
            try tool.detach(mountpoint: layout.stagingMount, force: false)
            try? files.removeItem(at: layout.stagingMount)
            record.step = .verified
            record.fileCount = original.fileCount
            record.byteCount = original.byteCount
            try save(record)
        } catch {
            undoEncrypting()
            throw error
        }

        // From here on the original is moved, never deleted.
        progress(.swapping)
        let original = layout.unencryptedCopy(record.stamp)
        record.step = .swapping
        record.unencryptedCopyPath = original.path
        try save(record)
        try files.moveItem(at: layout.vault, to: original)
        try makeLockedMountpoint()
        record.phase = .encrypted
        record.step = .done
        try save(record)
        try tool.attach(image: layout.image, passphrase: key, mountpoint: layout.vault)
        progress(.done)
        // Last, so a Keychain problem can't leave the move half done; the recovery key still opens the Vault.
        if keepKeyOnThisMac { try keyStore.save(key) }
    }

    /// Cleans up an encryption that stopped before the swap; the original was never touched.
    private func undoEncrypting() {
        if tool.isMounted(layout.stagingMount) { try? tool.detach(mountpoint: layout.stagingMount, force: true) }
        try? files.removeItem(at: layout.stagingMount)
        try? files.removeItem(at: layout.image)
        try? files.removeItem(at: layout.stateFile)
    }

    // MARK: Locking

    /// Opens the Vault with `key`, or with this Mac's saved key when `key` is nil.
    public func unlock(key typed: String? = nil, keepKeyOnThisMac: Bool = false) throws {
        guard state()?.phase == .encrypted, state()?.step == .done else { throw VaultEncryptionError.notEncrypted }
        guard !tool.isMounted(layout.vault) else { return }
        let key: String
        if let typed {
            guard let normalized = VaultRecoveryKey.normalize(typed) else { throw VaultEncryptionError.wrongKey }
            key = normalized
        } else {
            guard let saved = keyStore.load() else { throw VaultEncryptionError.noSavedKey }
            key = saved
        }
        try makeLockedMountpoint()
        // Mounting over files would hide them; the locked folder should only ever hold the marker.
        let strays = ((try? files.contentsOfDirectory(atPath: layout.vault.path)) ?? [])
            .filter { $0 != VaultEncryptionLayout.lockedMarkerName && $0 != ".DS_Store" }
        guard strays.isEmpty else {
            throw VaultEncryptionError.tool("Something put files in the locked Vault folder (\(strays.prefix(3).joined(separator: ", "))). "
                                            + "Move them out of \(layout.vault.path), then unlock.")
        }
        try tool.attach(image: layout.image, passphrase: key, mountpoint: layout.vault)
        if typed != nil, keepKeyOnThisMac { try keyStore.save(key) }
    }

    /// Closes the Vault. Fails while an app has Vault files open, unless `force`.
    public func lock(force: Bool = false) throws {
        guard state()?.phase == .encrypted else { throw VaultEncryptionError.notEncrypted }
        guard tool.isMounted(layout.vault) else { return }
        try tool.detach(mountpoint: layout.vault, force: force)
    }

    public func forgetSavedKey() { keyStore.delete() }

    public func saveKey(_ typed: String) throws {
        guard let key = VaultRecoveryKey.normalize(typed) else { throw VaultEncryptionError.wrongKey }
        try keyStore.save(key)
    }

    // MARK: Turning it off

    /// Copies the Vault's files out of the image into a plain folder, checks
    /// the copy, then puts the folder back in the Vault's place. The old
    /// image is kept (see `retiredImage`). The Vault must be unlocked.
    public func decrypt(progress: (Progress) -> Void = { _ in }) throws {
        guard var record = state(), record.phase == .encrypted, record.step == .done else { throw VaultEncryptionError.notEncrypted }
        guard tool.isMounted(layout.vault) else { throw VaultEncryptionError.locked }
        progress(.checking)
        let check = try preflight()
        guard check.free >= check.needed else { throw VaultEncryptionError.notEnoughSpace(needed: check.needed, free: check.free) }
        let stamp = Self.stamp()
        let plain = layout.decryptedCopy(stamp)
        let kept = record
        record.phase = .decrypting
        record.step = .copying
        record.stamp = stamp
        try save(record)
        do {
            try files.createDirectory(at: plain, withIntermediateDirectories: true)
            let total = check.bytes
            try Self.copyContents(of: layout.vault, into: plain) { done in progress(.copying(done: done, total: total)) }
            progress(.verifying)
            let original = try VaultInventory.scan(layout.vault, hashing: true)
            let copy = try VaultInventory.scan(plain, hashing: true)
            if let difference = original.firstDifference(from: copy) { throw VaultEncryptionError.copyMismatch(difference) }
            if try VaultInventory.scan(layout.vault, hashing: false).changed(since: original) { throw VaultEncryptionError.vaultChangedDuringCopy }
            record.step = .verified
            try save(record)
            progress(.swapping)
            try tool.detach(mountpoint: layout.vault, force: false)
        } catch {
            try? files.removeItem(at: plain)
            try? save(kept)
            throw error
        }
        record.step = .swapping
        record.retiredImagePath = layout.retiredImage(stamp).path
        try save(record)
        try finishDecryptSwap(record)
        progress(.done)
    }

    /// The swap after the image is closed: the plain copy becomes the Vault, the image is set aside.
    private func finishDecryptSwap(_ given: VaultEncryptionState) throws {
        var record = given
        let plain = layout.decryptedCopy(record.stamp)
        if files.fileExists(atPath: plain.path) {
            if tool.isMounted(layout.vault) { try tool.detach(mountpoint: layout.vault, force: false) }
            try removeLockedMountpoint()
            try files.moveItem(at: plain, to: layout.vault)
        }
        if files.fileExists(atPath: layout.image.path), let retired = record.retiredImagePath {
            try files.moveItem(at: layout.image, to: URL(fileURLWithPath: retired, isDirectory: true))
        }
        record.phase = .decrypted
        record.step = .done
        try save(record)
    }

    // MARK: Cleaning up

    /// Deletes the unencrypted original kept after encrypting.
    public func removeUnencryptedCopy() throws {
        guard var record = state(), record.phase == .encrypted, let copy = unencryptedCopy else { return }
        try files.removeItem(at: copy)
        record.unencryptedCopyPath = nil
        try save(record)
    }

    /// Deletes the old image kept after turning encryption off, and the saved key with it.
    public func removeRetiredImage() throws {
        guard let record = state(), record.phase == .decrypted else { return }
        if let image = retiredImage { try files.removeItem(at: image) }
        keyStore.delete()
        try files.removeItem(at: layout.stateFile)
    }

    // MARK: Interrupted moves

    /// Finishes or undoes a move that was cut off, and says which.
    @discardableResult
    public func resumeInterrupted() throws -> String {
        guard let record = state() else { return "Nothing to finish." }
        switch (record.phase, record.step) {
        case (.encrypting, .copying), (.encrypting, .verified):
            undoEncrypting()
            return "Turning on encryption was cut off before the Vault was moved. It's as it was, unencrypted."
        case (.encrypting, .swapping):
            let original = record.unencryptedCopyPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let moved = original.map { files.fileExists(atPath: $0.path) } ?? false
            if moved {
                var done = record
                try makeLockedMountpoint()
                done.phase = .encrypted
                done.step = .done
                try save(done)
                return "Encryption was finished. Unlock the Vault to use it; the unencrypted original is still kept."
            }
            undoEncrypting()
            return "Turning on encryption was cut off before the Vault was moved. It's as it was, unencrypted."
        case (.decrypting, .copying), (.decrypting, .verified):
            try? files.removeItem(at: layout.decryptedCopy(record.stamp))
            var back = record
            back.phase = .encrypted
            back.step = .done
            try save(back)
            return "Turning off encryption was cut off before anything moved. The Vault is still encrypted."
        case (.decrypting, .swapping):
            try finishDecryptSwap(record)
            return "Turning off encryption was finished. The Vault is a plain folder again; the old encrypted copy is kept."
        default:
            return "Nothing to finish."
        }
    }

    // MARK: Helpers

    private func save(_ record: VaultEncryptionState) throws {
        try makeControlFolder()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: layout.stateFile, options: .atomic)
    }

    private func makeControlFolder() throws {
        try files.createDirectory(at: layout.control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The locked Vault: an empty read-only folder with the marker in it, which the image is mounted over.
    private func makeLockedMountpoint() throws {
        if !files.fileExists(atPath: layout.vault.path) {
            try files.createDirectory(at: layout.vault, withIntermediateDirectories: true)
        }
        guard !tool.isMounted(layout.vault) else { return }
        if !files.fileExists(atPath: layout.lockedMarker.path) {
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.vault.path)
            files.createFile(atPath: layout.lockedMarker.path, contents: Data("RoachNet keeps the encrypted Vault in .vault-encryption. Unlock it in RoachNet.\n".utf8))
        }
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: layout.vault.path)
    }

    private func removeLockedMountpoint() throws {
        guard files.fileExists(atPath: layout.vault.path) else { return }
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.vault.path)
        try? files.removeItem(at: layout.lockedMarker)
        let leftovers = (try? files.contentsOfDirectory(atPath: layout.vault.path)) ?? []
        guard leftovers.isEmpty else {
            throw VaultEncryptionError.tool("The locked Vault folder isn't empty (\(leftovers.prefix(3).joined(separator: ", "))), so it wasn't replaced.")
        }
        try files.removeItem(at: layout.vault)
    }

    /// Copies each item in `source` into `destination` with `ditto`, which
    /// keeps extended attributes, resource forks and permissions.
    static func copyContents(of source: URL, into destination: URL, progress: (Int64) -> Void) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { !VaultInventory.ignored.contains($0) }.sorted()
        var done: Int64 = 0
        progress(0)
        for name in names {
            let item = source.appendingPathComponent(name)
            // ditto follows a link named on its command line; inside folders it keeps links as links. Do the same here.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
                try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent(name).path, withDestinationPath: target)
                continue
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [item.path, destination.appendingPathComponent(name).path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw VaultEncryptionError.tool("Copying \(name) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            done += (try? VaultInventory.scan(item, hashing: false).byteCount) ?? 0
            done += Int64((try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.int64Value ?? 0)
            progress(done)
        }
    }

    static func availableBytes(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    public static func describe(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
