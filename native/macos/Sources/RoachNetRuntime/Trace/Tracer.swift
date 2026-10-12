import Foundation

/// Scrubs secrets out of captured content before it is written: values the
/// runtime registered (provider keys, Org secrets, tokens it minted) and
/// anything shaped like a RoachNet or provider token.
public final class TraceRedactor {
    private let lock = NSLock()
    private var secrets = Set<String>()
    private static let patterns: [NSRegularExpression] = [
        "rnrun_[A-Za-z0-9._-]{8,}", "rnorg_[A-Za-z0-9._-]{8,}", "\\brn_[A-Za-z0-9]{16,}",
        "sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}", "(?i)bearer\\s+[A-Za-z0-9._~+/=-]{12,}",
        "gh[pousr]_[A-Za-z0-9]{20,}", "xox[baprs]-[A-Za-z0-9-]{10,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public init() {}

    public func register(_ secret: String?) {
        guard let secret, secret.count >= 8 else { return }
        lock.lock(); secrets.insert(secret); lock.unlock()
    }

    public func redact(_ text: String) -> String {
        var out = text
        lock.lock(); let known = secrets; lock.unlock()
        for secret in known where out.contains(secret) { out = out.replacingOccurrences(of: secret, with: "***") }
        for pattern in TraceRedactor.patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = pattern.stringByReplacingMatches(in: out, range: range, withTemplate: "***")
        }
        return out
    }

    /// Redacts every string and caps each one at `maxChars`.
    public func scrub(_ value: JSON, maxChars: Int) -> JSON {
        switch value {
        case .string(let text):
            let clean = redact(text)
            return clean.count > maxChars ? JSON(String(clean.prefix(maxChars)) + "… [\(clean.count - maxChars) more characters]") : JSON(clean)
        case .array(let items):
            return .array(items.prefix(500).map { scrub($0, maxChars: maxChars) })
        case .object(let object):
            var next = JSONObject()
            for (key, item) in object {
                let lowered = key.lowercased()
                if ["authorization", "apikey", "api_key", "password", "secret", "token"].contains(lowered) { next[key] = "***"; continue }
                next[key] = scrub(item, maxChars: maxChars)
            }
            return .object(next)
        default:
            return value
        }
    }
}

/// The entry point instrumentation uses. Every call is cheap and safe when
/// tracing is off: it hands back nil and nothing is recorded.
public final class Tracer {
    public let store: TraceStore
    public let redactor = TraceRedactor()
    public var onTraceEnded: ((TraceRecord, [ObservationRecord]) -> Void)?

    public init(store: TraceStore) { self.store = store }

    public var settings: TraceSettings { store.settings }

    func content(_ value: JSON) -> JSON {
        let settings = store.settings
        guard settings.captureContent, !value.isUndefined else { return .null }
        return redactor.scrub(value, maxChars: settings.maxContentChars)
    }

    public func startTrace(kind: String, name: String, companyId: String? = nil, agentId: String? = nil, issueId: String? = nil,
                           runId: String? = nil, sessionId: String? = nil, userId: String? = nil, tags: [String] = [],
                           input: JSON = .null, metadata: JSONObject = JSONObject()) -> TraceHandle? {
        guard store.settings.enabled else { return nil }
        let record = TraceRecord(id: TraceIDs.trace(), kind: kind, name: String(name.prefix(200)), companyId: companyId, agentId: agentId,
                                 issueId: issueId, runId: runId, sessionId: sessionId, userId: userId, tags: tags,
                                 input: content(input), metadata: redactor.scrub(.object(metadata), maxChars: 2_000), startMs: TraceClock.nowMs())
        store.upsert(record)
        return TraceHandle(tracer: self, traceId: record.id)
    }

    /// Joins a trace another component started (a `traceparent` header).
    public func attach(traceparent: String?) -> (TraceHandle, ObservationRecord)? {
        guard store.settings.enabled, let parsed = TraceIDs.parseTraceparent(traceparent),
              store.trace(parsed.traceId) != nil, let parent = store.observation(parsed.traceId, parsed.parentId) else { return nil }
        return (TraceHandle(tracer: self, traceId: parsed.traceId), parent)
    }

    /// Price for a metered call the provider did not price itself, from the
    /// person's own table; otherwise unpriced.
    public func price(model: String?, usage: TraceUsage, billingType: String) -> TraceCost {
        if billingType == "local" { return .local }
        guard let model, let table = store.settings.pricing[model] ?? store.settings.pricing[model.lowercased()] else {
            return TraceCost(totalUsd: 0, status: billingType == "subscription_included" ? "reported" : "unpriced", billingType: billingType)
        }
        let cached = Double(usage.cachedInputTokens), uncached = Double(max(0, usage.inputTokens - usage.cachedInputTokens))
        let total = (uncached * table.inputPerMTok + cached * (table.cachedInputPerMTok ?? table.inputPerMTok) + Double(usage.outputTokens) * table.outputPerMTok) / 1_000_000
        return TraceCost(totalUsd: total, status: "estimated", billingType: billingType)
    }

    /// Recomputes a trace's totals from its generations and embeddings.
    func rollUp(_ traceId: String) {
        guard var trace = store.trace(traceId) else { return }
        let observations = store.observations(traceId)
        var usage = TraceUsage(), cost = 0.0, unpriced = false
        for observation in observations where observation.type == .generation || observation.type == .embedding {
            if let item = observation.usage { usage = usage + item }
            if let item = observation.cost {
                cost += item.totalUsd
                if item.status == "unpriced" && item.billingType != "local" { unpriced = true }
            }
        }
        trace.usage = usage
        trace.costUsd = cost
        trace.unpriced = unpriced
        trace.observationCount = observations.count
        store.upsert(trace)
    }
}

public final class TraceHandle {
    public let tracer: Tracer
    public let traceId: String

    init(tracer: Tracer, traceId: String) {
        self.tracer = tracer
        self.traceId = traceId
    }

    public func observation(_ type: TraceObservationType, _ name: String, parentId: String? = nil, input: JSON = .null,
                            metadata: JSONObject = JSONObject(), model: String? = nil, provider: String? = nil,
                            modelParameters: JSON = .null) -> ObservationHandle {
        let record = ObservationRecord(id: TraceIDs.observation(), traceId: traceId, parentId: parentId, type: type, name: String(name.prefix(200)),
                                       startMs: TraceClock.nowMs(), input: tracer.content(input),
                                       metadata: tracer.redactor.scrub(.object(metadata), maxChars: 2_000), model: model, provider: provider,
                                       modelParameters: modelParameters)
        tracer.store.upsert(record)
        return ObservationHandle(tracer: tracer, traceId: traceId, id: record.id)
    }

    /// A point-in-time event (a log line, a wake, a decision).
    public func event(_ name: String, parentId: String? = nil, level: TraceLevel = .default, input: JSON = .null, metadata: JSONObject = JSONObject()) {
        let now = TraceClock.nowMs()
        var record = ObservationRecord(id: TraceIDs.observation(), traceId: traceId, parentId: parentId, type: .event, name: String(name.prefix(200)),
                                       startMs: now, input: tracer.content(input), metadata: tracer.redactor.scrub(.object(metadata), maxChars: 2_000))
        record.level = level
        record.endMs = now
        tracer.store.upsert(record)
    }

    public func end(status: String, output: JSON = .null, message: String? = nil, metadata: JSONObject? = nil) {
        guard var trace = tracer.store.trace(traceId) else { return }
        trace.status = status
        trace.statusMessage = message.map { tracer.redactor.redact(String($0.prefix(4_000))) }
        if !output.isNull { trace.output = tracer.content(output) }
        if let metadata { trace.metadata = trace.metadata.merging(tracer.redactor.scrub(.object(metadata), maxChars: 2_000)) }
        trace.endMs = TraceClock.nowMs()
        tracer.store.upsert(trace)
        tracer.rollUp(traceId)
        if let ended = tracer.store.trace(traceId) { tracer.onTraceEnded?(ended, tracer.store.observations(traceId)) }
    }
}

public final class ObservationHandle {
    public let tracer: Tracer
    public let traceId: String
    public let id: String

    init(tracer: Tracer, traceId: String, id: String) {
        self.tracer = tracer
        self.traceId = traceId
        self.id = id
    }

    public var traceparent: String { TraceIDs.traceparent(traceId, id) }

    public func child(_ type: TraceObservationType, _ name: String, input: JSON = .null, metadata: JSONObject = JSONObject(),
                      model: String? = nil, provider: String? = nil, modelParameters: JSON = .null) -> ObservationHandle {
        TraceHandle(tracer: tracer, traceId: traceId).observation(type, name, parentId: id, input: input, metadata: metadata,
                                                                  model: model, provider: provider, modelParameters: modelParameters)
    }

    public func event(_ name: String, level: TraceLevel = .default, input: JSON = .null, metadata: JSONObject = JSONObject()) {
        TraceHandle(tracer: tracer, traceId: traceId).event(name, parentId: id, level: level, input: input, metadata: metadata)
    }

    public func markFirstToken(at ms: Int64 = TraceClock.nowMs()) {
        update { if $0.completionStartMs == nil { $0.completionStartMs = ms } }
    }

    /// Merges into the stored record, so a component that enriched this
    /// observation in the meantime (the model server, for one) keeps its fields.
    public func update(_ change: (inout ObservationRecord) -> Void) {
        guard var record = tracer.store.observation(traceId, id) else { return }
        change(&record)
        tracer.store.upsert(record)
    }

    public func end(output: JSON = .null, usage: TraceUsage? = nil, cost: TraceCost? = nil, level: TraceLevel? = nil,
                    statusMessage: String? = nil, metadata: JSONObject? = nil, model: String? = nil) {
        let content = output.isNull ? JSON.null : tracer.content(output)
        let message = statusMessage.map { tracer.redactor.redact(String($0.prefix(4_000))) }
        let extra = metadata.map { tracer.redactor.scrub(.object($0), maxChars: 2_000) }
        update { record in
            if !content.isNull { record.output = content }
            if let usage, !usage.isEmpty || record.usage == nil { record.usage = usage }
            if let cost { record.cost = cost }
            if let level { record.level = level }
            if let message { record.statusMessage = message }
            if let extra { record.metadata = record.metadata.merging(extra) }
            if let model { record.model = model }
            if record.endMs == nil { record.endMs = TraceClock.nowMs() }
        }
        tracer.rollUp(traceId)
    }
}
