import Foundation

/// JSON for the API, and the rollups the Traces board and `/api/traces/metrics` show.
public enum TraceJSON {
    public static func usage(_ usage: TraceUsage?) -> JSON {
        guard let usage else { return .null }
        return ["input": JSON(usage.inputTokens), "output": JSON(usage.outputTokens), "cachedInput": JSON(usage.cachedInputTokens), "total": JSON(usage.totalTokens)]
    }

    public static func cost(_ cost: TraceCost?) -> JSON {
        guard let cost else { return .null }
        return ["totalUsd": JSON(cost.totalUsd), "status": JSON(cost.status), "billingType": JSON(cost.billingType)]
    }

    public static func trace(_ trace: TraceRecord, includeContent: Bool = true) -> JSON {
        var json: JSON = [
            "id": JSON(trace.id), "kind": JSON(trace.kind), "name": JSON(trace.name),
            "companyId": JSON(trace.companyId), "agentId": JSON(trace.agentId), "issueId": JSON(trace.issueId), "runId": JSON(trace.runId),
            "sessionId": JSON(trace.sessionId), "userId": JSON(trace.userId), "tags": JSON(trace.tags),
            "status": JSON(trace.status), "statusMessage": JSON(trace.statusMessage),
            "startTime": TraceClock.iso(trace.startMs), "endTime": TraceClock.iso(trace.endMs), "latencyMs": JSON(trace.latencyMs.map { Int($0) }),
            "usage": usage(trace.usage), "costUsd": JSON(trace.costUsd), "unpriced": JSON(trace.unpriced),
            "observationCount": JSON(trace.observationCount), "metadata": trace.metadata,
        ]
        if includeContent { json["input"] = trace.input; json["output"] = trace.output }
        return json
    }

    public static func observation(_ item: ObservationRecord) -> JSON {
        [
            "id": JSON(item.id), "traceId": JSON(item.traceId), "parentObservationId": JSON(item.parentId),
            "type": JSON(item.type.rawValue), "name": JSON(item.name), "level": JSON(item.level.rawValue), "statusMessage": JSON(item.statusMessage),
            "startTime": TraceClock.iso(item.startMs), "endTime": TraceClock.iso(item.endMs), "completionStartTime": TraceClock.iso(item.completionStartMs),
            "latencyMs": JSON(item.latencyMs.map { Int($0) }), "timeToFirstTokenMs": JSON(item.timeToFirstTokenMs.map { Int($0) }),
            "input": item.input, "output": item.output, "metadata": item.metadata,
            "model": JSON(item.model), "provider": JSON(item.provider), "modelParameters": item.modelParameters,
            "usage": usage(item.usage), "cost": cost(item.cost),
            "promptTokensPerSecond": JSON(item.promptTokensPerSecond), "outputTokensPerSecond": JSON(item.outputTokensPerSecond),
        ]
    }

    public static func score(_ score: ScoreRecord) -> JSON {
        [
            "id": JSON(score.id), "traceId": JSON(score.traceId), "observationId": JSON(score.observationId), "name": JSON(score.name),
            "dataType": JSON(score.dataType), "value": JSON(score.value), "stringValue": JSON(score.stringValue), "comment": JSON(score.comment),
            "source": JSON(score.source), "authorId": JSON(score.authorId), "createdAt": TraceClock.iso(score.createdMs),
        ]
    }
}

public enum TraceMetrics {
    static func percentile(_ values: [Int64], _ fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * fraction).rounded())
        return Int(sorted[min(max(rank, 0), sorted.count - 1)])
    }

    private struct Bucket {
        var count = 0, errors = 0, unpriced = 0
        var usage = TraceUsage()
        var costUsd = 0.0
        var latencies: [Int64] = []
        var ttfts: [Int64] = []
        var outputRates: [Double] = []
    }

    /// Rollups over the traces `matching` selects. `groupBy`: kind, agent, name,
    /// day, model, provider. Model and provider group the generations inside.
    public static func compute(store: TraceStore, groupBy: String, matching: (TraceRecord) -> Bool) -> JSON {
        let traces = store.allTraces(matching: matching)
        var buckets: [String: Bucket] = [:]
        var totals = Bucket()
        for trace in traces {
            totals.count += 1
            if trace.status == "error" { totals.errors += 1 }
            totals.usage = totals.usage + trace.usage
            totals.costUsd += trace.costUsd
            if trace.unpriced { totals.unpriced += 1 }
            if let latency = trace.latencyMs { totals.latencies.append(latency) }
            switch groupBy {
            case "model", "provider":
                for item in store.observations(trace.id) where item.type == .generation || item.type == .embedding {
                    let key = (groupBy == "model" ? item.model : item.provider) ?? "unknown"
                    var bucket = buckets[key] ?? Bucket()
                    bucket.count += 1
                    if item.level == .error { bucket.errors += 1 }
                    if let usage = item.usage { bucket.usage = bucket.usage + usage }
                    if let cost = item.cost { bucket.costUsd += cost.totalUsd; if cost.status == "unpriced" && cost.billingType != "local" { bucket.unpriced += 1 } }
                    if let latency = item.latencyMs { bucket.latencies.append(latency) }
                    if let ttft = item.timeToFirstTokenMs { bucket.ttfts.append(ttft); totals.ttfts.append(ttft) }
                    if let rate = item.outputTokensPerSecond { bucket.outputRates.append(rate); totals.outputRates.append(rate) }
                    buckets[key] = bucket
                }
            default:
                let key: String
                switch groupBy {
                case "agent": key = trace.agentId ?? "none"
                case "name": key = trace.name
                case "day": key = TraceClock.day(trace.startMs)
                default: key = trace.kind
                }
                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1
                if trace.status == "error" { bucket.errors += 1 }
                bucket.usage = bucket.usage + trace.usage
                bucket.costUsd += trace.costUsd
                if trace.unpriced { bucket.unpriced += 1 }
                if let latency = trace.latencyMs { bucket.latencies.append(latency) }
                for item in store.observations(trace.id) where item.type == .generation {
                    if let ttft = item.timeToFirstTokenMs { bucket.ttfts.append(ttft); totals.ttfts.append(ttft) }
                    if let rate = item.outputTokensPerSecond { bucket.outputRates.append(rate); totals.outputRates.append(rate) }
                }
                buckets[key] = bucket
            }
        }
        func row(_ key: String?, _ bucket: Bucket) -> JSON {
            [
                "key": JSON(key), "count": JSON(bucket.count), "errors": JSON(bucket.errors),
                "errorRate": JSON(bucket.count > 0 ? Double(bucket.errors) / Double(bucket.count) : 0),
                "usage": TraceJSON.usage(bucket.usage), "costUsd": JSON(bucket.costUsd), "unpricedCount": JSON(bucket.unpriced),
                "latencyP50Ms": JSON(percentile(bucket.latencies, 0.5)), "latencyP95Ms": JSON(percentile(bucket.latencies, 0.95)),
                "timeToFirstTokenP50Ms": JSON(percentile(bucket.ttfts, 0.5)),
                "outputTokensPerSecond": JSON(bucket.outputRates.isEmpty ? nil : bucket.outputRates.reduce(0, +) / Double(bucket.outputRates.count)),
            ]
        }
        let rows = buckets.sorted { lhs, rhs in lhs.value.count != rhs.value.count ? lhs.value.count > rhs.value.count : lhs.key < rhs.key }
        return ["groupBy": JSON(groupBy), "totals": row(nil, totals), "groups": .array(rows.map { row($0.key, $0.value) })]
    }
}
