import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class RuntimeServer {
    public let runtime: NativeRuntime
    private var apiServer: LoopbackHTTPServer?
    private var companionServer: LoopbackHTTPServer?
    private var signalSources: [DispatchSourceSignal] = []

    static let runtimeProcessNames = [RuntimeBuildInfo.executableName, "run-roachnet-native-api.mjs"]
    static let companionProcessNames = ["roachnet-companion-server.mjs"]

    public init(runtime: NativeRuntime = NativeRuntime()) {
        self.runtime = runtime
    }

    var config: RuntimeConfiguration { runtime.config }

    public func cleanupRuntimeStateFiles() {
        Files.remove(config.statePath)
        Files.remove(config.processInfoPath)
        if let info = config.trimmedEnv("ROACHNET_SERVER_INFO_FILE") { Files.remove(info) }
    }

    private func terminate(pid: Int32, allowed: [String], label: String) {
        guard pid > 0, pid != getpid(), Processes.isAlive(pid) else { return }
        let command = Processes.command(for: pid)
        guard allowed.contains(where: { command.contains($0) }) else {
            RuntimeLog.write("skipped \(label) stale pid \(pid); command did not match RoachNet runtime")
            return
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, Processes.isAlive(pid) { usleep(150_000) }
        if Processes.isAlive(pid) { kill(pid, SIGKILL) }
        RuntimeLog.write("stopped previous \(label) pid=\(pid)")
    }

    public func stopExistingRuntime() {
        if let state = JSON.read(contentsOf: config.statePath) {
            let pid = state["pid"].jsNumber
            let companionPid = state["companionPid"].jsNumber
            if JSCoercion.isSafeInteger(pid) {
                terminate(pid: Int32(pid), allowed: RuntimeServer.runtimeProcessNames, label: "native api")
            }
            if JSCoercion.isSafeInteger(companionPid) {
                terminate(pid: Int32(companionPid), allowed: RuntimeServer.companionProcessNames, label: "companion")
            }
        }
        cleanupRuntimeStateFiles()
    }

    static func normalizeLoopbackHost(_ value: String?) throws -> String {
        var raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("[") && raw.hasSuffix("]") { raw = String(raw.dropFirst().dropLast()) }
        if raw.isEmpty || raw == "0.0.0.0" || raw == "::" { return "127.0.0.1" }
        if ["127.0.0.1", "localhost", "::1"].contains(raw.lowercased()) { return raw }
        throw RuntimeError("RoachNet native API only binds to loopback hosts. Refusing HOST=\(raw).")
    }

    public func start() throws {
        try Files.mkdirp(config.logRoot)
        try Files.mkdirp(config.runtimeStateRoot)
        stopExistingRuntime()

        let host = try RuntimeServer.normalizeLoopbackHost(config.env("HOST"))
        let portNumber = JSCoercion.number(fromString: config.env("PORT") ?? "0")
        let port = UInt16(clamping: JSCoercion.isSafeInteger(portNumber) && portNumber > 0 ? Int(portNumber) : 0)
        let runtime = self.runtime
        _ = runtime.tracer
        _ = runtime.runtimeReachabilityCache
        _ = runtime.roachInferenceIdentityCache
        _ = runtime.installedModelsCache
        let server = LoopbackHTTPServer(host: host, port: port, maxBodyBytes: config.maxRequestBodyBytes) { request in
            runtime.handle(&request)
        }
        try server.start()
        apiServer = server
        runtime.listenPort = server.port
        let baseUrl = "http://127.0.0.1:\(server.port)"

        var companionLocal: String?
        var companionAdvertised: String?
        do {
            (companionLocal, companionAdvertised) = try startCompanion()
        } catch {
            RuntimeLog.write("companion start failed: \(error)")
        }
        runtime.companionLocalURL = companionLocal
        if !runtime.orgStoreIsEmpty { _ = runtime.orgService }
        try writeRuntimeInfo(
            baseUrl: baseUrl, port: server.port, companionUrl: companionLocal,
            companionAdvertisedUrl: companionAdvertised)
        RuntimeLog.write("native api listening on \(baseUrl)")
        DispatchQueue.global(qos: .utility).async { runtime.ensureOllama() }
        installSignalHandlers()
    }

    private func writeRuntimeInfo(baseUrl: String, port: UInt16, companionUrl: String?, companionAdvertisedUrl: String?)
        throws
    {
        let pid = Int(getpid())
        let healthUrl = "\(baseUrl)/api/health"
        let info: JSON = [
            "pid": JSON(pid),
            "healthUrl": JSON(healthUrl),
            "webUrl": JSON(baseUrl),
            "companionUrl": JSON(companionUrl),
            "companionAdvertisedUrl": JSON(companionAdvertisedUrl),
            "target": "native-api",
            "runtime": "native-swift",
            "repoRoot": JSON(config.repoRoot),
            "logPath": JSON(config.logPath),
            "apiToken": JSON(runtime.apiToken),
        ]
        try Files.writePrettyJSON(
            [
                "pid": JSON(pid),
                "companionPid": nil,
                "port": JSON(String(port)),
                "baseUrl": JSON(baseUrl),
                "startedAt": JSON(JS.isoNow()),
            ], to: config.statePath)
        var processes: [JSON] = [
            ["name": "native-api", "pid": JSON(pid), "port": JSON(Int(port)), "healthUrl": JSON(healthUrl)]
        ]
        if let companionUrl {
            processes.append(["name": "companion", "pid": JSON(pid), "url": JSON(companionUrl), "inProcess": true])
        }
        try Files.writePrettyJSON(
            [
                "target": "native-api",
                "companionUrl": JSON(companionUrl),
                "companionAdvertisedUrl": JSON(companionAdvertisedUrl),
                "processes": .array(processes),
                "updatedAt": JSON(JS.isoNow()),
            ], to: config.processInfoPath)
        if let infoFile = config.trimmedEnv("ROACHNET_SERVER_INFO_FILE") {
            try Files.writePrettyJSON(info, to: infoFile, mode: Files.privateFileMode)
        }
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    public func shutdown() {
        cleanupRuntimeStateFiles()
        companionServer?.stop()
        apiServer?.stop()
        exit(0)
    }

    func startCompanion() throws -> (String?, String?) {
        guard runtime.wantsCompanionRuntime() else { return (nil, nil) }
        guard let token = config.trimmedEnv("ROACHNET_COMPANION_TOKEN") else {
            RuntimeLog.write("companion requested without token; skipping companion bridge")
            return (nil, nil)
        }
        let (host, portText) = runtime.companionHostPort()
        let bindHost = try CompanionProxy.assertBindHost(host)
        let portNumber = JSCoercion.number(fromString: portText)
        guard JSCoercion.isSafeInteger(portNumber), portNumber >= 0, portNumber <= 65535 else {
            throw RuntimeError("Invalid companion port \(portText).")
        }
        let proxy = CompanionProxy(runtime: runtime, token: token)
        let server = LoopbackHTTPServer(
            host: bindHost == "localhost" ? "127.0.0.1" : bindHost, port: UInt16(portNumber),
            maxBodyBytes: proxy.maxRequestBodyBytes
        ) { request in
            proxy.handle(&request)
        }
        try server.start()
        companionServer = server
        runtime.companionBoundPort = server.port
        let localUrl = runtime.companionLocalUrl()
        let advertised = config.trimmedEnv("ROACHNET_COMPANION_ADVERTISED_URL") ?? localUrl
        RuntimeLog.write("started companion in-process url=\(localUrl ?? "")")
        return (localUrl, advertised)
    }
}

final class CompanionProxy {
    let runtime: NativeRuntime
    let token: String
    let maxRequestBodyBytes: Int
    let maxResponseBodyBytes: Int
    let aliasHost: String

    static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type, X-RoachNet-Companion-Token"),
        ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"),
        ("Cache-Control", "no-store"),
    ]

    init(runtime: NativeRuntime, token: String) {
        self.runtime = runtime
        self.token = token
        func positive(_ key: String, _ fallback: Int) -> Int {
            let number = JSCoercion.number(fromString: runtime.config.env(key) ?? "")
            return JSCoercion.isSafeInteger(number) && number > 0 ? Int(number) : fallback
        }
        maxRequestBodyBytes = positive("ROACHNET_COMPANION_MAX_BODY_BYTES", 2 * 1024 * 1024)
        maxResponseBodyBytes = positive("ROACHNET_COMPANION_MAX_RESPONSE_BYTES", 10 * 1024 * 1024)
        aliasHost = runtime.config.trimmedEnv("ROACHNET_LOCAL_HOSTNAME") ?? "RoachNet"
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "::ffff:127.0.0.1"]

    static func normalizedHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        if value.hasSuffix(".") { value.removeLast() }
        return value.lowercased()
    }

    static func hostnameForChecks(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if let parsed = WebURL(trimmed), !parsed.hostname.isEmpty, parsed.isSpecial {
            return normalizedHost(parsed.hostname)
        }
        if trimmed.hasPrefix("[") {
            if let close = trimmed.firstIndex(of: "]") {
                return normalizedHost(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
            }
            return normalizedHost(trimmed)
        }
        if trimmed.filter({ $0 == ":" }).count == 1 { return normalizedHost(String(trimmed.split(separator: ":")[0])) }
        return normalizedHost(trimmed)
    }

    static func isLoopback(_ raw: String) -> Bool { loopbackHosts.contains(hostnameForChecks(raw)) }

    static func assertBindHost(_ raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, isLoopback(host) else {
            throw RuntimeError("RoachNet companion server must bind only to a loopback address.")
        }
        return hostnameForChecks(host)
    }

    static func isProxyPath(_ pathname: String) -> Bool {
        pathname == "/api/companion" || pathname.hasPrefix("/api/companion/") || pathname == "/api/org"
            || pathname.hasPrefix("/api/org/")
    }

    func sanitizeUserFacingHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return aliasHost }
        var display = trimmed
        if let parsed = WebURL(trimmed), parsed.isSpecial, !parsed.host.isEmpty { display = parsed.host }
        let check = CompanionProxy.hostnameForChecks(display)
        if check.isEmpty || CompanionProxy.isLoopback(check) || IPAddress.version(check) != 0 { return aliasHost }
        return display
    }

    func json(_ status: Int, _ value: JSON) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: CompanionProxy.corsHeaders + [("Content-Type", "application/json; charset=utf-8")],
            body: value.serializedData())
    }

    func extractToken(_ request: HTTPRequest) -> String {
        if let authorization = request.header("authorization")?.trimmingCharacters(in: .whitespaces),
            authorization.lowercased().hasPrefix("bearer ")
        {
            return String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return (request.header("x-roachnet-companion-token") ?? "").split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
    }

    func resolvePeer(_ tokenValue: String, allowDisabled: Bool) -> JSON? {
        guard !tokenValue.isEmpty, let state = runtime.readRoachTailStateFile() else { return nil }
        if !state["enabled"].truthy && !allowDisabled { return nil }
        let hashed = SHA256Digest.hex(tokenValue)
        let peer = state["peers"].array.first { peer in
            peer["id"].stringValue != nil && CompanionProxy.tokensMatch(peer["tokenHash"].stringValue ?? "", hashed)
        }
        guard let peer, !CompanionProxy.peerTokenIsIdle(peer, limitMs: peerIdleLimitMs) else { return nil }
        return peer
    }

    var peerIdleLimitMs: Double {
        let raw = runtime.config.trimmedEnv("ROACHTAIL_PEER_IDLE_DAYS").map { JSCoercion.number(fromString: $0) } ?? 90
        guard raw.isFinite, raw > 0 else { return 0 }
        return raw * 86_400_000
    }

    static func peerTokenIsIdle(_ peer: JSON, limitMs: Double, nowMs: Double = JS.nowMs()) -> Bool {
        guard limitMs > 0 else { return false }
        let stamp = (peer["lastSeenAt"] || peer["createdAt"]).jsString
        guard let seen = JS.parseDate(stamp) else { return false }
        return nowMs - seen > limitMs
    }

    func peerCanUseWhenDisabled(_ pathname: String, _ method: String) -> Bool {
        guard pathname.hasPrefix("/api/companion/roachtail") else { return false }
        return method == "GET" ? pathname == "/api/companion/roachtail" : pathname == "/api/companion/roachtail/affect"
    }

    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    func requestPeerEndpoint(_ request: HTTPRequest) -> String {
        if let forwardedHost = request.header("x-forwarded-host")?.split(separator: ",").first,
            !forwardedHost.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return sanitizeUserFacingHost(String(forwardedHost))
        }
        if let forwardedFor = request.header("x-forwarded-for")?.split(separator: ",").first?.trimmingCharacters(
            in: .whitespaces), !forwardedFor.isEmpty
        {
            return sanitizeUserFacingHost(forwardedFor)
        }
        if !request.remoteAddress.isEmpty { return sanitizeUserFacingHost(request.remoteAddress) }
        return aliasHost
    }

    func recordPeerActivity(peerId: String, request: HTTPRequest) {
        runtime.withState {
            guard let state = runtime.readRoachTailStateFile(), state["peers"].isArray else { return }
            let peers = state["peers"].array
            guard peers.contains(where: { $0["id"].stringValue == peerId }) else { return }
            let now = JS.isoNow()
            var next = state
            next["status"] = JSON(state["enabled"].truthy ? "connected" : (state["status"] || "local-only").jsString)
            next["lastUpdatedAt"] = JSON(now)
            let endpoint = requestPeerEndpoint(request)
            next["peers"] = .array(
                peers.map { peer in
                    guard peer["id"].stringValue == peerId else { return peer }
                    var updated = peer
                    updated["status"] = JSON(state["enabled"].truthy ? "connected" : "paired")
                    updated["lastSeenAt"] = JSON(now)
                    updated["endpoint"] = endpoint.isEmpty ? (peer["endpoint"] || nil) : JSON(endpoint)
                    return updated
                })
            try? Files.writePrettyJSON(next, to: runtime.config.roachTailStatePath, mode: Files.privateFileMode)
        }
    }

    func handle(_ request: inout HTTPRequest) -> HTTPResponse {
        let url =
            WebURL(request.target, base: WebURL("http://roachnet-companion.local")) ?? WebURL(
                "http://roachnet-companion.local/")!
        let pathname = url.pathname
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: CompanionProxy.corsHeaders)
        }
        if pathname == "/health" {
            return json(
                200,
                [
                    "status": "ok",
                    "targetOrigin": JSON("http://127.0.0.1:\(runtime.listenPort)"),
                    "tokenConfigured": JSON(!token.isEmpty),
                    "inProcess": true,
                ])
        }
        if !CompanionProxy.isProxyPath(pathname) || pathname.hasPrefix("//") {
            return json(404, ["error": "Not found"])
        }

        let pairing = pathname == "/api/companion/roachtail/pair" && request.method == "POST"
        var authKind = "pairing"
        var peerId: String?
        var peerName: String?
        if !pairing {
            let provided = extractToken(request)
            if !provided.isEmpty && !token.isEmpty && CompanionProxy.tokensMatch(provided, token) {
                authKind = "primary"
            } else if let peer = resolvePeer(provided, allowDisabled: peerCanUseWhenDisabled(pathname, request.method))
            {
                authKind = "peer"
                peerId = peer["id"].stringValue
                peerName = peer["name"].stringValue ?? "Linked device"
            } else {
                return json(
                    401,
                    [
                        "error":
                            "Invalid or missing companion token. A phone that went unused for a long time has to pair again."
                    ])
            }
        }

        var body: Data?
        if request.method != "GET" && request.method != "HEAD" {
            do {
                body = try request.body()
            } catch {
                return json(413, ["error": "Companion request body is too large."])
            }
        }

        if authKind == "peer", let peerId { recordPeerActivity(peerId: peerId, request: request) }

        var headers: [String: String] = [
            "accept": "application/json",
            "content-type": request.header("content-type") ?? "application/json",
            "x-roachtail-auth-kind": authKind,
        ]
        if pathname.hasPrefix("/api/org"), let orgKey = request.header("x-roachnet-org-key") {
            headers["x-roachnet-org-key"] = orgKey
        }
        if let peerId {
            headers["x-roachtail-peer-id"] = peerId
            headers["x-roachtail-peer-name"] = peerName ?? "Linked device"
            headers["x-roachtail-auth-peer-id"] = peerId
        }
        var upstream = HTTPRequest(
            method: request.method, target: pathname + url.search, headers: headers, remoteAddress: "127.0.0.1",
            body: body ?? Data())
        upstream.inProcess = true
        let response = runtime.handle(&upstream)
        if response.body.count > maxResponseBodyBytes {
            return json(502, ["error": JSON("Local runtime response exceeded \(maxResponseBodyBytes) bytes.")])
        }
        let contentType =
            response.headers.first { $0.0.lowercased() == "content-type" }?.1 ?? "application/json; charset=utf-8"
        return HTTPResponse(
            status: response.status, headers: CompanionProxy.corsHeaders + [("Content-Type", contentType)],
            body: response.body)
    }
}
