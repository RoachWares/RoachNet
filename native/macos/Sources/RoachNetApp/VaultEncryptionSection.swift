import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

/// Unlocks the Vault when RoachNet opens and locks it when RoachNet quits,
/// if the person left those on. A move that was cut off is finished or
/// undone first (see VaultEncryptionManager.resumeInterrupted).
@MainActor
enum VaultEncryptionSession {
    static let unlockAtLaunchKey = "vaultEncryption.unlockAtLaunch"
    static let lockAtQuitKey = "vaultEncryption.lockAtQuit"
    private static var storagePath: String?
    private static var triedLaunchUnlock = false
    private(set) static var lastResumeNote: String?

    static func appDidLoad(storagePath: String) async {
        Self.storagePath = storagePath
        guard !triedLaunchUnlock else { return }
        triedLaunchUnlock = true
        let unlock = UserDefaults.standard.object(forKey: unlockAtLaunchKey) as? Bool ?? true
        let note = await Task.detached(priority: .userInitiated) { () -> String? in
            let manager = VaultEncryptionManager(storagePath: storagePath)
            var note: String?
            if manager.status() == .interrupted { note = try? manager.resumeInterrupted() }
            if unlock, manager.status() == .locked, manager.hasSavedKey { try? manager.unlock() }
            return note
        }.value
        lastResumeNote = note
    }

    static func appWillQuit() {
        guard let storagePath, UserDefaults.standard.object(forKey: lockAtQuitKey) as? Bool ?? true else { return }
        let manager = VaultEncryptionManager(storagePath: storagePath)
        if manager.status() == .unlocked { try? manager.lock(force: false) }
    }
}

/// Settings › Vault › Encryption. Off unless the person turns it on here.
struct VaultEncryptionSection: View {
    let storagePath: String

    @State private var status: VaultEncryptionManager.Status = .off
    @State private var hasSavedKey = false
    @State private var unencryptedCopy: URL?
    @State private var retiredImage: URL?
    @State private var message: String?
    @State private var busy = false
    @State private var showingSetup = false
    @State private var showingUnlock = false
    @State private var confirmingOff = false
    @State private var confirmingRemoveCopy = false
    @State private var confirmingRemoveImage = false
    @AppStorage(VaultEncryptionSession.unlockAtLaunchKey) private var unlockAtLaunch = true
    @AppStorage(VaultEncryptionSession.lockAtQuitKey) private var lockAtQuit = true

    private var manager: VaultEncryptionManager { VaultEncryptionManager(storagePath: storagePath) }

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("VAULT ENCRYPTION")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
                HStack(spacing: 8) {
                    Image(systemName: statusIcon).foregroundStyle(statusColor)
                    Text(statusTitle).font(.roach(size: 14, weight: .semibold))
                }
                Text(statusDetail)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                actions

                if status == .unlocked || status == .locked {
                    Toggle("Unlock with this Mac's saved key when RoachNet opens", isOn: $unlockAtLaunch)
                        .disabled(!hasSavedKey)
                    Toggle("Lock when RoachNet quits", isOn: $lockAtQuit)
                    if !hasSavedKey {
                        Text("No key is saved on this Mac, so the Vault opens only with the recovery key.")
                            .font(.roach(size: 11, weight: .medium)).foregroundStyle(RoachPalette.muted)
                    }
                }

                if let unencryptedCopy {
                    leftover(
                        title: "The unencrypted original is still on this Mac.",
                        detail: "RoachNet kept it in case anything went wrong. Check your files in the Vault, then remove it; until then, anyone who can read your storage folder can read it.",
                        reveal: unencryptedCopy,
                        removeLabel: "Remove the Unencrypted Original…"
                    ) { confirmingRemoveCopy = true }
                }
                if let retiredImage {
                    leftover(
                        title: "The old encrypted copy is still on this Mac.",
                        detail: "It holds the Vault as it was when encryption was turned off, and opens only with the recovery key.",
                        reveal: retiredImage,
                        removeLabel: "Remove the Encrypted Copy…"
                    ) { confirmingRemoveImage = true }
                }

                DisclosureGroup("What encryption protects, and what it doesn't") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(VaultEncryptionCopy.protects)
                        Text(VaultEncryptionCopy.doesNotProtect)
                        Text(VaultEncryptionCopy.recovery)
                    }
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                }
                .font(.roach(size: 12, weight: .semibold))

                if let message {
                    Text(message)
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { refresh() }
        .sheet(isPresented: $showingSetup, onDismiss: refresh) {
            VaultEncryptionSetupSheet(storagePath: storagePath)
        }
        .sheet(isPresented: $showingUnlock, onDismiss: refresh) {
            VaultUnlockSheet(storagePath: storagePath)
        }
        .confirmationDialog("Turn off Vault encryption?", isPresented: $confirmingOff) {
            Button("Turn Off Encryption", role: .destructive) { run { try $0.decrypt(); return nil } }
        } message: {
            Text("RoachNet copies the Vault's files back into a plain folder, checks every file, and keeps the encrypted copy until you remove it. Afterwards anyone who can read your storage folder can read the Vault.")
        }
        .confirmationDialog("Remove the unencrypted original?", isPresented: $confirmingRemoveCopy) {
            Button("Remove It", role: .destructive) { run { try $0.removeUnencryptedCopy(); return nil } }
        } message: {
            Text("This deletes the plain copy RoachNet kept when it encrypted the Vault. On an SSD, deleted data can stay readable until the drive reuses the space; FileVault protects against that.")
        }
        .confirmationDialog("Remove the old encrypted copy?", isPresented: $confirmingRemoveImage) {
            Button("Remove It", role: .destructive) { run { try $0.removeRetiredImage(); return nil } }
        } message: {
            Text("This deletes the encrypted image from before encryption was turned off, and this Mac's saved key with it. The Vault folder itself isn't touched.")
        }
    }

    @ViewBuilder private var actions: some View {
        RoachFlowLayout(spacing: 8) {
            switch status {
            case .off:
                Button("Turn On Encryption…") { showingSetup = true }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(busy || retiredImage != nil)
            case .unlocked:
                Button("Lock Now") { run { try $0.lock(); return nil } }
                    .buttonStyle(RoachPrimaryButtonStyle())
                Button("Turn Off Encryption…") { confirmingOff = true }
                    .buttonStyle(RoachSecondaryButtonStyle())
                if hasSavedKey {
                    Button("Forget the Key on This Mac") { run { $0.forgetSavedKey(); return nil } }
                        .buttonStyle(RoachSecondaryButtonStyle())
                }
            case .locked:
                if hasSavedKey {
                    Button("Unlock") { run { try $0.unlock(); return nil } }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    Button("Unlock with Recovery Key…") { showingUnlock = true }
                        .buttonStyle(RoachSecondaryButtonStyle())
                } else {
                    Button("Unlock…") { showingUnlock = true }
                        .buttonStyle(RoachPrimaryButtonStyle())
                }
            case .interrupted:
                Button("Finish or Undo the Move") { run { try $0.resumeInterrupted() } }
                    .buttonStyle(RoachPrimaryButtonStyle())
            }
        }
        .disabled(busy)
    }

    private func leftover(title: String, detail: String, reveal: URL, removeLabel: String, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.roach(size: 12, weight: .semibold)).foregroundStyle(RoachPalette.warning)
            Text(detail).font(.roach(size: 12, weight: .medium)).foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            RoachFlowLayout(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                    .buttonStyle(RoachSecondaryButtonStyle())
                Button(removeLabel, action: remove)
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(busy)
            }
        }
    }

    private var statusTitle: String {
        switch status {
        case .off: return "Off"
        case .unlocked: return "On · unlocked"
        case .locked: return "On · locked"
        case .interrupted: return "A Vault move was cut off"
        }
    }

    private var statusDetail: String {
        switch status {
        case .off:
            return "The Vault is a plain folder in your storage folder. Turning encryption on keeps its files in an encrypted disk image that only your recovery key, or this Mac's saved copy of it, can open."
        case .unlocked:
            return "The Vault's files are encrypted on disk. While it's unlocked, RoachNet and other apps you run can read them, as with any folder."
        case .locked:
            return "Nothing in the Vault can be read until it's unlocked. Features that use the Vault, like RoachBrain memory and Shelf files, wait until then."
        case .interrupted:
            return VaultEncryptionSession.lastResumeNote
                ?? "RoachNet stopped in the middle of moving the Vault. Finishing or undoing it is safe: the original is never deleted before the copy is checked."
        }
    }

    private var statusIcon: String {
        switch status {
        case .off: return "lock.open"
        case .unlocked: return "lock.open.fill"
        case .locked: return "lock.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .off: return RoachPalette.muted
        case .unlocked, .locked: return RoachPalette.success
        case .interrupted: return RoachPalette.warning
        }
    }

    private func refresh() {
        let manager = manager
        status = manager.status()
        hasSavedKey = manager.hasSavedKey
        unencryptedCopy = manager.unencryptedCopy
        retiredImage = manager.retiredImage
    }

    /// Runs a Vault step off the main thread (hdiutil and file copies take a while); a returned note is shown.
    private func run(_ work: @escaping @Sendable (VaultEncryptionManager) throws -> String?) {
        busy = true
        message = nil
        let path = storagePath
        Task { @MainActor in
            let outcome: Result<String?, Error> = await Task.detached(priority: .userInitiated) {
                Result { try work(VaultEncryptionManager(storagePath: path)) }
            }.value
            busy = false
            switch outcome {
            case .success(let note): message = note
            case .failure(let error): message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            refresh()
        }
    }
}

/// The words Settings and the setup sheet share.
enum VaultEncryptionCopy {
    static let protects = "Protects: everything in the Vault folder (Shelf files, RoachBrain memory and wiki, Dev Studio projects kept in the Vault, the list of saved secrets, and the list of linked Obsidian vaults) while the Vault is locked or the Mac is off, and in any copy of the storage folder, such as a backup or a copied drive. Someone with those files sees one encrypted disk image."
    static let doesNotProtect = "Doesn't protect: the Vault while it's unlocked (apps running as you can read it, as with any folder); Obsidian vaults kept elsewhere; Roach's Archive, chat history, models, settings and logs, which live outside the Vault; copies you export or open in other apps; and the unencrypted original until you remove it. Secret values are already in the Keychain."
    static let recovery = "The recovery key is the only way in if this Mac's saved key is gone, for example on a new Mac or after a Keychain reset. RoachWares never sees it and can't recover it. Lose both and the Vault can't be opened by anyone."
}
