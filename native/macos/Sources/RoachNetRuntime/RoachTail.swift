import Foundation

extension NativeRuntime {
    func roachTailDeviceId() -> String { String(SHA256Digest.hex("\(Host.hostname)::\(storageRoot)").prefix(16)) }
    func roachTailNetworkName() -> String { config.trimmedEnv("ROACHTAIL_NETWORK_NAME") ?? "RoachTail" }
    func roachTailNamespace() -> String { config.trimmedEnv("ROACHTAIL_NAMESPACE") ?? "roachnet" }
    func roachTailNow() -> String { JS.isoNow() }
    func roachTailHash(_ value: JSON) -> String { SHA256Digest.hex(value.truthy ? value.jsString : "") }

    func generateRoachTailJoinCode() -> String {
        let raw = JS.randomHex(12).uppercased()
        var groups: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw.index(index, offsetBy: 4, limitedBy: raw.endIndex) ?? raw.endIndex
            groups.append(String(raw[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    func generateRoachTailSecret(_ prefix: String) -> String {
        "\(prefix)_\(JS.randomHex(32))\(JS.randomHex(32))"
    }

    func roachTailAddMs(_ ms: Int) -> String { JS.iso(Date(timeIntervalSince1970: (JS.nowMs() + Double(ms)) / 1000)) }

    func wantsCompanionRuntime() -> Bool {
        if let mode = config.trimmedEnv("ROACHNET_COMPANION_ENABLED") {
            return !["0", "false", "no", "off"].contains(mode.lowercased())
        }
        return config.companionToken != nil
    }

    func companionHostPort() -> (host: String, port: String) {
        (
            config.trimmedEnv("ROACHNET_COMPANION_HOST") ?? "127.0.0.1",
            config.trimmedEnv("ROACHNET_COMPANION_PORT") ?? "38111"
        )
    }

    func companionLocalUrl() -> String? {
        guard wantsCompanionRuntime() else { return nil }
        var (host, port) = companionHostPort()
        if port == "0", companionBoundPort > 0 { port = String(companionBoundPort) }
        let displayHost = host == "0.0.0.0" || host == "::" ? "127.0.0.1" : host
        return "http://\(displayHost.contains(":") ? "[\(displayHost)]" : displayHost):\(port)"
    }

    func roachTailBridgeUrl() -> String? {
        config.trimmedEnv("ROACHNET_COMPANION_ADVERTISED_URL") ?? companionLocalUrl()
    }

    func roachTailRuntimeOrigin() -> String {
        let host = config.trimmedEnv("HOST") ?? "127.0.0.1"
        let displayHost = host == "0.0.0.0" || host == "::" ? "127.0.0.1" : host
        let port = config.trimmedEnv("PORT") ?? (listenPort > 0 ? String(listenPort) : "8080")
        return "http://\(displayHost.contains(":") ? "[\(displayHost)]" : displayHost):\(port)"
    }

    func normalizeRoachTailRelayHost(_ value: JSON) -> String? {
        let trimmed = (value.isNullish ? "" : value.jsString).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let parsed = WebURL(trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
            ["http", "https"].contains(parsed.scheme), !parsed.hostname.isEmpty
        else { return nil }
        return parsed.host
    }

    func roachTailAdvertisedUrl(_ relayHost: String?, _ fallbackUrl: JSON) -> JSON {
        guard let relayHost else { return fallbackUrl || nil }
        return JSON("https://\(relayHost)")
    }

    func roachTailRuntimeTunnelUrl(_ relayHost: String?, _ fallbackUrl: JSON) -> JSON {
        guard let relayHost else { return fallbackUrl || nil }
        return JSON("https://\(relayHost)/runtime")
    }

    func roachTailStatusFor(_ state: JSON) -> String {
        if !state["enabled"].truthy { return "local-only" }
        if state["peers"].array.contains(where: { $0["status"].stringValue == "connected" }) { return "connected" }
        return state["relayHost"].truthy ? "relay-ready" : "armed"
    }

    func roachTailTransportModeFor(_ state: JSON) -> String {
        if !state["enabled"].truthy { return "local-only" }
        return state["relayHost"].truthy ? "tailnet-relay" : "local-bridge"
    }

    func createRoachTailPreAuthKey(_ joinCode: String, _ issuedAt: String) -> JSON {
        [
            "id": JSON("rtpak_\(JS.randomHex(16))"),
            "keyHash": JSON(roachTailHash(JSON(joinCode))),
            "createdAt": JSON(issuedAt),
            "expiresAt": JSON(roachTailAddMs(config.roachTailJoinCodeTTLms)),
            "reusable": false,
            "ephemeral": true,
            "used": false,
            "tags": ["tag:roachnet-companion"],
            "capabilities": ["companion-bootstrap", "runtime-status", "app-install"],
        ]
    }

    func issueRoachTailJoinCode() -> JSON {
        let issuedAt = roachTailNow()
        let joinCode = generateRoachTailJoinCode()
        return [
            "joinCode": JSON(joinCode),
            "joinCodeHash": JSON(roachTailHash(JSON(joinCode))),
            "joinCodeExpiresAt": JSON(roachTailAddMs(config.roachTailJoinCodeTTLms)),
            "pairingIssuedAt": JSON(issuedAt),
            "preAuthKeys": [createRoachTailPreAuthKey(joinCode, issuedAt)],
        ]
    }

    func defaultRoachTailState() -> JSON {
        let enabled = wantsCompanionRuntime()
        let issued = enabled ? issueRoachTailJoinCode() : .object(JSONObject())
        let relayHost = normalizeRoachTailRelayHost(JSON(config.env("ROACHTAIL_RELAY_HOST")))
        let advertisedUrl = roachTailAdvertisedUrl(relayHost, JSON(roachTailBridgeUrl()))
        let runtimeOrigin = roachTailRuntimeOrigin()
        let notes: JSON =
            enabled
            ? [
                "RoachTail is using a native RoachNet control plane shaped after Headscale: local node records, expiring join keys, route approval, and no user-content custody.",
                JSON(
                    relayHost != nil
                        ? "The bridge advertises a relay host instead of the raw machine address."
                        : "Paired phones need an https:// relay host or a tailnet address: RoachNet iOS 0.3 will not send its token over plain http:// on Wi-Fi."
                ),
            ]
            : ["RoachTail is off in the dependency-free native bridge."]
        return [
            "schema": "org.roachnet.roachtail.control-plane.v1",
            "enabled": JSON(enabled),
            "networkName": JSON(roachTailNetworkName()),
            "namespace": JSON(roachTailNamespace()),
            "deviceName": JSON(Host.hostname),
            "deviceId": JSON(roachTailDeviceId()),
            "machineKey": JSON("mkey_\(roachTailHash(JSON("\(storageRoot):machine")).prefix(32))"),
            "nodeKey": JSON("node_\(roachTailHash(JSON("\(storageRoot):node")).prefix(32))"),
            "status": JSON(enabled ? "armed" : "local-only"),
            "transportMode": JSON(enabled ? (relayHost != nil ? "tailnet-relay" : "local-bridge") : "local-only"),
            "secureOverlay": true,
            "relayHost": JSON(relayHost),
            "advertisedUrl": advertisedUrl,
            "runtimeOrigin": JSON(runtimeOrigin),
            "runtimeTunnelUrl": roachTailRuntimeTunnelUrl(relayHost, JSON(runtimeOrigin)),
            "joinCode": issued["joinCode"] || nil,
            "joinCodeHash": issued["joinCodeHash"] || nil,
            "joinCodeExpiresAt": issued["joinCodeExpiresAt"] || nil,
            "pairingPayload": nil,
            "pairingIssuedAt": issued["pairingIssuedAt"] || nil,
            "preAuthKeys": issued["preAuthKeys"] || [],
            "peers": [],
            "policy": [
                "mode": "local-owner",
                "aclDefault": "deny",
                "ownerCanApproveRoutes": true,
                "peerCanSelfRemove": true,
            ],
            "lastUpdatedAt": JSON(roachTailNow()),
            "notes": notes,
        ]
    }

    func readRoachTailStateFile() -> JSON? {
        for target in [config.roachTailStatePath, config.legacyRoachTailStatePath] {
            if Files.exists(target), let parsed = JSON.read(contentsOf: target) { return parsed }
        }
        return nil
    }

    func keepRoachTailJoinCodeInMemory(_ state: JSON) -> JSON {
        withState {
            if let code = state["joinCode"].stringValue, !code.isEmpty {
                roachTailJoinCode = (roachTailHash(JSON(code)), code)
            } else if state["joinCodeHash"].stringValue == nil {
                roachTailJoinCode = nil
            }
        }
        var onDisk = state
        onDisk["joinCode"] = nil
        return onDisk
    }

    func roachTailJoinCodeInMemory(for state: JSON) -> JSON {
        withState {
            guard let kept = roachTailJoinCode, let hash = state["joinCodeHash"].stringValue,
                CompanionProxy.tokensMatch(kept.hash, hash)
            else { return nil }
            return JSON(kept.code)
        }
    }

    func isRoachTailJoinCodeFresh(_ state: JSON) -> Bool {
        guard state["joinCode"].truthy, let expires = state["joinCodeExpiresAt"].stringValue,
            let ms = JS.parseDate(expires)
        else { return false }
        return ms > JS.nowMs()
    }

    func readRoachTailStateRaw(persistIfMissing: Bool, mintJoinCode: Bool = true) -> JSON {
        withState {
            let state = readRoachTailStateFile()
            let fallback = defaultRoachTailState()
            var merged = fallback.merging(state?.isObject == true ? state! : .object(JSONObject()))
            let codeInFile = state?["joinCode"].stringValue.map { !$0.isEmpty } ?? false
            if let state, codeInFile { _ = keepRoachTailJoinCodeInMemory(state) }
            if state != nil { merged["joinCode"] = roachTailJoinCodeInMemory(for: merged) }
            merged["schema"] = "org.roachnet.roachtail.control-plane.v1"
            merged["networkName"] = JSON((merged["networkName"] || JSON(roachTailNetworkName())).jsString)
            merged["namespace"] = JSON((merged["namespace"] || JSON(roachTailNamespace())).jsString)
            merged["deviceName"] = JSON((merged["deviceName"] || JSON(Host.hostname)).jsString)
            merged["deviceId"] = JSON((merged["deviceId"] || JSON(roachTailDeviceId())).jsString)
            merged["machineKey"] = JSON((merged["machineKey"] || fallback["machineKey"]).jsString)
            merged["nodeKey"] = JSON((merged["nodeKey"] || fallback["nodeKey"]).jsString)
            let relay = normalizeRoachTailRelayHost(merged["relayHost"])
            merged["relayHost"] = JSON(relay)
            merged["advertisedUrl"] = roachTailAdvertisedUrl(
                relay, merged["advertisedUrl"] || JSON(roachTailBridgeUrl()))
            merged["runtimeOrigin"] = merged["runtimeOrigin"] || JSON(roachTailRuntimeOrigin())
            merged["runtimeTunnelUrl"] = roachTailRuntimeTunnelUrl(
                relay, merged["runtimeTunnelUrl"] || merged["runtimeOrigin"])
            merged["peers"] = .array(merged["peers"].array)
            merged["preAuthKeys"] = .array(merged["preAuthKeys"].array)
            merged["policy"] = merged["policy"].isObject ? merged["policy"] : fallback["policy"]
            merged["transportMode"] = JSON(roachTailTransportModeFor(merged))
            merged["status"] = JSON(roachTailStatusFor(merged))
            merged["secureOverlay"] = true

            var persist = persistIfMissing || codeInFile
            if mintJoinCode && merged["enabled"].truthy
                && (!isRoachTailJoinCodeFresh(merged) || !merged["joinCode"].truthy)
            {
                let issued = issueRoachTailJoinCode()
                for key in ["joinCode", "joinCodeHash", "joinCodeExpiresAt", "pairingIssuedAt", "preAuthKeys"] {
                    merged[key] = issued[key]
                }
                merged["lastUpdatedAt"] = JSON(roachTailNow())
                persist = true
            }
            if persist && (state == nil || merged["enabled"].truthy || codeInFile) {
                return writeRoachTailStateRaw(merged)
            }
            return merged
        }
    }

    @discardableResult
    func writeRoachTailStateRaw(_ state: JSON) -> JSON {
        var next = state
        next["transportMode"] = JSON(roachTailTransportModeFor(state))
        next["status"] = JSON(roachTailStatusFor(state))
        next["lastUpdatedAt"] = JSON(roachTailNow())
        try? Files.writePrettyJSON(
            keepRoachTailJoinCodeInMemory(next), to: config.roachTailStatePath, mode: Files.privateFileMode)
        return next
    }

    func roachTailRoutes(_ state: JSON) -> [JSON] {
        var routes: [JSON] = []
        let advertised = JSON(state["enabled"].truthy)
        if state["advertisedUrl"].truthy {
            routes.append([
                "id": "companion-bridge", "type": "service", "target": state["advertisedUrl"], "approved": true,
                "advertised": advertised, "primary": true, "tags": ["tag:companion"],
                "description": "Companion control bridge for iPhone, iPad, and web chat carryover.",
            ])
        }
        if state["runtimeTunnelUrl"].truthy {
            routes.append([
                "id": "native-runtime", "type": "service", "target": state["runtimeTunnelUrl"], "approved": true,
                "advertised": advertised, "primary": false, "tags": ["tag:runtime"],
                "description": "Read-only runtime status and install handoff route.",
            ])
        }
        routes.append([
            "id": "local-tailnet-cidr", "type": "cidr",
            "target": JSON(config.trimmedEnv("ROACHTAIL_TAILNET_CIDR") ?? "100.64.0.0/10"),
            "approved": true, "advertised": advertised, "primary": false, "tags": ["tag:roachnet"],
            "description": "Reserved RoachTail address space for local peer records.",
        ])
        return routes
    }

    func roachTailDerpMap(_ state: JSON) -> JSON {
        let relay = state["relayHost"].truthy
        return [
            "mode": JSON(relay ? "custom-relay" : "local-only"),
            "regions": [
                [
                    "id": JSON(relay ? "roachnet-relay" : "roachnet-local"),
                    "name": JSON(relay ? "RoachTail relay" : "RoachTail local bridge"),
                    "host": state["relayHost"]
                        || JSON(config.env("ROACHNET_LOCAL_HOSTNAME").flatMap { $0.isEmpty ? nil : $0 } ?? "RoachNet"),
                    "url": state["advertisedUrl"],
                    "embedded": JSON(!relay),
                ]
            ],
        ]
    }

    func roachTailControlPlane(_ state: JSON) -> JSON {
        let dnsName = JS.replace(
            "[^a-z0-9.-]", in: "\(state["deviceName"].jsString).roachtail.local".lowercased(), with: "-")
        return [
            "provider": "roachnet-native",
            "designReference": "headscale",
            "namespace": state["namespace"],
            "nodeApproval": "owner-local",
            "routeApproval": "owner-local",
            "authKeyTtlSeconds": JSON(JS.round(Double(config.roachTailAuthKeyTTLms) / 1000)),
            "joinCodeTtlSeconds": JSON(JS.round(Double(config.roachTailJoinCodeTTLms) / 1000)),
            "policyMode": state["policy"]["mode"] || "local-owner",
            "dnsName": JSON(dnsName),
        ]
    }

    func sanitizeRoachTailPeer(_ peer: JSON) -> JSON {
        [
            "id": JSON((peer["id"] || JSON(JS.randomUUID())).jsString),
            "name": JSON((peer["name"] || "Linked device").jsString),
            "platform": JSON((peer["platform"] || "unknown").jsString),
            "status": JSON((peer["status"] || "paired").jsString),
            "endpoint": peer["endpoint"] || nil,
            "lastSeenAt": peer["lastSeenAt"] || nil,
            "allowsExitNode": JSON(peer["allowsExitNode"].truthy),
            "tags": peer["tags"].isArray ? peer["tags"] : ["tag:roachnet-companion"],
            "nodeKey": peer["nodeKey"] || nil,
            "machineKey": peer["machineKey"] || nil,
            "routes": peer["routes"].isArray ? peer["routes"] : [],
            "capabilities": peer["capabilities"].isArray
                ? peer["capabilities"] : ["companion-bootstrap", "runtime-status", "app-install"],
        ]
    }

    func sanitizeRoachTailPreAuthKey(_ key: JSON) -> JSON {
        [
            "id": JSON((key["id"] || "").jsString),
            "createdAt": key["createdAt"] || nil,
            "expiresAt": key["expiresAt"] || nil,
            "reusable": JSON(key["reusable"].truthy),
            "ephemeral": JSON(key["ephemeral"] != .bool(false)),
            "used": JSON(key["used"].truthy),
            "tags": key["tags"].isArray ? key["tags"] : [],
            "capabilities": key["capabilities"].isArray ? key["capabilities"] : [],
        ]
    }

    func sanitizeRoachTailState(_ state: JSON, hideJoinCode: Bool = false) -> JSON {
        let hiddenJoinCode: JSON = hideJoinCode ? .null : (state["joinCode"] || nil)
        var display = state
        display["joinCode"] = hiddenJoinCode
        display["pairingPayload"] =
            hiddenJoinCode.truthy ? (buildRoachTailPairingPayload(state).map { JSON($0) } ?? .null) : .null
        display["peers"] = .array(state["peers"].array.map(sanitizeRoachTailPeer))
        display["preAuthKeys"] = .array(state["preAuthKeys"].array.map(sanitizeRoachTailPreAuthKey))
        display["routes"] = .array(roachTailRoutes(state))
        display["derpMap"] = roachTailDerpMap(state)
        display["controlPlane"] = roachTailControlPlane(state)
        var object = display.object
        object.remove("joinCodeHash")
        return .object(object)
    }

    func buildRoachTailPairingPayload(_ state: JSON) -> String? {
        guard state["enabled"].truthy, state["joinCode"].truthy, isRoachTailJoinCodeFresh(state) else { return nil }
        let payload: JSON = [
            "schema": "roachnet.roachtail.v2",
            "networkName": state["networkName"],
            "namespace": state["namespace"],
            "deviceName": state["deviceName"],
            "deviceId": state["deviceId"],
            "joinCode": state["joinCode"],
            "joinCodeExpiresAt": state["joinCodeExpiresAt"],
            "bridgeUrl": state["advertisedUrl"],
            "runtimeTunnelUrl": state["runtimeTunnelUrl"],
            "controlPlane": roachTailControlPlane(state),
            "routes": .array(roachTailRoutes(state).filter { $0["approved"].truthy && $0["advertised"].truthy }),
        ]
        return payload.serialized()
    }

    func roachTailState(hideJoinCode: Bool = false) -> JSON {
        sanitizeRoachTailState(
            readRoachTailStateRaw(persistIfMissing: true, mintJoinCode: !hideJoinCode), hideJoinCode: hideJoinCode)
    }

    func roachTailPeerFromPayload(_ payload: JSON, tokenHash: String?) -> JSON {
        let now = roachTailNow()
        var name = JS.slice(
            (payload["peerName"] || payload["name"] || payload["deviceName"] || "Linked device").jsString
                .trimmingCharacters(in: .whitespacesAndNewlines), 80)
        if name.isEmpty { name = "Linked device" }
        var platform = JS.slice(
            (payload["platform"] || payload["os"] || "unknown").jsString.trimmingCharacters(
                in: .whitespacesAndNewlines), 48)
        if platform.isEmpty { platform = "unknown" }
        let tags = payload["tags"].array
        let capabilities = payload["capabilities"].array
        return [
            "id": JSON((payload["peerId"] || payload["id"] || JSON("rtpeer_\(JS.randomHex(16))")).jsString),
            "name": JSON(name),
            "platform": JSON(platform),
            "status": "paired",
            "endpoint": payload["endpoint"].truthy
                ? JSON(JS.slice(payload["endpoint"].jsString.trimmingCharacters(in: .whitespacesAndNewlines), 180))
                : nil,
            "lastSeenAt": JSON(now),
            "allowsExitNode": JSON(payload["allowsExitNode"].truthy),
            "tags": !tags.isEmpty ? .array(tags.map { JSON($0.jsString) }) : ["tag:roachnet-companion"],
            "nodeKey": JSON(
                (payload["nodeKey"] || JSON("node_\(roachTailHash(JSON("\(name):\(platform):\(now)")).prefix(32))"))
                    .jsString),
            "machineKey": JSON(
                (payload["machineKey"] || JSON("mkey_\(roachTailHash(JSON("\(platform):\(name):\(now)")).prefix(32))"))
                    .jsString),
            "routes": payload["routes"].isArray ? payload["routes"] : [],
            "capabilities": !capabilities.isEmpty
                ? .array(capabilities.map { JSON($0.jsString) })
                : ["companion-bootstrap", "runtime-status", "app-install"],
            "tokenHash": JSON(tokenHash),
            "preAuthKeyId": payload["preAuthKeyId"] || nil,
            "createdAt": JSON(now),
        ]
    }

    func finalizeRoachTailState(_ state: JSON) -> JSON {
        let relay = normalizeRoachTailRelayHost(state["relayHost"])
        var next = state
        next["relayHost"] = JSON(relay)
        next["advertisedUrl"] = roachTailAdvertisedUrl(relay, state["advertisedUrl"] || JSON(roachTailBridgeUrl()))
        next["runtimeOrigin"] = state["runtimeOrigin"] || JSON(roachTailRuntimeOrigin())
        next["runtimeTunnelUrl"] = roachTailRuntimeTunnelUrl(
            relay, state["runtimeTunnelUrl"] || state["runtimeOrigin"] || JSON(roachTailRuntimeOrigin()))
        next["secureOverlay"] = true
        return next
    }

    func roachTailActionMessage(_ action: String, _ state: JSON) -> String {
        switch action {
        case "enable": return "RoachTail armed with a fresh join key."
        case "disable": return "RoachTail disabled."
        case "refresh-join-code": return "RoachTail join key refreshed."
        case "clear-peers": return "RoachTail peers cleared."
        case "set-relay-host":
            return state["relayHost"].truthy ? "RoachTail relay host updated." : "RoachTail relay host cleared."
        case "remove-peer": return "RoachTail peer removed."
        default: return "RoachTail updated."
        }
    }

    func mutateRoachTailState(_ action: JSON, _ payload: JSON, headers: [String: String]) throws -> JSON {
        try withState {
            let current = readRoachTailStateRaw(persistIfMissing: true)
            var next = current
            let normalizedAction = (action.isNullish ? "" : action.jsString).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let peerAuthKind = headers["x-roachtail-auth-kind"]?.trimmingCharacters(in: .whitespaces).lowercased()
            let authPeerId = headers["x-roachtail-auth-peer-id"]?.trimmingCharacters(in: .whitespaces)
            let peerScoped = peerAuthKind == "peer"
            if peerScoped && normalizedAction != "remove-peer" {
                throw requestError("Peer-scoped RoachTail changes can only remove that paired device.", 403)
            }

            func applyIssued(_ issued: JSON) {
                for key in ["joinCode", "joinCodeHash", "joinCodeExpiresAt", "pairingIssuedAt", "preAuthKeys"] {
                    next[key] = issued[key]
                }
            }

            switch normalizedAction {
            case "enable":
                next["enabled"] = true
                next["relayHost"] = JSON(normalizeRoachTailRelayHost(payload["relayHost"])) || next["relayHost"]
                applyIssued(issueRoachTailJoinCode())
                next["notes"] = [
                    "RoachTail is armed with a native RoachNet control plane: expiring join key, local node registry, approved service routes, and private peer tokens.",
                    JSON(
                        next["relayHost"].truthy
                            ? "Relay mode is active, so paired devices should use the relay host instead of the raw local bridge."
                            : "Local bridge mode is active. Add a relay host when you need remote devices off the raw machine address."
                    ),
                ]
            case "disable":
                next["enabled"] = false
                next["joinCode"] = nil
                next["joinCodeHash"] = nil
                next["joinCodeExpiresAt"] = nil
                next["pairingPayload"] = nil
                next["preAuthKeys"] = .array(
                    next["preAuthKeys"].array.map { key in
                        var updated = key
                        updated["used"] = true
                        return updated
                    })
                next["notes"] = [
                    "RoachTail is disabled. Existing peer records are kept so the private lane can be re-armed without rebuilding every device link."
                ]
            case "refresh-join-code":
                next["enabled"] = true
                applyIssued(issueRoachTailJoinCode())
                next["notes"] = [
                    "RoachTail issued a fresh one-use join key.",
                    "The old pairing window is closed; scan the new payload from the device you are adding.",
                ]
            case "clear-peers":
                next["peers"] = []
                next["notes"] = [
                    "RoachTail peer records were cleared from the local control plane.",
                    "Refresh the join key when you are ready to add devices again.",
                ]
            case "set-relay-host":
                let relay = normalizeRoachTailRelayHost(payload["relayHost"])
                next["relayHost"] = JSON(relay)
                next["notes"] = [
                    JSON(
                        relay.map { "RoachTail will advertise the relay host \($0)." }
                            ?? "RoachTail relay host was cleared and the bridge will use the local advertised URL.")
                ]
            case "register-peer":
                let peerToken = generateRoachTailSecret("rtp")
                let peer = roachTailPeerFromPayload(payload, tokenHash: roachTailHash(JSON(peerToken)))
                next["enabled"] = true
                next["peers"] = .array(next["peers"].array.filter { $0["id"] != peer["id"] } + [peer])
                next["notes"] = [
                    JSON("\(peer["name"].jsString) was registered in the RoachTail control plane."),
                    "Store the peer token once; RoachNet only keeps its hash.",
                ]
                let written = writeRoachTailStateRaw(finalizeRoachTailState(next))
                return [
                    "success": true,
                    "ok": true,
                    "message": JSON("\(peer["name"].jsString) registered with RoachTail."),
                    "token": JSON(peerToken),
                    "peerId": peer["id"],
                    "peerToken": JSON(peerToken),
                    "state": sanitizeRoachTailState(written),
                ]
            case "remove-peer":
                let peerId =
                    peerScoped
                    ? (authPeerId ?? "")
                    : (payload["peerId"] || "").jsString.trimmingCharacters(in: .whitespacesAndNewlines)
                if peerId.isEmpty { throw requestError("A peerId is required to remove a RoachTail peer.", 400) }
                let remaining = next["peers"].array.filter { $0["id"].stringValue != peerId }
                next["peers"] = .array(remaining)
                next["notes"] = [
                    "RoachTail removed one peer from the local control plane.",
                    JSON(
                        remaining.isEmpty
                            ? "No linked peers remain. Refresh the join key before adding another device."
                            : "\(remaining.count) linked peer\(remaining.count == 1 ? "" : "s") remain."),
                ]
            default:
                throw requestError(
                    "RoachTail action must be enable, disable, refresh-join-code, clear-peers, set-relay-host, register-peer, or remove-peer.",
                    400)
            }

            let written = writeRoachTailStateRaw(finalizeRoachTailState(next))
            return [
                "success": true,
                "ok": true,
                "message": JSON(roachTailActionMessage(normalizedAction, written)),
                "state": sanitizeRoachTailState(written, hideJoinCode: peerScoped),
            ]
        }
    }

    func pairRoachTailPeer(_ payload: JSON) throws -> JSON {
        try withState {
            let current = readRoachTailStateRaw(persistIfMissing: true)
            if !current["enabled"].truthy {
                throw requestError("RoachTail is off on this desktop. Turn it on before pairing a device.", 409)
            }
            if !isRoachTailJoinCodeFresh(current) {
                throw requestError(
                    "That RoachTail join code expired. Refresh the code on the desktop and try again.", 401)
            }
            let joinCode = (payload["joinCode"] || "").jsString.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if joinCode.isEmpty
                || !CompanionProxy.tokensMatch(roachTailHash(JSON(joinCode)), current["joinCodeHash"].jsString)
            {
                var next = current
                let failures = Int(next["joinCodeFailedAttempts"].jsString) ?? 0
                next["joinCodeFailedAttempts"] = JSON(failures + 1)
                if failures + 1 >= 5 {
                    next["joinCode"] = nil
                    next["joinCodeHash"] = nil
                    next["joinCodeExpiresAt"] = nil
                    next["joinCodeFailedAttempts"] = nil
                }
                writeRoachTailStateRaw(next)
                throw requestError("That RoachTail join code does not match this desktop.", 401)
            }
            let activeKey = current["preAuthKeys"].array.first { $0["keyHash"] == current["joinCodeHash"] }
            if let activeKey, activeKey["used"].truthy {
                throw requestError(
                    "That RoachTail join code was already used. Refresh the code on the desktop and try again.", 401)
            }
            let peerToken = generateRoachTailSecret("rtp")
            var peerPayload = payload
            peerPayload["preAuthKeyId"] = (activeKey ?? .undefined)["id"] || nil
            peerPayload["peerId"] = nil
            peerPayload["id"] = nil
            let peer = roachTailPeerFromPayload(peerPayload, tokenHash: roachTailHash(JSON(peerToken)))
            var next = current
            next["enabled"] = true
            next["joinCodeFailedAttempts"] = nil
            next["joinCode"] = nil
            next["joinCodeHash"] = nil
            next["joinCodeExpiresAt"] = nil
            next["peers"] = .array(current["peers"].array.filter { $0["id"] != peer["id"] } + [peer])
            next["preAuthKeys"] = .array(
                current["preAuthKeys"].array.map { key in
                    guard key["keyHash"] == current["joinCodeHash"] else { return key }
                    var used = key
                    used["used"] = true
                    used["usedAt"] = JSON(roachTailNow())
                    used["usedBy"] = peer["id"]
                    return used
                })
            next["notes"] = [
                JSON("\(peer["name"].jsString) paired over RoachTail."),
                "This device now has its own private bridge token for chat carryover, runtime control, and App Store installs.",
                "Refresh the join key if you want to close the current pairing window and mint a new one.",
            ]
            let written = writeRoachTailStateRaw(finalizeRoachTailState(next))
            return [
                "success": true,
                "ok": true,
                "message": JSON("\(peer["name"].jsString) paired with RoachTail."),
                "token": JSON(peerToken),
                "peerId": peer["id"],
                "peerToken": JSON(peerToken),
                "bridgeUrl": written["advertisedUrl"],
                "runtimeTunnelUrl": written["runtimeTunnelUrl"],
                "state": sanitizeRoachTailState(written),
            ]
        }
    }
}
