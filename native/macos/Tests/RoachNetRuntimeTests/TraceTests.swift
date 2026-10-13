import XCTest
@testable import RoachNetRuntime

final class TraceTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachtrace-tests-" + JS.randomHex(8)
        try Files.mkdirp(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testTraceTreeRollsUpUsageAndCost() throws {
        let tracer = Tracer(store: TraceStore(root: root))
        let trace = try XCTUnwrap(tracer.startTrace(kind: "org_run", name: "Ada: work", agentId: "a1", input: ["hello": "world"]))
        let agent = trace.observation(.agent, "Ada")
        let first = agent.child(.generation, "step 1", model: "m1", provider: "roachinference")
        first.markFirstToken(at: TraceClock.nowMs())
        first.end(output: "ok", usage: TraceUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 40), cost: .local)
        let second = agent.child(.generation, "step 2", model: "gpt-x", provider: "openai_compatible")
        second.end(usage: TraceUsage(inputTokens: 10, outputTokens: 5), cost: TraceCost(totalUsd: 0.25, status: "estimated", billingType: "metered_api"))
        agent.child(.tool, "comment").end(output: ["ok": true])
        agent.end()
        trace.end(status: "ok", output: "done")

        let stored = try XCTUnwrap(tracer.store.trace(trace.traceId))
        XCTAssertEqual(stored.usage, TraceUsage(inputTokens: 110, outputTokens: 25, cachedInputTokens: 40))
        XCTAssertEqual(stored.costUsd, 0.25, accuracy: 1e-9)
        XCTAssertFalse(stored.unpriced)
        XCTAssertEqual(stored.observationCount, 4)
        XCTAssertNotNil(stored.endMs)
        let generations = tracer.store.observations(trace.traceId).filter { $0.type == .generation }
        XCTAssertEqual(generations.count, 2)
        XCTAssertNotNil(generations.first { $0.name == "step 1" }?.timeToFirstTokenMs)
        XCTAssertEqual(generations.first { $0.name == "step 1" }?.parentId, agent.id)
    }

    func testEngineUsageOutlastsTheCallersOllamaCount() throws {
        let tracer = Tracer(store: TraceStore(root: root))
        let trace = try XCTUnwrap(tracer.startTrace(kind: "org_run", name: "Ada: work"))
        let step = trace.observation(.generation, "step 2", model: "qwen3:0.6b")
        // The model server enriches the caller's generation first: 300 prompt tokens, 267 of them reused.
        let parent = try XCTUnwrap(tracer.attach(traceparent: step.traceparent))
        ObservationHandle(tracer: tracer, traceId: parent.0.traceId, id: parent.1.id)
            .end(usage: TraceUsage(inputTokens: 300, outputTokens: 40, cachedInputTokens: 267), cost: .local, metadata: JSONObject([("engine", "roachinference")]))
        // Then the agent loop ends it with prompt_eval_count, which counts only the 33 it evaluated.
        step.end(output: "reply", usage: TraceUsage(inputTokens: 33, outputTokens: 40))
        trace.end(status: "ok")

        let stored = try XCTUnwrap(tracer.store.observation(trace.traceId, step.id))
        XCTAssertEqual(stored.usage, TraceUsage(inputTokens: 300, outputTokens: 40, cachedInputTokens: 267))
        XCTAssertEqual(tracer.store.trace(trace.traceId)?.usage.cachedInputTokens, 267)

        // Without an engine report the caller's count stands.
        let other = try XCTUnwrap(tracer.startTrace(kind: "chat", name: "remote"))
        let call = other.observation(.generation, "g")
        call.end(usage: TraceUsage(inputTokens: 33, outputTokens: 40))
        XCTAssertEqual(tracer.store.observation(other.traceId, call.id)?.usage?.inputTokens, 33)
    }

    func testStoreReloadsFromDiskAndClosesOrphanedTraces() throws {
        let traceId: String
        do {
            let tracer = Tracer(store: TraceStore(root: root))
            let finished = try XCTUnwrap(tracer.startTrace(kind: "chat", name: "finished"))
            finished.observation(.generation, "g").end(usage: TraceUsage(inputTokens: 3, outputTokens: 4))
            finished.end(status: "ok")
            let orphan = try XCTUnwrap(tracer.startTrace(kind: "chat", name: "never ended"))
            traceId = orphan.traceId
            tracer.store.add(ScoreRecord(id: TraceIDs.observation(), traceId: finished.traceId, name: "quality", dataType: "NUMERIC", value: 4,
                                         source: "human", createdMs: TraceClock.nowMs()))
        }
        let reloaded = TraceStore(root: root)
        let all = reloaded.list(limit: 10, cursor: nil) { _ in true }.items
        XCTAssertEqual(all.count, 2)
        let orphan = try XCTUnwrap(reloaded.trace(traceId))
        XCTAssertEqual(orphan.status, "error", "a trace left running by an earlier process is closed out")
        let finished = try XCTUnwrap(all.first { $0.name == "finished" })
        XCTAssertEqual(finished.usage.totalTokens, 7)
        XCTAssertEqual(reloaded.scores(finished.id).first?.value, 4)
        XCTAssertEqual(reloaded.observations(finished.id).count, 1)

        XCTAssertTrue(reloaded.delete(finished.id))
        let again = TraceStore(root: root)
        XCTAssertNil(again.trace(finished.id), "a delete survives a reload")
        XCTAssertNotNil(again.trace(traceId))
    }

    func testListPagesNewestFirstWithACursor() throws {
        let store = TraceStore(root: root)
        let base = TraceClock.nowMs() - 10_000
        for index in 0..<5 {
            store.upsert(TraceRecord(id: TraceIDs.trace(), kind: "model", name: "t\(index)", status: "ok", startMs: base + Int64(index), endMs: base + Int64(index) + 1))
        }
        let first = store.list(limit: 2, cursor: nil) { _ in true }
        XCTAssertEqual(first.items.map(\.name), ["t4", "t3"])
        let second = store.list(limit: 2, cursor: first.next) { _ in true }
        XCTAssertEqual(second.items.map(\.name), ["t2", "t1"])
        let third = store.list(limit: 2, cursor: second.next) { _ in true }
        XCTAssertEqual(third.items.map(\.name), ["t0"])
        XCTAssertNil(third.next)
    }

    func testFiltersFindSlowExpensiveAndTaggedTraces() throws {
        let tracer = Tracer(store: TraceStore(root: root))
        let base = TraceClock.nowMs() - 60_000
        func add(_ name: String, latency: Int64?, cost: Double = 0) -> String {
            var record = TraceRecord(id: TraceIDs.trace(), kind: "model", name: name, status: latency == nil ? "running" : "ok",
                                     startMs: base, endMs: latency.map { base + $0 })
            record.costUsd = cost
            tracer.store.upsert(record)
            return record.id
        }
        let quick = add("quick", latency: 40)
        _ = add("slow", latency: 4_000, cost: 0.02)
        _ = add("running", latency: nil)
        let split = add("split", latency: 900)

        tracer.tag(split, ["cluster", " cluster-fallback ", "cluster", ""])
        XCTAssertEqual(tracer.store.trace(split)?.tags, ["cluster", "cluster-fallback"], "tags are trimmed, deduplicated and blanks dropped")
        tracer.tag(quick, (0..<40).map { "t\($0)" })
        XCTAssertEqual(tracer.store.trace(quick)?.tags.count, 32)

        func names(_ query: String) throws -> [String] {
            let url = try XCTUnwrap(WebURL("http://127.0.0.1/api/traces?\(query)"))
            return tracer.store.list(limit: 50, cursor: nil, matching: NativeRuntime.traceFilter(url, companyId: nil)).items.map(\.name).sorted()
        }
        XCTAssertEqual(try names("minLatencyMs=500"), ["slow", "split"])
        XCTAssertEqual(try names("maxLatencyMs=1000"), ["quick", "split"], "a running trace has no latency, so a bound skips it")
        XCTAssertEqual(try names("minLatencyMs=500&maxLatencyMs=1000"), ["split"])
        XCTAssertEqual(try names("minCostUsd=0.01"), ["slow"])
        XCTAssertEqual(try names("tag=cluster-fallback"), ["split"])
        XCTAssertEqual(try names("minLatencyMs=-5&minCostUsd=nan"), ["quick", "running", "slow", "split"], "bad bounds mean no bound")
    }

    func testRetentionRemovesOldDayFiles() throws {
        let old = Path.join(root, "2020-01-01.jsonl")
        try Files.write("{\"k\":\"d\",\"id\":\"x\"}\n", to: old)
        _ = TraceStore(root: root)
        XCTAssertFalse(Files.exists(old))
    }

    func testRedactorScrubsSecretsTokensAndLongText() {
        let redactor = TraceRedactor()
        redactor.register("hunter2-super-secret")
        let scrubbed = redactor.scrub([
            "text": "key=hunter2-super-secret and sk-ant-abcdefghijklmnopqrstu and Bearer abcdefghijklmnop.qrs",
            "authorization": "Basic xyz",
            "run": "rnrun_0123456789.abcdef0123",
            "long": JSON(String(repeating: "a", count: 50)),
        ], maxChars: 20)
        let text = scrubbed["text"].stringValue ?? ""
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("sk-ant-"))
        XCTAssertFalse(text.contains("abcdefghijklmnop.qrs"))
        XCTAssertEqual(scrubbed["authorization"].stringValue, "***")
        XCTAssertEqual(scrubbed["run"].stringValue, "***")
        XCTAssertTrue(scrubbed["long"].stringValue?.hasSuffix("[30 more characters]") ?? false)
    }

    func testRedactorCatchesCompoundCredentialNamesButKeepsCounts() {
        let credentials = ["access_token", "refresh_token", "client_secret", "private_key", "x-api-key", "X-Api-Key", "apiKey", "APIKey",
                           "accessToken", "idToken", "set-cookie", "Cookie", "dbPassword", "key", "authorization", "X-Auth", "apikey",
                           "clientsecret", "session_key", "credentials"]
        let ordinary = ["max_tokens", "input_tokens", "outputTokens", "tokens", "prompt_tokens", "total_tokens", "keys", "tokenizer",
                        "keyword", "monkey", "author", "model", "prompt", "temperature", "sessionId"]
        for name in credentials { XCTAssertTrue(TraceRedactor.isCredentialKey(name), name) }
        for name in ordinary { XCTAssertFalse(TraceRedactor.isCredentialKey(name), name) }
        let scrubbed = TraceRedactor().scrub(["request": ["headers": ["x-api-key": "opaque-value-1", "accept": "json"],
                                                          "body": ["client_secret": "opaque-value-2", "max_tokens": 64]]], maxChars: 200)
        XCTAssertEqual(scrubbed["request"]["headers"]["x-api-key"].stringValue, "***")
        XCTAssertEqual(scrubbed["request"]["headers"]["accept"].stringValue, "json")
        XCTAssertEqual(scrubbed["request"]["body"]["client_secret"].stringValue, "***")
        XCTAssertEqual(scrubbed["request"]["body"]["max_tokens"].numberValue, 64)
        XCTAssertFalse(scrubbed.serialized().contains("opaque-value"))
    }

    func testOverlappingFlushesNeverDropAnUnsentBatch() throws {
        let store = TraceStore(root: root)
        _ = try store.updateSettings { settings in
            settings.export.enabled = true
            settings.export.endpoint = "http://127.0.0.1:4318/"
        }
        let exporter = TraceExporter(store: store, version: "1.1.0-test")
        let now = TraceClock.nowMs()
        for index in 0..<450 {
            exporter.enqueue(TraceRecord(id: TraceIDs.trace(), kind: "model", name: "t\(index)", status: "ok", startMs: now, endMs: now + 1), [])
        }
        XCTAssertEqual(exporter.pendingCount, 450)
        let lock = NSLock()
        var sent: [String] = []
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var first = true
        exporter.send = { _, _, body in
            let spans = ((try? JSON.parse(body)) ?? .null)["resourceSpans"][0]["scopeSpans"][0]["spans"].array.compactMap { $0["spanId"].stringValue }
            lock.lock(); let isFirst = first; first = false; sent += spans; lock.unlock()
            if isFirst { entered.signal(); release.wait() }
            return .init(status: 200, body: Data())
        }
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { exporter.flush(force: true) }
        entered.wait()
        // A second flush (the timer's, say) starts while the first is still sending.
        DispatchQueue.global().async(group: group) { exporter.flush(force: true) }
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(sent.count, 400)
        XCTAssertEqual(Set(sent).count, 400, "the second flush sent the next batch, not the same one again")
        XCTAssertEqual(exporter.pendingCount, 50)
    }

    func testReplayingABigDayHoldsTheMemoryCap() throws {
        do {
            let store = TraceStore(root: root)
            let now = TraceClock.nowMs()
            for index in 0..<(TraceStore.memoryTraceCap + 2_500) {
                store.upsert(TraceRecord(id: TraceIDs.trace(), kind: "model", name: "t\(index)", status: "ok", startMs: now - 100_000 + Int64(index), endMs: now))
            }
        }
        let reloaded = TraceStore(root: root)
        let kept = reloaded.allTraces { _ in true }
        XCTAssertEqual(kept.count, TraceStore.memoryTraceCap, "one day's file larger than the cap is trimmed while it replays")
        XCTAssertNotNil(kept.first { $0.name == "t\(TraceStore.memoryTraceCap + 2_499)" }, "the newest traces are the ones kept")
        XCTAssertNil(kept.first { $0.name == "t0" })
    }

    func testTracingOffRecordsNothing() throws {
        let store = TraceStore(root: root)
        _ = try store.updateSettings { $0.enabled = false }
        let tracer = Tracer(store: store)
        XCTAssertNil(tracer.startTrace(kind: "chat", name: "x"))
        XCTAssertNil(tracer.attach(traceparent: "00-\(TraceIDs.trace())-\(TraceIDs.observation())-01"))
    }

    func testTraceparentRoundTripAndAttach() throws {
        XCTAssertNil(TraceIDs.parseTraceparent("garbage"))
        XCTAssertNil(TraceIDs.parseTraceparent("01-\(TraceIDs.trace())-\(TraceIDs.observation())-01"))
        let tracer = Tracer(store: TraceStore(root: root))
        let trace = try XCTUnwrap(tracer.startTrace(kind: "chat", name: "x"))
        let generation = trace.observation(.generation, "g")
        let attached = try XCTUnwrap(tracer.attach(traceparent: generation.traceparent))
        XCTAssertEqual(attached.0.traceId, trace.traceId)
        XCTAssertEqual(attached.1.id, generation.id)
        XCTAssertNil(tracer.attach(traceparent: TraceIDs.traceparent(TraceIDs.trace(), generation.id)), "an unknown trace is not joined")
    }

    func testPricingTableEstimatesMeteredCalls() throws {
        let store = TraceStore(root: root)
        _ = try store.updateSettings { $0.pricing["gpt-x"] = TracePrice(inputPerMTok: 2, outputPerMTok: 8, cachedInputPerMTok: 0.5) }
        let tracer = Tracer(store: store)
        let cost = tracer.price(model: "gpt-x", usage: TraceUsage(inputTokens: 1_000_000, outputTokens: 500_000, cachedInputTokens: 200_000), billingType: "metered_api")
        XCTAssertEqual(cost.status, "estimated")
        XCTAssertEqual(cost.totalUsd, 0.8 * 2 + 0.2 * 0.5 + 0.5 * 8, accuracy: 1e-9)
        XCTAssertEqual(tracer.price(model: "other", usage: TraceUsage(inputTokens: 5), billingType: "metered_api").status, "unpriced")
        XCTAssertEqual(tracer.price(model: nil, usage: TraceUsage(), billingType: "local"), .local)
    }

    func testMetricsGroupByModelWithPercentiles() throws {
        let tracer = Tracer(store: TraceStore(root: root))
        for latency in [10, 20, 30, 40, 1_000] {
            let trace = try XCTUnwrap(tracer.startTrace(kind: "model", name: "chat m"))
            let generation = trace.observation(.generation, "m", model: "m")
            generation.update { $0.startMs -= Int64(latency); $0.outputTokensPerSecond = 50 }
            generation.end(usage: TraceUsage(inputTokens: 1, outputTokens: 2), cost: .local)
            trace.end(status: latency == 1_000 ? "error" : "ok")
        }
        let metrics = TraceMetrics.compute(store: tracer.store, groupBy: "model") { _ in true }
        let group = metrics["groups"][0]
        XCTAssertEqual(group["key"].stringValue, "m")
        XCTAssertEqual(group["count"].numberValue, 5)
        XCTAssertEqual(group["usage"]["output"].numberValue, 10)
        XCTAssertGreaterThanOrEqual(group["latencyP95Ms"].numberValue ?? 0, 1_000)
        XCTAssertEqual(group["outputTokensPerSecond"].numberValue, 50)
        XCTAssertEqual(metrics["totals"]["errors"].numberValue, 1)
    }

    func testOTLPSpansAndExportRetry() throws {
        let store = TraceStore(root: root)
        _ = try store.updateSettings { settings in
            settings.export.enabled = true
            settings.export.endpoint = "http://127.0.0.1:4318/"
            settings.export.headers["x-key"] = "abc"
        }
        XCTAssertEqual(TraceExporter.endpointURL("http://127.0.0.1:4318/"), "http://127.0.0.1:4318/v1/traces")
        XCTAssertEqual(TraceExporter.endpointURL("https://cloud.langfuse.com/api/public/otel"), "https://cloud.langfuse.com/api/public/otel/v1/traces")
        XCTAssertNil(TraceExporter.endpointURL("http://192.168.1.4:4318"), "plain http leaves this Mac only over https")

        let tracer = Tracer(store: store)
        let exporter = TraceExporter(store: store, version: "1.1.0-test")
        tracer.onTraceEnded = { exporter.enqueue($0, $1) }
        let trace = try XCTUnwrap(tracer.startTrace(kind: "chat", name: "hello", sessionId: "s1", input: "secret prompt"))
        let generation = trace.observation(.generation, "m", input: "secret prompt", model: "m", provider: "roachinference")
        generation.end(output: "reply", usage: TraceUsage(inputTokens: 7, outputTokens: 3), cost: .local)
        trace.end(status: "ok")
        XCTAssertEqual(exporter.pendingCount, 1)

        var sent: [(String, [String: String], JSON)] = []
        var failNext = true
        exporter.send = { url, headers, body in
            sent.append((url, headers, (try? JSON.parse(body)) ?? .null))
            if failNext { failNext = false; return .init(status: 503, body: Data("busy".utf8)) }
            return .init(status: 200, body: Data())
        }
        XCTAssertFalse(exporter.flush(force: true))
        XCTAssertEqual(exporter.pendingCount, 1, "a refused batch stays queued")
        XCTAssertTrue(Files.exists(Path.join(root, "export-queue.json")))
        XCTAssertTrue(exporter.flush(force: true))
        XCTAssertEqual(exporter.pendingCount, 0)

        let (url, headers, payload) = sent[1]
        XCTAssertEqual(url, "http://127.0.0.1:4318/v1/traces")
        XCTAssertEqual(headers["x-key"], "abc")
        let span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
        XCTAssertEqual(span["traceId"].stringValue, trace.traceId)
        XCTAssertEqual(span["spanId"].stringValue, generation.id)
        XCTAssertEqual(span["kind"].numberValue, 3)
        let attributes = Dictionary(uniqueKeysWithValues: span["attributes"].array.map { ($0["key"].stringValue ?? "", $0["value"]) })
        XCTAssertEqual(attributes["langfuse.observation.type"]?["stringValue"].stringValue, "generation")
        XCTAssertEqual(attributes["langfuse.session.id"]?["stringValue"].stringValue, "s1")
        XCTAssertEqual(attributes["gen_ai.usage.output_tokens"]?["intValue"].stringValue, "3")
        XCTAssertNil(attributes["langfuse.observation.input"], "content is not exported unless included")
        XCTAssertNil(attributes["langfuse.trace.input"])
        XCTAssertFalse(payload.serialized().contains("secret prompt"))
    }
}
