import Foundation

public struct RoachBrainMemory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var summary: String
    public var body: String
    public var source: String
    public var tags: [String]
    public var pinned: Bool
    public var createdAt: String
    public var lastAccessedAt: String

    public init(
        id: String,
        title: String,
        summary: String,
        body: String,
        source: String,
        tags: [String],
        pinned: Bool,
        createdAt: String,
        lastAccessedAt: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.body = body
        self.source = source
        self.tags = tags
        self.pinned = pinned
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

public struct RoachBrainMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let memory: RoachBrainMemory
    public let score: Double
    public let matchedTags: [String]

    public init(memory: RoachBrainMemory, score: Double, matchedTags: [String]) {
        self.id = memory.id
        self.memory = memory
        self.score = score
        self.matchedTags = matchedTags
    }
}

public struct RoachBrainWikiStatus: Codable, Hashable, Sendable {
    public let rootPath: String
    public let pageCount: Int
    public let memoryCount: Int
    public let updatedAt: String?
    public let indexPath: String
    public let logPath: String

    public init(
        rootPath: String,
        pageCount: Int,
        memoryCount: Int,
        updatedAt: String?,
        indexPath: String,
        logPath: String
    ) {
        self.rootPath = rootPath
        self.pageCount = pageCount
        self.memoryCount = memoryCount
        self.updatedAt = updatedAt
        self.indexPath = indexPath
        self.logPath = logPath
    }
}

public struct RoachBrainWikiPage: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let slug: String
    public let summary: String
    public let tags: [String]
    public let source: String
    public let path: String
}

public enum RoachBrainWikiStore {
    private static let schemaFileName = "AGENTS.md"
    private static let indexFileName = "index.md"
    private static let logFileName = "log.md"
    private static let manifestFileName = "manifest.json"

    public static func wikiRootURL(storagePath: String) -> URL {
        URL(fileURLWithPath: RoachNetDeveloperPaths.roachBrainRoot(storagePath: storagePath))
            .appendingPathComponent("wiki", isDirectory: true)
    }

    public static func status(storagePath: String) -> RoachBrainWikiStatus {
        let root = wikiRootURL(storagePath: storagePath)
        let manifestURL = root.appendingPathComponent(manifestFileName)
        let decoded = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(WikiManifest.self, from: $0) }

        return RoachBrainWikiStatus(
            rootPath: root.path,
            pageCount: decoded?.pages.count ?? countMarkdownPages(in: pagesURL(root: root)),
            memoryCount: decoded?.memoryCount ?? 0,
            updatedAt: decoded?.updatedAt,
            indexPath: root.appendingPathComponent(indexFileName).path,
            logPath: root.appendingPathComponent(logFileName).path
        )
    }

    public static func rebuildFromMemories(storagePath: String, memories: [RoachBrainMemory]) throws -> RoachBrainWikiStatus {
        try RoachNetDeveloperPaths.ensureWorkspaceDirectories(storagePath: storagePath)

        let root = wikiRootURL(storagePath: storagePath)
        let rawRoot = root.appendingPathComponent("raw", isDirectory: true)
        let pageRoot = pagesURL(root: root)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: pageRoot.path) {
            try fileManager.removeItem(at: pageRoot)
        }
        try fileManager.createDirectory(at: pageRoot, withIntermediateDirectories: true)

        let sortedMemories = memories.sorted { lhs, rhs in
            lhs.lastAccessedAt > rhs.lastAccessedAt
        }
        let rawData = try JSONEncoder.pretty.encode(sortedMemories)
        try rawData.write(to: rawRoot.appendingPathComponent("memories.json"), options: [.atomic])
        try schemaText().write(
            to: root.appendingPathComponent(schemaFileName),
            atomically: true,
            encoding: .utf8
        )

        var usedSlugs = Set<String>()
        let pages = try sortedMemories.map { memory -> RoachBrainWikiPage in
            let baseSlug = slug(for: memory.title)
            let pageSlug = uniqueSlug(baseSlug.isEmpty ? "memory" : baseSlug, usedSlugs: &usedSlugs)
            let pageURL = pageRoot.appendingPathComponent("\(pageSlug).md")
            let page = RoachBrainWikiPage(
                id: memory.id,
                title: memory.title,
                slug: pageSlug,
                summary: memory.summary,
                tags: memory.tags,
                source: memory.source,
                path: pageURL.path
            )
            try pageText(for: memory, slug: pageSlug)
                .write(to: pageURL, atomically: true, encoding: .utf8)
            return page
        }

        let timestamp = timestampString(from: Date())
        try indexText(pages: pages, updatedAt: timestamp)
            .write(to: root.appendingPathComponent(indexFileName), atomically: true, encoding: .utf8)
        try appendLogEntry(root: root, timestamp: timestamp, pageCount: pages.count)

        let manifest = WikiManifest(
            updatedAt: timestamp,
            memoryCount: sortedMemories.count,
            pages: pages
        )
        try JSONEncoder.pretty.encode(manifest)
            .write(to: root.appendingPathComponent(manifestFileName), options: [.atomic])

        return status(storagePath: storagePath)
    }

    public static func contextBlock(storagePath: String, query: String, matches: [RoachBrainMatch]) -> String {
        let root = wikiRootURL(storagePath: storagePath)
        let status = status(storagePath: storagePath)
        guard status.pageCount > 0 else { return "" }

        let directPagePaths = matches.compactMap { match -> String? in
            let candidate = pagesURL(root: root).appendingPathComponent("\(slug(for: match.memory.title)).md")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
        }

        let queryTokens = tokenSet(from: query)
        let discoveredPagePaths = (try? FileManager.default.contentsOfDirectory(
            at: pagesURL(root: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> (URL, Int)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let hits = queryTokens.intersection(tokenSet(from: text)).count
                return hits > 0 ? (url, hits) : nil
            }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }
            .map { $0.0.path }
            ?? []

        var seen = Set<String>()
        let selectedPaths = (directPagePaths + discoveredPagePaths).filter { seen.insert($0).inserted }.prefix(3)
        guard !selectedPaths.isEmpty else {
            return """
            RoachBrain compiled wiki:
            - Pages: \(status.pageCount)
            - Index: \(status.indexPath)
            - Pattern: read the index first, then use the linked pages as the durable local memory layer.
            """
        }

        let excerpts = selectedPaths.compactMap { path -> String? in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return """
            [[pages/\(title)]]
            \(normalizedExcerpt(text, maxCharacters: 720))
            """
        }

        return """
        RoachBrain compiled wiki:
        - Pages: \(status.pageCount)
        - Index: \(status.indexPath)
        - Log: \(status.logPath)
        - AutoResearch discipline: propose one bounded experiment, name one measurable signal, keep or discard the result in the log.

        Relevant wiki pages:
        \(excerpts.joined(separator: "\n\n"))
        """
    }

    public static func researchProtocolBlock() -> String {
        """
        RoachBrain research protocol:
        1. Work like a small AutoResearch loop: one hypothesis, one bounded change, one measurable signal.
        2. Prefer the compiled RoachBrain wiki over raw recall when the question needs project history.
        3. Record useful conclusions back into RoachBrain so the next thread starts from compiled knowledge, not from scratch.
        4. Keep raw sources untouched and treat generated wiki pages as revisable synthesis.
        """
    }

    public static func operatorProtocolBlock() -> String {
        """
        RoachClaw operator protocol:
        1. Answer normal conversation normally. Treat the user request as a task only when it asks you to build, fix, research, verify, automate, or ship.
        2. State the concrete assumption you are using only when it affects the outcome.
        3. Use the smallest effective sequence: inspect context, choose the next action, make the change or give the exact patch, then name the verification signal.
        4. Prefer working facts from the local app context, RoachBrain wiki, active file, and vault before relying on general memory.
        5. Never claim a command ran, a file changed, or a release shipped unless the surrounding RoachNet tool lane actually performed that action.
        6. Preserve the user's chosen model, voice, memory, context permissions, and chat style. The task loop is an added operating mode, not a replacement for basic chat.
        7. If you cannot perform an action directly, return the exact command, file path, or UI action needed so the Dev lane or command bar can execute it.
        """
    }

    private struct WikiManifest: Codable {
        let updatedAt: String
        let memoryCount: Int
        let pages: [RoachBrainWikiPage]
    }

    private static func pagesURL(root: URL) -> URL {
        root.appendingPathComponent("pages", isDirectory: true)
    }

    private static func schemaText() -> String {
        """
        # RoachBrain Wiki Agent Rules

        RoachBrain keeps a local, Markdown-first knowledge layer for RoachClaw.

        ## Layers

        - `raw/` is the immutable source layer. Do not edit source snapshots by hand.
        - `pages/` is the compiled wiki. Each page should be readable in Obsidian and linkable with `[[wikilinks]]`.
        - `index.md` is the navigation layer. Read it before answering questions that need memory.
        - `log.md` is the chronological layer. Append ingest, query, lint, and research-loop decisions here.

        ## Operations

        - Ingest one source at a time when possible.
        - Query the wiki first, then use raw sources only when the wiki is incomplete.
        - Lint for contradictions, orphan pages, stale claims, and missing links.
        - For research work, run bounded AutoResearch-style loops: one hypothesis, one change, one metric, one keep-or-discard decision.

        ## Safety

        Keep this wiki inside the user-selected RoachNet storage path. Do not assume any machine-specific path.
        """
    }

    private static func pageText(for memory: RoachBrainMemory, slug: String) -> String {
        let tags = memory.tags.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        return """
        ---
        id: \(memory.id)
        source: \(memory.source)
        created_at: \(memory.createdAt)
        last_accessed_at: \(memory.lastAccessedAt)
        tags: [\(tags)]
        ---

        # \(memory.title)

        \(memory.summary)

        ## Source

        \(memory.source)

        ## Body

        \(memory.body)

        ## Links

        - [[index]]
        - [[pages/\(slug)]]
        """
    }

    private static func indexText(pages: [RoachBrainWikiPage], updatedAt: String) -> String {
        let lines = pages.map { page in
            "- [[pages/\(page.slug)|\(page.title)]] - \(page.summary)"
        }

        return """
        # RoachBrain Wiki Index

        Updated: \(updatedAt)
        Pages: \(pages.count)

        ## Compiled Pages

        \(lines.isEmpty ? "- No compiled pages yet." : lines.joined(separator: "\n"))

        ## Operating Notes

        - Read this index before answering questions that need memory.
        - File useful answers back into RoachBrain so they become durable pages.
        - Use `log.md` for ingest, lint, query, and AutoResearch loop decisions.
        """
    }

    private static func appendLogEntry(root: URL, timestamp: String, pageCount: Int) throws {
        let logURL = root.appendingPathComponent(logFileName)
        let existing = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "# RoachBrain Wiki Log\n\n"
        let entry = "## [\(timestamp)] rebuild | compiled \(pageCount) pages\n\n"
        try (existing + entry).write(to: logURL, atomically: true, encoding: .utf8)
    }

    private static func countMarkdownPages(in root: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return contents.filter { $0.pathExtension.lowercased() == "md" }.count
    }

    private static func uniqueSlug(_ base: String, usedSlugs: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while !usedSlugs.insert(candidate).inserted {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func slug(for value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func tokenSet(from value: String) -> Set<String> {
        Set(
            value
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
    }

    private static func normalizedExcerpt(_ text: String, maxCharacters: Int) -> String {
        let squashed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard squashed.count > maxCharacters else { return squashed }
        return String(squashed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func timestampString(from date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true))
    }
}

public enum RoachBrainStore {
    private static let maxMemories = 180

    public static func load(storagePath: String) -> [RoachBrainMemory] {
        let url = RoachNetDeveloperPaths.roachBrainCatalogURL(storagePath: storagePath)
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([RoachBrainMemory].self, from: data)
        else {
            return []
        }

        return decoded.sorted(by: sortNewestFirst)
    }

    public static func save(_ memories: [RoachBrainMemory], storagePath: String) throws {
        try RoachNetDeveloperPaths.ensureWorkspaceDirectories(storagePath: storagePath)
        let trimmed = trim(memories.sorted(by: sortNewestFirst))
        let data = try JSONEncoder.pretty.encode(trimmed)
        try data.write(to: RoachNetDeveloperPaths.roachBrainCatalogURL(storagePath: storagePath), options: [.atomic])
        _ = try? RoachBrainWikiStore.rebuildFromMemories(storagePath: storagePath, memories: trimmed)
    }

    @discardableResult
    public static func capture(
        storagePath: String,
        title: String,
        body: String,
        source: String,
        tags: [String] = [],
        pinned: Bool = false
    ) throws -> RoachBrainMemory {
        let normalizedTitle = cleaned(title)
        let normalizedBody = cleaned(body)
        guard !normalizedTitle.isEmpty, !normalizedBody.isEmpty else {
            throw NSError(domain: "RoachBrain", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "RoachBrain needs both a title and body before it can store a memory."
            ])
        }

        let timestamp = timestampString(from: Date())
        var memories = load(storagePath: storagePath)

        if let index = memories.firstIndex(where: { existing in
            existing.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame
            && cleaned(existing.body) == normalizedBody
        }) {
            memories[index].summary = summarize(body: normalizedBody)
            memories[index].source = source
            memories[index].tags = mergedTags(memories[index].tags + tags)
            memories[index].pinned = memories[index].pinned || pinned
            memories[index].lastAccessedAt = timestamp
            try save(memories, storagePath: storagePath)
            return memories[index]
        }

        let memory = RoachBrainMemory(
            id: UUID().uuidString,
            title: normalizedTitle,
            summary: summarize(body: normalizedBody),
            body: normalizedBody,
            source: cleaned(source).isEmpty ? "RoachNet" : cleaned(source),
            tags: mergedTags(tags),
            pinned: pinned,
            createdAt: timestamp,
            lastAccessedAt: timestamp
        )

        memories.insert(memory, at: 0)
        try save(memories, storagePath: storagePath)
        return memory
    }

    public static func search(
        storagePath: String,
        query: String,
        tags: [String] = [],
        limit: Int = 5
    ) -> [RoachBrainMatch] {
        search(load(storagePath: storagePath), query: query, tags: tags, limit: limit)
    }

    public static func search(
        _ memories: [RoachBrainMemory],
        query: String,
        tags: [String] = [],
        limit: Int = 5
    ) -> [RoachBrainMatch] {
        let normalizedQuery = cleaned(query)
        let queryTokens = tokenSet(from: normalizedQuery)
        let requestedTags = Set(mergedTags(tags))

        let matches = memories.compactMap { memory -> RoachBrainMatch? in
            let title = memory.title.lowercased()
            let summary = memory.summary.lowercased()
            let body = memory.body.lowercased()
            let memoryTagSet = Set(memory.tags.map { $0.lowercased() })
            let matchedTags = Array(requestedTags.intersection(memoryTagSet)).sorted()

            let titleTokens = tokenSet(from: title)
            let summaryTokens = tokenSet(from: summary)
            let bodyTokens = tokenSet(from: body)

            var score = 0.0

            if normalizedQuery.isEmpty {
                score += memory.pinned ? 30 : 10
            } else {
                if title.contains(normalizedQuery) { score += 110 }
                if summary.contains(normalizedQuery) { score += 60 }
                if body.contains(normalizedQuery) { score += 40 }
            }

            let titleHits = Double(queryTokens.intersection(titleTokens).count)
            let summaryHits = Double(queryTokens.intersection(summaryTokens).count)
            let bodyHits = Double(queryTokens.intersection(bodyTokens).count)

            score += titleHits * 30
            score += summaryHits * 14
            score += bodyHits * 8
            score += Double(matchedTags.count) * 18

            if memory.pinned { score += 24 }
            score += recencyBonus(for: memory)

            return score > 0 ? RoachBrainMatch(memory: memory, score: score, matchedTags: matchedTags) : nil
        }

        return Array(matches.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return sortNewestFirst(lhs.memory, rhs.memory)
            }
            return lhs.score > rhs.score
        }.prefix(limit))
    }

    public static func markAccessed(memoryIDs: [String], storagePath: String) throws {
        guard !memoryIDs.isEmpty else { return }
        var memories = load(storagePath: storagePath)
        let timestamp = timestampString(from: Date())
        let idSet = Set(memoryIDs)

        var changed = false
        for index in memories.indices where idSet.contains(memories[index].id) {
            memories[index].lastAccessedAt = timestamp
            changed = true
        }

        if changed {
            try save(memories, storagePath: storagePath)
        }
    }

    public static func contextBlock(for matches: [RoachBrainMatch]) -> String {
        guard !matches.isEmpty else { return "" }

        let lines = matches.enumerated().map { index, match in
            let tags = match.memory.tags.isEmpty ? "" : " [tags: \(match.memory.tags.joined(separator: ", "))]"
            return """
            \(index + 1). \(match.memory.title) — \(match.memory.summary)\(tags)
            Source: \(match.memory.source)
            """
        }

        return """
        RoachBrain memory context:
        \(lines.joined(separator: "\n\n"))
        """
    }

    private static func summarize(body: String) -> String {
        let firstParagraph = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? body

        let compact = firstParagraph.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return compact.count > 140 ? String(compact.prefix(137)) + "..." : compact
    }

    private static func mergedTags(_ tags: [String]) -> [String] {
        Array(
            Set(
                tags
                    .map { cleaned($0).lowercased() }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }

    private static func cleaned(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{0000}", with: "")
    }

    private static func tokenSet(from value: String) -> Set<String> {
        Set(
            value
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
    }

    private static func recencyBonus(for memory: RoachBrainMemory) -> Double {
        guard let date = parsedDate(from: memory.lastAccessedAt) ?? parsedDate(from: memory.createdAt) else {
            return 0
        }

        let age = Date().timeIntervalSince(date)
        switch age {
        case ..<86_400:
            return 22
        case ..<604_800:
            return 16
        case ..<2_592_000:
            return 8
        default:
            return 2
        }
    }

    private static func trim(_ memories: [RoachBrainMemory]) -> [RoachBrainMemory] {
        guard memories.count > maxMemories else { return memories }

        let pinned = memories.filter(\.pinned)
        let unpinned = memories.filter { !$0.pinned }
        let remainingSlots = max(maxMemories - pinned.count, 0)
        return Array((pinned + unpinned.prefix(remainingSlots)).sorted(by: sortNewestFirst))
    }

    private static func sortNewestFirst(_ lhs: RoachBrainMemory, _ rhs: RoachBrainMemory) -> Bool {
        let lhsDate = parsedDate(from: lhs.lastAccessedAt) ?? parsedDate(from: lhs.createdAt) ?? .distantPast
        let rhsDate = parsedDate(from: rhs.lastAccessedAt) ?? parsedDate(from: rhs.createdAt) ?? .distantPast
        return lhsDate > rhsDate
    }

    private static func timestampString(from date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true))
    }

    private static func parsedDate(from value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }
}
