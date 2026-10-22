import Foundation

extension NativeRuntime {
    static let companionChatFile = "companion-chat.json"
    static let companionAccountFile = "companion-account.json"
    static let companionRoachSyncFile = "companion-roachsync.json"
    static let companionChatSessionLimit = 200
    static let companionChatHistoryLimit = 40

    func companionChatState() -> JSON {
        var state = readRoachClawState(
            Self.companionChatFile,
            [
                "schema": "org.roachnet.companion.chat.v1",
                "sessions": [],
            ])
        if !state.isObject { state = ["schema": "org.roachnet.companion.chat.v1", "sessions": []] }
        if !state["sessions"].isArray { state["sessions"] = [] }
        return state
    }

    func companionChatSummary(_ session: JSON) -> JSON {
        [
            "id": session["id"],
            "title": session["title"] || "New Chat",
            "model": session["model"] ?? nil,
            "timestamp": session["timestamp"] ?? nil,
        ]
    }

    func companionChatSessions() -> JSON {
        let sessions = companionChatState()["sessions"].array
            .sorted { ($0["timestamp"].stringValue ?? "") > ($1["timestamp"].stringValue ?? "") }
        return .array(sessions.map(companionChatSummary))
    }

    func companionChatSession(_ id: String) throws -> JSON {
        guard let session = companionChatState()["sessions"].array.first(where: { $0["id"].stringValue == id }) else {
            throw requestError("Session not found", 404)
        }
        return session
    }

    func newCompanionChatSession(title: String, model: String?) -> JSON {
        [
            "id": JSON(JS.randomUUID()),
            "title": JSON(title.isEmpty ? "New Chat" : title),
            "model": JSON(model),
            "timestamp": JSON(JS.isoNow()),
            "messages": [],
        ]
    }

    func companionChatMessage(_ role: String, _ content: String) -> JSON {
        let now = JS.isoNow()
        return [
            "id": JSON(JS.randomUUID()), "role": JSON(role), "content": JSON(content), "createdAt": JSON(now),
            "timestamp": JSON(now),
        ]
    }

    func storeCompanionChatSession(_ session: JSON) {
        var state = companionChatState()
        var sessions = state["sessions"].array.filter { $0["id"] != session["id"] } + [session]
        if sessions.count > Self.companionChatSessionLimit {
            sessions.sort { ($0["timestamp"].stringValue ?? "") < ($1["timestamp"].stringValue ?? "") }
            sessions.removeFirst(sessions.count - Self.companionChatSessionLimit)
        }
        state["sessions"] = .array(sessions)
        state["updatedAt"] = JSON(JS.isoNow())
        writeRoachClawState(Self.companionChatFile, state)
    }

    func createCompanionChatSession(_ body: JSON) -> JSON {
        let title = (body["title"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (body["model"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let session = newCompanionChatSession(title: title, model: model.isEmpty ? nil : model)
        withState { storeCompanionChatSession(session) }
        return session
    }

    func sendCompanionChatMessage(_ body: JSON, allowPlans: Bool) throws -> JSON {
        let content = (body["content"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw requestError("Message content is required", 400) }
        let images = body["images"].array.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(4)
        let visionSummary = (body["visionSummary"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let storedContent =
            visionSummary.isEmpty
            ? content
            : "\(content)\n\n[Vision attachment\(images.count > 1 ? "s" : ""): \(images.count)]\n\(visionSummary)"
        let requestedModel = (body["model"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedId =
            body["sessionId"].stringValue ?? (body["sessionId"].numberValue.map { JSCoercion.format(number: $0) } ?? "")

        let userMessage = companionChatMessage("user", storedContent)
        let (sessionId, model, history): (JSON, String, [JSON]) = try withState {
            var session =
                companionChatState()["sessions"].array.first { $0["id"].stringValue == requestedId }
                ?? newCompanionChatSession(title: "New Chat", model: requestedModel.isEmpty ? nil : requestedModel)
            let model =
                !requestedModel.isEmpty
                ? requestedModel : (session["model"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel)
            try requirePlanAccess(model: model, owner: allowPlans)
            session["messages"] = .array(session["messages"].array + [userMessage])
            session["timestamp"] = JSON(JS.isoNow())
            storeCompanionChatSession(session)
            return (session["id"], model, Array(session["messages"].array.suffix(Self.companionChatHistoryLimit)))
        }

        var outbound: [JSON] = history.map { ["role": $0["role"], "content": $0["content"]] }
        if !images.isEmpty && !model.lowercased().hasSuffix(":cloud"), var last = outbound.popLast() {
            last["images"] = JSON(Array(images))
            outbound.append(last)
        }
        let reply = handleChat(
            ["model": JSON(model), "messages": .array(outbound), "stream": false], sessionId: sessionId.stringValue,
            source: "companion", allowPlans: allowPlans)
        let assistantContent = (reply["message"]["content"].stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        if reply["error"].stringValue != nil || assistantContent.isEmpty
            || assistantContent.hasPrefix("Local model route is not ready")
        {
            throw requestError(
                "RoachClaw can't reach a local model right now. Start it from Runtime on your Mac; everything else still works.",
                503)
        }

        let assistantMessage = companionChatMessage("assistant", assistantContent)
        let summary: JSON = withState {
            var session =
                companionChatState()["sessions"].array.first { $0["id"] == sessionId }
                ?? newCompanionChatSession(title: "New Chat", model: model)
            session["messages"] = .array(session["messages"].array + [assistantMessage])
            session["model"] = JSON(model)
            session["timestamp"] = JSON(JS.isoNow())
            if (session["title"].stringValue ?? "New Chat") == "New Chat" {
                let line = content.split(separator: "\n").first.map(String.init) ?? content
                session["title"] = JSON(String(line.prefix(57)))
            }
            storeCompanionChatSession(session)
            return companionChatSummary(session)
        }
        return ["session": summary, "userMessage": userMessage, "assistantMessage": assistantMessage]
    }

    func affectCompanionService(_ body: JSON) throws -> JSON {
        let serviceName = (body["serviceName"].stringValue ?? body["service_name"].stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (body["action"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if serviceName.isEmpty { throw requestError("Service name is required", 400) }
        guard ["start", "stop", "restart"].contains(action) else {
            throw requestError("Service action must be start, stop, or restart", 400)
        }
        guard serviceCatalog.contains(where: { $0["service_name"].stringValue == serviceName }) else {
            throw requestError("Unknown RoachNet service: \(serviceName)", 404)
        }
        if serviceName == "roachnet_ollama" && (action == "start" || action == "restart") { ensureOllama() }
        return [
            "ok": true,
            "serviceName": JSON(serviceName),
            "action": JSON(action),
            "result": ["success": true, "ok": true, "message": JSON("\(action) request recorded.")],
        ]
    }

    func storedCompanionAccount() -> JSON { readRoachClawState(Self.companionAccountFile, [:]) }

    func affectCompanionAccount(_ body: JSON) throws -> JSON {
        let action = (body["action"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["link", "unlink", "refresh"].contains(action) else {
            throw requestError("Account action must be link, unlink, or refresh.", 400)
        }
        let now = JS.isoNow()
        withState {
            var stored = storedCompanionAccount()
            if !stored.isObject { stored = [:] }
            switch action {
            case "link":
                let email = (body["email"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (body["displayName"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                stored["linked"] = true
                stored["status"] = "linked"
                stored["email"] = email.isEmpty ? stored["email"] ?? nil : JSON(email)
                stored["displayName"] = name.isEmpty ? stored["displayName"] ?? nil : JSON(name)
                stored["accountId"] = stored["accountId"] || JSON("acct_\(JS.randomHex(8))")
                for key in ["settingsSyncEnabled", "savedAppsSyncEnabled", "hostedChatEnabled"]
                where body[key].boolValue != nil {
                    stored[key] = body[key]
                }
                stored["linkedAt"] = JSON(now)
            case "unlink":
                stored = ["linked": false, "status": "local-only"]
            default:
                break
            }
            stored["lastUpdatedAt"] = JSON(now)
            writeRoachClawState(Self.companionAccountFile, stored)
        }
        let message =
            action == "link"
            ? "RoachNet account linked."
            : action == "unlink" ? "RoachNet account unlinked." : "RoachNet account refreshed."
        return ["success": true, "message": JSON(message), "state": accountState()]
    }

    func storedCompanionRoachSync() -> JSON { readRoachClawState(Self.companionRoachSyncFile, [:]) }

    func affectCompanionRoachSync(_ body: JSON) throws -> JSON {
        let action = (body["action"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["enable", "disable", "refresh", "set-folder-path", "clear-peers"].contains(action) else {
            throw requestError(
                "RoachSync action must be enable, disable, refresh, set-folder-path, or clear-peers.", 400)
        }
        var folderPath: String?
        if action == "set-folder-path" {
            let raw = (body["folderPath"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw requestError("RoachSync needs an existing folder on this Mac.", 400)
            }
            folderPath = expanded
        }
        withState {
            var stored = storedCompanionRoachSync()
            if !stored.isObject { stored = [:] }
            switch action {
            case "enable":
                stored["enabled"] = true
                stored["status"] = "armed"
            case "disable":
                stored["enabled"] = false
                stored["status"] = "local-only"
            case "set-folder-path": stored["folderPath"] = JSON(folderPath)
            case "clear-peers": stored["peers"] = []
            default: break
            }
            stored["lastUpdatedAt"] = JSON(JS.isoNow())
            writeRoachClawState(Self.companionRoachSyncFile, stored)
        }
        let messages = [
            "enable": "RoachSync enabled.", "disable": "RoachSync disabled.",
            "set-folder-path": "RoachSync folder updated.", "clear-peers": "RoachSync peers cleared.",
            "refresh": "RoachSync refreshed.",
        ]
        return [
            "success": true, "message": JSON(messages[action] ?? "RoachSync refreshed."), "state": roachSyncState(),
        ]
    }
}
