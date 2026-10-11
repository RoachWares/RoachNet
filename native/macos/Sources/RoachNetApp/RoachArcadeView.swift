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
    @State private var metadataGameID: UUID?
    @State private var metadataNotes = ""
    @State private var metadataTags = ""
    @State private var metadataArtworkPath = ""
    @State private var metadataStoreURL = ""
    @State private var metadataRunnerPath = ""
    @State private var metadataBottlePath = ""

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
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorLine = store.errorLine {
                RoachNotice(title: "RoachArcade notice", detail: errorLine)
            }

            if let session = store.activePlayerSession {
                player(session)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    libraryColumn
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)

                    detailColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 16) {
                    libraryColumn
                    detailColumn
                }
            }
        }
        .padding(.bottom, 16)
    }

    private var header: some View {
        let stats = store.stats
        return RoachSpotlightPanel(accent: RoachPalette.magenta) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    RoachModuleMark(systemName: "gamecontroller.fill", size: 34, isSelected: true, glow: true)
                    RoachSectionHeader(
                        "RoachArcade",
                        title: "Backlog graveyard. Still boots.",
                        detail: nil
                    )
                    Spacer(minLength: 12)
                    arcadeImportActions
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], alignment: .leading, spacing: 8) {
                    RoachMetricCard(label: "Games", value: "\(stats.games)", detail: "On disk")
                    RoachMetricCard(label: "Playable", value: "\(stats.playable)", detail: "Bootable")
                    RoachMetricCard(label: "Needs Work", value: "\(stats.attention)", detail: "Bad paths")
                    RoachMetricCard(label: "Controllers", value: "\(store.connectedControllers.count)", detail: store.connectedControllerSummary)
                }

                if !store.systemShelf.isEmpty {
                    systemShelfStrip
                }
            }
        }
    }

    private var systemShelfStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.systemShelf.prefix(12)) { summary in
                    Button {
                        store.searchText = summary.system
                        store.libraryFilter = .all
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: summary.core == nil ? "questionmark.square.dashed" : "memorychip.fill")
                                .font(.roach(size: 12, weight: .semibold))
                                .foregroundStyle(summary.core == nil ? RoachPalette.warning : RoachPalette.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.system)
                                    .font(.roach(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                Text(summary.readinessLabel)
                                    .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.62))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(RoachPalette.magenta.opacity(0.22), lineWidth: RoachMetrics.line(1))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Filter to \(summary.system)")
                }
            }
        }
    }

    private var arcadeImportActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                arcadeImportButtons
            }

            VStack(alignment: .trailing, spacing: 8) {
                arcadeImportButtons
            }
        }
    }

    @ViewBuilder
    private var arcadeImportButtons: some View {
        Button {
            if let url = chooseFolder(title: "Choose an ES-DE library folder") {
                store.importESDELibrary(url)
            }
        } label: {
            Label("ES-DE", systemImage: "square.grid.3x3.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachPrimaryButtonStyle())

        Button {
            if let url = chooseFolder(title: "Choose a ROM folder") {
                store.importROMFolder(url)
            }
        } label: {
            Label("ROMs", systemImage: "rectangle.on.rectangle.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())

        Button {
            if let url = chooseApplication() {
                store.importMacGame(url)
            }
        } label: {
            Label("Mac App", systemImage: "app.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())

        Button {
            store.importInstalledMacGames()
        } label: {
            Label("Scan", systemImage: "magnifyingglass")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())

        Button {
            if let url = chooseWindowsExecutable() {
                store.importWindowsGame(url)
            }
        } label: {
            Label("Windows", systemImage: "pc")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private func player(_ session: RoachArcadePlayerSession) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RoachSectionHeader(
                        "Now Playing",
                        title: session.title,
                        detail: "Embedded in RoachArcade. Controllers stay wired to the room."
                    )
                    Spacer()
                    RoachTag("In-tab emulator", accent: RoachPalette.magenta)
                    Button("Close Player") {
                        store.activePlayerSession = nil
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
                RoachArcadeEmbeddedPlayer(session: session)
                    .frame(minHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                    )
            }
        }
    }

    private var libraryColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader("Library", title: "Game shelf", detail: store.statusLine)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        TextField("Search games", text: $store.searchText)
                            .textFieldStyle(.plain)
                            .font(.roach(size: 13, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(13), style: .continuous)
                                    .fill(RoachPalette.shade.opacity(0.22))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(13), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                        Picker("Filter", selection: $store.libraryFilter) {
                            ForEach(RoachArcadeLibraryFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 142)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Search games", text: $store.searchText)
                            .textFieldStyle(.plain)
                            .font(.roach(size: 13, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(13), style: .continuous)
                                    .fill(RoachPalette.shade.opacity(0.22))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(13), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                        Picker("Filter", selection: $store.libraryFilter) {
                            ForEach(RoachArcadeLibraryFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("\(store.libraryFilter.label) · \(store.filteredGames.count) shown")
                            .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)

                        Spacer()

                        Button("Reveal") {
                            store.revealLibraryFolder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(store.libraryFilter.label) · \(store.filteredGames.count) shown")
                            .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)

                        Button("Reveal") {
                            store.revealLibraryFolder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }

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
                            Label("No fossils on the shelf", systemImage: "tray")
                                .font(.roach(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.muted)
                                .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                                .padding(14)
                        }
                    }
                }
                .frame(minHeight: 420)
            }
        }
    }

    private func gameRow(_ game: RoachArcadeGame) -> some View {
        let isSelected = store.selectedGame?.id == game.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                gameArtwork(game, width: 42, height: 52, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if game.favorite {
                            Image(systemName: "star.fill")
                                .font(.roach(size: 10, weight: .bold))
                                .foregroundStyle(RoachPalette.bronze)
                        }
                        Text(game.title)
                            .font(.roach(size: 14, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                    }
                    Text("\(game.system) · \(game.kind.label) · \(game.source)")
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                RoachTag(game.status.label, accent: game.status == .ready ? RoachPalette.green : RoachPalette.warning)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(isSelected ? RoachPalette.panelSoft.opacity(0.90) : RoachPalette.panelRaised.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(isSelected ? RoachPalette.green.opacity(0.28) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let game = store.selectedGame {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    gameDetail(game)
                    runnerReadinessPanel
                    gameManagementPanel(game)
                    cheatsPanel(game)
                    modsPanel(game)
                    vortexPanel(game)
                }
            }
            .onAppear {
                syncMetadataDraft(for: game)
            }
            .onChange(of: game.id) { _, _ in
                syncMetadataDraft(for: game)
            }
        } else {
            arcadeEmptyState
        }
    }

    private var arcadeEmptyState: some View {
        RoachSpotlightPanel(accent: RoachPalette.magenta) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    arcadeEmptyStateTitle
                    Spacer(minLength: 12)
                    arcadeImportActions
                }

                VStack(alignment: .leading, spacing: 16) {
                    arcadeEmptyStateTitle
                    arcadeImportActions
                }
            }
        }
    }

    private var arcadeEmptyStateTitle: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                    .fill(RoachPalette.magenta.opacity(0.14))
                Image(systemName: store.games.isEmpty ? "gamecontroller.fill" : "list.bullet.rectangle")
                    .font(.roach(size: 24, weight: .semibold))
                    .foregroundStyle(RoachPalette.magenta)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 6) {
                Text(store.games.isEmpty ? "Build the shelf." : "Pick a fossil.")
                    .font(.roach(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text("Library root: \(displayStoragePath)")
                    .font(.roach(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func gameDetail(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        gameArtwork(game, width: 118, height: 154, cornerRadius: 18)

                        gameTitleBlock(game)

                        Spacer(minLength: 12)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                gameDetailActions(game)
                            }

                            VStack(alignment: .trailing, spacing: 8) {
                                gameDetailActions(game)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            gameArtwork(game, width: 86, height: 112, cornerRadius: 16)
                            gameTitleBlock(game)
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                gameDetailActions(game)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                gameDetailActions(game)
                            }
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                    RoachMetricCard(label: "System", value: game.system, detail: game.source)
                    RoachMetricCard(label: game.kind == .windows ? "Runner" : "Core", value: game.kind == .windows ? game.compatibilityRunner.label : (game.resolvedCore ?? "None"), detail: game.kind == .rom ? "In-tab emulator" : "Launch route")
                    RoachMetricCard(label: "Controllers", value: "\(store.connectedControllers.count)", detail: store.connectedControllerSummary)
                    RoachMetricCard(label: "Mods", value: "\(store.profilesForSelectedGame.count)", detail: "Profiles attached to this game")
                    RoachMetricCard(label: "Cheats", value: "\(game.cheats.count)", detail: "Stored with this game")
                }
            }
        }
    }

    private func gameTitleBlock(_ game: RoachArcadeGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoachSectionHeader(game.kind.label, title: game.title, detail: game.launchPath ?? "No launch path linked")
            gameTagStrip(game)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func gameTagStrip(_ game: RoachArcadeGame) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if game.favorite {
                    RoachTag("Favorite", accent: RoachPalette.bronze)
                }
                RoachTag(game.status.label, accent: game.status == .ready ? RoachPalette.green : RoachPalette.warning)
                RoachTag(game.kind == .windows ? game.compatibilityRunner.label : (game.resolvedCore ?? "native"), accent: RoachPalette.cyan)
                RoachTag("\(game.playCount) plays", accent: RoachPalette.bronze)
                if !store.connectedControllers.isEmpty {
                    RoachTag("Controller ready", accent: RoachPalette.green)
                }
            }
        }
    }

    @ViewBuilder
    private func gameDetailActions(_ game: RoachArcadeGame) -> some View {
        Button {
            store.play(game)
        } label: {
            Label(game.kind == .rom ? "Play" : "Launch", systemImage: game.kind == .rom ? "play.rectangle.fill" : "play.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachPrimaryButtonStyle())
        .disabled(game.status != .ready)

        Button {
            store.reveal(game.launchPath)
        } label: {
            Label("Reveal", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
        .disabled(game.launchPath == nil)

        Button {
            store.toggleFavorite(game.id)
        } label: {
            Label(game.favorite ? "Unpin" : "Pin", systemImage: game.favorite ? "star.slash" : "star")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private var runnerReadinessPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Readiness", title: "Runners and input", detail: nil)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(store.runnerDiagnostics) { diagnostic in
                        RoachMetricCard(
                            label: diagnostic.label,
                            value: diagnostic.value,
                            detail: diagnostic.detail
                        )
                    }
                }
            }
        }
    }

    private func gameManagementPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Metadata", title: "Launch context", detail: nil)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    arcadeTextField("Tags, comma separated", text: $metadataTags)
                    arcadeTextField("Artwork path", text: $metadataArtworkPath, monospaced: true)
                    arcadeTextField("Store URL", text: $metadataStoreURL, monospaced: true)
                }

                if game.kind == .windows {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                        Picker("Runner", selection: Binding(
                            get: { game.compatibilityRunner },
                            set: { store.setCompatibilityRunner($0, for: game.id) }
                        )) {
                            ForEach(RoachArcadeCompatibilityRunner.allCases) { runner in
                                Text(runner.label).tag(runner)
                            }
                        }
                        .pickerStyle(.menu)

                        arcadeTextField("Runner path override", text: $metadataRunnerPath, monospaced: true)
                        arcadeTextField("Bottle / prefix path", text: $metadataBottlePath, monospaced: true)
                    }
                }

                TextEditor(text: $metadataNotes)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 92)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.64))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                    )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button("Choose Artwork") {
                            if let url = chooseArtwork() {
                                metadataArtworkPath = url.path
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Save Metadata") {
                            store.updateGameMetadata(
                                gameID: game.id,
                                notes: metadataNotes,
                                tagsText: metadataTags,
                                artworkPath: metadataArtworkPath,
                                storeURL: metadataStoreURL,
                                runnerPath: metadataRunnerPath,
                                bottlePath: metadataBottlePath
                            )
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Choose Artwork") {
                            if let url = chooseArtwork() {
                                metadataArtworkPath = url.path
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Save Metadata") {
                            store.updateGameMetadata(
                                gameID: game.id,
                                notes: metadataNotes,
                                tagsText: metadataTags,
                                artworkPath: metadataArtworkPath,
                                storeURL: metadataStoreURL,
                                runnerPath: metadataRunnerPath,
                                bottlePath: metadataBottlePath
                            )
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gameArtwork(_ game: RoachArcadeGame, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        if
            let artworkPath = game.artworkPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !artworkPath.isEmpty,
            let image = NSImage(contentsOfFile: NSString(string: artworkPath).expandingTildeInPath)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(cornerRadius), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(cornerRadius), style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                )
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        RoachPalette.panelRaised.opacity(0.92),
                        game.kind == .rom ? RoachPalette.magenta.opacity(0.18) : RoachPalette.green.opacity(0.16),
                        RoachPalette.shade.opacity(0.28),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: game.kind == .rom ? "rectangle.on.rectangle.circle.fill" : (game.kind == .windows ? "pc" : "gamecontroller.fill"))
                    .font(.roach(size: min(width, height) * 0.36, weight: .semibold))
                    .foregroundStyle(RoachPalette.green.opacity(0.84))
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(cornerRadius), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(cornerRadius), style: .continuous)
                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
            )
        }
    }

    private func cheatsPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Cheats", title: "Game codes", detail: "Codes stay attached to this game.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        cheatEntryFields(game)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        cheatEntryFields(game)
                    }
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
                                .font(.roach(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(cheat.code)
                                .font(.roach(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }
                        Spacer()
                        Button("Remove") {
                            store.deleteCheat(cheat.id, from: game.id)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous).fill(RoachPalette.panelRaised.opacity(0.56)))
                }
            }
        }
    }

    @ViewBuilder
    private func cheatEntryFields(_ game: RoachArcadeGame) -> some View {
        arcadeTextField("Cheat name", text: $newCheatName)
        arcadeTextField("Code", text: $newCheatCode, monospaced: true)
        Button("Add") {
            store.addCheat(to: game.id, name: newCheatName, code: newCheatCode)
            newCheatName = ""
            newCheatCode = ""
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private func modsPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Mods", title: "Profiles and deployment", detail: "Folders, order, conflicts.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        modFolderControls(game)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        modFolderControls(game)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        profileEntryFields(game)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        profileEntryFields(game)
                    }
                }

                ForEach(store.profilesForSelectedGame) { profile in
                    RoachInsetPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) {
                                    profileHeaderControls(profile, game: game)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    profileHeaderControls(profile, game: game)
                                }
                            }

                            ForEach(profile.mods) { mod in
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) {
                                        modRowControls(mod, profileID: profile.id)
                                    }

                                    VStack(alignment: .leading, spacing: 10) {
                                        modRowControls(mod, profileID: profile.id)
                                    }
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(RoachPalette.panelRaised.opacity(0.48)))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modFolderControls(_ game: RoachArcadeGame) -> some View {
        RoachTag(game.modDirectoryPath == nil ? "No deploy folder" : "Deploy folder set", accent: game.modDirectoryPath == nil ? RoachPalette.warning : RoachPalette.green)
        Text(game.modDirectoryPath ?? "Pick the folder this game reads for mods.")
            .font(.roach(size: 12, weight: .medium))
            .foregroundStyle(RoachPalette.muted)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        Button("Set Folder") {
            if let url = chooseFolder(title: "Choose this game's mod folder") {
                store.setModDirectory(url, for: game.id)
            }
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    @ViewBuilder
    private func profileEntryFields(_ game: RoachArcadeGame) -> some View {
        arcadeTextField("Profile name", text: $newProfileName)
        Button("Create") {
            store.createProfile(for: game.id, name: newProfileName)
            newProfileName = ""
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    @ViewBuilder
    private func profileHeaderControls(_ profile: RoachArcadeModProfile, game: RoachArcadeGame) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
                .font(.roach(size: 16, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
            Text("\(profile.mods.count) mod\(profile.mods.count == 1 ? "" : "s")")
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button("Add Folder") {
            if let url = chooseFolder(title: "Choose a mod folder") {
                store.importModFolder(url, for: profile.id)
            }
        }
        .buttonStyle(RoachSecondaryButtonStyle())
        Button("Deploy") {
            store.deployProfile(profile, for: game)
        }
        .buttonStyle(RoachPrimaryButtonStyle())
        Button("Delete") {
            store.deleteProfile(profile.id)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    @ViewBuilder
    private func modRowControls(_ mod: RoachArcadeModEntry, profileID: UUID) -> some View {
        Button {
            store.setModEnabled(!mod.enabled, modID: mod.id, profileID: profileID)
        } label: {
            Image(systemName: mod.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(mod.enabled ? RoachPalette.green : RoachPalette.muted)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)

        VStack(alignment: .leading, spacing: 3) {
            Text("\(mod.loadOrder). \(mod.name)")
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
            Text(URL(fileURLWithPath: mod.sourcePath).lastPathComponent)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Up") {
            store.moveMod(mod.id, profileID: profileID, direction: -1)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
        Button("Down") {
            store.moveMod(mod.id, profileID: profileID, direction: 1)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
        Button("Remove") {
            store.removeMod(mod.id, profileID: profileID)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private func vortexPanel(_ game: RoachArcadeGame) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader("Vortex Bridge", title: "Collection imports", detail: "Map an extracted collection into a profile.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        vortexEntryFields(game)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        vortexEntryFields(game)
                    }
                }

                ForEach(store.collectionsForSelectedGame) { collection in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.title)
                                .font(.roach(size: 13, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(collection.sourceURL.isEmpty ? "Local collection" : collection.sourceURL)
                                .font(.roach(size: 12, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        RoachTag(collection.status, accent: RoachPalette.cyan)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous).fill(RoachPalette.panelRaised.opacity(0.56)))
                }
            }
        }
    }

    @ViewBuilder
    private func vortexEntryFields(_ game: RoachArcadeGame) -> some View {
        arcadeTextField("Collection title", text: $vortexCollectionTitle)
        arcadeTextField("Vortex or Nexus collection URL", text: $vortexCollectionURL, monospaced: true)
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

    private func syncMetadataDraft(for game: RoachArcadeGame) {
        guard metadataGameID != game.id else { return }
        metadataGameID = game.id
        metadataNotes = game.notes
        metadataTags = game.tags.joined(separator: ", ")
        metadataArtworkPath = game.artworkPath ?? ""
        metadataStoreURL = game.storeURL ?? ""
        metadataRunnerPath = game.runnerPath ?? ""
        metadataBottlePath = game.bottlePath ?? ""
    }

    private func arcadeTextField(
        _ placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.roach(size: 12, weight: .medium, design: monospaced ? .monospaced : .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(13), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(0.74),
                                RoachPalette.shade.opacity(0.20),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(13), style: .continuous)
                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
            )
    }

    private func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseArtwork() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose game artwork"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
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
                            .font(.roach(size: 15, weight: .semibold))
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
                    .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                    )
            }
        }
    }
}
