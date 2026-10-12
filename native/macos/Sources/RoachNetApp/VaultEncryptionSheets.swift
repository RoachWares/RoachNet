import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI
import UniformTypeIdentifiers

/// Turning encryption on: what it does, the recovery key, a check that the
/// key was kept, then the move itself.
@MainActor
final class VaultSetupModel: ObservableObject {
    enum Step: Equatable { case intro, key, confirm, working, done, failed(String) }

    @Published var step: Step = .intro
    @Published var sizes: (files: Int, bytes: Int64, needed: Int64, free: Int64)?
    @Published var sizeProblem: String?
    @Published var progress: VaultEncryptionManager.Progress = .checking
    @Published var keepKey = true
    @Published var keptKey = false
    @Published var typedEnding = ""
    let key = VaultRecoveryKey.generate()
    let storagePath: String

    init(storagePath: String) { self.storagePath = storagePath }

    var groupedKey: String { VaultRecoveryKey.grouped(key) }
    var keyEnding: String { String(key.suffix(4)) }
    var endingMatches: Bool { VaultRecoveryKey.normalizeFragment(typedEnding) == keyEnding }

    func checkSizes() async {
        let path = storagePath
        let result: Result<(files: Int, bytes: Int64, needed: Int64, free: Int64), Error> = await Task.detached(priority: .userInitiated) {
            Result { try VaultEncryptionManager(storagePath: path).preflight() }
        }.value
        switch result {
        case .success(let value):
            sizes = value
            if value.free < value.needed {
                sizeProblem = VaultEncryptionError.notEnoughSpace(needed: value.needed, free: value.free).errorDescription
            }
        case .failure(let error):
            sizeProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func encrypt() {
        step = .working
        let path = storagePath, key = key, keep = keepKey
        Task { @MainActor in
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try VaultEncryptionManager(storagePath: path).encrypt(recoveryKey: key, keepKeyOnThisMac: keep) { progress in
                        Task { @MainActor in self.progress = progress }
                    }
                }
            }.value
            switch outcome {
            case .success: step = .done
            case .failure(let error): step = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func saveKeyToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RoachNet Vault recovery key.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "RoachNet Vault recovery key\n\n\(groupedKey)\n\nKeep this somewhere safe and away from this Mac. Anyone with it can open the Vault; without it (and without this Mac's saved key) nobody can.\n"
        try? Data(text.utf8).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var progressText: String {
        switch progress {
        case .checking: return "Checking the Vault…"
        case .creatingImage: return "Making the encrypted disk image…"
        case .copying(let done, let total):
            return "Copying files… \(VaultEncryptionManager.describe(bytes: done)) of \(VaultEncryptionManager.describe(bytes: total))"
        case .verifying: return "Checking every copied file against the original…"
        case .swapping: return "Putting the encrypted Vault in place…"
        case .done: return "Done."
        }
    }
}

struct VaultEncryptionSetupSheet: View {
    let storagePath: String
    @StateObject private var model: VaultSetupModel
    @Environment(\.dismiss) private var dismiss

    init(storagePath: String) {
        self.storagePath = storagePath
        _model = StateObject(wrappedValue: VaultSetupModel(storagePath: storagePath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .intro: intro
            case .key: keyStep
            case .confirm: confirm
            case .working: working
            case .done: done
            case .failed(let reason): failed(reason)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await model.checkSizes() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Encrypt the Vault")
            para(VaultEncryptionCopy.protects)
            para(VaultEncryptionCopy.doesNotProtect)
            if let sizes = model.sizes {
                para("The Vault holds \(sizes.files) files (\(VaultEncryptionManager.describe(bytes: sizes.bytes))). RoachNet copies them into the encrypted image, checks every file, and keeps the original until you remove it, so this needs about \(VaultEncryptionManager.describe(bytes: sizes.needed)) free. This drive has \(VaultEncryptionManager.describe(bytes: sizes.free)).")
            } else if model.sizeProblem == nil {
                ProgressView().controlSize(.small)
            }
            if let problem = model.sizeProblem { warning(problem) }
            para("Close Vault files in other apps first, and don't add or change Vault files until it finishes. If anything in the Vault changes during the copy, RoachNet stops and changes nothing.")
            buttons(primary: "Continue", enabled: model.sizes != nil && model.sizeProblem == nil) { model.step = .key }
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Your recovery key")
            para(VaultEncryptionCopy.recovery)
            Text(model.groupedKey)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoachPalette.panelSoft, in: RoundedRectangle(cornerRadius: 8))
            RoachFlowLayout(spacing: 8) {
                Button("Save to a File…") { model.saveKeyToFile() }
                    .buttonStyle(RoachSecondaryButtonStyle())
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.groupedKey, forType: .string)
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }
            para("Write it down or save it somewhere off this Mac, such as a password manager. Clipboard tools may keep anything you copy.")
            Toggle("Also keep the key in this Mac's Keychain, so RoachNet can unlock the Vault without it", isOn: $model.keepKey)
            buttons(primary: "Continue", enabled: true) { model.step = .confirm }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Check that you kept the key")
            para("Type the last four characters of your recovery key.")
            TextField("Last four characters", text: $model.typedEnding)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Toggle("I've stored the recovery key somewhere safe. Without it, and without this Mac's saved key, nobody can open the Vault, RoachWares included.", isOn: $model.keptKey)
            buttons(primary: "Encrypt the Vault", enabled: model.keptKey && model.endingMatches) { model.encrypt() }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Encrypting the Vault")
            ProgressView(value: fraction).progressViewStyle(.linear)
            para(model.progressText)
            para("Leave RoachNet open until this finishes. If the Mac stops partway, RoachNet finishes or undoes the move the next time it opens; the original isn't deleted.")
        }
    }

    private var fraction: Double {
        switch model.progress {
        case .checking: return 0.02
        case .creatingImage: return 0.05
        case .copying(let done, let total): return 0.05 + 0.6 * (total > 0 ? min(1, Double(done) / Double(total)) : 1)
        case .verifying: return 0.7
        case .swapping: return 0.95
        case .done: return 1
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("The Vault is encrypted")
            para("It's unlocked now. Check that your files look right, then remove the unencrypted original in Settings › Vault › Encryption.")
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(RoachPrimaryButtonStyle()) }
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title("The Vault wasn't encrypted")
            warning(reason)
            para("If the copy hadn't been put in place yet, the Vault is exactly as it was. Settings › Vault › Encryption shows its state.")
            HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(RoachPrimaryButtonStyle()) }
        }
    }

    private func title(_ text: String) -> some View { Text(text).font(.roach(size: 20, weight: .bold)) }

    private func para(_ text: String) -> some View {
        Text(text).font(.roach(size: 13, weight: .medium)).foregroundStyle(RoachPalette.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.roach(size: 13, weight: .semibold)).foregroundStyle(RoachPalette.warning).fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(primary: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(RoachSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            Button(primary, action: action).buttonStyle(RoachPrimaryButtonStyle()).disabled(!enabled).keyboardShortcut(.defaultAction)
        }
    }
}

/// Unlocking with the recovery key, for a Mac without a saved key.
struct VaultUnlockSheet: View {
    let storagePath: String
    @State private var typed = ""
    @State private var save = true
    @State private var problem: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock the Vault").font(.roach(size: 20, weight: .bold))
            Text("Type or paste your recovery key. Dashes and spaces don't matter.")
                .font(.roach(size: 13, weight: .medium)).foregroundStyle(RoachPalette.muted)
            TextField("XXXX-XXXX-…", text: $typed, axis: .vertical)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
            Toggle("Save the key in this Mac's Keychain", isOn: $save)
            if let problem {
                Text(problem).font(.roach(size: 13, weight: .semibold)).foregroundStyle(RoachPalette.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(RoachSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Unlock") { unlock() }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || VaultRecoveryKey.normalize(typed) == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func unlock() {
        busy = true
        problem = nil
        let path = storagePath, key = typed, keep = save
        Task { @MainActor in
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try VaultEncryptionManager(storagePath: path).unlock(key: key, keepKeyOnThisMac: keep) }
            }.value
            busy = false
            switch outcome {
            case .success: dismiss()
            case .failure(let error): problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
