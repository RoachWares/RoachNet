import Foundation

/// The loopback API's own credential (security review M11, ROA-39).
///
/// The Host, Origin and JSON-body checks stop web pages; this stops other
/// processes and other accounts on the Mac. When whoever starts the runtime
/// sets `ROACHNET_API_TOKEN` (RoachNet.app does, with a fresh random value on
/// every launch), every request from the network must carry it as
/// `Authorization: Bearer <token>` or `X-RoachNet-API-Token`, or carry an
/// active RoachClaw API token (`rn_…`, minted in Settings) whose scopes cover
/// the route. Requests the companion proxy makes in-process, Org calls that
/// bring their own `x-roachnet-org-key`, and `GET /api/health` are let through.
/// Without the variable nothing changes, so scripts that start a bare runtime
/// keep working.
extension NativeRuntime {
    var apiToken: String? {
        guard let token = config.trimmedEnv("ROACHNET_API_TOKEN"), !token.isEmpty else { return nil }
        return token
    }

    /// Route families a RoachClaw API token scope opens.
    static func apiTokenScope(method: String, pathname: String) -> String {
        let chatPrefixes = ["/api/ollama/chat", "/api/companion/chat", "/api/roachclaw/chat", "/api/roachclaw/sessions", "/api/chat"]
        if chatPrefixes.contains(where: { pathname == $0 || pathname.hasPrefix("\($0)/") }) { return "chat" }
        if method == "GET" || method == "HEAD" { return "read" }
        return "admin"
    }

    func apiTokenRefusal(_ request: HTTPRequest) -> HTTPResponse? {
        guard let required = apiToken, !request.inProcess else { return nil }
        let pathname = String(request.target.split(separator: "?", maxSplits: 1).first ?? "")
        if request.method == "GET", pathname == "/api/health" { return nil }
        if pathname == "/api/org" || pathname.hasPrefix("/api/org/"),
           let orgKey = request.header("x-roachnet-org-key"), !orgKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }

        let presented = Self.presentedAPIToken(request)
        guard let presented, !presented.isEmpty else {
            return .json(401, ["error": "This RoachNet API needs its token. RoachNet passes it automatically; scripts can use a RoachClaw API token from Settings."])
        }
        if orgConstantTimeEquals(presented, required) { return nil }
        if presented.hasPrefix("rn_") {
            let scope = Self.apiTokenScope(method: request.method, pathname: pathname)
            switch roachClawAPITokenAccess(presented, scope: scope) {
            case .allowed: return nil
            case .missingScope(let scopes):
                return .json(403, ["error": JSON("That API token can't use this route (it needs \"\(scope)\"; the token has \(scopes.joined(separator: ", ")))."), "requiredScope": JSON(scope)])
            case .unknown:
                break
            }
        }
        return .json(401, ["error": "That RoachNet API token is not valid."])
    }

    static func presentedAPIToken(_ request: HTTPRequest) -> String? {
        if let header = request.header("x-roachnet-api-token")?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            return header
        }
        guard let authorization = request.header("authorization")?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    enum APITokenAccess: Equatable {
        case allowed
        case missingScope([String])
        case unknown
    }

    /// Checks an `rn_` token against the hashed records in `api-tokens.json`
    /// and stamps `lastUsedAt` at most once a minute.
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
                state["tokens"] = .array(state["tokens"].array.map { item in
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
