import AppKit
import SwiftUI
import RoachNetDesign

struct RoachArchiveVaultPanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: RoachArchiveStore

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 16) {
                responsiveHeader
                searchBar

                if let errorLine = store.errorLine {
                    RoachNotice(title: "Roach's Archive notice", detail: errorLine)
                }

                if !store.results.isEmpty {
                    resultsGrid
                }

                if !store.vaultRecords.isEmpty {
                    importedShelf
                }

                torrentStrip
            }
        }
        .task(id: model.storagePath) {
            store.configure(storagePath: model.storagePath)
        }
    }

    private var responsiveHeader: some View {
        responsiveBar {
            RoachSectionHeader(
                "Roach's Archive",
                title: "Search the preservation lanes.",
                detail: "Bulk metadata, torrents, and local mirrors feed this shelf. The public website can keep its CAPTCHA."
            )
        } actions: {
            HStack(spacing: 8) {
                Button(store.isRefreshingTorrents ? "Refreshing..." : "Refresh Torrents") {
                    Task { await store.refreshTorrentManifest() }
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(store.isRefreshingTorrents)

                if let booksRootURL = store.booksRootURL {
                    Button("Reveal Books") {
                        NSWorkspace.shared.open(booksRootURL)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                RoachTag("\(store.metadataTorrentCount) metadata torrents", accent: RoachPalette.cyan)
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Title, author, ISBN, DOI, keyword", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await store.search() }
                    }

                Button(store.isSearching ? "Searching..." : "Search") {
                    Task { await store.search() }
                }
                .buttonStyle(RoachPrimaryButtonStyle())
                .disabled(store.isSearching)
            }

            HStack(spacing: 8) {
                RoachTag("API \(shortEndpoint)", accent: RoachPalette.green)
                RoachTag("Metadata \(shortMetadataPath)", accent: RoachPalette.bronze)
                Text(store.statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
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
                detail: "Files and metadata land in Vault. If a mirror only exposes metadata, RoachNet keeps the record ready for a local copy later."
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(store.vaultRecords.prefix(6)) { record in
                    Button {
                        if let filePath = record.filePath {
                            model.previewVaultFile(filePath)
                        } else {
                            model.previewVaultFile(record.metadataPath)
                        }
                    } label: {
                        VaultVirtualShelfCard(
                            title: record.result.title,
                            detail: record.result.authors.isEmpty ? record.status : record.result.authors.joined(separator: ", "),
                            pathLabel: record.filePath ?? record.metadataPath,
                            kindLabel: record.result.format?.uppercased() ?? "Book",
                            actionLabel: "Open in Vault",
                            accent: record.filePath == nil ? RoachPalette.bronze : RoachPalette.magenta,
                            fallbackSystemName: "book.closed.fill",
                            extraTags: [record.result.source, record.status]
                        )
                    }
                    .buttonStyle(RoachCardButtonStyle())
                }
            }
        }
    }

    private var torrentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoachSectionHeader(
                "Torrent Index",
                title: "Bulk lanes, not scrape jobs.",
                detail: store.torrentItems.isEmpty
                    ? "Refresh the torrent manifest to see Anna's metadata and data lanes."
                    : "Use these records to seed a local Roach's Archive mirror/API. RoachNet searches that mirror first."
            )

            if !store.torrentItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.torrentItems.filter(\.isMetadata).prefix(12)) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.groupName)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RoachPalette.cyan)
                                    .lineLimit(1)
                                Text(item.displayName)
                                    .font(.system(size: 12, weight: .medium))
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
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.58))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
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
}

private struct RoachArchiveResultCard: View {
    let result: RoachArchiveSearchResult
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RoachPalette.magenta)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 5) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                    if !result.authors.isEmpty {
                        Text(result.authors.joined(separator: ", "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
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
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            HStack {
                Text(result.downloadURL == nil ? "Metadata first" : "File available")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(result.downloadURL == nil ? RoachPalette.bronze : RoachPalette.green)
                Spacer()
                Button(result.downloadURL == nil ? "Add Record" : "Add to Vault") {
                    onAdd()
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
    }
}
