import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import RoachNetDesign

struct RoachArcadeView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: RoachArcadeLibraryStore
    @State private var newCheatName = ""
    @State private var newCheatCode = ""
    @State private var newProfileName = ""
    @State private var vortexCollectionTitle = ""
    @State private var vortexCollectionURL = ""

    private var displayStoragePath: String {
        let home = NSHomeDirectory()
        let path = "\(model.storagePath)/RoachArcade"
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let errorLine = store.errorLine {
                RoachNotice(title: "RoachArcade notice", detail: errorLine)
            }

            if let session = store.activePlayerSession {
                player(session)
            }

            HStack(alignment: .top, spacing: 18) {
                libraryColumn
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)

                detailColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        let stats = store.stats
        return RoachSpotlightPanel(accent: RoachPalette.magenta) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    RoachModuleMark(systemName: "gamecontroller.fill", size: 56, isSelected: true, glow: true)
                    RoachSectionHeader(
                        "RoachArcade",
                        title: "Games stay on disk. RoachArcade keeps them bootable.",
                        detail: "ROMs run in this tab. macOS games launch from the same shelf. Mods, cheats, collection notes, play counts, and source paths stay local."
                    )
                    Spacer(minLength: 12)
                    Button("Import ROM Folder") {
                        if let url = chooseFolder(title: "Choose a ROM folder") {
                            store.importROMFolder(url)
                        }
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    Button("Add macOS Game") {
                        if let url = chooseApplication() {
                            store.importMacGame(url)
                        }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    Button("Add Windows Game") {
                        if let url = chooseWindowsExecutable() {
                            store.importWindowsGame(url)
                        }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Games", value: "\(stats.games)")
                    RoachInfoPill(title: "ROMs", value: "\(stats.roms)")
                    RoachInfoPill(title: "Native", value: "\(stats.native)")
                    RoachInfoPill(title: "Windows", value: "\(stats.windows)")
                    RoachInfoPill(title: "Playable", value: "\(stats.playable)")
                    RoachInfoPill(title: "Controllers", value: "\(store.connectedControllers.count)")
                    RoachInfoPill(title: "Mods", value: "\(stats.profiles)")
                    RoachInfoPill(title: "Cheats", value: "\(stats.cheats)")
                }
            }
        }
    }

    private func player(_ session: RoachArcadePlayerSession) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RoachSectionHeader("Now Playing", title: session.title, detail: "The game keeps running while you open the vault, music, or RoachClaw.")
                    Spacer()
                    Button("Close Player") {
                        store.activePlayerSession = nil
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
                RoachArcadeEmbeddedPlayer(session: session)
                    .frame(minHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: 1)
                    )
            }
        }
    }

    private var libraryColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Library", title: "Games", detail: store.statusLine)
                TextField("Search games", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.filteredGames) { game in
                            Button {
                                store.selectedGameID = game.id
                            } label: {
                                gameRow(game)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Reveal File") {
                                    store.reveal(game.launchPath)
                                }
                                Button("Remove From Library", role: .destructive) {
                                    store.remove(game)
                                }
                            }
                        }

                        if store.filteredGames.isEmpty {
                            Text("No games in this library yet.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                    }
                }
                .frame(minHeight: 320)
            }
        }
    }

    private func gameRow(_ game: RoachArcadeGame) -> some View {
        let isSelected = store.selectedGame?.id == game.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: game.kind == .rom ? "rectangle.on.rectangle.circle.fill" : (game.kind == .windows ? "pc" : "gamecontroller.fill"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.green : RoachPalette.muted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    Text("\(game.system) · \(game.kind.label)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                RoachTag(game.status.label, accent: game.status == .ready ? RoachPalette.green : RoachPalette.warning)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? RoachPalette.panelSoft.opacity(0.90) : RoachPalette.panelRaised.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? RoachPalette.green.opacity(0.28) : RoachPalette.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let game = store.selectedGame {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    gameDetail(game)
                    cheatsPanel(game)
                    modsPanel(game)
                    vortexPanel(game)
                }
            }
        } else {
            RoachInsetPanel {
                RoachSectionHeader("Empty", title: "Drag the backlog out of launcher jail.", detail: "RoachArcade stores the library under \(displayStoragePath).")
            }
        }
    }

    private func gameDetail(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        RoachSectionHeader(game.kind.label, title: game.title, detail: game.launchPath ?? "No launch path linked")
                        HStack(spacing: 8) {
                            RoachTag(game.status.label, accent: game.status == .ready ? RoachPalette.green : RoachPalette.warning)
                            RoachTag(game.kind == .windows ? game.compatibilityRunner.label : (game.resolvedCore ?? "native"), accent: RoachPalette.cyan)
                            RoachTag("\(game.playCount) plays", accent: RoachPalette.bronze)
                            if !store.connectedControllers.isEmpty {
                                RoachTag("Controller ready", accent: RoachPalette.green)
                            }
                        }
                    }
                    Spacer()
                    Button(game.kind == .rom ? "Play In Tab" : "Launch") {
                        store.play(game)
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(game.status != .ready)
                    Button("Reveal") {
                        store.reveal(game.launchPath)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(game.launchPath == nil)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "System", value: game.system, detail: game.source)
                    RoachMetricCard(label: game.kind == .windows ? "Runner" : "Core", value: game.kind == .windows ? game.compatibilityRunner.label : (game.resolvedCore ?? "None"), detail: game.kind == .rom ? "Embedded player mapping" : "Launch route")
                    RoachMetricCard(label: "Controllers", value: "\(store.connectedControllers.count)", detail: store.connectedControllerSummary)
                    RoachMetricCard(label: "Mods", value: "\(store.profilesForSelectedGame.count)", detail: "Profiles attached to this game")
                    RoachMetricCard(label: "Cheats", value: "\(game.cheats.count)", detail: "Stored with this game")
                }
            }
        }
    }

    private func cheatsPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Cheats", title: "Game codes", detail: "If you are going to break the game, do it offline.")
                HStack(spacing: 10) {
                    TextField("Cheat name", text: $newCheatName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Code", text: $newCheatCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        store.addCheat(to: game.id, name: newCheatName, code: newCheatCode)
                        newCheatName = ""
                        newCheatCode = ""
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                ForEach(game.cheats) { cheat in
                    HStack(spacing: 10) {
                        Button {
                            store.toggleCheat(cheat.id, for: game.id)
                        } label: {
                            Image(systemName: cheat.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(cheat.enabled ? RoachPalette.green : RoachPalette.muted)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cheat.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(cheat.code)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }
                        Spacer()
                        Button("Remove") {
                            store.deleteCheat(cheat.id, from: game.id)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RoachPalette.panelRaised.opacity(0.56)))
                }
            }
        }
    }

    private func modsPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Mods", title: "Profiles and deployment", detail: "Profiles keep mod folders, order, and conflict groups attached to the game.")
                HStack(spacing: 10) {
                    RoachTag(game.modDirectoryPath == nil ? "No deploy folder" : "Deploy folder set", accent: game.modDirectoryPath == nil ? RoachPalette.warning : RoachPalette.green)
                    Text(game.modDirectoryPath ?? "Pick the folder this game actually reads for mods. RoachArcade will not guess and wreck a save.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                    Spacer()
                    Button("Set Mod Folder") {
                        if let url = chooseFolder(title: "Choose this game's mod folder") {
                            store.setModDirectory(url, for: game.id)
                        }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
                HStack(spacing: 10) {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                    Button("Create Profile") {
                        store.createProfile(for: game.id, name: newProfileName)
                        newProfileName = ""
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                ForEach(store.profilesForSelectedGame) { profile in
                    RoachInsetPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text("\(profile.mods.count) mod\(profile.mods.count == 1 ? "" : "s")")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                }
                                Spacer()
                                Button("Add Mod Folder") {
                                    if let url = chooseFolder(title: "Choose a mod folder") {
                                        store.importModFolder(url, for: profile.id)
                                    }
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                                Button("Deploy") {
                                    store.deployProfile(profile, for: game)
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())
                            }

                            ForEach(profile.mods) { mod in
                                HStack {
                                    Text("\(mod.loadOrder). \(mod.name)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                    Spacer()
                                    Text(URL(fileURLWithPath: mod.sourcePath).lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func vortexPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Vortex Bridge", title: "Collection imports for macOS games.", detail: "Track a Nexus/Vortex collection and map a local extracted folder into a deployable profile.")
                HStack(spacing: 10) {
                    TextField("Collection title", text: $vortexCollectionTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Vortex or Nexus collection URL", text: $vortexCollectionURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Import Folder") {
                        let folder = chooseFolder(title: "Choose an extracted Vortex collection folder")
                        store.importVortexCollection(
                            gameID: game.id,
                            title: vortexCollectionTitle,
                            sourceURL: vortexCollectionURL,
                            localFolderURL: folder
                        )
                        vortexCollectionTitle = ""
                        vortexCollectionURL = ""
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                ForEach(store.collectionsForSelectedGame) { collection in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(collection.sourceURL.isEmpty ? "Local collection" : collection.sourceURL)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        RoachTag(collection.status, accent: RoachPalette.cyan)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RoachPalette.panelRaised.opacity(0.56)))
                }
            }
        }
    }

    private func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a macOS game"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle, .executable]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseWindowsExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows game executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data,
            UTType(filenameExtension: "msi") ?? .data,
            .data,
        ]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct RoachArcadeEmbeddedPlayer: NSViewRepresentable {
    let session: RoachArcadePlayerSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The WKWebView lives on the session so pane changes do not restart the emulator.
    }
}

struct RoachArcadeFloatingPlayer: View {
    let session: RoachArcadePlayerSession
    let onOpenArcade: () -> Void
    let onClose: () -> Void

    var body: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        RoachKicker("RoachArcade")
                        Text(session.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button("Open Arcade") {
                        onOpenArcade()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("Close") {
                        onClose()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                RoachArcadeEmbeddedPlayer(session: session)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: 1)
                    )
            }
        }
    }
}
