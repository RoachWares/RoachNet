import Foundation

extension NativeRuntime {
    /// Reads and parses a JSON request body (`readRequestJson`).
    func readRequestJSON(_ request: inout HTTPRequest) throws -> JSON {
        let data: Data
        do {
            data = try request.body()
        } catch let tooLarge as BodyTooLarge {
            throw requestError("Request body is larger than \(tooLarge.limit) bytes.", 413)
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .object(JSONObject()) }
        // A browser can post `text/plain` or form bodies to loopback without a
        // preflight; a JSON content type cannot be sent cross-origin without
        // one, and this API answers no preflight. Requiring it closes CSRF.
        guard Self.declaresJSONBody(request) else {
            throw requestError("Request body must be sent as application/json.", 415)
        }
        do {
            return try JSON.parse(raw)
        } catch {
            throw requestError("Request body must be valid JSON.", 400)
        }
    }

    static func declaresJSONBody(_ request: HTTPRequest) -> Bool {
        let type = (request.header("content-type") ?? "").split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return type == "application/json" || type.hasSuffix("+json")
    }

    /// Only hostnames a browser could reach by rebinding its own DNS name are
    /// rejected: loopback literals and the names the companion proxy maps to it.
    static func isTrustedLoopbackHost(_ raw: String?) -> Bool {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") {
            host = String(host.drop(while: { $0 == "[" }).prefix { $0 != "]" })
        } else if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        return isLoopbackHostname(host)
    }

    /// Loopback names and literals only. `127.example.net` is a DNS name a page
    /// can rebind, so 127/8 must be a dotted-quad literal, not a prefix.
    static func isLoopbackHostname(_ raw: String) -> Bool {
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" || host == "::ffff:127.0.0.1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy { $0.isASCII && $0.isNumber } && (Int(octet) ?? 256) <= 255
        }
    }

    /// Browsers send `Origin` on every cross-origin POST, including the
    /// "simple" ones that skip the CORS preflight (an empty body, text/plain).
    /// A request with no Origin is not from a page on another site; `null`
    /// (sandboxed frames, files) is refused.
    static func isTrustedLoopbackOrigin(_ raw: String?) -> Bool {
        guard let raw else { return true }
        guard let origin = WebURL(raw.trimmingCharacters(in: .whitespaces)),
              origin.scheme == "http" || origin.scheme == "https" else { return false }
        return isLoopbackHostname(origin.hostname)
    }

    /// Entry point for the loopback API (and the in-process companion proxy).
    public func handle(_ request: inout HTTPRequest) -> HTTPResponse {
        do {
            // The companion proxy rewrites requests in-process with no Host
            // header; direct loopback clients must present a loopback Host so
            // a DNS-rebound page cannot read responses from this port.
            guard Self.isTrustedLoopbackHost(request.header("host")) else {
                return .json(403, ["error": "Loopback API requests must use a loopback Host."])
            }
            guard Self.isTrustedLoopbackOrigin(request.header("origin")) else {
                return .json(403, ["error": "Loopback API requests from other sites are refused."])
            }
            return try route(&request)
        } catch let error as RuntimeError {
            if error.statusCode >= 500 { log("request failed: \(error.message)") }
            return .json(error.statusCode, ["error": JSON(error.message)])
        } catch let tooLarge as BodyTooLarge {
            return .json(413, ["error": JSON("Request body is larger than \(tooLarge.limit) bytes.")])
        } catch {
            log("request failed: \(error)")
            return .json(500, ["error": JSON("\(error)")])
        }
    }

    private func lastSegment(_ pathname: String) -> String {
        String(pathname.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func route(_ request: inout HTTPRequest) throws -> HTTPResponse {
        let url = WebURL(request.target, base: WebURL("http://127.0.0.1")) ?? WebURL("http://127.0.0.1/")!
        let method = request.method
        let pathname = url.pathname
        func ok(_ value: JSON, _ status: Int = 200) -> HTTPResponse { .json(status, value) }
        func body() throws -> JSON { try readRequestJSON(&request) }

        // Collections with GET / POST / DELETE /:id
        let collections: [(String, String, String, () -> JSON, (JSON) -> JSON)] = [
            ("contacts", "contacts.json", "contacts", roachClawContactsState, upsertRoachClawContact),
            ("tasks", "tasks.json", "tasks", roachClawTaskState, upsertRoachClawTask),
            ("calendar", "calendar.json", "events", roachClawCalendarState, upsertRoachClawCalendarEvent),
            ("reports", "reports.json", "reports", roachClawReportsState, upsertRoachClawReport),
            ("memories", "memories.json", "memories", roachClawMemoriesState, upsertRoachClawMemory),
            ("skills", "skills.json", "skills", roachClawSkillsState, upsertRoachClawSkill),
            ("editor-drafts", "editor-drafts.json", "drafts", roachClawEditorDraftsState, upsertRoachClawEditorDraft),
            ("search-cache", "search-cache.json", "entries", roachClawSearchCacheState, upsertRoachClawSearchCacheEntry),
            ("gallery", "gallery.json", "assets", roachClawGalleryState, upsertRoachClawGalleryAsset),
            ("webhooks", "webhooks.json", "webhooks", roachClawWebhooksState, upsertRoachClawWebhook),
            ("agent-runs", "agent-runs.json", "runs", roachClawAgentRunsState, upsertRoachClawAgentRun),
            ("context-compactions", "context-compactions.json", "compactions", roachClawContextCompactionsState, upsertRoachClawContextCompaction),
            ("tool-index", "tool-index.json", "tools", roachClawToolIndexState, upsertRoachClawToolIndexEntry),
            ("events", "events.json", "events", roachClawEventsState, upsertRoachClawEvent),
            ("presets", "presets.json", "templates", roachClawPresetsState, upsertRoachClawPreset),
            ("signatures", "signatures.json", "signatures", roachClawSignaturesState, upsertRoachClawSignature),
        ]

        if pathname == "/api/org" || pathname.hasPrefix("/api/org/") { return try routeOrg(&request, url: url) }

        switch (method, pathname) {
        case ("GET", "/api/health"): return ok(["status": "ok"])
        case ("GET", "/api/packs"):
            refreshPackCatalog(force: url.queryParameter("refresh") == "1")
            return ok(packRegistry.catalogJSON(includeSizes: url.queryParameter("sizes") == "1"))
        case ("POST", "/api/packs/install"): return ok(try installPack(try body()), 202)
        case ("GET", _) where pathname.hasPrefix("/api/packs/"):
            let id = lastSegment(pathname)
            guard let record = packRegistry.record(id) else { throw requestError("No pack named \(id).", 404) }
            return ok(packRegistry.recordJSON(record))
        case ("POST", _) where pathname.hasPrefix("/api/packs/") && ["enable", "disable", "uninstall"].contains(lastSegment(pathname)):
            return ok(try affectPack(pathname, try body()))
        case ("GET", "/api/system/internet-status"): return ok(JSON(DNS.resolves("github.com")))
        case ("GET", "/api/system/info"): return ok(systemInfo())
        case ("GET", "/api/system/services"): return ok(.array(systemServices()))
        case ("GET", "/api/system/ai/providers"):
            return ok([
                "providers": [
                    "ollama": providerStatus("ollama", config.ollamaBaseUrl),
                    "openclaw": providerStatus("openclaw", config.openClawBaseUrl),
                ],
                "cloudProviders": roachClawPublicCloudProviderKeysState(),
            ])
        case ("GET", "/api/system/latest-version"): return ok(latestVersionResponse(force: url.queryParameter("force") == "1"))
        case ("GET", "/api/system/update/status"): return ok(withState { systemUpdateStatus })
        case ("POST", "/api/system/update"): return ok(try requestUpdateDownload(force: true), 202)
        case ("GET", "/api/roachclaw/status"): return ok(roachClawStatus())
        case ("GET", "/api/roachclaw/diagnostics/services"): return ok(roachClawStatus()["operations"]["serviceHealth"]["report"])
        case ("GET", "/api/roachclaw/workspace/browse"): return ok(browseRoachClawWorkspace(url.queryParameter("path") ?? ""))
        case ("GET", "/api/roachclaw/user-time"): return ok(roachClawUserTimeState())
        case ("POST", "/api/roachclaw/user-time"): return ok(upsertRoachClawUserTime(try body()))
        case ("GET", "/api/roachclaw/cookbook/schedules"): return ok(roachClawCookbookServeState())
        case ("POST", "/api/roachclaw/cookbook/schedules"): return ok(upsertRoachClawCookbookServeSchedule(try body()))
        case ("POST", "/api/roachclaw/cookbook/progress-signal"): return ok(computeRoachClawCookbookProgressSignal(try body()))
        case ("GET", "/api/roachclaw/scoped-tools/capabilities"): return ok(roachClawScopedToolBridgeState())
        case ("GET", "/api/roachclaw/security/tls-overrides"): return ok(roachClawTlsOverridesState())
        case ("POST", "/api/roachclaw/security/tls-overrides"): return ok(try upsertRoachClawTlsOverride(try body()))
        case ("GET", "/api/roachclaw/security/upload-limits"): return ok(roachClawUploadLimitsState())
        case ("GET", "/api/roachclaw/migration-document-tools"): return ok(roachClawMigrationDocumentToolsState())
        case ("GET", "/api/roachclaw/memory-provider"): return ok(roachClawMemoryProviderState())
        case ("POST", "/api/roachclaw/memory-provider"): return ok(upsertRoachClawMemoryProvider(try body()))
        case ("GET", "/api/roachclaw/provider-oauth"): return ok(roachClawProviderOAuthState())
        case ("POST", "/api/roachclaw/provider-oauth"): return ok(try upsertRoachClawProviderOAuthFlow(try body()))
        case ("GET", "/api/roachclaw/embedding-lanes"): return ok(roachClawEmbeddingLanesState())
        case ("POST", "/api/roachclaw/embedding-lanes"): return ok(try upsertRoachClawEmbeddingLane(try body()))
        case ("GET", "/api/roachclaw/tool-policy"): return ok(roachClawToolPolicyState())
        case ("POST", "/api/roachclaw/tool-policy"): return ok(upsertRoachClawToolPolicy(try body()))
        case ("POST", "/api/roachclaw/tool-policy/evaluate"): return ok(roachClawToolPolicyState(try body()))
        case ("GET", "/api/roachclaw/context-budget"): return ok(roachClawContextBudgetState())
        case ("POST", "/api/roachclaw/context-budget"): return ok(upsertRoachClawContextBudget(try body()))
        case ("POST", "/api/roachclaw/url-safety/check"):
            let payload = try body()
            return ok(checkRoachClawOutboundUrl(payload["url"], blockPrivate: payload["blockPrivate"].truthy))
        case ("GET", "/api/roachclaw/readiness"): return ok(roachClawReadinessState())
        case ("GET", "/api/roachclaw/agent/status"): return ok(roachClawStatus()["agent"])
        case ("POST", "/api/roachclaw/agent/run"):
            let status = roachClawStatus()
            return ok(try RoachClawAgent.createRun(try body(), status: status["agent"]))
        case ("POST", "/api/roachclaw/apply"):
            let payload = try body()
            pullModel((payload["model"] || JSON(defaultModel)).jsString)
            return ok(["success": true, "ok": true, "message": "Local model pull queued."])
        case ("POST", "/api/system/services/install"):
            let payload = try body()
            if payload["service_name"].stringValue == "roachnet_ollama" {
                ensureOllama()
                return ok(["success": true, "ok": true, "message": "Local model lane start requested."])
            }
            return ok(["success": true, "ok": true, "message": "Native service registered. Container install is not required for this lane."])
        case ("POST", "/api/system/services/affect"):
            let payload = try body()
            if payload["service_name"].stringValue == "roachnet_ollama" && payload["action"].stringValue == "start" { ensureOllama() }
            return ok(["success": true, "ok": true, "message": JSON("\((payload["action"] || "Service").jsString) request recorded.")])
        case ("GET", "/api/ollama/installed-models"): return ok(.array(installedModels()))
        case ("POST", "/api/ollama/chat"): return ok(handleChat(try body()))
        case ("GET", "/api/openclaw/skills/installed"):
            let workspace = config.env("OPENCLAW_WORKSPACE_PATH").flatMap { $0.isEmpty ? nil : $0 } ?? Path.join(storageRoot, "RoachClaw")
            return ok(["workspacePath": JSON(workspace), "skills": []])
        case ("GET", "/api/rag/files"): return ok(["files": jsonStrings(listVaultKnowledgeFiles(Path.join(storageRoot, "Vault")))])
        case ("GET", "/api/collections"):
            refreshCollections(force: url.queryParameter("refresh") == "1")
            return ok(["collections": collectionsStatus()])
        case ("GET", "/api/maps/curated-collections"):
            refreshCollections()
            return ok(.array(mapCollections()))
        case ("POST", "/api/maps/download-base-assets"):
            try Files.mkdirp(Path.join(storageRoot, "maps", "pmtiles"))
            try Files.mkdirp(Path.join(storageRoot, "maps", "basemaps-assets"))
            let queued = queueWorldAtlasInBackground()
            return ok(["success": true, "ok": true,
                       "message": JSON(queued ? "Base atlas folders are ready. The World Atlas download is starting." : "Base atlas folders are ready.")])
        case ("POST", "/api/maps/download-collection"):
            let payload = try body()
            let jobs = try queueResources(resourcesForMapCollection(payload["slug"]), Path.join(storageRoot, "maps", "pmtiles"), "pmtiles")
            return ok(["success": true, "ok": true, "message": JSON("\(plural(jobs.count, "map download")) queued.")])
        case ("POST", "/api/maps/download-remote"):
            let payload = try body()
            let job = try queueResolvedDownload(payload["url"], Path.join(storageRoot, "maps", "pmtiles"), "pmtiles")
            return ok(["success": JSON(job != nil), "ok": JSON(job != nil), "message": JSON(job != nil ? "Remote map download queued." : "No map URL provided.")])
        case ("GET", "/api/zim/curated-categories"):
            refreshCollections()
            return ok(.array(educationCategories()))
        case ("GET", "/api/zim/wikipedia"):
            refreshCollections()
            return ok(wikipediaState())
        case ("POST", "/api/zim/download-category-tier"):
            let payload = try body()
            let jobs = try queueResources(resourcesForEducationTier(payload["categorySlug"], payload["tierSlug"]), Path.join(storageRoot, "zim"), "zim")
            return ok(["success": true, "ok": true, "message": JSON("\(plural(jobs.count, "knowledge download")) queued.")])
        case ("POST", "/api/zim/download-category-resource"):
            let payload = try body()
            let jobs = try queueResources(resourcesForEducationResource(payload["categorySlug"], payload["resourceId"]), Path.join(storageRoot, "zim"), "zim")
            return ok(["success": true, "ok": true, "message": JSON("\(plural(jobs.count, "knowledge download")) queued.")])
        case ("POST", "/api/zim/download-remote"):
            let payload = try body()
            let job = try queueResolvedDownload(payload["url"], Path.join(storageRoot, "zim"), "zim")
            return ok(["success": JSON(job != nil), "ok": JSON(job != nil), "message": JSON(job != nil ? "Remote knowledge pack queued." : "No ZIM URL provided.")])
        case ("POST", "/api/zim/wikipedia/select"):
            let payload = try body()
            let (job, option) = try selectWikipediaOption(payload["optionId"])
            if job == nil && option == nil { return ok(["success": true, "ok": true, "message": "Wikipedia install skipped."]) }
            return ok(["success": true, "ok": true, "message": JSON("\(option!["name"].jsString) queued.")])
        case ("POST", "/api/roachspeech/model-packs/download"):
            let queued = try queueRoachSpeechPackDownload(try body())
            return ok([
                "success": JSON(queued.job != nil),
                "ok": JSON(queued.job != nil),
                "message": JSON(queued.job != nil
                    ? "\(queued.packID) RoachSpeech pack queued. It will unpack into the local model shelf when the download finishes."
                    : "No RoachSpeech pack URL provided."),
                "packID": JSON(queued.packID),
                "kind": JSON(queued.kind),
                "jobId": JSON(queued.job?.jobId),
            ])
        case ("GET", "/api/roachspeech/model-packs"): return ok(roachSpeechModelPacksState())
        case ("GET", "/api/roachclaw/mail"): return ok(roachClawMailState())
        case ("POST", "/api/roachclaw/mail/messages"): return ok(upsertRoachClawMailMessage(try body()))
        case ("POST", "/api/roachclaw/mail/drafts"): return ok(upsertRoachClawMailDraft(try body()))
        case ("GET", "/api/roachclaw/tokens"): return ok(roachClawPublicApiTokensState())
        case ("POST", "/api/roachclaw/tokens"): return ok(createRoachClawApiToken(try body()))
        case ("GET", "/api/roachclaw/cloud-providers"): return ok(roachClawPublicCloudProviderKeysState())
        case ("POST", "/api/roachclaw/cloud-providers"): return ok(try upsertRoachClawCloudProviderKey(try body()))
        case ("GET", "/api/roachclaw/backups"): return ok(roachClawBackupsState())
        case ("POST", "/api/roachclaw/backups"): return ok(createRoachClawBackup(try body()))
        case ("GET", "/api/roachclaw/export"): return ok(roachClawExportPayload())
        case ("GET", "/api/site-archives"): return ok(["archives": .array(siteArchives())])
        case ("GET", "/api/companion/bootstrap"): return ok(companionBootstrapState())
        case ("GET", "/api/companion/runtime"): return ok(companionRuntimeState())
        case ("GET", "/api/companion/vault"): return ok(companionVaultState())
        case ("GET", "/api/companion/account"): return ok(accountState())
        case ("GET", "/api/companion/roachtail"):
            let peer = request.header("x-roachtail-auth-kind")?.trimmingCharacters(in: .whitespaces).lowercased() == "peer"
            return ok(roachTailState(hideJoinCode: peer))
        case ("POST", "/api/companion/roachtail/pair"): return ok(try pairRoachTailPeer(try body()))
        case ("POST", "/api/companion/roachtail/affect"):
            let payload = try body()
            return ok(try mutateRoachTailState(payload["action"], payload, headers: request.headers))
        case ("GET", "/api/companion/roachsync"): return ok(roachSyncState())
        case ("POST", "/api/companion/install"):
            let payload = try body()
            // A paired phone may queue catalog installs, but it must not turn the
            // Mac into a fetcher for private-network or self-chosen hosts.
            if request.header("x-roachtail-auth-kind")?.trimmingCharacters(in: .whitespaces).lowercased() == "peer" {
                for key in ["url", "mirrorUrl", "sourceUrl"] where payload[key].truthy {
                    let verdict = checkRoachClawOutboundUrl(payload[key], blockPrivate: true)
                    if !verdict["ok"].truthy {
                        throw requestError("Paired devices can only queue downloads from public hosts (\(verdict["reason"].jsString)).", 403)
                    }
                }
            }
            return ok(try handleCompanionInstall(payload))
        case ("GET", "/api/companion/chat/sessions"): return ok(companionChatSessions())
        case ("POST", "/api/companion/chat/sessions"): return ok(createCompanionChatSession(try body()), 201)
        case ("POST", "/api/companion/chat/send"): return ok(try sendCompanionChatMessage(try body()))
        case ("POST", "/api/companion/services/affect"): return ok(try affectCompanionService(try body()))
        case ("POST", "/api/companion/account/affect"): return ok(try affectCompanionAccount(try body()))
        case ("POST", "/api/companion/roachsync/affect"): return ok(try affectCompanionRoachSync(try body()))
        case ("GET", "/api/downloads/jobs"): return ok(.array(downloadJobsSnapshot()))
        case ("GET", "/api/benchmark/status"): return ok(withState { benchmarkStatus })
        case ("POST", "/api/benchmark/run"):
            let payload = try body()
            let benchmarkId = JS.randomUUID()
            withState { benchmarkStatus = ["status": "starting", "benchmarkId": JSON(benchmarkId)] }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.withState { self?.benchmarkStatus = ["status": "idle", "benchmarkId": nil] }
            }
            return ok([
                "success": true,
                "job_id": JSON(benchmarkId),
                "benchmark_id": JSON(benchmarkId),
                "message": JSON("\((payload["benchmark_type"] || "system").jsString) benchmark started"),
            ], 201)
        default:
            break
        }

        if method == "GET" && pathname.hasPrefix("/api/companion/chat/sessions/") {
            return ok(try companionChatSession(decodeURIComponent(lastSegment(pathname))))
        }

        if method == "GET" && pathname.hasPrefix("/api/roachclaw/operations") {
            let operations = roachClawStatus()["operations"]
            let section = lastSegment(pathname)
            if !section.isEmpty && section != "operations" && operations.object.has(section) {
                return ok(operations[section])
            }
            return ok(operations)
        }

        if method == "DELETE" {
            if pathname.hasPrefix("/api/roachclaw/cookbook/schedules/") {
                return ok(try deleteRoachClawCollectionItem("cookbook-serve-schedules.json", "schedules", decodeURIComponent(lastSegment(pathname))))
            }
            for (route, file, key, _, _) in collections where pathname.hasPrefix("/api/roachclaw/\(route)/") {
                return ok(try deleteRoachClawCollectionItem(file, key, lastSegment(pathname)))
            }
            if pathname.hasPrefix("/api/roachclaw/mail/messages/") { return ok(try deleteRoachClawMailItem("messages", lastSegment(pathname))) }
            if pathname.hasPrefix("/api/roachclaw/mail/drafts/") { return ok(try deleteRoachClawMailItem("drafts", lastSegment(pathname))) }
            if pathname.hasPrefix("/api/roachclaw/tokens/") { return ok(try deleteRoachClawApiToken(lastSegment(pathname))) }
            if pathname.hasPrefix("/api/roachclaw/cloud-providers/") { return ok(try deleteRoachClawCloudProviderKey(lastSegment(pathname))) }
            if pathname.hasPrefix("/api/roachclaw/backups/") { return ok(try deleteRoachClawCollectionItem("backups.json", "snapshots", lastSegment(pathname))) }
            if pathname.hasPrefix("/api/downloads/jobs/") {
                let cancelled = cancelDownloadJob(decodeURIComponent(lastSegment(pathname)))
                return ok(["success": true, "ok": true, "cancelled": JSON(cancelled)])
            }
        }

        for (route, _, _, list, upsert) in collections where pathname == "/api/roachclaw/\(route)" {
            if method == "GET" { return ok(list()) }
            if method == "POST" { return ok(upsert(try body())) }
        }

        if method == "POST" && pathname.hasPrefix("/api/companion/") {
            return ok(["success": true, "ok": true, "message": "Native companion action recorded."])
        }

        return .json(404, ["error": JSON("No native endpoint for \(method) \(pathname)")])
    }
}
