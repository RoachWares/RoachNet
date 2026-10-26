import AppKit
import RoachNetDesign
import SwiftUI
import UniformTypeIdentifiers

struct RoachArchiveVaultPanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: RoachArchiveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            responsiveHeader
            archiveSearchDock

            if let errorLine = store.errorLine {
                RoachNotice(title: "Roach's Archive notice", detail: errorLine)
            }

            if !store.results.isEmpty {
                resultsGrid
            }

            if !store.vaultRecords.isEmpty {
                importedShelf
            } else if store.results.isEmpty {
                archiveEmptyState
            }

            torrentStrip
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(22), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.88),
                            RoachPalette.panel.opacity(0.82),
                            RoachPalette.shade.opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(22), style: .continuous)
                .stroke(RoachPalette.ink.opacity(0.07), lineWidth: RoachMetrics.line(1))
                .allowsHitTesting(false)
        )
        .shadow(color: RoachPalette.shadow.opacity(0.10), radius: 14, x: 0, y: 8)
        .task(id: model.storagePath) {
            store.configure(storagePath: model.storagePath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var responsiveHeader: some View {
        responsiveBar {
            RoachSectionHeader(
                "Roach's Archive",
                title: "Find books and papers, then keep them in the Vault.",
                detail: nil
            )
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    archiveRefreshButton

                    if let booksRootURL = store.booksRootURL {
                        Button {
                            NSWorkspace.shared.open(booksRootURL)
                        } label: {
                            Label("Open books folder", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    RoachTag(
                        "\(RoachCopy.count(store.metadataTorrentCount, "metadata torrent"))", accent: RoachPalette.cyan)
                }

                VStack(alignment: .leading, spacing: 8) {
                    archiveRefreshButton

                    if let booksRootURL = store.booksRootURL {
                        Button {
                            NSWorkspace.shared.open(booksRootURL)
                        } label: {
                            Label("Open books folder", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    RoachTag(
                        "\(RoachCopy.count(store.metadataTorrentCount, "metadata torrent"))", accent: RoachPalette.cyan)
                }
            }
        }
    }

    private var archiveSearchDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBar
            archiveStatusRow
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.94),
                            RoachPalette.panel.opacity(0.88),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(RoachPalette.borderStrong.opacity(0.82), lineWidth: RoachMetrics.line(1))
        )
        .shadow(color: RoachPalette.shadow.opacity(0.10), radius: 14, x: 0, y: 8)
        .layoutPriority(1)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    archiveSearchField
                        .frame(minWidth: 260)
                        .layoutPriority(2)
                    archiveSearchButton
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    archiveSearchField
                    archiveSearchButton
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var archiveStatusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        archiveStatusPills
                    }
                }
                .frame(maxWidth: 320)
                archiveStatusText
            }

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        archiveStatusPills
                    }
                }
                archiveStatusText
            }
        }
    }

    @ViewBuilder
    private var archiveStatusPills: some View {
        RoachTag("API \(shortEndpoint)", accent: RoachPalette.green)
        RoachTag("Local metadata", accent: RoachPalette.bronze)
            .help(shortMetadataPath)
    }

    private var archiveStatusText: some View {
        Text(store.statusLine)
            .font(.roach(size: 12, weight: .medium))
            .foregroundStyle(RoachPalette.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var archiveSearchField: some View {
        TextField("Title, author, ISBN, DOI, keyword", text: $store.query)
            .textFieldStyle(.plain)
            .font(.roach(size: 13, weight: .medium))
            .foregroundStyle(RoachPalette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .fill(RoachPalette.shade.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
            )
            .onSubmit {
                Task { await store.search() }
            }
    }

    private var archiveSearchButton: some View {
        Button {
            Task { await store.search() }
        } label: {
            Label(store.isSearching ? "Searching" : "Search", systemImage: "magnifyingglass")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachPrimaryButtonStyle())
        .disabled(store.isSearching)
        .accessibilityLabel("Search Roach's Archive")
    }

    private var archiveRefreshButton: some View {
        Button {
            Task { await store.refreshTorrentManifest() }
        } label: {
            Label(store.isRefreshingTorrents ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
        .disabled(store.isRefreshingTorrents || !store.hasTorrentListAddress)
        .help(store.hasTorrentListAddress ? "Load the torrent list" : "Add a torrent list address in Settings first")
    }

    private var archiveEmptyState: some View {
        RoachSpotlightPanel(accent: RoachPalette.cyan) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    archiveEmptyStateCopy
                    Spacer(minLength: 12)
                    archiveEmptyStateActions
                }

                VStack(alignment: .leading, spacing: 14) {
                    archiveEmptyStateCopy
                    archiveEmptyStateActions
                }
            }
        }
    }

    private var archiveEmptyStateCopy: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.roach(size: 22, weight: .semibold))
                .foregroundStyle(RoachPalette.cyan)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                        .fill(RoachPalette.panelGlass)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(
                    store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Search results show up here." : "No matches for that search."
                )
                .font(.roach(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                Text(
                    store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Search by title, author, ISBN, DOI or keyword."
                        : "Try a shorter title or author name, or search by ISBN or DOI."
                )
                .font(.roach(size: 13, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var archiveEmptyStateActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                archiveSearchButton
                archiveRefreshButton
            }

            VStack(alignment: .leading, spacing: 8) {
                archiveSearchButton
                archiveRefreshButton
            }
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(store.results) { result in
                RoachArchiveResultCard(result: result) {
                    Task {
                        if let url = await store.addToVault(result) {
                            model.previewVaultURL(url)
                            await model.refreshRuntimeState(silently: true)
                        }
                    }
                }
                .disabled(store.isImporting)
            }
        }
    }

    private var importedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoachSectionHeader(
                "Bookshelf",
                title: "Recently added",
                detail: nil
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(store.vaultRecords.prefix(6)) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            store.markOpened(record.id)
                            if let filePath = record.filePath {
                                model.previewVaultFile(filePath)
                            } else {
                                model.previewVaultFile(record.metadataPath)
                            }
                        } label: {
                            VaultVirtualShelfCard(
                                title: record.result.title,
                                detail: record.result.authors.isEmpty
                                    ? record.status : record.result.authors.joined(separator: ", "),
                                pathLabel: record.filePath ?? record.metadataPath,
                                kindLabel: record.result.format?.uppercased() ?? "Book",
                                actionLabel: "Open in Vault",
                                accent: record.filePath == nil ? RoachPalette.bronze : RoachPalette.magenta,
                                fallbackSystemName: "book.closed.fill",
                                extraTags: archiveRecordTags(record)
                            )
                        }
                        .buttonStyle(RoachCardButtonStyle())

                        ProgressView(value: record.readingProgress)
                            .progressViewStyle(.linear)
                            .tint(record.readingProgress >= 1 ? RoachPalette.green : RoachPalette.magenta)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                archiveRecordActions(record)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                archiveRecordActions(record)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func archiveRecordActions(_ record: RoachArchiveVaultRecord) -> some View {
        if record.filePath == nil {
            Button {
                if let url = chooseBookFile(), let attached = store.attachLocalBook(url, to: record.id) {
                    model.previewVaultURL(attached)
                }
            } label: {
                Label("Attach…", systemImage: "paperclip")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }

        Button {
            store.updateReadingProgress(0.25, for: record.id)
        } label: {
            Label("25%", systemImage: "bookmark")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())

        Button {
            store.updateReadingProgress(1, for: record.id)
        } label: {
            Label("Read", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private func archiveRecordTags(_ record: RoachArchiveVaultRecord) -> [String] {
        var tags = [record.result.source, record.status]
        if record.readingProgress > 0 {
            tags.append("\(Int(record.readingProgress * 100))%")
        }
        tags.append(contentsOf: record.tags.prefix(2))
        return tags
    }

    private var torrentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoachSectionHeader(
                "Torrent index",
                title: "Metadata torrents from your torrent list.",
                detail: store.torrentItems.isEmpty
                    ? (store.hasTorrentListAddress
                        ? "Refresh to load the torrent list."
                        : "Add a torrent list address in Settings, under Roach's Archive, then refresh.")
                    : "These torrents hold the metadata that local search reads. File downloads go through a Roach's Archive API."
            )

            if !store.torrentItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.torrentItems.filter(\.isMetadata).prefix(12)) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.groupName)
                                    .font(.roach(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.cyan)
                                    .lineLimit(1)
                                Text(item.displayName)
                                    .font(.roach(size: 12, weight: .medium))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    RoachTag("\(item.seeders ?? 0) seed", accent: RoachPalette.green)
                                    if let addedAt = item.addedAt {
                                        RoachTag(addedAt, accent: RoachPalette.bronze)
                                    }
                                }
                            }
                            .frame(width: 230, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.58))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                        }
                    }
                }
            }
        }
    }

    private var shortEndpoint: String {
        store.endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "off"
            : store.endpointURLString.replacingOccurrences(of: "http://", with: "")
    }

    private var shortMetadataPath: String {
        let path = store.metadataDirectoryPath
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func responsiveBar<Lead: View, Actions: View>(
        @ViewBuilder lead: () -> Lead,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                lead()
                Spacer(minLength: 12)
                actions()
            }

            VStack(alignment: .leading, spacing: 12) {
                lead()
                actions()
            }
        }
    }

    private func chooseBookFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Attach a local book or document"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .pdf,
            UTType(filenameExtension: "epub") ?? .data,
            UTType(filenameExtension: "mobi") ?? .data,
            UTType(filenameExtension: "azw") ?? .data,
            UTType(filenameExtension: "azw3") ?? .data,
            UTType(filenameExtension: "cbz") ?? .zip,
            UTType(filenameExtension: "cbr") ?? .data,
            .plainText,
            .data,
        ]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct RoachArchiveResultCard: View {
    let result: RoachArchiveSearchResult
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.roach(size: 18, weight: .semibold))
                    .foregroundStyle(RoachPalette.magenta)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 5) {
                    Text(result.title)
                        .font(.roach(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if !result.authors.isEmpty {
                        Text(result.authors.joined(separator: ", "))
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            HStack(spacing: 8) {
                RoachTag(result.source, accent: RoachPalette.cyan)
                if let format = result.format {
                    RoachTag(format.uppercased(), accent: RoachPalette.bronze)
                }
                if let year = result.year {
                    RoachTag("\(year)", accent: RoachPalette.green)
                }
            }

            if let description = result.description {
                Text(description)
                    .font(.roach(size: 12, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            HStack {
                Text(result.downloadURL == nil ? "Metadata only" : "File available")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(result.downloadURL == nil ? RoachPalette.bronze : RoachPalette.green)
                Spacer()
                Button(result.downloadURL == nil ? "Add record" : "Add to Vault") {
                    onAdd()
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }
}
