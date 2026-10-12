import Foundation

/// `/api/cluster`: RoachNet Cluster's settings and status for the app.
///
/// - `GET /api/cluster` — this Mac, the other Macs (asked live with `?refresh=1`),
///   the pairing code, and how loaded models are split.
/// - `PUT /api/cluster` — `{enabled, name, mode: "auto"|"always", peers: ["host:port"],
///   code: "<pairing code>" (join that cluster), resetPairing: true (start a new one)}`.
/// - `POST /api/cluster/peers` `{address}` and `DELETE /api/cluster/peers` `{address}`.
extension NativeRuntime {
    func routeCluster(_ request: inout HTTPRequest, url: WebURL) throws -> HTTPResponse {
        #if canImport(CryptoKit) && canImport(Metal)
        let node = cluster
        switch (request.method, url.pathname) {
        case ("GET", "/api/cluster"):
            return .json(200, node.status(probe: url.queryParameter("refresh") == "1"))
        case ("GET", "/api/cluster/nearby"):
            guard node.settings.enabled else { return .json(200, ["macs": []]) }
            return .json(200, ["macs": .array(node.nearby())])
        case ("PUT", "/api/cluster"), ("PATCH", "/api/cluster"):
            try node.update(try readRequestJSON(&request))
            if node.settings.enabled, nativeModelServer == nil { _ = startNativeModelServer() }
            return .json(200, node.status(probe: false))
        case ("POST", "/api/cluster/peers"), ("DELETE", "/api/cluster/peers"):
            let body = try readRequestJSON(&request)
            guard let address = body["address"].stringValue?.trimmingCharacters(in: .whitespaces), !address.isEmpty else {
                throw requestError("Give the other Mac's address, such as studio.local or 192.168.1.20.", 400)
            }
            var peers = Set(node.settings.peers)
            if request.method == "POST" { peers.insert(address) } else { peers.remove(address) }
            try node.update(["peers": .array(peers.sorted().map { JSON($0) })])
            return .json(200, node.status(probe: request.method == "POST"))
        default:
            throw requestError("Not found.", 404)
        }
        #else
        throw requestError("RoachNet Cluster runs on Apple silicon Macs.", 501)
        #endif
    }
}
