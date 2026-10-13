import Foundation

/// OTLP/HTTP (JSON encoding) export to the person's own collector or Langfuse.
/// Off by default. Batches finished traces, keeps a bounded queue on disk while
/// the endpoint is unreachable, and backs off up to five minutes.
public final class TraceExporter {
    public static let queueCap = 5_000
    public static let batchSize = 200
    let store: TraceStore
    let version: String
    private let lock = NSLock()
    /// One flush at a time: the timer's and `POST /api/traces/export/flush` would
    /// otherwise send the same batch and each drop a batch's worth, losing the next one.
    private let flushLock = NSLock()
    private var pending: [JSON] = []
    /// Spans `enqueue` dropped from the front to stay under the cap, so a flush
    /// in flight removes only what it sent and is still queued.
    private var droppedFromFront = 0
    private let queue = DispatchQueue(label: "org.roachnet.trace-export")
    private var timer: DispatchSourceTimer?
    private var retryAfter = Date.distantPast
    private var backoffSeconds = 5.0
    public private(set) var lastResult: JSON = .null
    var send: (String, [String: String], Data) throws -> HTTPResponseLite = { url, headers, body in
        let response = try HTTPClient.request(url, method: "POST", headers: headers, body: body, timeoutMs: 15_000, maxResponseBytes: 256 * 1024)
        return HTTPResponseLite(status: response.status, body: response.body)
    }

    public struct HTTPResponseLite { public var status: Int; public var body: Data }

    private var queuePath: String { Path.join(store.root, "export-queue.json") }

    public init(store: TraceStore, version: String) {
        self.store = store
        self.version = version
        if let data = FileManager.default.contents(atPath: queuePath), let saved = try? JSON.parse(data) { pending = saved.array }
    }

    public static func endpointURL(_ raw: String) -> String? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let parsed = WebURL(base) else { return nil }
        let host = parsed.bareHostname.lowercased()
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard parsed.scheme == "https" || (parsed.scheme == "http" && loopback) else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return base.hasSuffix("/v1/traces") ? base : base + "/v1/traces"
    }

    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume()
        timer = source
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Called when a trace ends.
    public func enqueue(_ trace: TraceRecord, _ observations: [ObservationRecord]) {
        let settings = store.settings
        guard settings.export.enabled, TraceExporter.endpointURL(settings.export.endpoint) != nil else { return }
        let spans = TraceExporter.spans(trace, observations, includeContent: settings.export.includeContent)
        lock.lock()
        pending.append(contentsOf: spans)
        if pending.count > TraceExporter.queueCap {
            let overflow = pending.count - TraceExporter.queueCap
            pending.removeFirst(overflow)
            droppedFromFront += overflow
        }
        lock.unlock()
    }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    /// Sends one batch. Returns false when the endpoint refused it or was unreachable.
    @discardableResult
    public func flush(force: Bool = false) -> Bool {
        let settings = store.settings
        guard settings.export.enabled, let url = TraceExporter.endpointURL(settings.export.endpoint) else { return false }
        flushLock.lock()
        defer { flushLock.unlock() }
        lock.lock()
        guard !pending.isEmpty, force || Date() >= retryAfter else { lock.unlock(); return true }
        let batch = Array(pending.prefix(TraceExporter.batchSize))
        let droppedBefore = droppedFromFront
        lock.unlock()
        let ok = post(url: url, spans: batch, settings: settings)
        lock.lock()
        if ok {
            let sentAndQueued = max(0, batch.count - (droppedFromFront - droppedBefore))
            pending.removeFirst(min(sentAndQueued, pending.count))
            backoffSeconds = 5
            retryAfter = .distantPast
        } else {
            retryAfter = Date().addingTimeInterval(backoffSeconds)
            backoffSeconds = min(backoffSeconds * 2, 300)
        }
        let snapshot = pending
        lock.unlock()
        try? Files.write(JSON.array(snapshot).serialized(), to: queuePath, mode: Files.privateFileMode)
        return ok
    }

    /// One span named "RoachNet export test", sent straight away.
    public func test() -> JSON {
        let settings = store.settings
        guard let url = TraceExporter.endpointURL(settings.export.endpoint) else {
            return ["ok": false, "error": "Set an https endpoint (or http on this Mac) first."]
        }
        let now = TraceClock.nowMs()
        let trace = TraceRecord(id: TraceIDs.trace(), kind: "api", name: "RoachNet export test", tags: ["roachnet-test"], status: "ok", startMs: now, endMs: now + 1)
        let ok = post(url: url, spans: TraceExporter.spans(trace, [], includeContent: false), settings: settings)
        return ["ok": JSON(ok), "result": lastResult]
    }

    private func post(url: String, spans: [JSON], settings: TraceSettings) -> Bool {
        var headers = ["content-type": "application/json", "user-agent": "RoachNet/\(version) roachtrace"]
        for (key, value) in settings.export.headers { headers[key.lowercased()] = value }
        if headers["x-langfuse-ingestion-version"] == nil, url.contains("/api/public/otel") { headers["x-langfuse-ingestion-version"] = "4" }
        let body = TraceExporter.payload(spans, serviceName: settings.export.serviceName, version: version, environment: settings.export.environment)
        do {
            let response = try send(url, headers, body.serializedData())
            let ok = (200..<300).contains(response.status)
            lastResult = ["status": JSON(response.status), "at": JSON(JS.isoNow()), "sent": JSON(spans.count),
                          "error": ok ? .null : JSON(String(decoding: response.body.prefix(500), as: UTF8.self))]
            return ok
        } catch {
            lastResult = ["status": .null, "at": JSON(JS.isoNow()), "sent": 0, "error": JSON("\(error)")]
            return false
        }
    }

    // MARK: OTLP JSON

    static func attribute(_ key: String, _ value: JSON) -> JSON? {
        switch value {
        case .string(let text): return ["key": JSON(key), "value": ["stringValue": JSON(text)]]
        case .bool(let flag): return ["key": JSON(key), "value": ["boolValue": JSON(flag)]]
        case .number(let number):
            if number.rounded() == number && abs(number) < 9e15 { return ["key": JSON(key), "value": ["intValue": JSON(String(Int64(number)))]] }
            return ["key": JSON(key), "value": ["doubleValue": JSON(number)]]
        case .array, .object: return ["key": JSON(key), "value": ["stringValue": JSON(value.serialized())]]
        default: return nil
        }
    }

    static func nanos(_ ms: Int64) -> JSON { JSON(String(ms * 1_000_000)) }

    /// One OTLP span per observation (a trace with none becomes one span).
    /// Root spans carry the trace-level attributes Langfuse reads.
    public static func spans(_ trace: TraceRecord, _ observations: [ObservationRecord], includeContent: Bool) -> [JSON] {
        var traceAttributes: [(String, JSON)] = [
            ("langfuse.trace.name", JSON(trace.name)), ("roachnet.trace.kind", JSON(trace.kind)),
        ]
        if let session = trace.sessionId { traceAttributes.append(("langfuse.session.id", JSON(session))) }
        if let user = trace.userId { traceAttributes.append(("langfuse.user.id", JSON(user))) }
        if !trace.tags.isEmpty { traceAttributes.append(("langfuse.trace.tags", JSON(trace.tags))) }
        for (key, value) in [("roachnet.company.id", trace.companyId), ("roachnet.agent.id", trace.agentId), ("roachnet.issue.id", trace.issueId), ("roachnet.run.id", trace.runId)] {
            if let value { traceAttributes.append((key, JSON(value))) }
        }
        for (key, value) in trace.metadata.object { traceAttributes.append(("langfuse.trace.metadata.\(key)", value)) }
        if includeContent {
            if !trace.input.isNull { traceAttributes.append(("langfuse.trace.input", trace.input)) }
            if !trace.output.isNull { traceAttributes.append(("langfuse.trace.output", trace.output)) }
        }

        let items = observations.isEmpty
            ? [ObservationRecord(id: String(trace.id.suffix(16)), traceId: trace.id, type: .span, name: trace.name, startMs: trace.startMs, endMs: trace.endMs ?? trace.startMs)]
            : observations
        let ids = Set(items.map(\.id))
        return items.map { item in
            var attributes: [(String, JSON)] = [("langfuse.observation.type", JSON(item.type.rawValue)), ("langfuse.observation.level", JSON(item.level.rawValue))]
            let isRoot = item.parentId == nil || !ids.contains(item.parentId!)
            if isRoot { attributes.append(contentsOf: traceAttributes) }
            if let message = item.statusMessage { attributes.append(("langfuse.observation.status_message", JSON(message))) }
            if let model = item.model {
                attributes.append(("gen_ai.request.model", JSON(model))); attributes.append(("gen_ai.response.model", JSON(model)))
                attributes.append(("langfuse.observation.model.name", JSON(model)))
            }
            if let provider = item.provider { attributes.append(("gen_ai.system", JSON(provider))); attributes.append(("gen_ai.provider.name", JSON(provider))) }
            if item.type == .generation { attributes.append(("gen_ai.operation.name", "chat")) }
            if !item.modelParameters.isNullish { attributes.append(("langfuse.observation.model.parameters", item.modelParameters)) }
            if let usage = item.usage {
                attributes.append(("gen_ai.usage.input_tokens", JSON(usage.inputTokens)))
                attributes.append(("gen_ai.usage.output_tokens", JSON(usage.outputTokens)))
                attributes.append(("langfuse.observation.usage_details", ["input": JSON(usage.inputTokens), "output": JSON(usage.outputTokens), "input_cached_tokens": JSON(usage.cachedInputTokens)]))
            }
            if let cost = item.cost, cost.status != "unpriced" { attributes.append(("langfuse.observation.cost_details", ["total": JSON(cost.totalUsd)])) }
            if let first = item.completionStartMs { attributes.append(("langfuse.observation.completion_start_time", TraceClock.iso(first))) }
            if let rate = item.outputTokensPerSecond { attributes.append(("roachnet.output_tokens_per_second", JSON(rate))) }
            for (key, value) in item.metadata.object { attributes.append(("langfuse.observation.metadata.\(key)", value)) }
            if includeContent {
                if !item.input.isNull { attributes.append(("langfuse.observation.input", item.input)) }
                if !item.output.isNull { attributes.append(("langfuse.observation.output", item.output)) }
            }
            let failed = item.level == .error || (isRoot && trace.status == "error")
            var span: JSON = [
                "traceId": JSON(trace.id), "spanId": JSON(item.id), "name": JSON(item.name),
                "kind": JSON(item.type == .generation || item.type == .embedding ? 3 : 1),
                "startTimeUnixNano": nanos(item.startMs), "endTimeUnixNano": nanos(item.endMs ?? trace.endMs ?? item.startMs),
                "attributes": .array(attributes.compactMap { attribute($0.0, $0.1) }),
                "status": failed ? ["code": 2, "message": JSON(item.statusMessage ?? trace.statusMessage ?? "error")] : ["code": 1],
            ]
            if let parent = item.parentId, ids.contains(parent) { span["parentSpanId"] = JSON(parent) }
            return span
        }
    }

    public static func payload(_ spans: [JSON], serviceName: String, version: String, environment: String) -> JSON {
        [
            "resourceSpans": [[
                "resource": ["attributes": .array([
                    attribute("service.name", JSON(serviceName)), attribute("service.version", JSON(version)),
                    attribute("deployment.environment", JSON(environment)), attribute("langfuse.environment", JSON(environment)),
                    attribute("langfuse.release", JSON(version)),
                ].compactMap { $0 })],
                "scopeSpans": [["scope": ["name": "roachnet.roachtrace", "version": JSON(version)], "spans": .array(spans)]],
            ]],
        ]
    }
}
