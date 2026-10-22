import Foundation

extension NativeRuntime {
    func routeTraces(_ request: inout HTTPRequest, url: WebURL) throws -> HTTPResponse {
        let method = request.method
        let segments = url.pathname.split(separator: "/").dropFirst(2).map {
            String($0).removingPercentEncoding ?? String($0)
        }
        func ok(_ value: JSON, _ status: Int = 200) -> HTTPResponse { .json(status, value) }

        switch (method, segments.first ?? "", segments.count) {
        case ("GET", "", 0):
            return ok(listTraces(url, companyId: url.queryParameter("companyId")))
        case ("GET", "metrics", 1):
            return ok(traceMetrics(url, companyId: url.queryParameter("companyId")))
        case ("GET", "settings", 1):
            return ok(traceSettingsJSON())
        case ("PUT", "settings", 1), ("PATCH", "settings", 1):
            return ok(try updateTraceSettings(try readRequestJSON(&request)))
        case ("POST", "export", 2) where segments[1] == "test":
            return ok(traceExporter.test())
        case ("POST", "export", 2) where segments[1] == "flush":
            let sent = traceExporter.flush(force: true)
            return ok([
                "ok": JSON(sent), "pending": JSON(traceExporter.pendingCount), "result": traceExporter.lastResult,
            ])
        case ("GET", _, 1):
            return ok(try traceDetail(segments[0], companyId: nil))
        case ("DELETE", _, 1):
            guard tracer.store.delete(segments[0]) else { throw requestError("No trace \(segments[0]).", 404) }
            return ok(["deleted": true])
        case ("POST", _, 2) where segments[1] == "scores":
            return ok(try addTraceScore(segments[0], try readRequestJSON(&request), authorId: nil, companyId: nil), 201)
        default:
            throw requestError("Unknown trace route.", 404)
        }
    }

    static func traceMillis(_ raw: String?) -> Int64? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let number = Int64(raw) { return number }
        return JS.parseDate(raw).map { Int64($0) }
    }

    func traceFilter(_ url: WebURL, companyId: String?) -> (TraceRecord) -> Bool {
        let kind = url.queryParameter("kind")
        let agent = url.queryParameter("agentId")
        let issue = url.queryParameter("issueId")
        let session = url.queryParameter("sessionId")
        let status = url.queryParameter("status")
        let run = url.queryParameter("runId")
        let tag = url.queryParameter("tag")
        let query = url.queryParameter("q")?.lowercased().trimmingCharacters(in: .whitespaces)
        let from = Self.traceMillis(url.queryParameter("from"))
        let to = Self.traceMillis(url.queryParameter("to"))
        return { trace in
            if let companyId, trace.companyId != companyId { return false }
            if let kind, !kind.isEmpty, trace.kind != kind { return false }
            if let agent, !agent.isEmpty, trace.agentId != agent { return false }
            if let issue, !issue.isEmpty, trace.issueId != issue { return false }
            if let session, !session.isEmpty, trace.sessionId != session { return false }
            if let run, !run.isEmpty, trace.runId != run { return false }
            if let status, !status.isEmpty, trace.status != status { return false }
            if let tag, !tag.isEmpty, !trace.tags.contains(tag) { return false }
            if let from, trace.startMs < from { return false }
            if let to, trace.startMs > to { return false }
            if let query, !query.isEmpty, !trace.name.lowercased().contains(query) && trace.id != query { return false }
            return true
        }
    }

    func listTraces(_ url: WebURL, companyId: String?) -> JSON {
        let limit = Int(url.queryParameter("limit") ?? "") ?? 50
        let includeContent = url.queryParameter("content") == "1"
        let page = tracer.store.list(
            limit: limit, cursor: url.queryParameter("cursor"), matching: traceFilter(url, companyId: companyId))
        return [
            "traces": .array(page.items.map { TraceJSON.trace($0, includeContent: includeContent) }),
            "nextCursor": JSON(page.next),
        ]
    }

    func traceMetrics(_ url: WebURL, companyId: String?) -> JSON {
        let groupBy = url.queryParameter("groupBy") ?? "kind"
        guard ["kind", "agent", "name", "day", "model", "provider"].contains(groupBy) else {
            return ["error": "groupBy is one of kind, agent, name, day, model, provider."]
        }
        return TraceMetrics.compute(
            store: tracer.store, groupBy: groupBy, matching: traceFilter(url, companyId: companyId))
    }

    func traceDetail(_ id: String, companyId: String?) throws -> JSON {
        guard let trace = tracer.store.trace(id), companyId == nil || trace.companyId == companyId else {
            throw requestError("No trace \(id).", 404)
        }
        var json = TraceJSON.trace(trace)
        json["observations"] = .array(tracer.store.observations(id).map(TraceJSON.observation))
        json["scores"] = .array(tracer.store.scores(id).map(TraceJSON.score))
        return json
    }

    func addTraceScore(_ traceId: String, _ body: JSON, authorId: String?, companyId: String?) throws -> JSON {
        guard let trace = tracer.store.trace(traceId), companyId == nil || trace.companyId == companyId else {
            throw requestError("No trace \(traceId).", 404)
        }
        let name = (body["name"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw requestError("A score needs a name (80 characters or fewer).", 400)
        }
        let observationId = body["observationId"].stringValue
        if let observationId, tracer.store.observation(traceId, observationId) == nil {
            throw requestError("No observation \(observationId) in this trace.", 404)
        }
        var dataType = (body["dataType"].stringValue ?? "").uppercased()
        var value: Double?
        var text: String?
        switch body["value"] {
        case .number(let number):
            value = number
            if dataType.isEmpty { dataType = "NUMERIC" }
        case .bool(let flag):
            value = flag ? 1 : 0
            if dataType.isEmpty { dataType = "BOOLEAN" }
        case .string(let label):
            text = String(label.prefix(200))
            if dataType.isEmpty { dataType = "CATEGORICAL" }
        default: throw requestError("A score needs a value: a number, true/false or a label.", 400)
        }
        guard ["NUMERIC", "BOOLEAN", "CATEGORICAL"].contains(dataType) else {
            throw requestError("dataType is NUMERIC, BOOLEAN or CATEGORICAL.", 400)
        }
        let source =
            body["source"].stringValue.flatMap { ["human", "api", "evaluator"].contains($0) ? $0 : nil } ?? "api"
        let score = ScoreRecord(
            id: TraceIDs.observation(), traceId: traceId, observationId: observationId, name: name, dataType: dataType,
            value: value, stringValue: text, comment: body["comment"].stringValue.map { String($0.prefix(2_000)) },
            source: source, authorId: authorId, createdMs: TraceClock.nowMs())
        tracer.store.add(score)
        return TraceJSON.score(score)
    }

    func traceSettingsJSON() -> JSON {
        let settings = tracer.settings
        var pricing = JSONObject()
        for (model, price) in settings.pricing.sorted(by: { $0.key < $1.key }) {
            pricing[model] = [
                "inputPerMTok": JSON(price.inputPerMTok), "outputPerMTok": JSON(price.outputPerMTok),
                "cachedInputPerMTok": JSON(price.cachedInputPerMTok),
            ]
        }
        return [
            "enabled": JSON(settings.enabled), "captureContent": JSON(settings.captureContent),
            "maxContentChars": JSON(settings.maxContentChars),
            "retentionDays": JSON(settings.retentionDays), "traceModelServer": JSON(settings.traceModelServer),
            "export": [
                "enabled": JSON(settings.export.enabled), "endpoint": JSON(settings.export.endpoint),
                "includeContent": JSON(settings.export.includeContent),
                "headerNames": JSON(settings.export.headers.keys.sorted()),
                "serviceName": JSON(settings.export.serviceName),
                "environment": JSON(settings.export.environment), "pending": JSON(traceExporter.pendingCount),
                "lastResult": traceExporter.lastResult,
            ],
            "pricing": .object(pricing),
            "storagePath": JSON(tracer.store.root),
        ]
    }

    func updateTraceSettings(_ body: JSON) throws -> JSON {
        if let endpoint = body["export"]["endpoint"].stringValue,
            !endpoint.trimmingCharacters(in: .whitespaces).isEmpty,
            TraceExporter.endpointURL(endpoint) == nil
        {
            throw requestError("The export endpoint must be https (or http on this Mac).", 400)
        }
        var pricing: [String: TracePrice]?
        if body["pricing"].isObject {
            var table: [String: TracePrice] = [:]
            for (model, entry) in body["pricing"].object {
                guard let input = entry["inputPerMTok"].numberValue, let output = entry["outputPerMTok"].numberValue,
                    input >= 0, output >= 0
                else {
                    throw requestError(
                        "Pricing for \(model) needs inputPerMTok and outputPerMTok (US dollars per million tokens).",
                        400)
                }
                table[String(model.prefix(200))] = TracePrice(
                    inputPerMTok: input, outputPerMTok: output,
                    cachedInputPerMTok: entry["cachedInputPerMTok"].numberValue)
            }
            pricing = table
        }
        _ = try tracer.store.updateSettings { settings in
            if let value = body["enabled"].boolValue { settings.enabled = value }
            if let value = body["captureContent"].boolValue { settings.captureContent = value }
            if let value = body["maxContentChars"].clampedInt() { settings.maxContentChars = value }
            if let value = body["retentionDays"].clampedInt() { settings.retentionDays = value }
            if let value = body["traceModelServer"].boolValue { settings.traceModelServer = value }
            let export = body["export"]
            if let value = export["enabled"].boolValue { settings.export.enabled = value }
            if let value = export["endpoint"].stringValue {
                settings.export.endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = export["includeContent"].boolValue { settings.export.includeContent = value }
            if let value = export["serviceName"].stringValue, !value.isEmpty {
                settings.export.serviceName = String(value.prefix(100))
            }
            if let value = export["environment"].stringValue, !value.isEmpty {
                settings.export.environment = String(value.prefix(100))
            }
            for (name, value) in export["headers"].object {
                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty, key.count <= 100 else { continue }
                if let text = value.stringValue, !text.isEmpty {
                    settings.export.headers[key] = String(text.prefix(4_000))
                } else {
                    settings.export.headers.removeValue(forKey: key)
                }
            }
            if let pricing { settings.pricing = pricing }
        }
        tracer.store.purgeExpired(force: true)
        return traceSettingsJSON()
    }
}
