import AppKit
import SwiftUI
import RoachNetCore
import RoachNetDesign

struct RoachNetSettingsView: View {
    @ObservedObject var model: WorkspaceModel

    private let settingsColumns = [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)]

    var body: some View {
        ZStack {
            RoachBackground()
                .overlay(Color.black.opacity(0.52))
                .ignoresSafeArea()

            TabView {
                general
                    .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                ai
                    .tabItem { Label("RoachClaw", systemImage: "sparkles") }
                vault
                    .tabItem { Label("Vault", systemImage: "books.vertical.fill") }
                arcade
                    .tabItem { Label("Arcade", systemImage: "gamecontroller.fill") }
                network
                    .tabItem { Label("Runtime", systemImage: "server.rack") }
            }
            .padding(18)
        }
        .preferredColorScheme(.dark)
    }

    private var general: some View {
        settingsScroll {
            settingsHeader("General", "Storage, launch, release lane.")

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Storage")
                    RoachInlineField(title: "Content Folder", value: $model.config.storagePath, placeholder: "~/RoachNet/storage")
                    HStack(spacing: 10) {
                        Button("Choose Folder") {
                            Task { await model.promptForStorageRelocation() }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Reveal") {
                            model.openStorageInFinder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            }

            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 14) {
                    settingsToggle("Open at login", isOn: $model.config.autoLaunch)
                    settingsToggle("Install dependencies", isOn: $model.config.autoInstallDependencies)
                    settingsToggle("Install RoachClaw", isOn: $model.config.installRoachClaw)
                    settingsToggle("Launch intro", isOn: $model.config.pendingLaunchIntro)
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

            saveBar
        }
    }

    private var ai: some View {
        settingsScroll {
            settingsHeader("RoachClaw", "Local first. Remote only on purpose.")

            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Runner", value: "Ollama", detail: "Bundled local lane")
                    RoachMetricCard(label: "Default", value: model.displayedRoachClawDefaultModel, detail: "Chat and assist")
                    RoachMetricCard(label: "Fallback", value: model.hasCloudChatFallback ? "Available" : "Off", detail: "Opt-in route")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Local Model")
                    RoachInlineField(title: "Default Model", value: $model.config.roachClawDefaultModel, placeholder: "qwen2.5-coder:1.5b")
                    if !model.recommendedLocalModels.isEmpty {
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

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Routing")
                    Picker("Backend", selection: $model.config.distributedInferenceBackend) {
                        Text("Disabled").tag("disabled")
                        Text("Exo").tag("exo")
                    }
                    .pickerStyle(.segmented)
                    RoachInlineField(title: "Exo URL", value: $model.config.exoBaseUrl, placeholder: "http://127.0.0.1:52415")
                    RoachInlineField(title: "Exo Model", value: $model.config.exoModelId, placeholder: "llama-3.2-3b")
                }
            }

            saveBar
        }
    }

    private var arcade: some View {
        settingsScroll {
            settingsHeader("RoachArcade", "ROMs, apps, mods, cheats.")

            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    let stats = model.roachArcadeStore.stats
                    RoachMetricCard(label: "Games", value: "\(stats.games)", detail: "Library")
                    RoachMetricCard(label: "Playable", value: "\(stats.playable)", detail: "Ready")
                    RoachMetricCard(label: "Mods", value: "\(stats.profiles)", detail: "Profiles")
                    RoachMetricCard(label: "Cheats", value: "\(stats.cheats)", detail: "Codes")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Player Core")
                    RoachInlineField(
                        title: "EmulatorJS Data",
                        value: Binding(
                            get: { model.roachArcadeStore.library.emulatorJSDataPath },
                            set: { model.roachArcadeStore.setEmulatorDataPath($0) }
                        ),
                        placeholder: "https://cdn.emulatorjs.org/stable/data/"
                    )
                    Text("Leave the CDN path for first boot. Point this at a local EmulatorJS data folder when you want ROMs fully offline.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Windows Runners")
                    RoachInlineField(
                        title: "Game Porting Toolkit",
                        value: Binding(
                            get: { model.roachArcadeStore.library.gamePortingToolkitRunnerPath },
                            set: { model.roachArcadeStore.setGamePortingToolkitRunnerPath($0) }
                        ),
                        placeholder: "/usr/local/bin/gameportingtoolkit"
                    )
                    RoachInlineField(
                        title: "CrossOver App",
                        value: Binding(
                            get: { model.roachArcadeStore.library.crossoverAppPath },
                            set: { model.roachArcadeStore.setCrossoverAppPath($0) }
                        ),
                        placeholder: "/Applications/CrossOver.app"
                    )
                    RoachInlineField(
                        title: "Wine Runner",
                        value: Binding(
                            get: { model.roachArcadeStore.library.wineRunnerPath },
                            set: { model.roachArcadeStore.setWineRunnerPath($0) }
                        ),
                        placeholder: "/opt/homebrew/bin/wine64"
                    )
                    Text("RoachArcade also checks common Homebrew paths. If a runner is missing, Windows games stay blocked instead of pretending to be ready.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var vault: some View {
        settingsScroll {
            settingsHeader("Vault", "Books, metadata, local mirrors.")

            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Books", value: "\(model.roachArchiveStore.vaultRecords.count)", detail: "Added through Roach's Archive")
                    RoachMetricCard(label: "Results", value: "\(model.roachArchiveStore.results.count)", detail: "Last search")
                    RoachMetricCard(label: "Metadata", value: "\(model.roachArchiveStore.metadataTorrentCount)", detail: "Anna's torrent lanes")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    settingTitle("Roach's Archive")
                    RoachInlineField(
                        title: "API Endpoint",
                        value: $model.roachArchiveStore.endpointURLString,
                        placeholder: "http://127.0.0.1:38221"
                    )
                    RoachInlineField(
                        title: "Metadata Folder",
                        value: $model.roachArchiveStore.metadataDirectoryPath,
                        placeholder: "~/RoachNet/storage/RoachArchive/Metadata"
                    )
                    Text("Point this at a local API or decompressed bulk metadata. RoachNet uses Anna's torrents and metadata lane, not public-site scraping.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RoachInsetPanel {
                HStack(spacing: 10) {
                    Button(model.roachArchiveStore.isRefreshingTorrents ? "Refreshing" : "Refresh Torrent Manifest") {
                        Task { await model.roachArchiveStore.refreshTorrentManifest() }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.roachArchiveStore.isRefreshingTorrents)

                    Button("Reveal Storage") {
                        if let booksRootURL = model.roachArchiveStore.booksRootURL {
                            NSWorkspace.shared.open(booksRootURL)
                        }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.roachArchiveStore.booksRootURL == nil)
                }
            }
        }
    }

    private var network: some View {
        settingsScroll {
            settingsHeader("Runtime", "Gateway, companion, bootstrap.")

            RoachInsetPanel {
                LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "Runtime", value: model.snapshot == nil ? "Offline" : "Live", detail: "Local gateway")
                    RoachMetricCard(label: "Install", value: model.setupCompleted ? "Ready" : "Setup", detail: "Contained app")
                    RoachMetricCard(label: "Storage", value: RuntimeSurfacePathLabel.displayValue(model.storagePath, kind: .storageRoot), detail: "Content root")
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    settingTitle("Companion")
                    settingsToggle("Enable bridge", isOn: $model.config.companionEnabled)
                    RoachInlineField(title: "Host", value: $model.config.companionHost, placeholder: "0.0.0.0")
                    Stepper(value: $model.config.companionPort, in: 1_024...65_535) {
                        HStack {
                            Text("PORT")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                            Text("\(model.config.companionPort)")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                        }
                    }
                    RoachInlineField(title: "Advertised URL", value: $model.config.companionAdvertisedURL, placeholder: "http://roachnet.local:38111")
                }
            }

            RoachInsetPanel {
                HStack(spacing: 10) {
                    Button(model.isLoading ? "Refreshing" : "Refresh Runtime") {
                        Task { await model.refreshRuntimeState() }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(model.isLoading)

                    Button("Reveal Storage") {
                        model.openStorageInFinder()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
            }

            saveBar
        }
    }

    private var saveBar: some View {
        HStack {
            if let error = model.errorLine {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.warning)
                    .lineLimit(2)
            } else {
                Text(model.statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button("Save Settings") {
                Task { await model.saveSettingsFromPreferences() }
            }
            .buttonStyle(RoachPrimaryButtonStyle())
        }
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsHeader(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func settingTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(RoachPalette.muted)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
        }
        .toggleStyle(.switch)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.54))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
    }
}
