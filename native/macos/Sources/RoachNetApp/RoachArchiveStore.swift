import Foundation

struct RoachArchiveSearchResult: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var authors: [String]
    var year: Int?
    var language: String?
    var format: String?
    var source: String
    var sourceID: String?
    var description: String?
    var fileSize: String?
    var downloadURL: String?
    var metadataURL: String?
    var torrentURL: String?
    var mirrorHint: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case authors
        case author
        case year
        case language
        case format
        case extensionValue = "extension"
        case source
        case sourceID
        case sourceId
        case source_id
        case description
        case fileSize
        case file_size
        case downloadURL
        case downloadUrl
        case download_url
        case fileURL
        case fileUrl
        case file_url
        case metadataURL
        case metadataUrl
        case metadata_url
        case torrentURL
        case torrentUrl
        case torrent_url
        case magnetLink
        case magnet_link
        case mirrorHint
        case mirror_hint
    }

    init(
        id: String,
        title: String,
        authors: [String] = [],
        year: Int? = nil,
        language: String? = nil,
        format: String? = nil,
        source: String,
        sourceID: String? = nil,
        description: String? = nil,
        fileSize: String? = nil,
        downloadURL: String? = nil,
        metadataURL: String? = nil,
        torrentURL: String? = nil,
        mirrorHint: String? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.language = language
        self.format = format
        self.source = source
        self.sourceID = sourceID
        self.description = description
        self.fileSize = fileSize
        self.downloadURL = downloadURL
        self.metadataURL = metadataURL
        self.torrentURL = torrentURL
        self.mirrorHint = mirrorHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func stringValue(_ keys: CodingKeys...) throws -> String? {
            for key in keys {
                if let value = try container.decodeIfPresent(String.self, forKey: key)?.nilIfBlankForArchive {
                    return value
                }
            }
            return nil
        }

        title = try stringValue(.title) ?? "Untitled work"
        id = try stringValue(.id, .sourceID, .sourceId, .source_id) ?? UUID().uuidString
        if let decodedAuthors = try container.decodeIfPresent([String].self, forKey: .authors) {
            authors = decodedAuthors.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } else if let author = try stringValue(.author) {
            authors = [author]
        } else {
            authors = []
        }
        if let decodedYear = try? container.decodeIfPresent(Int.self, forKey: .year) {
            year = decodedYear
        } else if let yearString = try container.decodeIfPresent(String.self, forKey: .year) {
            year = Int(yearString.filter(\.isNumber).prefix(4))
        } else {
            year = nil
        }
        language = try stringValue(.language)
        format = try stringValue(.format, .extensionValue)
        source = try stringValue(.source) ?? "Bulk metadata"
        sourceID = try stringValue(.sourceID, .sourceId, .source_id)
        description = try stringValue(.description)
        fileSize = try stringValue(.fileSize, .file_size)
        downloadURL = try stringValue(.downloadURL, .downloadUrl, .download_url, .fileURL, .fileUrl, .file_url)
        metadataURL = try stringValue(.metadataURL, .metadataUrl, .metadata_url)
        torrentURL = try stringValue(.torrentURL, .torrentUrl, .torrent_url, .magnetLink, .magnet_link)
        mirrorHint = try stringValue(.mirrorHint, .mirror_hint)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(authors, forKey: .authors)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(sourceID, forKey: .sourceID)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(metadataURL, forKey: .metadataURL)
        try container.encodeIfPresent(torrentURL, forKey: .torrentURL)
        try container.encodeIfPresent(mirrorHint, forKey: .mirrorHint)
    }
}

struct RoachArchiveTorrentItem: Identifiable, Codable, Hashable {
    var id: String { btih ?? url }
    var url: String
    var displayName: String
    var groupName: String
    var isMetadata: Bool
    var magnetLink: String?
    var btih: String?
    var dataSize: Int64?
    var seeders: Int?
    var leechers: Int?
    var addedAt: String?

    private enum CodingKeys: String, CodingKey {
        case url
        case displayName = "display_name"
        case groupName = "group_name"
        case isMetadata = "is_metadata"
        case magnetLink = "magnet_link"
        case btih
        case dataSize = "data_size"
        case seeders
        case leechers
        case addedAt = "added_to_torrents_list_at"
    }
}

struct RoachArchiveVaultRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var result: RoachArchiveSearchResult
    var filePath: String?
    var metadataPath: String
    var importedAt: Date
    var status: String

    init(
        id: UUID = UUID(),
        result: RoachArchiveSearchResult,
        filePath: String?,
        metadataPath: String,
        importedAt: Date = Date(),
        status: String
    ) {
        self.id = id
        self.result = result
        self.filePath = filePath
        self.metadataPath = metadataPath
        self.importedAt = importedAt
        self.status = status
    }
}

@MainActor
final class RoachArchiveStore: ObservableObject {
    @Published var query = ""
    @Published var endpointURLString: String {
        didSet { UserDefaults.standard.set(endpointURLString, forKey: Self.endpointKey) }
    }
    @Published var metadataDirectoryPath: String {
        didSet { UserDefaults.standard.set(metadataDirectoryPath, forKey: Self.metadataDirectoryKey) }
    }
    @Published private(set) var results: [RoachArchiveSearchResult] = []
    @Published private(set) var torrentItems: [RoachArchiveTorrentItem] = []
    @Published private(set) var vaultRecords: [RoachArchiveVaultRecord] = []
    @Published var statusLine = "Roach's Archive is idle."
    @Published var errorLine: String?
    @Published var isSearching = false
    @Published var isImporting = false
    @Published var isRefreshingTorrents = false

    private static let endpointKey = "roachnet.roacharchive.endpoint"
    private static let metadataDirectoryKey = "roachnet.roacharchive.metadata-directory"
    private let fileManager = FileManager.default
    private var storageRoot: URL?

    init() {
        endpointURLString = UserDefaults.standard.string(forKey: Self.endpointKey) ?? "http://127.0.0.1:38221"
        metadataDirectoryPath = UserDefaults.standard.string(forKey: Self.metadataDirectoryKey) ?? ""
    }

    var metadataTorrentCount: Int {
        torrentItems.filter(\.isMetadata).count
    }

    var booksRootURL: URL? {
        storageRoot?.appendingPathComponent("Books", isDirectory: true)
    }

    func configure(storagePath: String) {
        let root = URL(fileURLWithPath: storagePath, isDirectory: true)
            .appendingPathComponent("RoachArchive", isDirectory: true)
        guard root != storageRoot else { return }

        storageRoot = root
        do {
            try fileManager.createDirectory(at: root.appendingPathComponent("Books", isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("Metadata", isDirectory: true), withIntermediateDirectories: true)
            if metadataDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadataDirectoryPath = root.appendingPathComponent("Metadata", isDirectory: true).path
            }
            loadCachedTorrents()
            loadVaultRecords()
        } catch {
            errorLine = "Roach's Archive storage failed: \(error.localizedDescription)"
        }
    }

    func search() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            errorLine = "Search needs a title, author, ISBN, DOI, or keyword."
            return
        }

        isSearching = true
        errorLine = nil
        defer { isSearching = false }

        if let endpointURL = normalizedEndpointURL(path: "/api/books/search") {
            do {
                let apiResults = try await searchAPI(endpointURL: endpointURL, query: trimmedQuery)
                results = apiResults
                statusLine = "Found \(apiResults.count) result\(apiResults.count == 1 ? "" : "s") from Roach's Archive API."
                return
            } catch {
                statusLine = "Local API unavailable. Searching staged metadata."
            }
        }

        do {
            let localResults = try searchLocalMetadata(query: trimmedQuery, limit: 40)
            results = localResults
            statusLine = localResults.isEmpty
                ? "No local metadata matches yet. Refresh torrents or point RoachNet at a Roach's Archive API."
                : "Found \(localResults.count) local metadata result\(localResults.count == 1 ? "" : "s")."
        } catch {
            errorLine = "Metadata search failed: \(error.localizedDescription)"
        }
    }

    func refreshTorrentManifest() async {
        guard let storageRoot else {
            errorLine = "Storage is not configured."
            return
        }

        isRefreshingTorrents = true
        errorLine = nil
        defer { isRefreshingTorrents = false }

        do {
            let url = URL(string: "https://annas-archive.gl/dyn/torrents.json")!
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "RoachArchive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Torrent manifest returned HTTP \(http.statusCode)."])
            }
            let decoder = JSONDecoder()
            let items = try decoder.decode([RoachArchiveTorrentItem].self, from: data)
            torrentItems = items
                .filter { !$0.url.isEmpty }
                .sorted { lhs, rhs in
                    if lhs.isMetadata != rhs.isMetadata {
                        return lhs.isMetadata && !rhs.isMetadata
                    }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            try data.write(to: storageRoot.appendingPathComponent("torrents.json"), options: .atomic)
            statusLine = "Loaded \(torrentItems.count) Anna's Archive torrent records, including \(metadataTorrentCount) metadata lanes."
        } catch {
            errorLine = "Torrent refresh failed: \(error.localizedDescription)"
        }
    }

    func addToVault(_ result: RoachArchiveSearchResult) async -> URL? {
        guard let booksRootURL else {
            errorLine = "Storage is not configured."
            return nil
        }

        isImporting = true
        errorLine = nil
        defer { isImporting = false }

        do {
            try fileManager.createDirectory(at: booksRootURL, withIntermediateDirectories: true)
            let metadataURL = booksRootURL.appendingPathComponent("\(result.safeBaseName).metadata.json")
            let metadataData = try JSONEncoder.archiveEncoder.encode(result)
            try metadataData.write(to: metadataURL, options: .atomic)

            if let rawDownload = result.downloadURL?.nilIfBlankForArchive,
               let sourceURL = URL(string: rawDownload) {
                let destinationURL = try await download(sourceURL: sourceURL, result: result, booksRootURL: booksRootURL)
                let record = RoachArchiveVaultRecord(
                    result: result,
                    filePath: destinationURL.path,
                    metadataPath: metadataURL.path,
                    status: "Book added"
                )
                upsertRecord(record)
                statusLine = "Added \(result.title) to Vault."
                return destinationURL
            }

            let record = RoachArchiveVaultRecord(
                result: result,
                filePath: nil,
                metadataPath: metadataURL.path,
                status: "Metadata added"
            )
            upsertRecord(record)
            statusLine = "Saved metadata for \(result.title). Add a mirror/download URL through Roach's Archive API to fetch the file."
            return metadataURL
        } catch {
            errorLine = "Vault import failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func searchAPI(endpointURL: URL, query: String) async throws -> [RoachArchiveSearchResult] {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "q", value: query))
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw NSError(domain: "RoachArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Roach's Archive endpoint."])
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "RoachArchive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Roach's Archive API returned HTTP \(http.statusCode)."])
        }

        let decoder = JSONDecoder.archiveDecoder
        if let wrapped = try? decoder.decode(RoachArchiveSearchResponse.self, from: data) {
            return wrapped.results
        }
        return try decoder.decode([RoachArchiveSearchResult].self, from: data)
    }

    private func searchLocalMetadata(query: String, limit: Int) throws -> [RoachArchiveSearchResult] {
        let metadataPath = NSString(string: metadataDirectoryPath).expandingTildeInPath
        let metadataURL = URL(fileURLWithPath: metadataPath, isDirectory: true)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw NSError(domain: "RoachArchive", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metadata folder does not exist: \(metadataURL.path)"])
        }

        let queryLower = query.lowercased()
        let urls = metadataFileURLs(in: metadataURL)
        var matches: [RoachArchiveSearchResult] = []
        var skippedCompressed = false

        for url in urls {
            if url.pathExtension.lowercased() == "zst" {
                skippedCompressed = true
                continue
            }
            try scanJSONLines(at: url, queryLower: queryLower, limit: limit, matches: &matches)
            if matches.count >= limit {
                break
            }
        }

        if skippedCompressed && matches.isEmpty {
            statusLine = "Found compressed metadata. Use the Roach's Archive API or decompress .zst JSONL into the metadata folder for direct in-app search."
        }

        return matches
    }

    private func metadataFileURLs(in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".jsonl") || name.hasSuffix(".ndjson") || name.hasSuffix(".json") || name.hasSuffix(".jsonl.zst") {
                urls.append(url)
            }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func scanJSONLines(
        at url: URL,
        queryLower: String,
        limit: Int,
        matches: inout [RoachArchiveSearchResult]
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while matches.count < limit {
            guard let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty else {
                if !buffer.isEmpty {
                    consumeMetadataLine(buffer, sourceURL: url, queryLower: queryLower, matches: &matches)
                }
                break
            }

            buffer.append(chunk)
            while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                consumeMetadataLine(line, sourceURL: url, queryLower: queryLower, matches: &matches)
                buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                if matches.count >= limit {
                    return
                }
            }
        }
    }

    private func consumeMetadataLine(
        _ line: Data,
        sourceURL: URL,
        queryLower: String,
        matches: inout [RoachArchiveSearchResult]
    ) {
        guard !line.isEmpty,
              let lineText = String(data: line, encoding: .utf8),
              lineText.lowercased().contains(queryLower),
              let data = lineText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = RoachArchiveSearchResult.fromFlexibleMetadata(object, sourceURL: sourceURL, queryLower: queryLower)
        else {
            return
        }
        matches.append(result)
    }

    private func download(sourceURL: URL, result: RoachArchiveSearchResult, booksRootURL: URL) async throws -> URL {
        if sourceURL.isFileURL {
            let destination = booksRootURL.appendingPathComponent(result.fileName(using: sourceURL.pathExtension))
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "RoachArchive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Download returned HTTP \(http.statusCode)."])
        }
        let extensionValue = sourceURL.pathExtension.nilIfBlankForArchive ?? result.format?.lowercased().nilIfBlankForArchive ?? "book"
        let destination = booksRootURL.appendingPathComponent(result.fileName(using: extensionValue))
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func upsertRecord(_ record: RoachArchiveVaultRecord) {
        vaultRecords.removeAll { $0.result.id == record.result.id }
        vaultRecords.insert(record, at: 0)
        saveVaultRecords()
    }

    private func loadCachedTorrents() {
        guard let storageRoot else { return }
        let url = storageRoot.appendingPathComponent("torrents.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RoachArchiveTorrentItem].self, from: data)
        else {
            torrentItems = []
            return
        }
        torrentItems = items
    }

    private func vaultRecordsURL() -> URL? {
        storageRoot?.appendingPathComponent("vault-records.json")
    }

    private func loadVaultRecords() {
        guard let url = vaultRecordsURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder.archiveDecoder.decode([RoachArchiveVaultRecord].self, from: data)
        else {
            vaultRecords = []
            return
        }
        vaultRecords = records
    }

    private func saveVaultRecords() {
        guard let url = vaultRecordsURL(),
              let data = try? JSONEncoder.archiveEncoder.encode(vaultRecords)
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func normalizedEndpointURL(path: String) -> URL? {
        let trimmed = endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        if components.scheme == nil {
            components.scheme = "http"
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = "/" + requestedPath
        } else if !basePath.hasSuffix(requestedPath) {
            components.path = "/" + basePath + "/" + requestedPath
        }
        return components.url
    }
}

private struct RoachArchiveSearchResponse: Decodable {
    var results: [RoachArchiveSearchResult]
}

private extension RoachArchiveSearchResult {
    var safeBaseName: String {
        let author = authors.first.map { "-\($0)" } ?? ""
        return "\(title)\(author)"
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted)
            .joined(separator: "-")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlankForArchive ?? "book-\(id)"
    }

    func fileName(using extensionValue: String) -> String {
        let ext = extensionValue.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return ext.isEmpty ? safeBaseName : "\(safeBaseName).\(ext)"
    }

    static func fromFlexibleMetadata(
        _ object: [String: Any],
        sourceURL: URL,
        queryLower: String
    ) -> RoachArchiveSearchResult? {
        let flattened = object.archiveFlattenedStrings.joined(separator: " ")
        guard flattened.lowercased().contains(queryLower) else { return nil }

        let title = object.archiveString(for: ["title", "name", "display_name", "original_title", "book_title"]) ?? "Untitled work"
        let id = object.archiveString(for: ["id", "aacid", "md5", "sha256", "doi", "isbn13", "isbn", "source_id"])
            ?? "\(sourceURL.lastPathComponent)-\(abs(flattened.hashValue))"
        let authors = object.archiveStringArray(for: ["authors", "author", "creator", "creators"])
        let year = object.archiveInt(for: ["year", "publish_year", "publication_year"])
        let format = object.archiveString(for: ["format", "extension", "filetype", "file_type"])
        let source = object.archiveString(for: ["source", "collection", "dataset", "record_source"]) ?? sourceURL.deletingPathExtension().lastPathComponent
        let size = object.archiveString(for: ["file_size", "filesize", "size", "size_bytes"])
        let downloadURL = object.archiveString(for: ["download_url", "downloadURL", "file_url", "fileURL", "direct_url", "directURL"])
        let metadataURL = object.archiveString(for: ["metadata_url", "metadataURL", "annas_archive_url", "aa_url", "url"])
        let torrentURL = object.archiveString(for: ["torrent_url", "torrentURL", "magnet_link", "magnet"])

        return RoachArchiveSearchResult(
            id: id,
            title: title,
            authors: authors,
            year: year,
            language: object.archiveString(for: ["language", "lang"]),
            format: format,
            source: source,
            sourceID: object.archiveString(for: ["source_id", "sourceID"]),
            description: object.archiveString(for: ["description", "comment", "notes"]),
            fileSize: size,
            downloadURL: downloadURL,
            metadataURL: metadataURL,
            torrentURL: torrentURL,
            mirrorHint: "Matched \(sourceURL.lastPathComponent)"
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    var archiveFlattenedStrings: [String] {
        flatMap { key, value -> [String] in
            if let string = value as? String {
                return [key, string]
            }
            if let number = value as? NSNumber {
                return [key, number.stringValue]
            }
            if let array = value as? [Any] {
                return [key] + array.compactMap { $0 as? String }
            }
            if let nested = value as? [String: Any] {
                return [key] + nested.archiveFlattenedStrings
            }
            return [key]
        }
    }

    func archiveString(for keys: [String]) -> String? {
        for key in keys {
            if let string = self[key] as? String, let value = string.nilIfBlankForArchive {
                return value
            }
            if let number = self[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    func archiveStringArray(for keys: [String]) -> [String] {
        for key in keys {
            if let array = self[key] as? [String] {
                return array.compactMap(\.nilIfBlankForArchive)
            }
            if let string = self[key] as? String, let value = string.nilIfBlankForArchive {
                return value
                    .split(separator: ";")
                    .flatMap { $0.split(separator: ",") }
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
        return []
    }

    func archiveInt(for keys: [String]) -> Int? {
        for key in keys {
            if let intValue = self[key] as? Int {
                return intValue
            }
            if let string = self[key] as? String,
               let intValue = Int(string.filter(\.isNumber).prefix(4)) {
                return intValue
            }
        }
        return nil
    }
}

private extension JSONEncoder {
    static var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nilIfBlankForArchive: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
