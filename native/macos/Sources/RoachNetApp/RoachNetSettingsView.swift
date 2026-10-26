import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

enum RoachNetSettingsPane: String, CaseIterable, Identifiable {
    static let requestedPaneUserDefaultsKey = "roachnet.settings.requested-pane"

    case general
    case appearance
    case packs
    case roachClaw
    case vault
    case arcade
    case atlas
    case models
    case apps
    case updates
    case benchmark
    case support
    case legal
    case runtime

    var id: String { rawValue }

    static let railSections: [(title: String, panes: [RoachNetSettingsPane])] = [
        ("RoachNet", [.general, .appearance, .updates]),
        ("Modules", [.packs, .roachClaw, .models, .vault, .arcade, .atlas, .apps]),
        ("System", [.runtime, .benchmark, .support, .legal]),
    ]

    var title: String {
        switch self {
        case .general:
            return "General"
        case .appearance:
            return "Appearance"
        case .packs:
            return "Packs"
        case .roachClaw:
            return "RoachClaw"
        case .vault:
            return "Vault"
        case .arcade:
            return "Arcade"
        case .atlas:
            return "Atlas"
        case .models:
            return "Models"
        case .apps:
            return "Apps"
        case .updates:
            return "Updates"
        case .benchmark:
            return "Benchmarks"
        case .support:
            return "Support"
        case .legal:
            return "Legal"
        case .runtime:
            return "Runtime"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Storage, startup, channel"
        case .appearance:
            return "Themes, type, motion"
        case .packs:
            return "Install only what you need"
        case .roachClaw:
            return "Model, context, fallback"
        case .vault:
            return "Books, notes, metadata"
        case .arcade:
            return "Cores, pads, runners"
        case .atlas:
            return "Offline maps, GPS"
        case .models:
            return "Browse and download"
        case .apps:
            return "Modules to install"
        case .updates:
            return "New versions"
        case .benchmark:
            return "Speed on this Mac"
        case .support:
            return "Logs, paths, GitHub"
        case .legal:
            return "Notices"
        case .runtime:
            return "Gateway and companion"
        }
    }

    var systemName: String {
        switch self {
        case .general:
            return "slider.horizontal.3"
        case .appearance:
            return "paintpalette.fill"
        case .packs:
            return "puzzlepiece.extension.fill"
        case .roachClaw:
            return "sparkles"
        case .vault:
            return "books.vertical.fill"
        case .arcade:
            return "gamecontroller.fill"
        case .atlas:
            return "map.fill"
        case .models:
            return "shippingbox.fill"
        case .apps:
            return "square.grid.2x2.fill"
        case .updates:
            return "arrow.down.circle.fill"
        case .benchmark:
            return "chart.bar.xaxis"
        case .support:
            return "lifepreserver.fill"
        case .legal:
            return "doc.text.magnifyingglass"
        case .runtime:
            return "server.rack"
        }
    }

    var accent: Color {
        switch self {
        case .general, .packs:
            return RoachPalette.green
        case .appearance:
            return RoachPalette.magenta
        case .roachClaw:
            return RoachPalette.magenta
        case .vault:
            return RoachPalette.cyan
        case .arcade:
            return RoachPalette.magenta
        case .atlas, .support:
            return RoachPalette.cyan
        case .models, .updates:
            return RoachPalette.green
        case .apps, .legal:
            return RoachPalette.magenta
        case .benchmark, .runtime:
            return RoachPalette.bronze
        }
    }
}

struct RoachNetSettingsView: View {
    @ObservedObject var model: WorkspaceModel

    @State private var selectedPane: RoachNetSettingsPane = .general
    @AppStorage(RoachNetSettingsPane.requestedPaneUserDefaultsKey) private var requestedPaneID = RoachNetSettingsPane
        .general.rawValue

    private let settingsColumns = [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)]

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 780

            ZStack {
                RoachBackground()
                    .overlay(RoachPalette.backdropDim(0.48))
                    .ignoresSafeArea()

                if isCompact {
                    VStack(spacing: 12) {
                        compactPanePicker
                        selectedSettingsContent
                    }
                    .padding(14)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        settingsRail
                            .frame(width: 248)
                            .frame(maxHeight: .infinity, alignment: .top)

                        selectedSettingsContent
                    }
                    .padding(14)
                }
            }
        }
        .roachThemed()
    }

    private var settingsRail: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.roach(size: 21, weight: .heavy, design: .rounded))
                        .tracking(-0.4)
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    RoachKicker("On this Mac", led: true)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(RoachNetSettingsPane.railSections.enumerated()), id: \.offset) {
                                index, section in
                                RoachKicker(section.title)
                                    .padding(.horizontal, 6)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 4)
                                ForEach(section.panes) { pane in
                                    settingsRailButton(pane)
                                        .id(pane.id)
                                }
                            }
                        }
                        .padding(.leading, 6)
                        .padding(.bottom, 4)
                    }
                    .onAppear { proxy.scrollTo(selectedPane.id, anchor: .center) }
                    .onChange(of: selectedPane) { _, pane in
                        withAnimation(RoachMotion.animation(.short)) {
                            proxy.scrollTo(pane.id, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                settingsRailFoot
            }
        }
    }

    private var settingsRailFoot: some View {
        let live = model.snapshot != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoachLED(live ? RoachPalette.signal : RoachPalette.warning, size: 6, pulses: !live)
                Text(live ? "Engine live" : "Engine starting")
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                RoachLED(model.setupCompleted ? RoachPalette.signal : RoachPalette.warning, size: 6, pulses: false)
                Text(model.setupCompleted ? "Setup complete" : "Setup not finished")
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                Spacer(minLength: 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roachSurface(.sunken, radius: 12)
        .accessibilityElement(children: .combine)
    }

    private var compactPanePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoachNetSettingsPane.allCases) { pane in
                    Button {
                        selectPane(pane)
                    } label: {
                        Label(pane.title, systemImage: pane.systemName)
                            .font(.roach(size: 12, weight: .semibold))
                            .foregroundStyle(selectedPane == pane ? RoachPalette.text : RoachPalette.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        selectedPane == pane
                                            ? pane.accent.opacity(0.18) : RoachPalette.panelRaised.opacity(0.68))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(
                                        selectedPane == pane ? pane.accent.opacity(0.32) : RoachPalette.border,
                                        lineWidth: RoachMetrics.line(1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var selectedSettingsContent: some View {
        VStack(spacing: 10) {
            settingsScroll {
                settingsHeader(selectedPane)

                switch selectedPane {
                case .general:
                    general
                case .appearance:
                    AppearanceSettingsView(store: RoachThemeStore.shared)
                case .packs:
                    FeaturePacksSettingsView(model: model, store: model.featurePacks)
                case .roachClaw:
                    ai
                case .vault:
                    vault
                case .arcade:
                    arcade
                case .atlas:
                    atlas
                case .models:
                    models
                case .apps:
                    apps
                case .updates:
                    updates
                case .benchmark:
                    benchmark
                case .support:
                    support
                case .legal:
                    legal
                case .runtime:
                    network
                }
            }

            saveBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: selectedPane)
        .onAppear {
            applyRequestedPane()
        }
        .onChange(of: requestedPaneID) { _, _ in
            applyRequestedPane()
        }
    }

    private func settingsRailButton(_ pane: RoachNetSettingsPane) -> some View {
        let isSelected = selectedPane == pane

        return Button {
            selectPane(pane)
        } label: {
            RoachSidebarTile(
                title: pane.title,
                subtitle: pane.subtitle,
                systemName: pane.systemName,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pane.title), \(pane.subtitle)")
        .accessibilityIdentifier("settings.\(pane.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectPane(_ pane: RoachNetSettingsPane) {
        requestedPaneID = pane.rawValue
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            selectedPane = pane
        }
    }

    private func applyRequestedPane() {
        guard let requestedPane = RoachNetSettingsPane(rawValue: requestedPaneID) else { return }
        guard selectedPane != requestedPane else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            selectedPane = requestedPane
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Storage")
                    RoachInlineField(
                        title: "Content folder", value: $model.config.storagePath, placeholder: "~/RoachNet/storage")
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.promptForStorageRelocation() }
                        } label: {
                            Label("Choose folder…", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button {
                            model.openStorageInFinder()
                        } label: {
                            Label("Reveal", systemImage: "arrow.up.forward.app")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Startup and setup")
                    settingsToggle(
                        "Open after setup",
                        detail: "Open RoachNet when setup finishes.",
                        isOn: $model.config.autoLaunch
                    )
                    settingsToggle(
                        "Install RoachClaw",
                        detail: "Include RoachClaw and its default model when setup runs.",
                        isOn: $model.config.installRoachClaw
                    )
                    settingsToggle(
                        "Intro on next launch",
                        detail: "Show the short tour the next time RoachNet opens.",
                        isOn: $model.config.pendingLaunchIntro
                    )
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Release")
                    Picker("Channel", selection: $model.config.releaseChannel) {
                        Text("Stable").tag("stable")
                        Text("Beta").tag("beta")
                        Text("Nightly").tag("nightly")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Runner", value: "RoachInference", detail: "Native Metal engine")
                    RoachMetricCard(
                        label: "Default", value: model.displayedRoachClawDefaultModel, detail: "Chat and assist")
                    RoachMetricCard(
                        label: "Fallback", value: model.hasCloudChatFallback ? "Available" : "Off",
                        detail: "Cloud, opt-in")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Local model")
                    RoachInlineField(
                        title: "Default model", value: $model.config.roachClawDefaultModel,
                        placeholder: "qwen2.5-coder:1.5b")
                    if !model.recommendedLocalModels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.recommendedLocalModels.prefix(4), id: \.self) { modelName in
                                    Button(modelName) {
                                        model.config.roachClawDefaultModel = modelName
                                    }
                                    .buttonStyle(RoachSecondaryButtonStyle())
                                }
                            }
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Context")
                    Stepper(
                        value: Binding(
                            get: { model.roachClawContextCharacterBudget },
                            set: { model.setRoachClawContextBudget($0) }
                        ),
                        in: 3_000...40_000,
                        step: 1_000
                    ) {
                        HStack {
                            Text("Budget")
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                            Text("\(model.roachClawContextCharacterBudget) chars")
                                .font(.roach(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                        }
                    }

                    LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                        ForEach(RoachClawContextScope.allCases) { scope in
                            Toggle(
                                isOn: Binding(
                                    get: { model.isRoachClawContextEnabled(scope) },
                                    set: { model.setRoachClawContext(scope, enabled: $0) }
                                )
                            ) {
                                Label(scope.title, systemImage: scope.systemImage)
                                    .font(.roach(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                            }
                            .toggleStyle(.switch)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.54))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Allow all") {
                            model.setAllRoachClawContext(enabled: true)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Lock all") {
                            model.setAllRoachClawContext(enabled: false)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            }

            RoachAPITokensSection(config: model.config)
            RoachSubscriptionsSection(config: model.config)
            RoachTraceSettingsSection(config: model.config)
        }
    }

    private var arcade: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    let stats = model.roachArcadeStore.stats
                    RoachMetricCard(label: "Games", value: "\(stats.games)", detail: "Library")
                    RoachMetricCard(label: "Playable", value: "\(stats.playable)", detail: "Ready")
                    RoachMetricCard(label: "Profiles", value: "\(stats.profiles)", detail: "Mods")
                    RoachMetricCard(label: "Cheats", value: "\(stats.cheats)", detail: "Codes")
                    RoachMetricCard(label: "Needs work", value: "\(stats.attention)", detail: "Missing files/runners")
                    RoachMetricCard(label: "Pinned", value: "\(stats.favorites)", detail: "Favorite games")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Player core")
                    RoachInlineField(
                        title: "EmulatorJS data",
                        value: Binding(
                            get: { model.roachArcadeStore.library.emulatorJSDataPath },
                            set: { model.roachArcadeStore.setEmulatorDataPath($0) }
                        ),
                        placeholder: "https://cdn.emulatorjs.org/stable/data/"
                    )
                    Text("EmulatorJS loads from its CDN first. Set a local data folder to play ROMs offline.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Windows runners")
                    RoachInlineField(
                        title: "Game Porting Toolkit",
                        value: Binding(
                            get: { model.roachArcadeStore.library.gamePortingToolkitRunnerPath },
                            set: { model.roachArcadeStore.setGamePortingToolkitRunnerPath($0) }
                        ),
                        placeholder: "/usr/local/bin/gameportingtoolkit"
                    )
                    RoachInlineField(
                        title: "CrossOver app",
                        value: Binding(
                            get: { model.roachArcadeStore.library.crossoverAppPath },
                            set: { model.roachArcadeStore.setCrossoverAppPath($0) }
                        ),
                        placeholder: "/Applications/CrossOver.app"
                    )
                    RoachInlineField(
                        title: "Wine runner",
                        value: Binding(
                            get: { model.roachArcadeStore.library.wineRunnerPath },
                            set: { model.roachArcadeStore.setWineRunnerPath($0) }
                        ),
                        placeholder: "/opt/homebrew/bin/wine64"
                    )
                    Text("Missing Windows runners keep those games blocked instead of pretending they are ready.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Readiness")
                    LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                        ForEach(model.roachArcadeStore.runnerDiagnostics) { diagnostic in
                            RoachMetricCard(label: diagnostic.label, value: diagnostic.value, detail: diagnostic.detail)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Scan Applications") {
                            model.roachArcadeStore.importInstalledMacGames()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Open library folder") {
                            model.roachArcadeStore.revealLibraryFolder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var vault: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(
                        label: "Books", value: "\(model.roachArchiveStore.vaultRecords.count)",
                        detail: "Added through Roach's Archive")
                    RoachMetricCard(
                        label: "Results", value: "\(model.roachArchiveStore.results.count)", detail: "Last search")
                    RoachMetricCard(
                        label: "Metadata", value: "\(model.roachArchiveStore.metadataTorrentCount)",
                        detail: "Bulk metadata")
                    RoachMetricCard(
                        label: "Reading",
                        value:
                            "\(model.roachArchiveStore.vaultRecords.filter { $0.readingProgress > 0 && $0.readingProgress < 1 }.count)",
                        detail: "Books in progress"
                    )
                    RoachMetricCard(
                        label: "Attached",
                        value: "\(model.roachArchiveStore.vaultRecords.filter { $0.filePath != nil }.count)",
                        detail: "Local copies"
                    )
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Roach's Archive")
                    RoachInlineField(
                        title: "API endpoint",
                        value: $model.roachArchiveStore.endpointURLString,
                        placeholder: "Optional local mirror URL"
                    )
                    RoachInlineField(
                        title: "Metadata folder",
                        value: $model.roachArchiveStore.metadataDirectoryPath,
                        placeholder: "~/RoachNet/storage/RoachArchive/Metadata"
                    )
                    RoachInlineField(
                        title: "Torrent list",
                        value: $model.roachArchiveStore.torrentListURLString,
                        placeholder: "Address of a torrents.json you trust"
                    )
                    Text(
                        "Use a local mirror/API or decompressed bulk metadata. RoachNet has no torrent list of its own: it loads the one you set."
                    )
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            RoachInsetPanel {
                HStack(spacing: 10) {
                    Button {
                        Task { await model.roachArchiveStore.refreshTorrentManifest() }
                    } label: {
                        Label(
                            model.roachArchiveStore.isRefreshingTorrents ? "Refreshing" : "Refresh manifest",
                            systemImage: "arrow.clockwise"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(
                        model.roachArchiveStore.isRefreshingTorrents || !model.roachArchiveStore.hasTorrentListAddress)

                    Button {
                        if let booksRootURL = model.roachArchiveStore.booksRootURL {
                            NSWorkspace.shared.open(booksRootURL)
                        }
                    } label: {
                        Label("Open storage folder", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.roachArchiveStore.booksRootURL == nil)
                }
            }
        }
    }

    private var atlas: some View {
        let collections = model.snapshot?.mapCollections ?? []
        let installedCollections = collections.filter { ($0.installed_count ?? 0) > 0 }
        let totalResources = collections.reduce(0) { $0 + $1.resources.count }
        let readyResources = collections.reduce(0) { $0 + ($1.installed_count ?? 0) }

        return VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(
                        label: "Packs", value: "\(installedCollections.count) / \(collections.count)",
                        detail: "Offline maps")
                    RoachMetricCard(
                        label: "Resources", value: "\(readyResources) / \(totalResources)", detail: "Ready assets")
                    RoachMetricCard(
                        label: "Storage",
                        value: RuntimeSurfacePathLabel.displayValue(model.storagePath, kind: .storageRoot),
                        detail: RuntimeSurfacePathLabel.displayDetail(model.storagePath, kind: .storageRoot)
                    )
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("RoachAtlas")
                    Text("Map packs stay on this Mac. Your phone sends its GPS position over Bluetooth.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button {
                                Task { await model.downloadBaseMapAssets() }
                            } label: {
                                Label(
                                    model.activeActions.contains("maps-base-assets")
                                        ? "Installing" : "Install base maps", systemImage: "square.and.arrow.down.fill"
                                )
                                .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(model.activeActions.contains("maps-base-assets"))

                            Button {
                                model.selectedPane = .maps
                            } label: {
                                Label("Open map", systemImage: "map.fill")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                Task { await model.downloadBaseMapAssets() }
                            } label: {
                                Label(
                                    model.activeActions.contains("maps-base-assets")
                                        ? "Installing" : "Install base maps", systemImage: "square.and.arrow.down.fill"
                                )
                                .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(model.activeActions.contains("maps-base-assets"))

                            Button {
                                model.selectedPane = .maps
                            } label: {
                                Label("Open map", systemImage: "map.fill")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }

            if collections.isEmpty {
                RoachNotice(
                    title: "No map catalog yet",
                    detail: "Refresh the runtime or install the base maps, and the map catalog appears here.",
                    accent: RoachPalette.cyan,
                    systemName: "map"
                )
            } else {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        settingTitle("Installed packs")
                        LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                            ForEach(Array(collections.prefix(6)), id: \.slug) { collection in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(collection.name)
                                        .font(.roach(size: 13, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                        .lineLimit(1)
                                    Text(
                                        "\(collection.installed_count ?? 0) / \(RoachCopy.count(collection.resources.count, "asset"))"
                                    )
                                    .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                        .fill(RoachPalette.panelRaised.opacity(0.54))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                        .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var models: some View {
        let installedModels = model.snapshot?.installedModels ?? []
        let activeModelDownloads =
            model.snapshot?.downloads.filter { $0.filetype == "model" && $0.status != "failed" } ?? []
        let activeLibraryPulls = model.modelLibrary?.pulls.filter(\.isActive).count ?? 0
        let roachClaw = model.snapshot?.roachClaw

        return VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Installed", value: "\(installedModels.count)", detail: "On this Mac")
                    RoachMetricCard(
                        label: "Default",
                        value: model.displayedRoachClawDefaultModel,
                        detail: model.modelWhereLabel(for: model.displayedRoachClawDefaultModel)
                    )
                    RoachMetricCard(
                        label: "Queue", value: "\(activeModelDownloads.count + activeLibraryPulls)", detail: "Downloads"
                    )
                    RoachMetricCard(
                        label: "Runner", value: roachClaw?.ollama.available == true ? "Live" : "Offline",
                        detail: "RoachInference")
                }
            }

            ModelLibrarySection(model: model)

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Default model")
                    RoachInlineField(
                        title: "Model", value: $model.config.roachClawDefaultModel, placeholder: "qwen2.5-coder:1.5b")
                    Text(
                        "Type a library name, or a Hugging Face GGUF repository as hf.co/owner/repo:Q4_K_M. Apply downloads it."
                    )
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                    if !model.recommendedLocalModels.isEmpty {
                        LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                            ForEach(model.recommendedLocalModels, id: \.self) { modelName in
                                Button {
                                    model.config.roachClawDefaultModel = modelName
                                    model.selectedChatModel = modelName
                                } label: {
                                    modelChip(modelName, active: model.displayedRoachClawDefaultModel == modelName)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await model.applyRoachClawDefaults() }
                        } label: {
                            Label(model.isApplyingDefaults ? "Applying" : "Apply", systemImage: "checkmark.seal.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.isApplyingDefaults)

                        Button {
                            selectPane(.roachClaw)
                        } label: {
                            Label("RoachClaw", systemImage: "sparkles")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            }

            RoachClusterSection(config: model.config)

            if !installedModels.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        settingTitle("On disk")
                        LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                            ForEach(installedModels) { installedModel in
                                RoachMetricCard(
                                    label: installedModel.name,
                                    value: modelSizeLabel(installedModel.size),
                                    detail: installedModel.name == model.displayedRoachClawDefaultModel
                                        ? "Default" : "Available"
                                )
                            }
                        }
                    }
                }
            }

            if !activeModelDownloads.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        settingTitle("Downloads")
                        ForEach(activeModelDownloads) { job in
                            RoachStatusRow(
                                title: URL(fileURLWithPath: job.filepath).lastPathComponent.isEmpty
                                    ? job.url : URL(fileURLWithPath: job.filepath).lastPathComponent,
                                value: "\(job.progress)%",
                                accent: RoachPalette.green
                            )
                        }
                    }
                }
            }
        }
    }

    private var apps: some View {
        let services =
            model.snapshot?.services.sorted {
                ($0.display_order ?? 10_000, $0.friendly_name ?? $0.service_name)
                    < ($1.display_order ?? 10_000, $1.friendly_name ?? $1.service_name)
            } ?? []
        let installed = services.filter { $0.installed ?? false }

        return VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Installed", value: "\(installed.count)", detail: "Local services")
                    RoachMetricCard(label: "Available", value: "\(services.count)", detail: "Catalog")
                    RoachMetricCard(
                        label: "Runtime", value: model.snapshot == nil ? "Offline" : "Live", detail: "Local gateway")
                }
            }

            if services.isEmpty {
                RoachNotice(
                    title: "No app catalog yet",
                    detail: "Refresh the runtime after setup so RoachNet can read the local module catalog.",
                    accent: RoachPalette.warning,
                    systemName: "square.grid.2x2"
                )
            } else {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        settingTitle("Modules")
                        LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                            ForEach(services) { service in
                                Button {
                                    Task {
                                        if service.installed ?? false {
                                            await model.openService(service)
                                        } else {
                                            await model.installService(service)
                                        }
                                    }
                                } label: {
                                    serviceChip(service)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.activeActions.contains("service-\(service.service_name)"))
                            }
                        }
                    }
                }
            }
        }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(
                        label: "Channel", value: model.config.releaseChannel.capitalized, detail: "Update channel")
                    RoachMetricCard(
                        label: "Version",
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Local",
                        detail: "Native app")
                    RoachMetricCard(label: "Latest", value: model.latestVersionLabel, detail: model.latestVersionDetail)
                    RoachMetricCard(
                        label: "Updater", value: model.systemUpdateStageLabel, detail: model.systemUpdateDetail)
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Release channel")
                    Picker("Channel", selection: $model.config.releaseChannel) {
                        Text("Stable").tag("stable")
                        Text("Beta").tag("beta")
                        Text("Nightly").tag("nightly")
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Button {
                            Task { await model.checkForRoachNetUpdates(force: true) }
                        } label: {
                            Label(model.isCheckingForUpdates ? "Checking" : "Check now", systemImage: "arrow.clockwise")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.isCheckingForUpdates)

                        Button {
                            Task { await model.requestRoachNetUpdate() }
                        } label: {
                            Label(
                                model.isRequestingUpdate ? "Requesting" : "Install update",
                                systemImage: "square.and.arrow.down.fill"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(model.isRequestingUpdate || !model.canRequestSystemUpdate)
                    }
                }
            }

            if let updateStatus = model.systemUpdateStatus {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        settingTitle("Update status")
                        RoachStatusRow(
                            title: RoachCopy.status(updateStatus.stage),
                            value: "\(updateStatus.progress)%",
                            accent: updateStatus.stage == "error" ? RoachPalette.warning : RoachPalette.green
                        )
                        Text(updateStatus.message)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task {
            await model.refreshUpdateStatusIfNeeded()
        }
    }

    private var benchmark: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Status", value: model.benchmarkStatusLabel, detail: model.benchmarkDetail)
                    RoachMetricCard(
                        label: "Machine", value: model.snapshot?.systemInfo.hardwareProfile.platformLabel ?? "Unknown",
                        detail: model.snapshot?.systemInfo.hardwareProfile.memoryTier.capitalized ?? "No profile")
                    RoachMetricCard(
                        label: "Model class",
                        value: model.snapshot.map {
                            RoachCopy.modelClass($0.systemInfo.hardwareProfile.recommendedModelClass)
                        } ?? "Unknown", detail: "Recommended")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Run")
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.runRoachNetBenchmark(type: "system") }
                        } label: {
                            Label("System", systemImage: "cpu.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(model.isRunningBenchmark)

                        Button {
                            Task { await model.runRoachNetBenchmark(type: "ai") }
                        } label: {
                            Label("AI", systemImage: "sparkles")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(model.isRunningBenchmark)

                        Button {
                            Task { await model.runRoachNetBenchmark(type: "full") }
                        } label: {
                            Label("Full", systemImage: "gauge.with.dots.needle.67percent")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(model.isRunningBenchmark)
                    }
                }
            }
        }
        .task {
            await model.refreshBenchmarkStatusIfNeeded()
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(
                        label: "Install",
                        value: RuntimeSurfacePathLabel.displayValue(model.installPath, kind: .installRoot),
                        detail: RuntimeSurfacePathLabel.displayDetail(model.installPath, kind: .installRoot)
                    )
                    RoachMetricCard(
                        label: "Storage",
                        value: RuntimeSurfacePathLabel.displayValue(model.storagePath, kind: .storageRoot),
                        detail: RuntimeSurfacePathLabel.displayDetail(model.storagePath, kind: .storageRoot)
                    )
                    RoachMetricCard(
                        label: "Runtime", value: model.snapshot == nil ? "Offline" : "Live",
                        detail: model.snapshot?.serverInfo.healthUrl ?? "No health URL")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Local paths")
                    supportPathRow(title: "Install root", path: model.installPath)
                    supportPathRow(title: "Storage", path: model.storagePath)
                    if let logPath = model.snapshot?.serverInfo.logPath {
                        supportPathRow(title: "Runtime log", path: logPath)
                    }
                }
            }

            RoachInsetPanel {
                HStack(spacing: 10) {
                    Button("RoachNet.org") {
                        NSWorkspace.shared.open(URL(string: "https://roachnet.org/")!)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("RoachWares.org") {
                        NSWorkspace.shared.open(URL(string: "https://roachwares.org/")!)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("GitHub") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/RoachWares/RoachNet")!)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
            }
        }
    }

    private var legal: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Source", value: "RoachWares", detail: "Public app source")
                    RoachMetricCard(label: "Custody", value: "Local", detail: "Files stay on disk")
                    RoachMetricCard(label: "Network", value: "Optional", detail: "Needed for downloads and updates")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 10) {
                    settingTitle("Notices")
                    Text(
                        "RoachNet keeps your files on this Mac. It goes online for catalogs, downloads, update checks, the optional RoachNet account and any remote model you turn on."
                    )
                    .font(.roach(size: 13, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Third-party runtimes and content sources keep their own licenses and terms. RoachNet doesn't share your vault with them."
                    )
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(
                        label: "Runtime", value: model.snapshot == nil ? "Offline" : "Live", detail: "Local gateway")
                    RoachMetricCard(
                        label: "Install", value: model.setupCompleted ? "Ready" : "Needs setup", detail: "App folder")
                    RoachMetricCard(
                        label: "Storage",
                        value: RuntimeSurfacePathLabel.displayValue(model.storagePath, kind: .storageRoot),
                        detail: RuntimeSurfacePathLabel.displayDetail(model.storagePath, kind: .storageRoot)
                    )
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Companion")
                    settingsToggle(
                        "Companion bridge",
                        detail: "Let RoachNet for iOS connect to this Mac. Off by default.",
                        isOn: $model.config.companionEnabled
                    )
                    RoachInlineField(title: "Host", value: $model.config.companionHost, placeholder: "127.0.0.1")
                    Stepper(value: $model.config.companionPort, in: 1_024...65_535) {
                        HStack {
                            Text("Port")
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                            Text(verbatim: String(model.config.companionPort))
                                .font(.roach(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                        }
                    }
                    RoachInlineField(
                        title: "Advertised URL", value: $model.config.companionAdvertisedURL,
                        placeholder: "http://roachnet.local:38111")
                }
            }

            RoachInsetPanel {
                HStack(spacing: 10) {
                    Button {
                        Task { await model.refreshRuntimeState() }
                    } label: {
                        Label(model.isLoading ? "Refreshing" : "Refresh runtime", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.isLoading)

                    Button {
                        model.openStorageInFinder()
                    } label: {
                        Label("Open storage folder", systemImage: "externaldrive.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
            }
        }
    }

    private var saveBar: some View {
        let hasError = model.errorLine != nil
        let statusText = model.errorLine ?? model.statusLine

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                saveBarStatusIcon(hasError: hasError)
                saveBarStatusText(statusText, hasError: hasError)

                Spacer(minLength: 12)

                saveSettingsButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    saveBarStatusIcon(hasError: hasError)
                    saveBarStatusText(statusText, hasError: hasError)
                }

                saveSettingsButton
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(
                    hasError ? RoachPalette.warning.opacity(0.24) : RoachPalette.border, lineWidth: RoachMetrics.line(1)
                )
        )
    }

    private var saveSettingsButton: some View {
        Button {
            Task { await model.saveSettingsFromPreferences() }
        } label: {
            Label("Save", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachPrimaryButtonStyle())
    }

    private func saveBarStatusIcon(hasError: Bool) -> some View {
        Image(systemName: hasError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
            .font(.roach(size: 14, weight: .semibold))
            .foregroundStyle(hasError ? RoachPalette.warning : RoachPalette.green)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(11), style: .continuous)
                    .fill((hasError ? RoachPalette.warning : RoachPalette.green).opacity(0.13))
            )
    }

    private func saveBarStatusText(_ text: String, hasError: Bool) -> some View {
        Text(text)
            .font(.roach(size: 12, weight: .medium))
            .foregroundStyle(hasError ? RoachPalette.warning : RoachPalette.muted)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(3)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsHeader(_ pane: RoachNetSettingsPane) -> some View {
        RoachSpotlightPanel(accent: pane.accent) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    RoachModuleMark(systemName: pane.systemName, size: 22, isSelected: true, glow: true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.title)
                            .font(.roach(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                        Text(pane.subtitle)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    RoachTag(
                        model.setupCompleted ? "Ready" : "Needs setup",
                        accent: model.setupCompleted ? RoachPalette.green : RoachPalette.warning)
                }

                HStack(alignment: .center, spacing: 10) {
                    RoachModuleMark(systemName: pane.systemName, size: 20, isSelected: true, glow: true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.title)
                            .font(.roach(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                        Text(pane.subtitle)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func settingTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(RoachPalette.muted)
    }

    private func modelChip(_ modelName: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "cpu")
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(active ? RoachPalette.green : RoachPalette.muted)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(modelName)
                    .font(.roach(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(1)
                Text(active ? "Default" : "Set as default")
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(active ? RoachPalette.green.opacity(0.12) : RoachPalette.panelRaised.opacity(0.54))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(
                    active ? RoachPalette.green.opacity(0.28) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    private func serviceChip(_ service: ManagedSystemService) -> some View {
        let installed = service.installed ?? false
        let name = service.friendly_name ?? service.service_name

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: installed ? "checkmark.seal.fill" : "square.grid.2x2")
                    .font(.roach(size: 14, weight: .semibold))
                    .foregroundStyle(installed ? RoachPalette.green : RoachPalette.muted)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous)
                            .fill((installed ? RoachPalette.green : RoachPalette.magenta).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.roach(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    Text(installed ? (service.status ?? "Installed") : "Install")
                        .font(.roach(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(installed ? RoachPalette.green : RoachPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            if let description = service.description, !description.isEmpty {
                Text(description)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.54))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(
                    installed ? RoachPalette.green.opacity(0.24) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    private func supportPathRow(title: String, path: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(path)
                    .font(.roach(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                model.revealPathInFinder(path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.roach(size: 13, weight: .semibold))
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.cyan))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.54))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    private func modelSizeLabel(_ size: Int64?) -> String {
        guard let size, size > 0 else { return "Ready" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func settingsToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityHint(detail)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.roach(size: 13, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
