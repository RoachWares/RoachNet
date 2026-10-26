import Foundation

extension NativeRuntime {
    var apiToken: String? { config.apiToken }

    static func routedURL(_ target: String) -> WebURL? {
        WebURL(target, base: WebURL("http://127.0.0.1"))
    }

    static func apiTokenScope(method: String, pathname: String) -> String {
        let chatPrefixes = [
            "/api/ollama/chat", "/api/companion/chat", "/api/roachclaw/chat", "/api/roachclaw/sessions", "/api/chat",
        ]
        if chatPrefixes.contains(where: { pathname == $0 || pathname.hasPrefix("\($0)/") }) { return "chat" }
        if method == "GET" || method == "HEAD" { return "read" }
        return "admin"
    }

    func apiTokenRefusal(_ request: HTTPRequest) -> HTTPResponse? {
        guard let required = apiToken, !request.inProcess else { return nil }
        guard let pathname = Self.routedURL(request.target)?.pathname else {
            return .json(400, ["error": "That request's address can't be read."])
        }
        if request.method == "GET", pathname == "/api/health" { return nil }
        if pathname == "/api/org" || pathname.hasPrefix("/api/org/"),
            let orgKey = request.header("x-roachnet-org-key"), !orgKey.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return nil
        }

        let presented = Self.presentedAPIToken(request)
        guard let presented, !presented.isEmpty else {
            return .json(
                401,
                [
                    "error":
                        "This RoachNet API needs its token. RoachNet passes it automatically; scripts can use a RoachClaw API token from Settings."
                ])
        }
        if orgConstantTimeEquals(presented, required) { return nil }
        if presented.hasPrefix("rn_") {
            let scope = Self.apiTokenScope(method: request.method, pathname: pathname)
            switch roachClawAPITokenAccess(presented, scope: scope) {
            case .allowed: return nil
            case .missingScope(let scopes):
                return .json(
                    403,
                    [
                        "error": JSON(
                            "That API token can't use this route (it needs \"\(scope)\"; the token has \(scopes.joined(separator: ", ")))."
                        ), "requiredScope": JSON(scope),
                    ])
            case .unknown:
                break
            }
        }
        return .json(401, ["error": "That RoachNet API token is not valid."])
    }

    static let planKeyHeader = "x-roachnet-plan-key"

    func callerIsOwner(_ request: HTTPRequest) -> Bool {
        if request.inProcess {
            return request.header("x-roachtail-auth-kind")?.trimmingCharacters(in: .whitespaces).lowercased()
                == "primary"
        }
        return presentsOwnerCredential(request)
    }

    func presentsOwnerCredential(_ request: HTTPRequest) -> Bool {
        guard let required = apiToken else { return true }
        guard let presented = Self.presentedAPIToken(request), !presented.isEmpty else { return false }
        if orgConstantTimeEquals(presented, required) { return true }
        return presented.hasPrefix("rn_") && roachClawAPITokenAccess(presented, scope: "admin") == .allowed
    }

    func mayUsePlanModels(_ request: HTTPRequest) -> Bool {
        if let key = request.header(Self.planKeyHeader)?.trimmingCharacters(in: .whitespaces), !key.isEmpty,
            orgConstantTimeEquals(key, planKey)
        {
            return true
        }
        return presentsOwnerCredential(request)
    }

    func isOwnRoachInference(_ url: String) -> Bool {
        guard let own = roachInferenceAddress.value, let ownURL = WebURL(own), let target = WebURL(url),
            target.origin == ownURL.origin
        else { return false }
        return IPAddress.version(target.bareHostname) != 0
    }

    static let planModelsRefusal =
        "Plan models (claude:…, codex:…) answer RoachNet's owner only, not paired devices or chat and read tokens. Pick a local model."

    func requirePlanAccess(model: String, owner: Bool) throws {
        if !owner, SubscriptionModels.parse(model) != nil { throw requestError(Self.planModelsRefusal, 403) }
    }

    static func presentedAPIToken(_ request: HTTPRequest) -> String? {
        if let header = request.header("x-roachnet-api-token")?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            return header
        }
        if let authorization = request.header("authorization")?.trimmingCharacters(in: .whitespaces) {
            let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        if let key = request.header("x-api-key")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            return key
        }
        return nil
    }

    enum APITokenAccess: Equatable {
        case allowed
        case missingScope([String])
        case unknown
    }

    func roachClawAPITokenAccess(_ token: String, scope: String) -> APITokenAccess {
        let digest = SHA256Digest.hex(token)
        let records = roachClawApiTokensState()["tokens"].array
        guard let record = records.first(where: { orgConstantTimeEquals($0["tokenHash"].jsString, digest) }),
            record["isActive"].truthy
        else { return .unknown }
        let scopes = record["scopes"].array.map(\.jsString)
        guard scopes.contains(scope) || scopes.contains("admin") else {
            return .missingScope(scopes)
        }
        let id = record["id"].jsString
        let last = JS.parseDate(record["lastUsedAt"].jsString) ?? 0
        if JS.nowMs() - last > 60_000 {
            withState {
                var state = roachClawApiTokensState()
                state["tokens"] = .array(
                    state["tokens"].array.map { item in
                        guard item["id"].jsString == id else { return item }
                        var updated = item
                        updated["lastUsedAt"] = JSON(JS.isoNow())
                        return updated
                    })
                writeRoachClawState("api-tokens.json", state)
            }
        }
        return .allowed
    }
}
