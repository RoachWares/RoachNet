import Foundation
import XCTest
@testable import RoachNetCore

/// Vault encryption against real encrypted disk images (hdiutil), in
/// throwaway folders. Every move is checked file by file, both ways, and
/// each place a move can be cut off is finished or undone without losing a file.
final class VaultEncryptionTests: XCTestCase {
    final class MemoryKeyStore: VaultKeyStore {
        var key: String?
        func save(_ key: String) throws { self.key = key }
        func load() -> String? { key }
        func delete() { key = nil }
    }

    private var root: URL!
    private var keys: MemoryKeyStore!
    private var manager: VaultEncryptionManager!
    private let files = FileManager.default

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil"), "needs hdiutil")
        try XCTSkipIf(ProcessInfo.processInfo.environment["ROACHNET_SKIP_DISK_IMAGE_TESTS"] == "1")
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rn-vault-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        keys = MemoryKeyStore()
        manager = VaultEncryptionManager(layout: VaultEncryptionLayout(storagePath: root.path), keyStore: keys,
                                         spareBytes: 0, imageCeiling: 256 << 20)
        try seedVault()
    }

    override func tearDownWithError() throws {
        guard let root, let manager else { return }
        for mountpoint in [manager.layout.vault, manager.layout.stagingMount] where VaultMounts.isMountPoint(mountpoint) {
            try? HdiutilDiskImageTool().detach(mountpoint: mountpoint, force: true)
        }
        if files.fileExists(atPath: manager.layout.vault.path) {
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manager.layout.vault.path)
        }
        try? files.removeItem(at: root)
    }

    private func seedVault() throws {
        let vault = manager.layout.vault
        try files.createDirectory(at: vault.appendingPathComponent("notes/deep", isDirectory: true), withIntermediateDirectories: true)
        try Data("# Plan\nLocal first.\n".utf8).write(to: vault.appendingPathComponent("notes/plan.md"))
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: vault.appendingPathComponent("notes/deep/blob.bin"))
        try Data("hidden".utf8).write(to: vault.appendingPathComponent(".obsidian-settings.json"))
        try Data("memory".utf8).write(to: vault.appendingPathComponent("roachbrain-memories.json"))
        try files.createSymbolicLink(atPath: vault.appendingPathComponent("plan-link.md").path, withDestinationPath: "notes/plan.md")
        let tagged = vault.appendingPathComponent("notes/plan.md").path.withCString { path in
            setxattr(path, "com.roachnet.test", "kept", 4, 0, 0)
        }
        XCTAssertEqual(tagged, 0)
    }

    private func inventory(_ url: URL) throws -> VaultInventory { try VaultInventory.scan(url, hashing: true) }

    func testRecoveryKeysRoundTripAndForgiveTyping() {
        let key = VaultRecoveryKey.generate()
        XCTAssertEqual(key.count, VaultRecoveryKey.length)
        XCTAssertNotEqual(key, VaultRecoveryKey.generate())
        let grouped = VaultRecoveryKey.grouped(key)
        XCTAssertEqual(grouped.split(separator: "-").count, 13)
        XCTAssertEqual(VaultRecoveryKey.normalize(grouped), key)
        XCTAssertEqual(VaultRecoveryKey.normalize(grouped.lowercased().replacingOccurrences(of: "-", with: " ")), key)
        XCTAssertEqual(VaultRecoveryKey.normalize(String(repeating: "O", count: 52)), String(repeating: "0", count: 52))
        XCTAssertNil(VaultRecoveryKey.normalize(String(key.dropLast())), "too short")
        XCTAssertNil(VaultRecoveryKey.normalize(String(key.dropLast()) + "U"), "U isn't in the alphabet")
    }

    func testOnLockUnlockOffKeepsEveryFile() throws {
        let before = try inventory(manager.layout.vault)
        XCTAssertEqual(manager.status(), .off)
        let key = VaultRecoveryKey.generate()
        var steps: [VaultEncryptionManager.Progress] = []
        try manager.encrypt(recoveryKey: VaultRecoveryKey.grouped(key), keepKeyOnThisMac: true) { steps.append($0) }
        XCTAssertEqual(steps.last, .done)
        XCTAssertTrue(steps.contains(.verifying))
        XCTAssertEqual(manager.status(), .unlocked)
        XCTAssertEqual(keys.key, key)
        XCTAssertNil(try inventory(manager.layout.vault).firstDifference(from: before), "the Vault reads the same while unlocked")
        XCTAssertEqual(try String(contentsOf: manager.layout.vault.appendingPathComponent("plan-link.md")), "# Plan\nLocal first.\n")
        let copy = try XCTUnwrap(manager.unencryptedCopy)
        XCTAssertNil(try inventory(copy).firstDifference(from: before), "the original is kept as it was")

        try manager.lock()
        XCTAssertEqual(manager.status(), .locked)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: manager.layout.vault.path), [VaultEncryptionLayout.lockedMarkerName])
        XCTAssertFalse(files.createFile(atPath: manager.layout.vault.appendingPathComponent("stray.txt").path, contents: Data("x".utf8)),
                       "nothing can be written into the locked Vault")
        XCTAssertThrowsError(try manager.unlock(key: VaultRecoveryKey.generate())) { XCTAssertEqual($0 as? VaultEncryptionError, .wrongKey) }
        XCTAssertEqual(manager.status(), .locked)
        try manager.unlock()
        XCTAssertEqual(manager.status(), .unlocked)
        try Data("added while encrypted".utf8).write(to: manager.layout.vault.appendingPathComponent("new.txt"))

        try manager.lock()
        keys.delete()
        XCTAssertThrowsError(try manager.unlock()) { XCTAssertEqual($0 as? VaultEncryptionError, .noSavedKey) }
        try manager.unlock(key: VaultRecoveryKey.grouped(key).lowercased(), keepKeyOnThisMac: false)
        XCTAssertNil(keys.key, "a typed key is saved only when asked")
        let encrypted = try inventory(manager.layout.vault)

        try manager.removeUnencryptedCopy()
        XCTAssertNil(manager.unencryptedCopy)

        try manager.decrypt()
        XCTAssertEqual(manager.status(), .off)
        XCTAssertFalse(VaultMounts.isMountPoint(manager.layout.vault))
        XCTAssertNil(try inventory(manager.layout.vault).firstDifference(from: encrypted), "every file comes back out, including new ones")
        let size = manager.layout.vault.appendingPathComponent("notes/plan.md").path.withCString { getxattr($0, "com.roachnet.test", nil, 0, 0, 0) }
        XCTAssertEqual(size, 4, "extended attributes survive both moves")
        XCTAssertNotNil(manager.retiredImage)
        try manager.removeRetiredImage()
        XCTAssertNil(manager.state())
        XCTAssertEqual(manager.status(), .off)
    }

    func testEncryptingCutOffBeforeTheSwapLeavesTheVaultAsItWas() throws {
        let before = try inventory(manager.layout.vault)
        let key = VaultRecoveryKey.generate()
        // What a crash mid-copy leaves: a state file, a half-filled image, a staging mount.
        try files.createDirectory(at: manager.layout.control, withIntermediateDirectories: true)
        try HdiutilDiskImageTool().create(image: manager.layout.image, passphrase: key, volumeName: "x", maxBytes: 128 << 20)
        try files.createDirectory(at: manager.layout.stagingMount, withIntermediateDirectories: true)
        try HdiutilDiskImageTool().attach(image: manager.layout.image, passphrase: key, mountpoint: manager.layout.stagingMount)
        try writeState(phase: "encrypting", step: "copying")
        XCTAssertEqual(manager.status(), .interrupted)
        XCTAssertThrowsError(try manager.encrypt(recoveryKey: key, keepKeyOnThisMac: false))

        XCTAssertTrue(try manager.resumeInterrupted().contains("as it was"))
        XCTAssertEqual(manager.status(), .off)
        XCTAssertFalse(files.fileExists(atPath: manager.layout.image.path))
        XCTAssertFalse(VaultMounts.isMountPoint(manager.layout.stagingMount))
        XCTAssertNil(try inventory(manager.layout.vault).firstDifference(from: before))
    }

    func testEncryptingCutOffMidSwapFinishesAndOpensWithTheKey() throws {
        let before = try inventory(manager.layout.vault)
        let key = VaultRecoveryKey.generate()
        try manager.encrypt(recoveryKey: key, keepKeyOnThisMac: false)
        try manager.lock()
        // What a crash right after moving the original leaves: no Vault folder at all.
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manager.layout.vault.path)
        try files.removeItem(at: manager.layout.vault)
        var record = try XCTUnwrap(manager.state())
        record.phase = .encrypting
        record.step = .swapping
        try write(record)
        XCTAssertEqual(manager.status(), .interrupted)

        XCTAssertTrue(try manager.resumeInterrupted().contains("finished"))
        XCTAssertEqual(manager.status(), .locked)
        try manager.unlock(key: key)
        XCTAssertNil(try inventory(manager.layout.vault).firstDifference(from: before))
    }

    func testDecryptingCutOffIsUndoneBeforeTheSwapAndFinishedDuringIt() throws {
        let key = VaultRecoveryKey.generate()
        try manager.encrypt(recoveryKey: key, keepKeyOnThisMac: true)
        let encrypted = try inventory(manager.layout.vault)
        var record = try XCTUnwrap(manager.state())

        // Cut off while copying out: the half copy goes, the Vault stays encrypted.
        let half = manager.layout.decryptedCopy("20261012T000000Z")
        try files.createDirectory(at: half, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: half.appendingPathComponent("plan.md"))
        record.phase = .decrypting
        record.step = .copying
        record.stamp = "20261012T000000Z"
        try write(record)
        XCTAssertTrue(try manager.resumeInterrupted().contains("still encrypted"))
        XCTAssertEqual(manager.status(), .unlocked)
        XCTAssertFalse(files.fileExists(atPath: half.path))

        // Cut off after the image was closed and before the folders were swapped: finished.
        let stamp = "20261012T000001Z"
        let plain = manager.layout.decryptedCopy(stamp)
        try files.createDirectory(at: plain, withIntermediateDirectories: true)
        try VaultEncryptionManager.copyContents(of: manager.layout.vault, into: plain) { _ in }
        try manager.lock()
        record = try XCTUnwrap(manager.state())
        record.phase = .decrypting
        record.step = .swapping
        record.stamp = stamp
        record.retiredImagePath = manager.layout.retiredImage(stamp).path
        try write(record)
        XCTAssertTrue(try manager.resumeInterrupted().contains("plain folder"))
        XCTAssertEqual(manager.status(), .off)
        XCTAssertNil(try inventory(manager.layout.vault).firstDifference(from: encrypted))
        XCTAssertNotNil(manager.retiredImage)
    }

    func testStrayFilesInTheLockedFolderStopTheUnlock() throws {
        let key = VaultRecoveryKey.generate()
        try manager.encrypt(recoveryKey: key, keepKeyOnThisMac: true)
        try manager.lock()
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manager.layout.vault.path)
        try Data("written while locked".utf8).write(to: manager.layout.vault.appendingPathComponent("stray.txt"))
        XCTAssertThrowsError(try manager.unlock()) { error in
            XCTAssertTrue((error as? VaultEncryptionError)?.errorDescription?.contains("stray.txt") ?? false, "\(error)")
        }
        XCTAssertEqual(manager.status(), .locked, "nothing was mounted over the stray file")
        XCTAssertTrue(files.fileExists(atPath: manager.layout.vault.appendingPathComponent("stray.txt").path))
    }

    func testInventoryCatchesAOneByteDifference() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try files.createDirectory(at: other, withIntermediateDirectories: true)
        try VaultEncryptionManager.copyContents(of: manager.layout.vault, into: other) { _ in }
        XCTAssertNil(try inventory(manager.layout.vault).firstDifference(from: try inventory(other)))
        var bytes = try Data(contentsOf: other.appendingPathComponent("notes/deep/blob.bin"))
        bytes[1_000] ^= 1
        try bytes.write(to: other.appendingPathComponent("notes/deep/blob.bin"))
        XCTAssertEqual(try inventory(manager.layout.vault).firstDifference(from: try inventory(other)), "notes/deep/blob.bin")
        try files.removeItem(at: other.appendingPathComponent(".obsidian-settings.json"))
        XCTAssertNotNil(try inventory(manager.layout.vault).firstDifference(from: try inventory(other)))
    }

    // MARK: Helpers

    private func writeState(phase: String, step: String) throws {
        let json = #"{"version":1,"phase":"\#(phase)","step":"\#(step)","stamp":"20261012T000000Z","startedAt":"2026-10-12T00:00:00Z"}"#
        try Data(json.utf8).write(to: manager.layout.stateFile)
    }

    private func write(_ record: VaultEncryptionState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: manager.layout.stateFile)
    }
}
