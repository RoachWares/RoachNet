import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

struct FeaturePack: Decodable, Identifiable, Equatable {
    struct Dependency: Decodable, Equatable {
        let id: String
        let minimumVersion: String?
    }

    struct DataRoot: Decodable, Equatable {
        let path: String
        let description: String?
        let exists: Bool?
        let bytes: Int?
    }

    struct Compatibility: Decodable, Equatable {
        let ok: Bool
        let reason: String?
    }

    let id: String
    let version: String
    let kind: String
    let name: String
    let summary: String?
    let publisher: String?
    let bundled: Bool
    let installed: Bool
    let available: Bool?
    let handler: String?
    let enabled: Bool
    let installedVersion: String?
    let downloadBytes: Int?
    let installedBytes: Int?
    let dependencies: [Dependency]
    let dependents: [String]
    let capabilities: [String]
    let dataRoots: [DataRoot]
    let compatibility: Compatibility?
    let unresolvedDependencies: [String]?

    var isCapability: Bool { kind == "capability" }
    var isAvailable: Bool { !installed && (available ?? true) }
    var dataBytes: Int { dataRoots.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var hasSizes: Bool { dataRoots.contains { $0.bytes != nil } || installedBytes != nil }
}

struct FeaturePackJob: Decodable, Identifiable, Equatable {
    let jobId: String
    let packID: String
    let version: String
    let status: String
    let totalBytes: Int
    let receivedBytes: Int
    let progress: Int
    let error: String?

    var id: String { jobId }
    var isActive: Bool { status == "queued" || status == "downloading" || status == "verifying" }
}

struct FeaturePackCatalog: Decodable {
    let schema: String
    let appVersion: String?
    let platform: String?
    let packs: [FeaturePack]
    let jobs: [FeaturePackJob]
}

extension WorkspacePane {
    var packID: String? {
        switch self {
        case .dev: return "dev"
        case .roachClaw: return "roachclaw"
        case .org: return "org"
        case .arcade: return "arcade"
        case .maps: return "maps"
        case .education: return "education"
        case .knowledge: return "vault"
        case .suite, .home, .runtime: return nil
        }
    }
}

@MainActor
final class FeaturePackStore: ObservableObject {
    private static let rememberedDisabledKey = "roachnet.packs.disabled"

    @Published private(set) var packs: [FeaturePack] = []
    @Published private(set) var jobs: [FeaturePackJob] = []
    @Published private(set) var loaded = false
    @Published private(set) var unsupported = false
    @Published private(set) var sizesLoaded = false
    @Published var isBusy = false
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var pendingInstalls: Set<String> = []

    private var rememberedDisabled: Set<String>
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rememberedDisabled = Set(defaults.stringArray(forKey: Self.rememberedDisabledKey) ?? [])
    }

    func pack(_ id: String) -> FeaturePack? {
        packs.first { $0.id == id }
    }

    func isMounted(_ pane: WorkspacePane) -> Bool {
        guard let packID = pane.packID else { return true }
        if loaded && !unsupported {
            return pack(packID)?.enabled ?? true
        }
        return !rememberedDisabled.contains(packID)
    }

    var enabledCount: Int { packs.filter(\.enabled).count }
    var capabilityPacks: [FeaturePack] { packs.filter(\.isCapability) }
    var resourcePacks: [FeaturePack] { packs.filter { !$0.isCapability && !$0.isAvailable } }
    var availablePacks: [FeaturePack] { packs.filter { !$0.isCapability && $0.isAvailable } }
    var activeJobs: [FeaturePackJob] { jobs.filter(\.isActive) }

    func dependentsBlockingDisable(of pack: FeaturePack) -> [String] {
        pack.dependents.filter { self.pack($0)?.enabled == true }
    }

    func refresh(using config: RoachNetInstallerConfig, includeSizes: Bool = false) async {
        do {
            let path = includeSizes ? "/api/packs?sizes=1" : "/api/packs"
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: path)
            try load(catalogJSON: data, includedSizes: includeSizes)
        } catch {
            if (error as NSError).code == 404, !loaded {
                unsupported = true
                loaded = true
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func load(catalogJSON data: Data, includedSizes: Bool = false) throws {
        let catalog = try decoder.decode(FeaturePackCatalog.self, from: data)
        guard catalog.schema == "org.roachnet.packs.v1" else {
            throw NSError(
                domain: "RoachNetPacks", code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RoachNet can't read this pack catalog (schema \(catalog.schema)). Nothing on this Mac changed. Check for a RoachNet update."
                ])
        }
        apply(catalog, includedSizes: includedSizes)
    }

    private func apply(_ catalog: FeaturePackCatalog, includedSizes: Bool) {
        if includedSizes || !sizesLoaded {
            packs = catalog.packs
        } else {
            packs = catalog.packs.map { fresh in
                guard let known = pack(fresh.id), known.version == fresh.version, fresh.hasSizes == false else {
                    return fresh
                }
                return FeaturePack(
                    id: fresh.id, version: fresh.version, kind: fresh.kind, name: fresh.name, summary: fresh.summary,
                    publisher: fresh.publisher, bundled: fresh.bundled, installed: fresh.installed,
                    available: fresh.available, handler: fresh.handler, enabled: fresh.enabled,
                    installedVersion: fresh.installedVersion, downloadBytes: fresh.downloadBytes,
                    installedBytes: known.installedBytes,
                    dependencies: fresh.dependencies, dependents: fresh.dependents, capabilities: fresh.capabilities,
                    dataRoots: zip(fresh.dataRoots, known.dataRoots).map { fresh, known in
                        FeaturePack.DataRoot(
                            path: fresh.path, description: fresh.description, exists: fresh.exists,
                            bytes: fresh.path == known.path ? known.bytes : nil)
                    },
                    compatibility: fresh.compatibility, unresolvedDependencies: fresh.unresolvedDependencies
                )
            }
        }
        if includedSizes { sizesLoaded = true }
        jobs = catalog.jobs
        pendingInstalls = pendingInstalls.filter { id in pack(id)?.installed == false }
        unsupported = false
        loaded = true
        errorMessage = nil
        remember()
    }

    private func remember() {
        rememberedDisabled = Set(packs.filter { $0.isCapability && !$0.enabled }.map(\.id))
        defaults.set(Array(rememberedDisabled).sorted(), forKey: Self.rememberedDisabledKey)
    }

    func setEnabled(_ id: String, _ enabled: Bool, using config: RoachNetInstallerConfig) async {
        await perform(using: config, success: "\(pack(id)?.name ?? id) \(enabled ? "switched on" : "switched off").") {
            _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/packs/\(id)/\(enabled ? "enable" : "disable")", method: "POST",
                jsonBody: Data("{}".utf8)
            )
        }
    }

    func uninstall(_ id: String, retainData: Bool, using config: RoachNetInstallerConfig) async {
        let name = pack(id)?.name ?? id
        await perform(
            using: config,
            success: retainData
                ? "\(name) removed. Your data stayed where it was."
                : "\(name) removed. Its data moved to the Retired folder."
        ) {
            let body = try JSONSerialization.data(withJSONObject: ["retainData": retainData])
            _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/packs/\(id)/uninstall", method: "POST", jsonBody: body)
        }
    }

    func install(_ id: String, using config: RoachNetInstallerConfig) async {
        pendingInstalls.insert(id)
        await perform(
            using: config,
            success: "\(pack(id)?.name ?? id) is downloading. It appears under Resource packs when it lands."
        ) {
            let body = try JSONSerialization.data(withJSONObject: ["id": id])
            _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/packs/install", method: "POST", jsonBody: body)
        }
        if errorMessage != nil { pendingInstalls.remove(id) }
    }

    func installLocalPackage(at folder: URL, using config: RoachNetInstallerConfig) async {
        await perform(using: config, success: "Pack installed from \(folder.lastPathComponent).") {
            let body = try JSONSerialization.data(withJSONObject: ["packagePath": folder.path])
            _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/packs/install", method: "POST", jsonBody: body)
        }
    }

    private func perform(using config: RoachNetInstallerConfig, success: String, _ work: () async throws -> Void) async
    {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await work()
            message = success
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh(using: config, includeSizes: sizesLoaded)
    }
}

enum RoachSettingsWindow {
    @MainActor
    static func open(_ pane: RoachNetSettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: RoachNetSettingsPane.requestedPaneUserDefaultsKey)
        NSApp.activate(ignoringOtherApps: true)
        if let item = menuItem(titledLike: "Settings", in: NSApp.mainMenu), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static func menuItem(titledLike prefix: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title.hasPrefix(prefix), item.action != nil { return item }
            if let found = menuItem(titledLike: prefix, in: item.submenu) { return found }
        }
        return nil
    }
}

struct FeaturePacksSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: FeaturePackStore
    @State private var pendingRemoval: FeaturePack?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.unsupported {
                RoachNotice(
                    title: "Packs need a newer runtime",
                    detail:
                        "Every feature stays on. Update roachnet-runtime to 1.1 or later to switch features on and off.",
                    accent: RoachPalette.bronze
                )
            }

            if let error = store.errorMessage {
                RoachNotice(title: "Packs", detail: error, accent: RoachPalette.warning)
            } else if let message = store.message {
                RoachNotice(
                    title: "Packs", detail: message, accent: RoachPalette.green, systemName: "checkmark.circle.fill")
            }

            RoachInsetPanel {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(
                        label: "Features",
                        value: "\(store.capabilityPacks.filter(\.enabled).count)/\(store.capabilityPacks.count)",
                        detail: "Switched on")
                    RoachMetricCard(label: "Resource packs", value: "\(store.resourcePacks.count)", detail: "Installed")
                    RoachMetricCard(
                        label: "On disk",
                        value: store.sizesLoaded
                            ? Self.bytes(store.packs.reduce(0) { $0 + ($1.installedBytes ?? 0) }) : "…",
                        detail: "Pack files")
                    RoachMetricCard(
                        label: "Your data",
                        value: store.sizesLoaded ? Self.bytes(store.packs.reduce(0) { $0 + $1.dataBytes }) : "…",
                        detail: "Kept on removal")
                }
            }

            if !store.activeJobs.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        RoachKicker("Installing")
                        ForEach(store.activeJobs) { job in
                            HStack(spacing: 10) {
                                Text(store.pack(job.packID)?.name ?? job.packID)
                                    .font(.roach(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                Spacer(minLength: 0)
                                Text("\(job.status) · \(job.progress)%")
                                    .font(.roach(size: 12, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                            }
                            ProgressView(value: Double(job.progress), total: 100)
                                .tint(RoachPalette.green)
                        }
                    }
                }
            }

            section(
                "Features",
                detail:
                    "Built into RoachNet. Switching one off hides its panes and stops its runtime services. It never touches your data."
            ) {
                ForEach(store.capabilityPacks) { pack in
                    packRow(pack)
                }
            }

            if !store.availablePacks.isEmpty {
                section(
                    "Available",
                    detail:
                        "Published by RoachWares. Nothing is fetched until you ask; every download is checked against its published checksum before it is unpacked."
                ) {
                    ForEach(store.availablePacks) { pack in
                        packRow(pack)
                    }
                }
            }

            section(
                "Resource packs",
                detail:
                    "Models, voices, maps and knowledge bundles. Verified by checksum before anything moves; removal keeps your data unless you say otherwise."
            ) {
                if store.resourcePacks.isEmpty {
                    Text(
                        "No resource packs yet. Add one from RoachNet Apps when you need it; removing it later keeps your data."
                    )
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.resourcePacks) { pack in
                    packRow(pack)
                }
                HStack(spacing: 10) {
                    Button("Install from folder…") { openPackage() }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(store.isBusy || store.unsupported)
                        .accessibilityIdentifier("packs.openPackage")
                    Text("A folder with manifest.json and its files. Nothing is downloaded.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
        .task {
            await store.refresh(using: model.config, includeSizes: true)
        }
        .task(id: store.pendingInstalls.isEmpty) {
            guard !store.pendingInstalls.isEmpty else { return }
            while !Task.isCancelled && !store.pendingInstalls.isEmpty {
                try? await Task.sleep(for: .seconds(4))
                await store.refresh(using: model.config, includeSizes: store.sizesLoaded)
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "pack")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { pack in
            Button("Remove, keep my data\(pack.dataBytes > 0 ? " (\(Self.bytes(pack.dataBytes)))" : "")") {
                Task { await store.uninstall(pack.id, retainData: true, using: model.config) }
            }
            Button("Remove and move my data to Retired", role: .destructive) {
                Task { await store.uninstall(pack.id, retainData: false, using: model.config) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pack in
            Text(
                pack.dataRoots.isEmpty
                    ? "The pack files are deleted. Nothing else changes."
                    : "The pack files are deleted. Your data in \(pack.dataRoots.map(\.path).joined(separator: ", ")) is kept unless you move it to Retired, where it stays until you empty that folder."
            )
        }
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachKicker(title)
                Text(detail)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func packRow(_ pack: FeaturePack) -> some View {
        let blockers = store.dependentsBlockingDisable(of: pack)
        let compatible = pack.compatibility?.ok ?? true

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(pack.name)
                            .font(.roach(size: 13, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(pack.installedVersion ?? pack.version)
                            .font(.roach(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                        if !pack.isCapability {
                            RoachTag(pack.kind, accent: RoachPalette.cyan)
                        }
                    }
                    if let summary = pack.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if pack.isAvailable {
                    if store.pendingInstalls.contains(pack.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Downloading")
                                .font(.roach(size: 12, weight: .semibold))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    } else {
                        Button("Install\(pack.downloadBytes.map { " (\(Self.bytes($0)))" } ?? "")") {
                            Task { await store.install(pack.id, using: model.config) }
                        }
                        .buttonStyle(RoachUtilityButtonStyle())
                        .disabled(store.isBusy || store.unsupported || !compatible)
                        .accessibilityIdentifier("packs.install.\(pack.id)")
                    }
                } else if pack.isCapability {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { pack.enabled },
                            set: { on in Task { await store.setEnabled(pack.id, on, using: model.config) } }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(RoachPalette.green)
                    .disabled(store.isBusy || store.unsupported || !compatible || (pack.enabled && !blockers.isEmpty))
                    .accessibilityLabel("\(pack.name) enabled")
                    .accessibilityIdentifier("packs.toggle.\(pack.id)")
                } else {
                    Button("Remove") { pendingRemoval = pack }
                        .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.warning))
                        .disabled(store.isBusy || !blockers.isEmpty)
                        .accessibilityIdentifier("packs.remove.\(pack.id)")
                }
            }

            if !pack.capabilities.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pack.capabilities, id: \.self) { capability in
                        RoachTag(Self.capabilityLabel(capability), accent: Self.capabilityAccent(capability))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if !pack.dependencies.isEmpty {
                    detailLine(
                        "Needs", pack.dependencies.map { store.pack($0.id)?.name ?? $0.id }.joined(separator: ", "))
                }
                if !blockers.isEmpty {
                    detailLine(
                        pack.isCapability ? "In use by" : "In use by",
                        blockers.map { store.pack($0)?.name ?? $0 }.joined(separator: ", "),
                        accent: RoachPalette.warning)
                }
                if let reason = pack.compatibility?.reason, !compatible {
                    detailLine("Unavailable", reason, accent: RoachPalette.warning)
                }
                ForEach(pack.dataRoots, id: \.path) { root in
                    detailLine(
                        root.description ?? "Data",
                        root.bytes.map { "\(root.path) · \(Self.bytes($0))" } ?? root.path
                    )
                }
                if let installedBytes = pack.installedBytes, !pack.isCapability {
                    detailLine("Pack files", Self.bytes(installedBytes))
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packs.row.\(pack.id)")
    }

    private func detailLine(_ title: String, _ value: String, accent: Color = RoachPalette.muted) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title + ":")
                .font(.roach(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(value)
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Install pack"
        panel.message = "Choose a pack folder that contains manifest.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.installLocalPackage(at: url, using: model.config) }
    }

    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(count))
    }

    static func capabilityLabel(_ raw: String) -> String {
        switch raw {
        case "network.public": return "Internet"
        case "network.local": return "Local network"
        case "filesystem.storage": return "RoachNet storage"
        case "filesystem.user": return "Your files"
        case "process.spawn": return "Runs programs"
        case "inference": return "Local AI"
        case "microphone": return "Microphone"
        case "speaker": return "Speaker"
        case "bluetooth": return "Bluetooth"
        case "location": return "Location"
        case "companion.bridge": return "Phone bridge"
        default: return raw
        }
    }

    static func capabilityAccent(_ raw: String) -> Color {
        switch raw {
        case "network.public": return RoachPalette.warning
        case "filesystem.user", "process.spawn": return RoachPalette.bronze
        case "microphone", "location", "bluetooth": return RoachPalette.magenta
        default: return RoachPalette.cyan
        }
    }
}
