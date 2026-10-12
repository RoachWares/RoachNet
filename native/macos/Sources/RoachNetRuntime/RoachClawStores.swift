import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension NativeRuntime {
    // MARK: Paths and raw state

    func roachClawVaultPath(_ parts: String...) -> String { Path.join([config.roachClawStateRoot] + parts) }
    func legacyRoachClawVaultPath(_ parts: String...) -> String { Path.join([config.legacyRoachClawStateRoot] + parts) }

    func readRoachClawState(_ filename: String, _ fallback: JSON) -> JSON {
        for target in [roachClawVaultPath(filename), legacyRoachClawVaultPath(filename)] {
            if Files.exists(target), let parsed = JSON.read(contentsOf: target) { return parsed }
        }
        return fallback
    }

    @discardableResult
    func writeRoachClawState(_ filename: String, _ state: JSON) -> JSON {
        // Owner-only: these hold memories, contacts, token hashes and webhook digests.
        try? Files.writePrettyJSON(state, to: roachClawVaultPath(filename), mode: Files.privateFileMode)
        return state
    }

    func roachClawCollectionState(_ filename: String, _ collectionKey: String) -> JSON {
        var state = readRoachClawState(filename, [
            "schema": JSON("org.roachnet.roachclaw.\(collectionKey).v1"),
            "updatedAt": nil,
            collectionKey: [],
        ])
        if !state.isObject { state = .object(JSONObject()) }
        if !state[collectionKey].isArray { state[collectionKey] = [] }
        return state
    }

    func roachClawUpsertCollectionItem(_ filename: String, _ collectionKey: String, _ body: JSON, _ normalize: (JSON) -> JSON) -> JSON {
        withState {
            var state = roachClawCollectionState(filename, collectionKey)
            let now = JS.isoNow()
            let prefix = String(collectionKey.dropLast())
            let generated = "\(prefix.isEmpty ? "item" : prefix)_\(JS.randomHex(16))"
            let id = JS.compactString(body["id"] || JSON(generated), "", 80)
            var items = state[collectionKey].array
            let existingIndex = items.firstIndex { $0["id"].stringValue == id }
            let existing = existingIndex.map { items[$0] } ?? .object(JSONObject())
            var merged = existing.merging(body)
            merged["id"] = JSON(id)
            merged["updatedAt"] = JSON(now)
            merged["createdAt"] = existing["createdAt"] || body["createdAt"] || JSON(now)
            let item = normalize(merged)
            if let existingIndex {
                items[existingIndex] = item
            } else {
                items.insert(item, at: 0)
            }
            state[collectionKey] = .array(items)
            state["updatedAt"] = JSON(now)
            return writeRoachClawState(filename, state)
        }
    }

    func deleteRoachClawCollectionItem(_ filename: String, _ collectionKey: String, _ rawId: String) throws -> JSON {
        let id = JS.compactString(JSON(decodeURIComponent(rawId)), "", 120)
        if id.isEmpty { throw requestError("Item id is missing.", 400) }
        return withState {
            var state = roachClawCollectionState(filename, collectionKey)
            let before = state[collectionKey].array.count
            state[collectionKey] = .array(state[collectionKey].array.filter { $0["id"].stringValue != id })
            state["updatedAt"] = JSON(JS.isoNow())
            writeRoachClawState(filename, state)
            return [
                "success": true,
                "ok": true,
                "deleted": JSON(before != state[collectionKey].array.count),
                "id": JSON(id),
                "state": state,
            ]
        }
    }

    // MARK: Collections

    func roachClawContactsState() -> JSON { roachClawCollectionState("contacts.json", "contacts") }

    func upsertRoachClawContact(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("contacts.json", "contacts", body) { item in
            [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || item["displayName"] || item["email"] || item["handle"] || "Unnamed contact", "Unnamed contact", 120)),
                "handle": nullIfEmpty(JS.compactString(item["handle"], "", 120)),
                "email": nullIfEmpty(JS.compactString(item["email"], "", 160)),
                "relationship": nullIfEmpty(JS.compactString(item["relationship"] || item["role"], "", 120)),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "notes": nullIfEmpty(JS.compactString(item["notes"], "", 1000)),
                "source": JSON(JS.compactString(item["source"] || "local", "local", 80)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawTaskState() -> JSON { roachClawCollectionState("tasks.json", "tasks") }

    func upsertRoachClawTask(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("tasks.json", "tasks", body) { item in
            [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || item["summary"] || "Untitled task", "Untitled task", 180)),
                "status": JSON(JS.compactString(item["status"] || "open", "open", 40)),
                "priority": JSON(JS.compactString(item["priority"] || "normal", "normal", 40)),
                "dueAt": nullIfEmpty(JS.compactString(item["dueAt"] || item["due"] || "", "", 80)),
                "source": JSON(JS.compactString(item["source"] || "roachclaw", "roachclaw", 80)),
                "notes": nullIfEmpty(JS.compactString(item["notes"], "", 1000)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawCalendarState() -> JSON { roachClawCollectionState("calendar.json", "events") }

    func upsertRoachClawCalendarEvent(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("calendar.json", "events", body) { item in
            [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || "Untitled event", "Untitled event", 180)),
                "startAt": nullIfEmpty(JS.compactString(item["startAt"] || item["startsAt"] || item["start"] || "", "", 80)),
                "endAt": nullIfEmpty(JS.compactString(item["endAt"] || item["endsAt"] || item["end"] || "", "", 80)),
                "location": nullIfEmpty(JS.compactString(item["location"], "", 180)),
                "status": JSON(JS.compactString(item["status"] || "planned", "planned", 40)),
                "source": JSON(JS.compactString(item["source"] || "roachclaw", "roachclaw", 80)),
                "notes": nullIfEmpty(JS.compactString(item["notes"], "", 1000)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawReportsState() -> JSON { roachClawCollectionState("reports.json", "reports") }

    func upsertRoachClawReport(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("reports.json", "reports", body) { item in
            [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || "Untitled report", "Untitled report", 180)),
                "kind": JSON(JS.compactString(item["kind"] || "research-brief", "research-brief", 80)),
                "status": JSON(JS.compactString(item["status"] || "draft", "draft", 40)),
                "summary": nullIfEmpty(JS.compactString(item["summary"], "", 1200)),
                "formats": jsonStrings(JS.compactStringList(item["formats"] || ["markdown"])),
                "vaultPath": nullIfEmpty(JS.compactString(item["vaultPath"] || item["path"] || "", "", 512)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawMemoriesState() -> JSON { roachClawCollectionState("memories.json", "memories") }

    func upsertRoachClawMemory(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("memories.json", "memories", body) { item in
            [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || item["summary"] || "Memory", "Memory", 160)),
                "content": JSON(JS.compactString(item["content"] || item["body"] || item["text"] || "", "", 6000)),
                "source": JSON(JS.compactString(item["source"] || "roachclaw", "roachclaw", 120)),
                "importance": JSON(JS.compactString(item["importance"] || "normal", "normal", 40)),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawSkillsState() -> JSON { roachClawCollectionState("skills.json", "skills") }

    func upsertRoachClawSkill(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("skills.json", "skills", body) { item in
            [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || item["title"] || "RoachClaw skill", "RoachClaw skill", 140)),
                "category": JSON(JS.compactString(item["category"] || "general", "general", 80)),
                "description": nullIfEmpty(JS.compactString(item["description"] || item["summary"] || "", "", 1200)),
                "body": JSON(JS.compactString(item["body"] || item["instructions"] || item["procedure"] || "", "", 12000)),
                "triggerHints": jsonStrings(JS.compactStringList(item["triggerHints"] || item["triggers"] || item["keywords"])),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "source": JSON(JS.compactString(item["source"] || "local", "local", 80)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawEditorDraftsState() -> JSON { roachClawCollectionState("editor-drafts.json", "drafts") }

    func upsertRoachClawEditorDraft(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("editor-drafts.json", "drafts", body) { item in
            [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || "Untitled draft", "Untitled draft", 180)),
                "format": JSON(JS.compactString(item["format"] || "markdown", "markdown", 40)),
                "status": JSON(JS.compactString(item["status"] || "draft", "draft", 40)),
                "target": nullIfEmpty(JS.compactString(item["target"] || item["path"] || "", "", 240)),
                "body": JSON(JS.compactString(item["body"] || item["content"] || "", "", 20000)),
                "excerpt": nullIfEmpty(JS.compactString(item["excerpt"] || item["body"] || item["content"] || "", "", 500)),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawSearchCacheState() -> JSON { roachClawCollectionState("search-cache.json", "entries") }

    func upsertRoachClawSearchCacheEntry(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("search-cache.json", "entries", body) { item in
            [
                "id": item["id"],
                "query": JSON(JS.compactString(item["query"] || item["title"] || "Search query", "Search query", 300)),
                "provider": JSON(JS.compactString(item["provider"] || "local", "local", 80)),
                "summary": nullIfEmpty(JS.compactString(item["summary"] || item["answer"] || "", "", 4000)),
                "status": JSON(JS.compactString(item["status"] || "cached", "cached", 40)),
                "sourceCount": safeIntegerOr(item["sourceCount"], JSON(JS.compactStringList(item["sources"]).count)),
                "sources": jsonStrings(JS.compactStringList(item["sources"], 20)),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawGalleryState() -> JSON { roachClawCollectionState("gallery.json", "assets") }

    func upsertRoachClawGalleryAsset(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("gallery.json", "assets", body) { item in
            let pathValue = (item["path"] || "Untitled asset").jsString
            return [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || JSON(Path.basename(pathValue)), "Untitled asset", 180)),
                "kind": JSON(JS.compactString(item["kind"] || "image", "image", 60)),
                "path": nullIfEmpty(JS.compactString(item["path"] || item["vaultPath"] || "", "", 512)),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "notes": nullIfEmpty(JS.compactString(item["notes"], "", 1000)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawWebhooksState() -> JSON { roachClawCollectionState("webhooks.json", "webhooks") }

    func upsertRoachClawWebhook(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("webhooks.json", "webhooks", body) { item in
            let rawSecret = JS.compactString(body["secret"] || body["signingSecret"] || "", "", 2000)
            let existingDigest = nullIfEmpty(JS.compactString(item["secretDigest"] || "", "", 160))
            let id = item["id"].jsString
            let hookPath = "/api/roachclaw/hooks/\(id)"
            // A per-secret salt and HMAC instead of a bare SHA-256, and a hint
            // that shows two characters, not four (security review M11).
            let secretHint: JSON
            let secretSalt: JSON
            let secretDigest: JSON
            if rawSecret.isEmpty {
                secretHint = nullIfEmpty(JS.compactString(item["secretHint"] || "", "", 40))
                secretSalt = nullIfEmpty(JS.compactString(item["secretSalt"] || "", "", 64))
                secretDigest = existingDigest
            } else {
                let salt = JS.randomHex(32)
                secretHint = JSON("…\(JS.sliceTail(rawSecret, 2))")
                secretSalt = JSON(salt)
                secretDigest = JSON(HMACSHA256.hex(key: salt, message: rawSecret))
            }
            return [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || item["label"] || "Local webhook", "Local webhook", 140)),
                "method": JSON(JS.compactString(item["method"] || "POST", "POST", 12).uppercased()),
                "path": JSON(JS.compactString(item["path"] || JSON(hookPath), hookPath, 240)),
                "target": JSON(JS.compactString(item["target"] || item["route"] || "roachclaw", "roachclaw", 160)),
                "scope": JSON(JS.compactString(item["scope"] || "local-integration", "local-integration", 120)),
                "isActive": JSON((item["isActive"] ?? item["enabled"] ?? true).truthy),
                "secretDigest": secretDigest,
                "secretSalt": secretSalt,
                "secretDigestAlgorithm": secretSalt.isNullish ? (secretDigest.isNullish ? nil : "sha256") : "hmac-sha256-salted-v1",
                "secretHint": secretHint,
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawAgentRunsState() -> JSON { roachClawCollectionState("agent-runs.json", "runs") }

    func upsertRoachClawAgentRun(_ body: JSON) -> JSON {
        let defaultModel = self.defaultModel
        return roachClawUpsertCollectionItem("agent-runs.json", "runs", body) { item in
            let status = JS.compactString(item["status"] || "queued", "queued", 40).lowercased()
            let events = item["events"].array
            return [
                "id": item["id"],
                "sessionId": JSON(JS.compactString(item["sessionId"] || item["session_id"] || "local-session", "local-session", 120)),
                "title": JSON(JS.compactString(item["title"] || item["prompt"] || "RoachClaw run", "RoachClaw run", 180)),
                "status": JSON(status),
                "model": JSON(JS.compactString(item["model"] || JSON(defaultModel), defaultModel, 160)),
                "mode": JSON(JS.compactString(item["mode"] || "agent", "agent", 60)),
                "promptPreview": nullIfEmpty(JS.compactString(item["promptPreview"] || item["prompt"] || "", "", 1000)),
                "eventCount": safeIntegerOr(item["eventCount"], JSON(events.count)),
                "replayPreview": jsonStrings(JS.compactStringList(item["replayPreview"] || .array(events), 12)),
                "lastEventAt": JS.compactString(item["lastEventAt"] || item["updatedAt"] || "", "", 80).isEmpty
                    ? item["updatedAt"]
                    : JSON(JS.compactString(item["lastEventAt"] || item["updatedAt"] || "", "", 80)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawContextCompactionsState() -> JSON { roachClawCollectionState("context-compactions.json", "compactions") }

    func upsertRoachClawContextCompaction(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("context-compactions.json", "compactions", body) { item in
            [
                "id": item["id"],
                "sessionId": JSON(JS.compactString(item["sessionId"] || item["session_id"] || "local-session", "local-session", 120)),
                "title": JSON(JS.compactString(item["title"] || "Context compaction", "Context compaction", 180)),
                "summary": JSON(JS.compactString(item["summary"] || item["content"] || "", "", 8000)),
                "turnsSummarized": safeIntegerOr(item["turnsSummarized"] ?? item["turns"], 0),
                "tokensBefore": safeIntegerOr(item["tokensBefore"], nil),
                "tokensAfter": safeIntegerOr(item["tokensAfter"], nil),
                "contextWindow": safeIntegerOr(item["contextWindow"], nil),
                "retentionPolicy": JSON(JS.compactString(item["retentionPolicy"] || "preserve-goals-decisions-paths", "preserve-goals-decisions-paths", 120)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawToolIndexState() -> JSON { roachClawCollectionState("tool-index.json", "tools") }

    func upsertRoachClawToolIndexEntry(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("tool-index.json", "tools", body) { item in
            [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || item["title"] || "RoachClaw tool", "RoachClaw tool", 140)),
                "kind": JSON(JS.compactString(item["kind"] || item["type"] || "native", "native", 80)),
                "category": JSON(JS.compactString(item["category"] || "general", "general", 80)),
                "description": nullIfEmpty(JS.compactString(item["description"] || item["summary"] || "", "", 1600)),
                "invocation": nullIfEmpty(JS.compactString(item["invocation"] || item["command"] || item["route"] || "", "", 500)),
                "enabled": JSON((item["enabled"] ?? true).truthy),
                "alwaysAvailable": JSON((item["alwaysAvailable"] ?? item["always_available"] ?? false).truthy),
                "tags": jsonStrings(JS.compactStringList(item["tags"] || item["keywords"])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawEventsState() -> JSON { roachClawCollectionState("events.json", "events") }

    func upsertRoachClawEvent(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("events.json", "events", body) { item in
            let increment = JSCoercion.isSafeInteger(body["increment"].jsNumber) ? max(0, body["increment"].jsNumber) : 0
            let existingCount = JSCoercion.isSafeInteger(item["count"].jsNumber) ? max(0, item["count"].jsNumber) : 0
            let fired = JS.compactString(item["lastFiredAt"] || item["firedAt"] || item["updatedAt"] || "", "", 80)
            return [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || item["event"] || "roachclaw.event", "roachclaw.event", 140)),
                "owner": JSON(JS.compactString(item["owner"] || "local-owner", "local-owner", 120)),
                "count": JSON(existingCount + increment),
                "threshold": safeIntegerOr(item["threshold"], min: 1, 1),
                "enabled": JSON((item["enabled"] ?? true).truthy),
                "lastFiredAt": fired.isEmpty ? item["updatedAt"] : JSON(fired),
                "actions": jsonStrings(JS.compactStringList(item["actions"] || item["triggers"], 12)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    // MARK: Mail

    func roachClawMailState() -> JSON {
        var state = readRoachClawState("mail.json", [
            "schema": "org.roachnet.roachclaw.mail.v1",
            "updatedAt": nil,
            "accounts": [],
            "messages": [],
            "drafts": [],
        ])
        if !state.isObject { state = .object(JSONObject()) }
        for key in ["accounts", "messages", "drafts"] where !state[key].isArray { state[key] = [] }
        return state
    }

    @discardableResult
    func writeRoachClawMailState(_ state: JSON) -> JSON {
        var next = state
        next["updatedAt"] = JSON(JS.isoNow())
        return writeRoachClawState("mail.json", next)
    }

    func upsertRoachClawMailMessage(_ body: JSON) -> JSON {
        withState {
            var state = roachClawMailState()
            let now = JS.isoNow()
            let id = JS.compactString(body["id"] || JSON("message_\(JS.randomHex(16))"), "", 80)
            var messages = state["messages"].array
            let existingIndex = messages.firstIndex { $0["id"].stringValue == id }
            let existing = existingIndex.map { messages[$0] } ?? .object(JSONObject())
            let message: JSON = [
                "id": JSON(id),
                "account": JSON(JS.compactString(body["account"] || existing["account"] || "local", "local", 120)),
                "folder": JSON(JS.compactString(body["folder"] || existing["folder"] || "Inbox", "Inbox", 120)),
                "from": nullIfEmpty(JS.compactString(body["from"] || existing["from"] || "", "", 180)),
                "to": jsonStrings(JS.compactStringList(body["to"] || existing["to"])),
                "subject": JSON(JS.compactString(body["subject"] || existing["subject"] || "Untitled message", "Untitled message", 220)),
                "preview": nullIfEmpty(JS.compactString(body["preview"] || body["body"] || existing["preview"] || "", "", 1200)),
                "tags": jsonStrings(JS.compactStringList(body["tags"] || existing["tags"])),
                "read": JSON((body["read"] ?? existing["read"] ?? false).truthy),
                "receivedAt": JSON(JS.compactString(body["receivedAt"] || existing["receivedAt"] || JSON(now), now, 80)),
                "createdAt": existing["createdAt"] || body["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            if let existingIndex { messages[existingIndex] = message } else { messages.insert(message, at: 0) }
            state["messages"] = .array(messages)
            return writeRoachClawMailState(state)
        }
    }

    func upsertRoachClawMailDraft(_ body: JSON) -> JSON {
        withState {
            var state = roachClawMailState()
            let now = JS.isoNow()
            let id = JS.compactString(body["id"] || JSON("draft_\(JS.randomHex(16))"), "", 80)
            var drafts = state["drafts"].array
            let existingIndex = drafts.firstIndex { $0["id"].stringValue == id }
            let existing = existingIndex.map { drafts[$0] } ?? .object(JSONObject())
            let draft: JSON = [
                "id": JSON(id),
                "account": JSON(JS.compactString(body["account"] || existing["account"] || "local", "local", 120)),
                "to": jsonStrings(JS.compactStringList(body["to"] || existing["to"])),
                "cc": jsonStrings(JS.compactStringList(body["cc"] || existing["cc"])),
                "subject": JSON(JS.compactString(body["subject"] || existing["subject"] || "Untitled draft", "Untitled draft", 220)),
                "body": JSON(JS.compactString(body["body"] || existing["body"] || "", "", 8000)),
                "status": JSON(JS.compactString(body["status"] || existing["status"] || "draft", "draft", 60)),
                "tags": jsonStrings(JS.compactStringList(body["tags"] || existing["tags"])),
                "createdAt": existing["createdAt"] || body["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            if let existingIndex { drafts[existingIndex] = draft } else { drafts.insert(draft, at: 0) }
            state["drafts"] = .array(drafts)
            return writeRoachClawMailState(state)
        }
    }

    func deleteRoachClawMailItem(_ collectionKey: String, _ rawId: String) throws -> JSON {
        guard ["messages", "drafts"].contains(collectionKey) else { throw requestError("Unsupported RoachMail collection.", 400) }
        let id = JS.compactString(JSON(decodeURIComponent(rawId)), "", 120)
        if id.isEmpty { throw requestError("Mail item id is missing.", 400) }
        return withState {
            var state = roachClawMailState()
            let before = state[collectionKey].array.count
            state[collectionKey] = .array(state[collectionKey].array.filter { $0["id"].stringValue != id })
            let written = writeRoachClawMailState(state)
            return ["success": true, "ok": true, "deleted": JSON(before != state[collectionKey].array.count), "id": JSON(id), "state": written]
        }
    }

    // MARK: Presets, signatures

    func roachClawPresetsState() -> JSON { roachClawCollectionState("presets.json", "templates") }

    func upsertRoachClawPreset(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("presets.json", "templates", body) { item in
            let temperature = item["temperature"].jsNumber
            let maxTokens = (item["maxTokens"] ?? item["max_tokens"]).jsNumber
            return [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || "Untitled preset", "Untitled preset", 120)),
                "systemPrompt": JSON(JS.compactString(item["systemPrompt"] || item["system_prompt"] || "", "", 10000)),
                "temperature": temperature.isFinite ? JSON(min(2, max(0, temperature))) : 0.7,
                "maxTokens": JSCoercion.isSafeInteger(maxTokens) ? JSON(max(0, maxTokens)) : 0,
                "enabled": JSON((item["enabled"] ?? true).truthy),
                "tags": jsonStrings(JS.compactStringList(item["tags"])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    func roachClawSignaturesState() -> JSON { roachClawCollectionState("signatures.json", "signatures") }

    func upsertRoachClawSignature(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("signatures.json", "signatures", body) { item in
            [
                "id": item["id"],
                "name": JSON(JS.compactString(item["name"] || "Signature", "Signature", 120)),
                "dataUrl": nullIfEmpty(JS.compactString(item["dataUrl"] || item["data_url"] || item["data"] || "", "", 500_000)),
                "width": safeIntegerOr(item["width"], nil),
                "height": safeIntegerOr(item["height"], nil),
                "source": JSON(JS.compactString(item["source"] || "local", "local", 80)),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }

    // MARK: API tokens

    func roachClawApiTokensState() -> JSON { roachClawCollectionState("api-tokens.json", "tokens") }

    private func stripTokenHash(_ record: JSON) -> JSON {
        var object = record.object
        object.remove("tokenHash")
        return .object(object)
    }

    func createRoachClawApiToken(_ body: JSON) -> JSON {
        withState {
            var state = roachClawApiTokensState()
            let now = JS.isoNow()
            let seed = "\(JS.randomUUID()):\(now):\(JS.compactString(body["name"], "", 120))"
            let rawToken = "rn_\(JS.slice(Encoding.base64url(SHA256Digest.bytes(seed)), 43))"
            let token: JSON = [
                "id": JSON("token_\(JS.randomHex(12))"),
                "name": JSON(JS.compactString(body["name"] || "RoachNet API token", "RoachNet API token", 120)),
                "owner": JSON(JS.compactString(body["owner"] || "local-owner", "local-owner", 120)),
                "tokenPrefix": nil,
                "tokenHash": JSON(SHA256Digest.hex(rawToken)),
                "scopes": jsonStrings(JS.compactStringList(body["scopes"] || ["chat"])),
                "isActive": JSON((body["isActive"] ?? true).truthy),
                "lastUsedAt": nil,
                "createdAt": JSON(now),
                "updatedAt": JSON(now),
            ]
            state["tokens"] = .array([token] + state["tokens"].array)
            state["updatedAt"] = JSON(now)
            writeRoachClawState("api-tokens.json", state)
            var publicState = state
            publicState["tokens"] = .array(state["tokens"].array.map(stripTokenHash))
            return [
                "success": true,
                "ok": true,
                "token": JSON(rawToken),
                "record": stripTokenHash(token),
                "state": publicState,
            ]
        }
    }

    func roachClawPublicApiTokensState() -> JSON {
        var state = roachClawApiTokensState()
        state["tokens"] = .array(state["tokens"].array.map(stripTokenHash))
        return state
    }

    func deleteRoachClawApiToken(_ rawId: String) throws -> JSON {
        var deleted = try deleteRoachClawCollectionItem("api-tokens.json", "tokens", rawId)
        deleted["state"] = roachClawPublicApiTokensState()
        return deleted
    }

    func roachClawBackupsState() -> JSON { roachClawCollectionState("backups.json", "snapshots") }

    // MARK: Cloud provider keys

    func roachClawCloudProviderDefinitions() -> [JSON] {
        [
            [
                "id": "openai", "name": "OpenAI", "envVar": "OPENAI_API_KEY", "baseUrl": "https://api.openai.com/v1",
                "scopes": ["chat", "models", "responses"],
                "summary": "Optional user-owned OpenAI route for cloud work the owner explicitly arms.",
            ],
            [
                "id": "anthropic", "name": "Anthropic", "envVar": "ANTHROPIC_API_KEY", "baseUrl": "https://api.anthropic.com",
                "scopes": ["chat", "models"],
                "summary": "Optional Claude route for users who bring their own Anthropic key.",
            ],
            [
                "id": "openrouter", "name": "OpenRouter", "envVar": "OPENROUTER_API_KEY", "baseUrl": "https://openrouter.ai/api/v1",
                "scopes": ["chat", "models", "router"],
                "summary": "Optional user-owned router lane for models outside the local stack.",
            ],
        ]
    }

    func normalizeRoachClawCloudProviderId(_ rawProvider: JSON) throws -> String {
        let normalized = JS.replace("[^a-z0-9-]", in: JS.compactString(rawProvider, "", 80).lowercased(), with: "")
        guard let definition = roachClawCloudProviderDefinitions().first(where: { $0["id"].stringValue == normalized }) else {
            let label = rawProvider.truthy ? rawProvider.jsString : "missing"
            throw RuntimeError("Unknown RoachClaw cloud provider: \(label)")
        }
        return definition["id"].jsString
    }

    func roachClawCloudProviderSecretPath(_ providerId: String) -> String { roachClawVaultPath("provider-secrets", "\(providerId).key") }
    func legacyRoachClawCloudProviderSecretPath(_ providerId: String) -> String { legacyRoachClawVaultPath("provider-secrets", "\(providerId).key") }

    /// The storage or runtime-state root that contains `stateDirectory`.
    func secretTrustRoot(for stateDirectory: String) -> String? {
        [config.storageRoot, config.runtimeStateRoot]
            .filter { stateDirectory.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    /// Rejects symlinked folders between the storage (or runtime-state) root
    /// and the secret, or non-directory secret folders. Symlinks at or above that root
    /// (macOS `/var` -> `/private/var`, a storage folder moved to another
    /// volume) are the user's own layout and are allowed.
    func isCloudProviderSecretDirectorySafe(_ secretDirectory: String, _ stateDirectory: String) -> Bool {
        guard let storageRoot = secretTrustRoot(for: stateDirectory) else { return false }
        var current = stateDirectory
        var ancestors: [String] = []
        while current != storageRoot && current.count > storageRoot.count {
            ancestors.append(current)
            current = Path.dirname(current)
        }
        for candidate in ancestors {
            guard let info = Files.lstatInfo(candidate) else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        for candidate in [stateDirectory, secretDirectory] {
            guard let info = Files.lstatInfo(candidate) else { return false }
            if (info.st_mode & S_IFMT) != S_IFDIR { return false }
        }
        return true
    }

    /// Hardened read: regular file, no symlinks, bounded size, stable inode.
    func readCloudProviderSecretFile(_ secretPath: String, _ source: String, _ stateDirectory: String) -> (source: String, value: String)? {
        guard isCloudProviderSecretDirectorySafe(Path.dirname(secretPath), stateDirectory),
              let initial = Files.lstatInfo(secretPath),
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size >= 1, initial.st_size <= 8_192
        else { return nil }
        let descriptor = open(secretPath, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_size == initial.st_size, opened.st_dev == initial.st_dev, opened.st_ino == initial.st_ino
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(opened.st_size))
        let bytesRead = pread(descriptor, &buffer, buffer.count, 0)
        var completed = stat()
        guard bytesRead == Int(opened.st_size), fstat(descriptor, &completed) == 0,
              completed.st_size == opened.st_size, completed.st_dev == opened.st_dev, completed.st_ino == opened.st_ino,
              isCloudProviderSecretDirectorySafe(Path.dirname(secretPath), stateDirectory),
              let resolved = Files.realpath(secretPath), SecretPathCheck.matches(resolved, secretTrustRoot(for: stateDirectory).flatMap { SecretPathCheck.expectedRealpath(secretPath, under: $0) }),
              let current = Files.statInfo(resolved), current.st_dev == completed.st_dev, current.st_ino == completed.st_ino
        else { return nil }
        let value = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : (source, value)
    }

    func resolveRoachClawCloudProviderSecret(_ providerId: String) -> (source: String, value: String)? {
        let candidates: [(String, String, String)] = [
            (roachClawCloudProviderSecretPath(providerId), "runtime-local-secret-file", config.roachClawStateRoot),
            (legacyRoachClawCloudProviderSecretPath(providerId), "legacy-local-secret-file", config.legacyRoachClawStateRoot),
        ]
        for (path, source, root) in candidates {
            if let secret = readCloudProviderSecretFile(path, source, root) { return secret }
        }
        return nil
    }

    func normalizePublicProviderBaseUrl(_ rawValue: JSON, _ fallback: String) throws -> String {
        let value = JS.compactString(rawValue || JSON(fallback), fallback, 240)
        guard var parsed = WebURL(value) else { throw requestError("Cloud provider base URL must be a valid URL", 400) }
        guard ["https", "http"].contains(parsed.scheme) else { throw requestError("Cloud provider base URL must use HTTP or HTTPS", 400) }
        let host = parsed.hostname.lowercased()
        let bare = parsed.bareHostname.lowercased()
        let literalIp = IPAddress.version(bare)
        let blockedHostnames = ["localhost", "localhost.localdomain"]
        let blockedSuffixes = [".local", ".lan", ".internal", ".home.arpa"]
        if blockedHostnames.contains(host)
            || blockedSuffixes.contains(where: { host.hasSuffix($0) })
            || (literalIp == 4 && JS.matches("^(10\\.|127\\.|169\\.254\\.|172\\.(1[6-9]|2\\d|3[0-1])\\.|192\\.168\\.)", host))
            || (literalIp == 6 && ["::1", "fc", "fd", "fe80"].contains(where: { bare.hasPrefix($0) }))
            || host.hasPrefix("[::1") || host.hasPrefix("[fc") || host.hasPrefix("[fd") || host.hasPrefix("[fe80")
        {
            throw requestError("Cloud provider base URL must be public; local/private targets belong in RoachNet local providers", 400)
        }
        parsed.fragment = nil
        parsed.query = nil
        var text = parsed.description
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func roachClawCloudProviderKeysState() -> JSON {
        var state = roachClawCollectionState("cloud-provider-keys.json", "providers")
        state["schema"] = "org.roachnet.roachclaw.cloud-provider-keys.v1"
        return state
    }

    func roachClawCloudProviderEnvMetadata(_ definition: JSON, _ now: String) -> JSON? {
        guard let rawKey = config.trimmedEnv(definition["envVar"].jsString), !rawKey.isEmpty else { return nil }
        return [
            "id": definition["id"],
            "provider": definition["id"],
            "name": definition["name"],
            "configured": true,
            "configuredVia": "environment",
            "tokenPrefix": nil,
            "baseUrl": definition["baseUrl"],
            "scopes": definition["scopes"],
            "isActive": true,
            "secretStorage": "process-env",
            "createdAt": JSON(now),
            "updatedAt": JSON(now),
        ]
    }

    func roachClawPublicCloudProviderKeysState() -> JSON {
        let state = roachClawCloudProviderKeysState()
        let now = JS.isoNow()
        var storedById: [String: JSON] = [:]
        for provider in state["providers"].array {
            var record = provider
            record["configured"] = true
            record["secretStorage"] = provider["secretStorage"] || "local-0600-file"
            storedById[(provider["provider"] || provider["id"]).jsString] = record
        }
        let providers: [JSON] = roachClawCloudProviderDefinitions().map { definition in
            let id = definition["id"].jsString
            let envProvider = roachClawCloudProviderEnvMetadata(definition, now)
            let stored = storedById[id] ?? .undefined
            let secret = resolveRoachClawCloudProviderSecret(id)
            var configured: JSON = .null
            if let envProvider {
                configured = envProvider
            } else if let secret {
                var record = stored.isObject ? stored : .object(JSONObject())
                record["configured"] = true
                record["configuredVia"] = JSON(secret.source)
                record["tokenPrefix"] = nil
                record["secretStorage"] = "local-0600-file"
                configured = record
            }
            return [
                "id": JSON(id),
                "provider": JSON(id),
                "name": definition["name"],
                "summary": definition["summary"],
                "baseUrl": configured["baseUrl"] || definition["baseUrl"],
                "scopes": configured["scopes"] || definition["scopes"],
                "configured": JSON(configured.truthy),
                "configuredVia": configured["configuredVia"] || "none",
                "tokenPrefix": configured["tokenPrefix"] || nil,
                "isActive": JSON((configured["isActive"] ?? false).truthy),
                "secretStorage": configured["secretStorage"] || "not-configured",
                "envVar": definition["envVar"],
                "createdAt": configured["createdAt"] || nil,
                "updatedAt": configured["updatedAt"] || nil,
            ]
        }
        return [
            "schema": state["schema"],
            "updatedAt": state["updatedAt"],
            "providers": .array(providers),
            "count": JSON(providers.count),
            "configured": JSON(providers.filter { $0["configured"].truthy }.count),
            "active": JSON(providers.filter { $0["isActive"].truthy }.count),
            "secretsPolicy": "user-owned-provider-keys-stay-local-and-are-never-returned-by-api",
        ]
    }

    func upsertRoachClawCloudProviderKey(_ body: JSON) throws -> JSON {
        let providerId = try normalizeRoachClawCloudProviderId(body["provider"] || body["id"])
        let definition = roachClawCloudProviderDefinitions().first { $0["id"].stringValue == providerId }!
        let name = definition["name"].jsString
        let supplied = (body["key"] || body["apiKey"] || body["token"] || "").jsString
        if supplied.utf8.count > 8_192 { throw RuntimeError("\(name) API key exceeds the 8192-byte limit") }
        let rawKey = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawKey.isEmpty { throw RuntimeError("Missing \(name) API key") }
        let baseUrl = try normalizePublicProviderBaseUrl(body["baseUrl"] || definition["baseUrl"], definition["baseUrl"].jsString)
        return try withState {
            let now = JS.isoNow()
            var state = roachClawCloudProviderKeysState()
            let secretPath = roachClawCloudProviderSecretPath(providerId)
            try Files.write(rawKey, to: secretPath, mode: 0o600)
            var providers = state["providers"].array
            let matches: (JSON) -> Bool = { $0["provider"].stringValue == providerId || $0["id"].stringValue == providerId }
            let record: JSON = [
                "id": JSON(providerId),
                "provider": JSON(providerId),
                "name": JSON(name),
                "configuredVia": "local-secret-file",
                "tokenPrefix": nil,
                "keyHash": JSON(SHA256Digest.hex(rawKey)),
                "baseUrl": JSON(baseUrl),
                "scopes": jsonStrings(JS.compactStringList(body["scopes"] || definition["scopes"], 12)),
                "isActive": JSON((body["isActive"] ?? true).truthy),
                "secretStorage": "local-0600-file",
                "createdAt": (providers.first(where: matches) ?? .undefined)["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            if let index = providers.firstIndex(where: matches) { providers[index] = record } else { providers.insert(record, at: 0) }
            state["providers"] = .array(providers)
            state["updatedAt"] = JSON(now)
            writeRoachClawState("cloud-provider-keys.json", state)
            let publicState = roachClawPublicCloudProviderKeysState()
            return [
                "success": true,
                "ok": true,
                "provider": publicState["providers"].array.first { $0["id"].stringValue == providerId } ?? .undefined,
                "state": publicState,
            ]
        }
    }

    func deleteRoachClawCloudProviderKey(_ rawProvider: String) throws -> JSON {
        let providerId = try normalizeRoachClawCloudProviderId(JSON(rawProvider))
        return withState {
            var state = roachClawCloudProviderKeysState()
            let before = state["providers"].array.count
            state["providers"] = .array(state["providers"].array.filter { ($0["provider"] || $0["id"]).jsString != providerId })
            state["updatedAt"] = JSON(JS.isoNow())
            writeRoachClawState("cloud-provider-keys.json", state)
            // Runtime-owned secret only; legacy copies stay untouched.
            Files.remove(roachClawCloudProviderSecretPath(providerId))
            return [
                "success": true,
                "ok": true,
                "deleted": JSON(before != state["providers"].array.count),
                "provider": JSON(providerId),
                "state": roachClawPublicCloudProviderKeysState(),
            ]
        }
    }

    // MARK: Workspace browser

    func roachClawWorkspaceBrowseRoot() -> String {
        Path.normalizeUserPath(config.env("ROACHNET_WORKSPACE_BROWSE_ROOT"), fallback: Host.homeDirectory)
    }

    func browseRoachClawWorkspace(_ rawPath: String) -> JSON {
        let fallbackRoot = roachClawWorkspaceBrowseRoot()
        let requested = Path.normalizeUserPath(rawPath, fallback: fallbackRoot)
        var resolved = fallbackRoot
        if let candidate = Files.realpath(requested), Files.isDirectory(candidate) { resolved = candidate }
        let dirs: [JSON] = Files.entries(resolved)
            .filter { $0.isDirectory && !$0.name.hasPrefix(".") }
            .compactMap { entry -> (String, JSON)? in
                let entryPath = Path.join(resolved, entry.name)
                guard let info = Files.lstatInfo(entryPath), (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
                return (entry.name, ["name": JSON(entry.name), "path": JSON(entryPath), "modifiedAt": JSON(Files.modificationISO(entryPath))])
            }
            .sorted { JS.localeCompare($0.0, $1.0, baseSensitivity: true) < 0 }
            .map { $0.1 }
        let parent = Path.dirname(resolved)
        return [
            "schema": "org.roachnet.roachclaw.workspace-browser.v1",
            "source": "github-upstream-workspace-routes-native-rewrite",
            "path": JSON(resolved),
            "parent": parent == resolved ? nil : JSON(parent),
            "dirs": .array(dirs),
            "count": JSON(dirs.count),
            "policy": "local-loopback-directories-only-hidden-and-symlinks-skipped",
        ]
    }

    // MARK: User time

    func systemTimeZoneName() -> String { TimeZone.current.identifier }

    func systemUTCOffsetMinutes() -> Double { Double(TimeZone.current.secondsFromGMT()) / 60 }

    func roachClawUserTimeState() -> JSON {
        let state = roachClawCollectionState("user-time.json", "contexts")
        let record = state["contexts"][0].isObject ? state["contexts"][0] : .object(JSONObject())
        let timeZoneName = JS.compactString(record["timeZoneName"] || JSON(systemTimeZoneName()) || "local", "local", 80)
        let offsetNumber = record["utcOffsetMinutes"].jsNumber
        let offsetMinutes = offsetNumber.isFinite ? max(-840, min(840, offsetNumber)) : systemUTCOffsetMinutes()
        let utcOffset = formatRoachClawUtcOffset(offsetMinutes)
        let localDateTime = NativeRuntime.localeDateTime(Date(), timeZoneName: timeZoneName)
        return [
            "schema": "org.roachnet.roachclaw.user-time.v1",
            "configured": JSON(state["contexts"][0].truthy),
            "timeZoneName": JSON(timeZoneName),
            "utcOffsetMinutes": JSON(offsetMinutes),
            "utcOffset": JSON(utcOffset),
            "localDateTime": JSON(localDateTime),
            "promptContext": JSON("User local time is \(localDateTime) (\(timeZoneName), UTC\(utcOffset))."),
            "updatedAt": state["updatedAt"],
        ]
    }

    /// `date.toLocaleString('en-US', { timeZone })`
    static func localeDateTime(_ date: Date, timeZoneName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy, h:mm:ss a"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        if timeZoneName != "local", let zone = TimeZone(identifier: timeZoneName) { formatter.timeZone = zone }
        return formatter.string(from: date)
    }

    func formatRoachClawUtcOffset(_ minutes: Double) -> String {
        let sign = minutes >= 0 ? "+" : "-"
        let absolute = abs(minutes)
        let hours = Int((absolute / 60).rounded(.down))
        let remainder = Int(absolute.truncatingRemainder(dividingBy: 60))
        return "\(sign)\(String(format: "%02d", hours)):\(String(format: "%02d", remainder))"
    }

    func upsertRoachClawUserTime(_ body: JSON) -> JSON {
        withState {
            var state = roachClawCollectionState("user-time.json", "contexts")
            let now = JS.isoNow()
            let offset = (body["utcOffsetMinutes"] ?? body["offsetMinutes"]).jsNumber
            let record: JSON = [
                "id": "local-user-time",
                "timeZoneName": JSON(JS.compactString(body["timeZoneName"] || body["timezone"] || JSON(systemTimeZoneName()) || "local", "local", 80)),
                "utcOffsetMinutes": JSON(offset.isFinite ? max(-840, min(840, JS.trunc(offset))) : systemUTCOffsetMinutes()),
                "source": JSON(JS.compactString(body["source"] || "native-settings", "native-settings", 80)),
                "createdAt": state["contexts"][0]["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            state["contexts"] = [record]
            state["updatedAt"] = JSON(now)
            writeRoachClawState("user-time.json", state)
            return roachClawUserTimeState()
        }
    }

    // MARK: Cookbook serve schedules

    func roachClawCookbookServeState() -> JSON {
        let state = roachClawCollectionState("cookbook-serve-schedules.json", "schedules")
        let now = JS.nowMs()
        let schedules: [JSON] = state["schedules"].array.map { schedule in
            let stopAt = (schedule["scheduledStopAtMs"] || 0).jsNumber
            let hasStop = stopAt != 0 && !stopAt.isNaN
            let isActive = schedule["isActive"].truthy
            var record = schedule
            record["active"] = JSON(isActive && (!hasStop || stopAt > now))
            record["expired"] = JSON(isActive && hasStop && stopAt <= now)
            return record
        }
        return [
            "schema": "org.roachnet.roachclaw.cookbook-serve-schedules.v1",
            "updatedAt": state["updatedAt"],
            "schedules": .array(schedules),
            "active": JSON(schedules.filter { $0["active"].truthy }.count),
            "pending": JSON(schedules.filter { ($0["status"] || "").jsString.lowercased() == "scheduled" }.count),
            "expired": JSON(schedules.filter { $0["expired"].truthy }.count),
            "policy": "local-scheduler-state-no-tmux-or-python-webui-required",
        ]
    }

    func upsertRoachClawCookbookServeSchedule(_ body: JSON) -> JSON {
        withState {
            let now = JS.isoNow()
            let duration = JS.clamp((body["durationMinutes"] || 60).jsNumber, 1, 24 * 60)
            let stopAt = body["scheduledStopAtMs"].jsNumber
            let defaultModel = self.defaultModel
            let record: JSON = [
                "id": JSON(JS.compactString(body["id"] || JSON("serve_\(JS.randomHex(12))"), "", 80)),
                "model": JSON(JS.compactString(body["model"] || body["modelName"] || JSON(defaultModel), defaultModel, 160)),
                "repoId": nullIfEmpty(JS.compactString(body["repoId"] || body["repository"] || "", "", 180)),
                "days": jsonStrings(JS.compactStringList(body["days"] || ["today"], 14)),
                "startTime": JSON(JS.compactString(body["startTime"] || "now", "now", 20)),
                "endTime": nullIfEmpty(JS.compactString(body["endTime"] || "", "", 20)),
                "durationMinutes": JSON(duration),
                "scheduledStopAtMs": (stopAt != 0 && !stopAt.isNaN) ? JSON(stopAt) : JSON(JS.nowMs() + duration * 60_000),
                "mirrorToCalendar": JSON(body["mirrorToCalendar"].truthy),
                "status": JSON(JS.compactString(body["status"] || "scheduled", "scheduled", 40)),
                "isActive": JSON((body["isActive"] ?? true).truthy),
                "createdAt": body["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            var state = roachClawCollectionState("cookbook-serve-schedules.json", "schedules")
            var schedules = state["schedules"].array
            if let index = schedules.firstIndex(where: { $0["id"] == record["id"] }) {
                schedules[index] = record
            } else {
                schedules.insert(record, at: 0)
            }
            state["schedules"] = .array(schedules)
            state["updatedAt"] = JSON(now)
            writeRoachClawState("cookbook-serve-schedules.json", state)
            return roachClawCookbookServeState()
        }
    }

    func computeRoachClawCookbookProgressSignal(_ body: JSON) -> JSON {
        let bytes = (body["bytes"] || body["receivedBytes"] || 0).jsNumber
        if bytes > 0 {
            return ["schema": "org.roachnet.roachclaw.progress-signal.v1", "signal": JSON("bytes:\(JSCoercion.format(number: bytes))"), "mode": "bytes"]
        }
        let aggregate = JS.compactString(body["downloadAggregate"] || body["dlAgg"] || "", "", 120)
        let lastPercentNumber = body["lastPercent"].jsNumber
        let lastPercent = lastPercentNumber.isFinite ? max(0, min(100, lastPercentNumber)) : 0
        let snapshotTail = JS.sliceTail(JS.compactString(body["snapshot"] || body["output"] || "", "", 4096), 300)
        let head = aggregate.isEmpty ? JSCoercion.format(number: lastPercent) : aggregate
        return [
            "schema": "org.roachnet.roachclaw.progress-signal.v1",
            "signal": JSON("\(head)|\(snapshotTail)"),
            "mode": "snapshot-tail",
        ]
    }

    // MARK: Scoped tools, TLS, upload limits

    func roachClawScopedToolBridgeState() -> JSON {
        [
            "schema": "org.roachnet.roachclaw.scoped-tool-bridge.v1",
            "source": "github-upstream-scoped-tool-routes-native-rewrite",
            "localOnly": true,
            "approvalRequired": true,
            "scopes": [
                "cookbook:read", "cookbook:launch", "todos:read", "todos:write", "memory:read", "memory:write",
                "calendar:read", "calendar:write", "documents:read", "documents:write", "documents:import",
                "email:read", "email:draft", "email:send", "diagnostics:read", "migration:read",
            ],
            "endpoints": [
                ["id": "capabilities", "method": "GET", "path": "/api/roachclaw/scoped-tools/capabilities", "scope": "tools:read"],
                ["id": "operations", "method": "GET", "path": "/api/roachclaw/operations", "scope": "operations:read"],
                ["id": "agent-run", "method": "POST", "path": "/api/roachclaw/agent/run", "scope": "agent:run"],
                ["id": "memory-provider", "method": "GET", "path": "/api/roachclaw/memory-provider", "scope": "memory:read"],
                ["id": "diagnostics-services", "method": "GET", "path": "/api/roachclaw/diagnostics/services", "scope": "diagnostics:read"],
                ["id": "migration-document-tools", "method": "GET", "path": "/api/roachclaw/migration-document-tools", "scope": "migration:read"],
            ],
            "safety": ["loopback-native-api", "owner-scoped-state", "raw-secrets-redacted", "action-approval-required"],
        ]
    }

    func roachClawTlsOverridesState() -> JSON {
        let state = roachClawCollectionState("tls-overrides.json", "overrides")
        let record = state["overrides"][0]
        let bundlePath = JS.compactString(record["bundlePath"] || JSON(config.env("LLM_CA_BUNDLE")) || "", "", 512)
        let resolved = Path.normalizeUserPath(bundlePath, fallback: bundlePath)
        let valid = !bundlePath.isEmpty && Files.isFile(resolved)
        return [
            "schema": "org.roachnet.roachclaw.tls-overrides.v1",
            "configured": JSON(!bundlePath.isEmpty),
            "valid": JSON(valid),
            "bundleLabel": JSON(bundlePath.isEmpty ? "system trust" : Path.basename(bundlePath)),
            "bundlePath": bundlePath.isEmpty ? nil : "[local-path-redacted]",
            "scope": "llm-provider-probes-only",
            "verifyMode": "default-plus-operator-ca-bundle",
            "insecureDisableAllowed": false,
            "updatedAt": state["updatedAt"],
        ]
    }

    func upsertRoachClawTlsOverride(_ body: JSON) throws -> JSON {
        let bundlePath = JS.compactString(body["bundlePath"] || body["path"] || "", "", 512)
        if bundlePath.isEmpty {
            writeRoachClawState("tls-overrides.json", ["schema": "org.roachnet.roachclaw.tls-overrides.v1", "updatedAt": JSON(JS.isoNow()), "overrides": []])
            return roachClawTlsOverridesState()
        }
        let resolvedPath = Path.normalizeUserPath(bundlePath, fallback: bundlePath)
        guard Files.isFile(resolvedPath) else { throw requestError("TLS CA bundle path must point at a local PEM file", 400) }
        let now = JS.isoNow()
        writeRoachClawState("tls-overrides.json", [
            "schema": "org.roachnet.roachclaw.tls-overrides.v1",
            "updatedAt": JSON(now),
            "overrides": [[
                "id": "llm-provider-ca-bundle",
                "bundlePath": JSON(resolvedPath),
                "scope": "llm-provider-probes-only",
                "verifyMode": "default-plus-operator-ca-bundle",
                "createdAt": JSON(now),
                "updatedAt": JSON(now),
            ]],
        ])
        return roachClawTlsOverridesState()
    }

    func roachClawUploadLimitsState() -> JSON {
        let limits: [JSON] = config.uploadLimitPolicies.map { limit in
            let bytes = limit["bytes"]
            let formatted = bytes.truthy
                ? formatByteLimit(bytes.jsNumber)
                : "\(JSCoercion.format(number: JS.round(limit["milliseconds"].jsNumber / 1000)))s"
            var record = limit
            record["formatted"] = JSON(formatted)
            record["tunable"] = true
            let label = limit["label"].jsString
            record["publicError"] = JSON(bytes.truthy ? "\(label) exceeds \(formatted) limit." : "\(label) exceeded \(formatted).")
            return record
        }
        var laneCounts = JSONObject()
        for limit in limits {
            let lane = limit["lane"].jsString
            laneCounts[lane] = JSON(((laneCounts[lane].numberValue) ?? 0) + 1)
        }
        return [
            "schema": "org.roachnet.roachclaw.upload-limits.v1",
            "source": "github-upstream-upload-limits-native-rewrite",
            "upstreamModule": "src/upload_limits.py",
            "policyVersion": "2026-06-08",
            "limits": .array(limits),
            "laneCounts": .object(laneCounts),
            "summaryItems": .array(limits.map { JSON("\($0["label"].jsString): \($0["formatted"].jsString)") }),
            "policy": "centralized-hard-caps-public-413-clean-partial-files",
            "envPrefix": "ROACHNET_*",
            "defaultPosture": "bounded-local-intake-no-unlimited-uploads",
        ]
    }

    func formatByteLimit(_ limit: Double) -> String {
        let gb = 1024.0 * 1024 * 1024
        let mb = 1024.0 * 1024
        if limit.truncatingRemainder(dividingBy: gb) == 0 { return "\(JSCoercion.format(number: limit / gb)) GB" }
        if limit.truncatingRemainder(dividingBy: mb) == 0 { return "\(JSCoercion.format(number: limit / mb)) MB" }
        if limit.truncatingRemainder(dividingBy: 1024) == 0 { return "\(JSCoercion.format(number: limit / 1024)) KB" }
        return "\(JSCoercion.format(number: limit)) bytes"
    }

    // MARK: Memory provider and OAuth

    func roachClawMemoryProviderState() -> JSON {
        let state = roachClawCollectionState("memory-provider.json", "providers")
        let nativeProvider: JSON = [
            "id": "roachbrain-native",
            "providerId": "native",
            "displayName": "RoachBrain native memory",
            "enabled": true,
            "storagePath": JSON(roachClawVaultPath("memories.json")),
            "tools": ["remember", "recall", "list", "delete"],
            "localFirst": true,
        ]
        let configured = state["providers"].array.filter { $0["id"].stringValue != "roachbrain-native" }
        return [
            "schema": "org.roachnet.roachclaw.memory-provider.v1",
            "providers": .array([nativeProvider] + configured),
            "policy": "native-provider-always-available-external-providers-opt-in",
            "updatedAt": state["updatedAt"],
        ]
    }

    func upsertRoachClawMemoryProvider(_ body: JSON) -> JSON {
        withState {
            let now = JS.isoNow()
            let provider: JSON = [
                "id": JSON(JS.compactString(body["id"] || body["providerId"] || JSON("provider_\(JS.randomHex(10))"), "", 80)),
                "providerId": JSON(JS.compactString(body["providerId"] || body["id"] || "external", "external", 80)),
                "displayName": JSON(JS.compactString(body["displayName"] || body["name"] || "External memory provider", "External memory provider", 140)),
                "enabled": JSON((body["enabled"] ?? false).truthy),
                "localFirst": JSON((body["localFirst"] ?? false).truthy),
                "tools": jsonStrings(JS.compactStringList(body["tools"] || [])),
                "createdAt": body["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            var state = roachClawCollectionState("memory-provider.json", "providers")
            var providers = state["providers"].array.filter { $0["id"] != provider["id"] }
            if provider["id"].stringValue != "roachbrain-native" { providers.insert(provider, at: 0) }
            state["providers"] = .array(providers)
            state["updatedAt"] = provider["updatedAt"]
            writeRoachClawState("memory-provider.json", state)
            return roachClawMemoryProviderState()
        }
    }

    func roachClawProviderOAuthState() -> JSON {
        let state = roachClawCollectionState("provider-oauth.json", "flows")
        let flows: [JSON] = state["flows"].array.map { flow in
            var object = flow.object
            for secret in ["token", "refreshToken", "accessToken"] { object.remove(secret) }
            return .object(object)
        }
        return [
            "schema": "org.roachnet.roachclaw.provider-oauth.v1",
            "redirectBase": "roachnet://provider-oauth/callback",
            "authWaitSeconds": 300,
            "flows": .array(flows),
            "policy": "user-owned-remote-tools-only-token-material-never-exported",
            "updatedAt": state["updatedAt"],
        ]
    }

    func upsertRoachClawProviderOAuthFlow(_ body: JSON) throws -> JSON {
        let serverUrl: JSON = body["serverUrl"].truthy
            ? JSON(try normalizePublicProviderBaseUrl(body["serverUrl"], body["serverUrl"].jsString))
            : .null
        return withState {
            let now = JS.isoNow()
            let flow: JSON = [
                "id": JSON(JS.compactString(body["id"] || JSON("oauth_\(JS.randomHex(12))"), "", 80)),
                "provider": JSON(JS.compactString(body["provider"] || "mcp-server", "mcp-server", 120)),
                "serverUrl": serverUrl,
                "scopes": jsonStrings(JS.compactStringList(body["scopes"] || [])),
                "status": JSON(JS.compactString(body["status"] || "needs-user-authorization", "needs-user-authorization", 80)),
                "needsUserAction": JSON((body["needsUserAction"] ?? true).truthy),
                "isActive": JSON((body["isActive"] ?? false).truthy),
                "authUrl": body["authUrl"].truthy ? "[redacted-user-auth-url]" : nil,
                "createdAt": body["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            var state = roachClawCollectionState("provider-oauth.json", "flows")
            var flows = state["flows"].array
            if let index = flows.firstIndex(where: { $0["id"] == flow["id"] }) { flows[index] = flow } else { flows.insert(flow, at: 0) }
            state["flows"] = .array(flows)
            state["updatedAt"] = JSON(now)
            writeRoachClawState("provider-oauth.json", state)
            return roachClawProviderOAuthState()
        }
    }

    // MARK: Embedding lanes

    func roachClawEmbeddingFingerprint(_ laneName: String, _ endpoint: String, _ model: String, _ dimension: Double?) -> String {
        let dimensionText = dimension.map { $0 == 0 || $0.isNaN ? "0" : JSCoercion.format(number: $0) } ?? "0"
        return String(SHA256Digest.hex("\(laneName)\n\(endpoint)\n\(model)\n\(dimensionText)").prefix(16))
    }

    func sanitizeEmbeddingEndpoint(_ rawValue: JSON) -> String {
        let raw = JS.compactString(rawValue, "", 512)
        if raw.isEmpty { return "" }
        guard var parsed = WebURL(raw) else { return raw.hasPrefix("local://") ? raw : "" }
        guard ["http", "https", "file", "local"].contains(parsed.scheme) else { return "" }
        parsed.username = ""
        parsed.password = ""
        parsed.query = nil
        parsed.fragment = nil
        var text = parsed.description
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func endpointDisplayLabel(_ rawEndpoint: String) -> String {
        guard let parsed = WebURL(rawEndpoint) else { return JS.compactString(JSON(rawEndpoint), "", 160) }
        if parsed.scheme == "local" { return rawEndpoint }
        let pathLabel = !parsed.pathname.isEmpty && parsed.pathname != "/" ? parsed.pathname : ""
        return "\(parsed.protocol)//\(parsed.host)\(pathLabel)"
    }

    func roachClawEmbeddingLanesState() -> JSON {
        let state = roachClawCollectionState("embedding-lanes.json", "lanes")
        let memories = roachClawMemoriesState()["memories"].array.count
        let skills = roachClawSkillsState()["skills"].array.count
        let searchCache = roachClawSearchCacheState()["entries"].array.count
        let tools = roachClawToolIndexState()["tools"].array.count
        let localDimension = max(1, JS.trunc((JSON(config.env("ROACHNET_LOCAL_EMBEDDING_DIMENSION")) || 384).jsNumber))
        let localModel = JS.compactString(JSON(config.env("ROACHNET_LOCAL_EMBEDDING_MODEL")) || "roachbrain-native-local-embeddings", "roachbrain-native-local-embeddings", 160)
        let localEndpoint = "local://roachbrain"
        let localIndexedCount = memories + skills + searchCache + tools
        let configuredCustom = state["lanes"].array.first { $0["id"].stringValue == "custom" || $0["name"].stringValue == "custom" } ?? .object(JSONObject())
        let customEndpoint = sanitizeEmbeddingEndpoint(
            configuredCustom["endpointUrl"] || configuredCustom["url"] || JSON(config.env("ROACHNET_CUSTOM_EMBEDDING_URL")) || JSON(config.env("EMBEDDING_URL")) || ""
        )
        let customModel = JS.compactString(
            configuredCustom["model"] || JSON(config.env("ROACHNET_CUSTOM_EMBEDDING_MODEL")) || JSON(config.env("EMBEDDING_MODEL")) || "", "", 160
        )
        let customDimension = (configuredCustom["dimension"] || JSON(config.env("ROACHNET_CUSTOM_EMBEDDING_DIMENSION")) || 0).jsNumber
        let customEnabled = (configuredCustom["enabled"] ?? JSON(!customEndpoint.isEmpty || !customModel.isEmpty || (customDimension != 0 && !customDimension.isNaN))).truthy
        let customHealthy = customEnabled && !customEndpoint.isEmpty && !customModel.isEmpty && JSCoercion.isSafeInteger(customDimension) && customDimension > 0
        let lastReset = state["lastResetAt"] || nil
        let customLane: JSON = [
            "id": "custom",
            "name": "custom",
            "label": "Custom",
            "kind": "custom",
            "enabled": JSON(customEnabled),
            "collectionName": "roachbrain_custom",
            "model": customModel.isEmpty ? nil : JSON(customModel),
            "endpoint": customEndpoint.isEmpty ? nil : "[user-owned-endpoint-redacted]",
            "endpointLabel": customEndpoint.isEmpty ? nil : JSON(endpointDisplayLabel(customEndpoint)),
            "dimension": customHealthy ? JSON(customDimension) : nil,
            "fingerprint": customHealthy ? JSON(roachClawEmbeddingFingerprint("custom", customEndpoint, customModel, customDimension)) : nil,
            "indexedCount": 0,
            "health": [
                "status": JSON(customHealthy ? "healthy" : (customEnabled ? "needs-configuration" : "not-configured")),
                "healthy": JSON(customHealthy),
                "reason": JSON(customHealthy
                    ? "custom embedding lane metadata is complete"
                    : "custom lane needs endpoint, model, and dimension before it can be promoted"),
            ],
            "resetSafety": [
                "destructiveResetAllowed": false,
                "preservePreviousLane": true,
                "requiresReindexBeforePromotion": true,
                "resetReasons": ["dimension-change", "model-change", "fingerprint-change"],
                "lastResetAt": lastReset,
            ],
        ]
        let localLane: JSON = [
            "id": "local",
            "name": "local",
            "label": "Local",
            "kind": "local",
            "enabled": true,
            "collectionName": "roachbrain_local",
            "model": JSON(localModel),
            "endpoint": JSON(localEndpoint),
            "endpointLabel": "RoachBrain local",
            "dimension": JSON(localDimension),
            "fingerprint": JSON(roachClawEmbeddingFingerprint("local", localEndpoint, localModel, localDimension)),
            "indexedCount": JSON(localIndexedCount),
            "health": [
                "status": "healthy",
                "healthy": true,
                "reason": "native local lane is always available without Chroma, Flask, or WebUI coupling",
            ],
            "resetSafety": [
                "destructiveResetAllowed": false,
                "preservePreviousLane": true,
                "requiresReindexBeforePromotion": false,
                "resetReasons": ["native-index-rebuild"],
                "lastResetAt": lastReset,
            ],
        ]
        let lanes = [customLane, localLane]
        let active = lanes.filter { $0["enabled"].truthy }
        let healthy = active.filter { $0["health"]["healthy"].truthy }
        return [
            "schema": "org.roachnet.roachbrain.embedding-lanes.v1",
            "source": "github-upstream-embedding-lanes-native-rewrite",
            "updatedAt": state["updatedAt"],
            "localFirst": true,
            "pythonRuntimeDependency": "none",
            "storagePath": JSON(roachClawVaultPath("embedding-lanes.json")),
            "preferredOrder": ["custom", "local"],
            "lanes": .array(lanes),
            "stats": [
                "laneCount": JSON(lanes.count),
                "activeLaneCount": JSON(active.count),
                "healthyLaneCount": JSON(healthy.count),
                "totalIndexedRecords": JSON(localIndexedCount),
                "memories": JSON(memories),
                "skills": JSON(skills),
                "searchCache": JSON(searchCache),
                "tools": JSON(tools),
            ],
            "resetSafety": [
                "destructiveResetAllowed": false,
                "resetEndpoint": "/api/roachclaw/embedding-lanes",
                "policy": "metadata-first-reset-preserves-old-lane-until-reindex-succeeds",
                "lastResetAt": lastReset,
            ],
            "health": [
                "status": JSON(healthy.isEmpty ? "needs-attention" : "healthy"),
                "healthy": JSON(!healthy.isEmpty),
                "warnings": customEnabled && !customHealthy ? ["Custom embedding lane is incomplete and will not be promoted."] : [],
            ],
        ]
    }

    func upsertRoachClawEmbeddingLane(_ body: JSON) throws -> JSON {
        let laneId = JS.compactString(body["id"] || body["name"] || body["lane"] || "custom", "custom", 80)
        guard laneId == "custom" else {
            throw requestError("Only the custom embedding lane is configurable from the native API.", 400)
        }
        return withState {
            let now = JS.isoNow()
            var state = roachClawCollectionState("embedding-lanes.json", "lanes")
            if body["reset"] == .bool(true) || body["resetRequested"] == .bool(true) { state["lastResetAt"] = JSON(now) }
            let dimension = (body["dimension"] || body["dimensions"] || 0).jsNumber
            let lane: JSON = [
                "id": "custom",
                "name": "custom",
                "endpointUrl": JSON(sanitizeEmbeddingEndpoint(body["endpointUrl"] || body["url"] || body["endpoint"] || "")),
                "model": JSON(JS.compactString(body["model"] || "", "", 160)),
                "dimension": JSCoercion.isSafeInteger(dimension) && dimension > 0 ? JSON(dimension) : nil,
                "enabled": JSON((body["enabled"] ?? true).truthy),
                "createdAt": (state["lanes"].array.first(where: { $0["id"].stringValue == "custom" }) ?? .undefined)["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            let others = state["lanes"].array.filter { $0["id"].stringValue != "custom" && $0["name"].stringValue != "custom" }
            state["lanes"] = .array([lane] + others)
            state["updatedAt"] = JSON(now)
            writeRoachClawState("embedding-lanes.json", state)
            return roachClawEmbeddingLanesState()
        }
    }

    // MARK: Tool policy

    static let commonToolNames = [
        "api_call", "app_api", "archive_email", "ask_teacher", "ask_user", "bash", "builtin_browser", "chat_with_model",
        "create_document", "create_session", "delete_email", "download_model", "edit_document", "edit_file", "generate_image",
        "glob", "grep", "list_models", "ls", "manage_calendar", "manage_contact", "manage_documents", "manage_mcp",
        "manage_memory", "manage_notes", "manage_session", "manage_settings", "manage_tasks", "python", "read_file",
        "search_chats", "send_email", "ui_control", "update_plan", "vault_get", "vault_search", "web_fetch", "web_search",
        "write_file",
    ]

    static let guideOnlyPatterns: [(String, String)] = [
        ("\\bguide[-\\s]?only mode\\b", "guide-only mode requested"),
        ("\\bno[-\\s]?tools? mode\\b", "no-tools mode requested"),
        ("\\bdo not use (?:any )?tools?\\b", "user forbade tool use"),
        ("\\bdon'?t use (?:any )?tools?\\b", "user forbade tool use"),
        ("\\bnot allowed to use (?:any )?tools?\\b", "user forbade tool use"),
        ("\\bnot allowed to:?.{0,120}\\buse (?:any )?tools?\\b", "user forbade tool use"),
        ("\\bask (?:me )?(?:for confirmation )?before using tools?\\b", "user requested confirmation before tools"),
    ]

    func detectRoachClawGuideOnlyTurn(_ message: JSON) -> String? {
        let text = JS.compactString(message, "", 20_000)
        if text.isEmpty { return nil }
        let normalized = JS.collapseWhitespace(text)
        for (pattern, reason) in NativeRuntime.guideOnlyPatterns where JS.matches(pattern, normalized, caseInsensitive: true) {
            return reason
        }
        return nil
    }

    func roachClawKnownToolNames() -> [String] {
        var names = Set(NativeRuntime.commonToolNames)
        for tool in roachClawToolIndexState()["tools"].array {
            let name = JS.compactString(tool["name"] || tool["id"], "", 120)
            if !name.isEmpty { names.insert(name) }
        }
        for endpoint in roachClawScopedToolBridgeState()["endpoints"].array {
            if let id = endpoint["id"].stringValue, !id.isEmpty { names.insert(id) }
        }
        return JS.sortedLocale(Array(names))
    }

    func roachClawToolPolicyState(_ input: JSON = .object(JSONObject())) -> JSON {
        let state = roachClawCollectionState("tool-policy.json", "disabledTools")
        let requestedDisabled = JS.compactStringList(input["disabledTools"] || input["disabled"] || [], 200)
        let persistedDisabled = JS.compactStringList(state["disabledTools"] || [], 200)
        let knownTools = roachClawKnownToolNames()
        var disabledOrdered: [String] = []
        for tool in persistedDisabled + requestedDisabled where !tool.isEmpty && !disabledOrdered.contains(tool) { disabledOrdered.append(tool) }
        var hidden: [String] = []
        var reasons = JSONObject()
        for tool in disabledOrdered { reasons[tool] = "Tool is disabled for this request." }
        let guideReason = detectRoachClawGuideOnlyTurn(input["lastUserMessage"] || input["message"] || "")
        if let guideReason {
            for tool in knownTools {
                if !disabledOrdered.contains(tool) { disabledOrdered.append(tool) }
                if !hidden.contains(tool) { hidden.append(tool) }
                reasons[tool] = JSON("\(guideReason).")
            }
        }
        let disabledTools = JS.sortedLocale(disabledOrdered)
        let hiddenTools = JS.sortedLocale(hidden)
        let guide = guideReason != nil
        return [
            "schema": "org.roachnet.roachclaw.tool-policy.v1",
            "source": "github-upstream-tool-policy-native-rewrite",
            "mode": JSON(guide ? "guide_only" : "normal"),
            "guideOnlyDetected": JSON(guide),
            "guideOnlyReason": JSON(guideReason),
            "blockAllToolCalls": JSON(guide),
            "disableMcp": JSON(guide),
            "knownToolCount": JSON(Set(knownTools).count),
            "disabledCount": JSON(disabledTools.count),
            "hiddenCount": JSON(hiddenTools.count),
            "disabledTools": jsonStrings(disabledTools),
            "hiddenTools": jsonStrings(hiddenTools),
            "reasons": .object(reasons),
            "enforcement": [
                "promptDirectiveInjected": JSON(guide),
                "functionSchemasHidden": JSON(guide),
                "mcpDiscoveryDisabled": JSON(guide),
                "executorBackstop": true,
                "nativeDisplayReady": true,
            ],
            "display": [
                "statusLabel": JSON(guide ? "Guide Only" : "Tools Allowed"),
                "summaryItems": [JSON(guide ? "guide-only" : "normal"), JSON("\(disabledTools.count) disabled"), JSON("\(hiddenTools.count) hidden")],
            ],
            "updatedAt": state["updatedAt"],
        ]
    }

    func upsertRoachClawToolPolicy(_ body: JSON) -> JSON {
        withState {
            var state = roachClawCollectionState("tool-policy.json", "disabledTools")
            state["disabledTools"] = jsonStrings(JS.compactStringList(body["disabledTools"] || body["disabled"] || [], 200))
            state["updatedAt"] = JSON(JS.isoNow())
            writeRoachClawState("tool-policy.json", state)
            return roachClawToolPolicyState(body)
        }
    }

    // MARK: Readiness and context budget

    func roachClawReadinessState() -> JSON {
        var checks = JSONObject()
        func checkWritableDirectory(_ id: String, _ target: String) {
            do {
                try Files.mkdirp(target)
                let probe = Path.join(target, ".roachnet-ready-\(JS.randomUUID())")
                guard FileManager.default.createFile(atPath: probe, contents: Data("ok".utf8)) else {
                    throw RuntimeError("EACCES: permission denied, open '\(probe)'")
                }
                Files.remove(probe)
                checks[id] = ["ok": true, "path": JSON(target)]
            } catch {
                checks[id] = ["ok": false, "path": JSON(target), "error": JSON("\(error)")]
            }
        }
        checkWritableDirectory("storageRoot", storageRoot)
        checkWritableDirectory("runtimeStateRoot", config.runtimeStateRoot)
        if vaultIsLocked {
            // An encrypted Vault that is locked is read-only on purpose; that's ready, not broken.
            checks["vaultRoot"] = ["ok": true, "path": JSON(Path.join(storageRoot, "Vault")), "locked": true]
        } else {
            checkWritableDirectory("vaultRoot", Path.join(storageRoot, "Vault"))
        }
        let localFirst = !JS.matches("^https?://", storageRoot, caseInsensitive: true) && Path.isAbsolute(storageRoot)
        checks["localFirst"] = ["ok": true, "local": JSON(localFirst)]
        let ready = checks.values.allSatisfy { $0["ok"].truthy }
        return [
            "schema": "org.roachnet.roachclaw.readiness.v1",
            "source": "github-upstream-readiness-native-rewrite",
            "ready": JSON(ready),
            "localFirst": JSON(localFirst),
            "version": JSON(version),
            "checks": .object(checks),
            "timestamp": JSON(JS.isoNow()),
        ]
    }

    func roachClawContextBudgetState() -> JSON {
        let state = roachClawCollectionState("context-budget.json", "profiles")
        let profile = state["profiles"][0].isObject ? state["profiles"][0] : .object(JSONObject())
        return computeRoachClawContextBudget(profile)
    }

    private func budgetValues(_ body: JSON) -> (configured: Double, modelContextLength: Double, explicit: Bool, headroom: Double, hardMax: Double) {
        let configured = max(0, JS.trunc((body["configuredBudget"] ?? body["configured"] ?? 6000).jsNumber))
        let modelContextLength = max(0, JS.trunc((body["modelContextLength"] ?? body["contextLength"] ?? 0).jsNumber))
        let explicit = body["explicit"].truthy
        let headroom = JS.clamp((body["headroom"] ?? 0.85).jsNumber, 0.1, 0.95)
        let hardMax = JS.clamp(JS.trunc((body["hardMax"] ?? 200_000).jsNumber), 1024, 1_000_000)
        return (configured, modelContextLength, explicit, headroom, hardMax)
    }

    func computeRoachClawContextBudget(_ body: JSON) -> JSON {
        let values = budgetValues(body)
        let configuredOr = (values.configured == 0 || values.configured.isNaN) ? 6000 : values.configured
        var effective = configuredOr
        if values.explicit && values.configured > 0 {
            effective = values.modelContextLength > 0 ? min(values.configured, values.modelContextLength) : values.configured
        } else if values.modelContextLength > 0 {
            effective = max(1, min(JS.trunc(values.modelContextLength * values.headroom), values.hardMax))
        }
        return [
            "schema": "org.roachnet.roachclaw.context-budget.v1",
            "source": "github-upstream-context-budget-native-rewrite",
            "configuredBudget": JSON(configuredOr),
            "modelContextLength": JSON(values.modelContextLength),
            "explicit": JSON(values.explicit),
            "headroom": JSON(values.headroom),
            "headroomPercent": JSON(JS.round(values.headroom * 100)),
            "hardMax": JSON(values.hardMax),
            "effectiveBudget": JSON(effective),
            "updatedAt": body["updatedAt"] || JSON(JS.isoNow()),
        ]
    }

    func upsertRoachClawContextBudget(_ body: JSON) -> JSON {
        withState {
            let now = JS.isoNow()
            let values = budgetValues(body)
            let record: JSON = [
                "id": "default-context-budget",
                "configuredBudget": JSON(values.configured),
                "modelContextLength": JSON(values.modelContextLength),
                "explicit": JSON(values.explicit),
                "headroom": JSON(values.headroom),
                "hardMax": JSON(values.hardMax),
                "createdAt": body["createdAt"] || JSON(now),
                "updatedAt": JSON(now),
            ]
            var state = roachClawCollectionState("context-budget.json", "profiles")
            state["profiles"] = [record]
            state["updatedAt"] = JSON(now)
            writeRoachClawState("context-budget.json", state)
            return computeRoachClawContextBudget(record)
        }
    }

    // MARK: Outbound URL safety

    func checkRoachClawOutboundUrl(_ rawUrl: JSON, blockPrivate: Bool = false) -> JSON {
        guard let text = rawUrl.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["ok": false, "reason": "URL is required"]
        }
        guard let parsed = WebURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["ok": false, "reason": "unparseable URL: Invalid URL"]
        }
        guard ["http", "https"].contains(parsed.scheme) else {
            return ["ok": false, "reason": JSON("scheme must be http or https, got '\(parsed.scheme.isEmpty ? "(none)" : parsed.scheme)'")]
        }
        let host = parsed.bareHostname
        if host.isEmpty { return ["ok": false, "reason": "URL has no host"] }
        let addresses = IPAddress.version(host) != 0 ? [host] : (DNS.addresses(host) ?? [])
        if addresses.isEmpty { return ["ok": false, "reason": "host does not resolve"] }
        for address in addresses {
            if let reason = classifyRoachClawOutboundAddress(address, blockPrivate: blockPrivate) {
                return ["ok": false, "reason": JSON(reason)]
            }
        }
        return ["ok": true, "reason": "ok"]
    }

    func classifyRoachClawOutboundAddress(_ address: String, blockPrivate: Bool) -> String? {
        let host = address.lowercased()
        if host.isEmpty { return "empty address" }
        if host.hasPrefix("169.254.") || host.hasPrefix("fe80:") { return "link-local address blocked (SSRF metadata risk): \(host)" }
        if JS.matches("^(0\\.|224\\.|239\\.)", host) || host == "::" || host.hasPrefix("ff") { return "disallowed address: \(host)" }
        if blockPrivate && (host == "localhost" || host == "::1" || JS.matches("^(10\\.|127\\.|172\\.(1[6-9]|2\\d|3[0-1])\\.|192\\.168\\.)", host) || host.hasPrefix("fc") || host.hasPrefix("fd")) {
            return "private/loopback address blocked: \(host)"
        }
        return nil
    }

    // MARK: Export and backups

    func roachClawExportPayload() -> JSON {
        let signatures: [JSON] = roachClawSignaturesState()["signatures"].array.map { signature in
            var record = signature
            record["dataUrl"] = signature["dataUrl"].truthy ? "[redacted-export-signature-payload]" : nil
            return record
        }
        return [
            "schema": "org.roachnet.roachclaw.export.v1",
            "exportedAt": JSON(JS.isoNow()),
            "contacts": roachClawContactsState()["contacts"],
            "tasks": roachClawTaskState()["tasks"],
            "calendar": roachClawCalendarState()["events"],
            "reports": roachClawReportsState()["reports"],
            "memories": roachClawMemoriesState()["memories"],
            "skills": roachClawSkillsState()["skills"],
            "editorDrafts": roachClawEditorDraftsState()["drafts"],
            "searchCache": roachClawSearchCacheState()["entries"],
            "gallery": roachClawGalleryState()["assets"],
            "webhooks": roachClawWebhooksState()["webhooks"],
            "agentRuns": roachClawAgentRunsState()["runs"],
            "contextCompactions": roachClawContextCompactionsState()["compactions"],
            "toolIndex": roachClawToolIndexState()["tools"],
            "events": roachClawEventsState()["events"],
            "mail": roachClawMailState(),
            "presets": roachClawPresetsState()["templates"],
            "signatures": .array(signatures),
            "apiTokens": roachClawPublicApiTokensState()["tokens"],
            "cloudProviders": roachClawPublicCloudProviderKeysState()["providers"],
            "userTime": roachClawUserTimeState(),
            "cookbookServeSchedules": roachClawCookbookServeState()["schedules"],
            "contextBudget": roachClawContextBudgetState(),
            "readiness": roachClawReadinessState(),
            "scopedToolBridge": roachClawScopedToolBridgeState(),
            "tlsOverrides": roachClawTlsOverridesState(),
            "uploadLimits": roachClawUploadLimitsState(),
            "memoryProvider": roachClawMemoryProviderState(),
            "providerOAuth": roachClawProviderOAuthState(),
            "embeddingLanes": roachClawEmbeddingLanesState(),
            "toolPolicy": roachClawToolPolicyState(),
        ]
    }

    func createRoachClawBackup(_ body: JSON) -> JSON {
        let exportPayload = roachClawExportPayload()
        let sections = exportPayload.object.filter { $0.value.isArray || $0.value.isObject || $0.value.isNull }.map { JSON($0.key) }
        let snapshot = upsertRoachClawBackupSnapshot([
            "title": body["title"] || JSON("RoachClaw backup \(JS.isoNow())"),
            "sections": .array(sections),
            "summary": JSON("Contacts \(exportPayload["contacts"].array.count), tasks \(exportPayload["tasks"].array.count), events \(exportPayload["calendar"].array.count), reports \(exportPayload["reports"].array.count)."),
        ])
        return ["success": true, "ok": true, "export": exportPayload, "snapshots": snapshot]
    }

    func upsertRoachClawBackupSnapshot(_ body: JSON) -> JSON {
        roachClawUpsertCollectionItem("backups.json", "snapshots", body) { item in
            [
                "id": item["id"],
                "title": JSON(JS.compactString(item["title"] || "RoachClaw backup", "RoachClaw backup", 180)),
                "summary": nullIfEmpty(JS.compactString(item["summary"] || "", "", 600)),
                "sections": jsonStrings(JS.compactStringList(item["sections"] || [])),
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            ]
        }
    }
}

/// The real path a secret must resolve to: the storage root may sit behind a
/// symlink, but nothing below it may.
enum SecretPathCheck {
    static func expectedRealpath(_ path: String, under root: String) -> String? {
        guard path.hasPrefix(root), let resolvedRoot = Files.realpath(root) else { return nil }
        return resolvedRoot + path.dropFirst(root.count)
    }

    /// macOS volumes are usually case-insensitive, so `vault/roachclaw` and
    /// `Vault/RoachClaw` can be the same folder and realpath reports the
    /// on-disk case. File identity is checked separately (device + inode).
    static func matches(_ resolved: String, _ expected: String?) -> Bool {
        guard let expected else { return false }
        #if canImport(Darwin)
        return resolved.compare(expected, options: [.caseInsensitive]) == .orderedSame
        #else
        return resolved == expected
        #endif
    }
}
