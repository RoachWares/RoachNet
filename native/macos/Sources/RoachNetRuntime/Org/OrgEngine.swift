import Foundation

/// Everything an adapter needs to execute one run.
struct OrgRunContext {
    var company: OrgCompany
    var agent: OrgAgent
    var run: OrgRun
    var issue: OrgIssue?
    var project: OrgProject?
    var comments: [OrgComment]
    var children: [OrgIssue]
    var assignedIssues: [OrgIssue]
    var skills: [OrgSkill]
    var agents: [OrgAgent]
    var wakeReasons: [String]
    var payload: JSON
    var runToken: String
    var apiBaseURL: String
    var deadline: Date
}

struct OrgRunResult {
    var status: String = "succeeded"          // succeeded | failed | cancelled | timed_out
    var summary: String?
    var error: String?
    var errorCode: String?
    var exitCode: Int?
    var usage: OrgUsage?
    var costCents: Int = 0
    var costStatus: String = "reported"
    var billingType: String = "local"
    var sessionState: JSON?

    static func failure(_ message: String, code: String) -> OrgRunResult {
        var result = OrgRunResult()
        result.status = "failed"; result.error = message; result.errorCode = code
        return result
    }
}

/// The wake queue, scheduler and run executor for RoachClaw Org.
final class OrgEngine {
    unowned let service: OrgService
    private let queue = DispatchQueue(label: "org.roachnet.engine")
    private var timer: DispatchSourceTimer?
    private let cancelLock = NSLock()
    private var cancelled = Set<String>()
    private var lastTick = Date.distantPast

    init(service: OrgService) {
        self.service = service
        recoverInterruptedRuns()
    }

    private var store: OrgStore { service.store }
    private var now: String { JS.isoNow() }

    // MARK: Lifecycle

    /// Starts the scheduler. `ROACHNET_ORG_SCHEDULER=0` disables the timer (tests drive `tick`).
    func start() {
        let env = ProcessInfo.processInfo.environment
        guard env["ROACHNET_ORG_SCHEDULER"] != "0", timer == nil else { return }
        let interval = max(Int(env["ROACHNET_ORG_TICK_MS"] ?? "") ?? 30_000, 1_000)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        source.setEventHandler { [weak self] in _ = self?.tickOnQueue(Date()) }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs left `running` by a previous process can never report back; close them out.
    private func recoverInterruptedRuns() {
        for state in store.allCompanies() where state.runs.contains(where: { $0.status == "running" || $0.status == "queued" }) || state.wakeRequests.contains(where: { $0.status == "claimed" }) {
            try? store.mutateCompany(state.company.id) { company in
                let stamp = now
                for index in company.runs.indices where company.runs[index].status == "running" || company.runs[index].status == "queued" {
                    company.runs[index].status = "failed"
                    company.runs[index].error = "RoachNet stopped while this run was active."
                    company.runs[index].errorCode = "process_lost"
                    company.runs[index].finishedAt = stamp
                }
                for index in company.wakeRequests.indices where company.wakeRequests[index].status == "claimed" {
                    company.wakeRequests[index].status = "failed"; company.wakeRequests[index].finishedAt = stamp
                }
                for index in company.agents.indices where company.agents[index].status == "running" { company.agents[index].status = "idle" }
                for index in company.issues.indices { company.issues[index].executionRunId = nil; company.issues[index].checkoutRunId = nil }
            }
        }
    }

    // MARK: Cancellation

    func cancel(_ runId: String) {
        cancelLock.lock(); cancelled.insert(runId); cancelLock.unlock()
    }

    func isCancelled(_ runId: String) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled.contains(runId)
    }

    // MARK: Wakes

    private func skip(_ wake: inout OrgWakeRequest, _ reason: String) {
        var payload = wake.payload.object
        payload["skipReason"] = JSON(reason)
        wake.payload = .object(payload)
        wake.status = "skipped"
        wake.finishedAt = now
    }

    /// Records a wake request after the admission gates, coalescing with an
    /// already-queued wake for the same agent and issue.
    @discardableResult
    func enqueue(_ intent: OrgWakeIntent) -> OrgWakeRequest? {
        let wake: OrgWakeRequest? = try? store.mutateCompany(intent.companyId) { company in
            var wake = OrgWakeRequest(id: OrgIDs.make("wake"), companyId: intent.companyId, agentId: intent.agentId, source: intent.source, reason: intent.reason,
                                      status: "queued", issueId: intent.issueId, payload: intent.payload, requestedByType: intent.requestedByType,
                                      requestedById: intent.requestedById, createdAt: now)
            guard let agent = company.agents.first(where: { $0.id == intent.agentId }) else {
                skip(&wake, "agent_missing"); company.wakeRequests.append(wake); return wake
            }
            if company.company.status != "active" { skip(&wake, "company_\(company.company.status)") }
            else if agent.status == "terminated" { skip(&wake, "agent_terminated") }
            else if agent.status == "pending_approval" { skip(&wake, "agent_pending_approval") }
            else if agent.status == "paused" { skip(&wake, agent.pauseReason == "budget" ? "agent_budget_paused" : "agent_paused") }
            else if intent.source != "timer" && !agent.heartbeat.wakeOnDemand { skip(&wake, "wake_on_demand_disabled") }
            if wake.status == "queued", let existingIndex = company.wakeRequests.lastIndex(where: {
                ($0.status == "queued" || $0.status == "deferred_issue_execution") && $0.agentId == intent.agentId && $0.issueId == intent.issueId
            }) {
                company.wakeRequests[existingIndex].coalescedCount += 1
                var payload = company.wakeRequests[existingIndex].payload.object
                var reasons = payload["coalescedReasons"].array
                reasons.append(JSON(intent.reason))
                payload["coalescedReasons"] = .array(Array(reasons.suffix(20)))
                company.wakeRequests[existingIndex].payload = .object(payload)
                wake.status = "coalesced"
                wake.finishedAt = now
                wake.runId = company.wakeRequests[existingIndex].id
            } else if wake.status == "queued", let issueId = intent.issueId,
                      company.runs.contains(where: { $0.status == "running" && $0.agentId == intent.agentId && $0.issueId == issueId }) {
                wake.status = "deferred_issue_execution"
            }
            company.wakeRequests.append(wake)
            return wake
        }
        if wake?.status == "queued" { kick(intent.companyId) }
        return wake
    }

    func kick(_ companyId: String) {
        queue.async { [weak self] in self?.dispatchCompany(companyId) }
    }

    // MARK: Dispatch

    private func startOfUTCDay() -> String { String(JS.isoNow().prefix(10)) + "T00:00:00.000Z" }

    private func dispatchCompany(_ companyId: String) {
        guard let snapshot = store.company(companyId), snapshot.company.status == "active",
              snapshot.wakeRequests.contains(where: { $0.status == "queued" }) else { return }
        let started: [String] = (try? store.mutateCompany(companyId) { company in
            var started: [String] = []
            let dayStart = startOfUTCDay()
            for wakeIndex in company.wakeRequests.indices where company.wakeRequests[wakeIndex].status == "queued" {
                let wake = company.wakeRequests[wakeIndex]
                guard let agentIndex = company.agents.firstIndex(where: { $0.id == wake.agentId }) else {
                    skip(&company.wakeRequests[wakeIndex], "agent_missing"); continue
                }
                let agent = company.agents[agentIndex]
                if ["terminated", "paused", "pending_approval"].contains(agent.status) {
                    skip(&company.wakeRequests[wakeIndex], "agent_\(agent.status)"); continue
                }
                let running = company.runs.filter { $0.agentId == agent.id && $0.status == "running" }
                if running.count >= agent.heartbeat.maxConcurrentRuns { continue }
                if let cap = agent.heartbeat.maxDailyRuns, company.runs.filter({ $0.agentId == agent.id && ($0.startedAt ?? "") >= dayStart }).count >= cap {
                    skip(&company.wakeRequests[wakeIndex], "daily_run_cap"); continue
                }
                if let cap = agent.heartbeat.maxDailyCostCents,
                   company.costEvents.filter({ $0.agentId == agent.id && $0.occurredAt >= dayStart }).reduce(0, { $0.orgAdding($1.costCents) }) >= cap {
                    skip(&company.wakeRequests[wakeIndex], "daily_cost_cap"); continue
                }
                var issue: OrgIssue?
                if let issueId = wake.issueId {
                    issue = company.issues.first { $0.id == issueId }
                    guard let found = issue else { skip(&company.wakeRequests[wakeIndex], "issue_missing"); continue }
                    if found.status == "cancelled" { skip(&company.wakeRequests[wakeIndex], "issue_cancelled"); continue }
                    if let projectId = found.projectId, company.projects.first(where: { $0.id == projectId })?.pauseReason == "budget" {
                        skip(&company.wakeRequests[wakeIndex], "project_budget_paused"); continue
                    }
                    if let lock = found.executionRunId, company.runs.contains(where: { $0.id == lock && $0.status == "running" }) {
                        company.wakeRequests[wakeIndex].status = "deferred_issue_execution"; continue
                    }
                }
                let stamp = now
                var reasons = [wake.reason]
                reasons += wake.payload["coalescedReasons"].array.compactMap { $0.stringValue }
                let run = OrgRun(id: OrgIDs.make("run"), companyId: companyId, agentId: agent.id, issueId: wake.issueId, taskKey: wake.issueId ?? "heartbeat",
                                 invocationSource: wake.source, wakeReason: wake.reason, status: "running",
                                 contextSnapshot: ["wakeId": JSON(wake.id), "reasons": JSON(reasons), "payload": wake.payload,
                                                   "issueIdentifier": JSON(issue?.identifier), "issueStatus": JSON(issue?.status)],
                                 adapterType: agent.adapterType, startedAt: stamp, sessionIdBefore: agent.sessionState?["sessionId"].stringValue,
                                 coalescedCount: wake.coalescedCount, createdAt: stamp)
                company.runs.append(run)
                company.wakeRequests[wakeIndex].status = "claimed"
                company.wakeRequests[wakeIndex].runId = run.id
                company.agents[agentIndex].status = "running"
                if let issueId = wake.issueId, let issueIndex = company.issues.firstIndex(where: { $0.id == issueId }) {
                    company.issues[issueIndex].executionRunId = run.id
                    company.issues[issueIndex].executionLockedAt = stamp
                }
                started.append(run.id)
            }
            return started
        }) ?? []
        for runId in started {
            let actor = OrgActor(kind: .system, userId: nil, agentId: nil, companyId: companyId, runId: runId, source: "engine")
            service.record(companyId, actor, "run.started", "run", runId)
            // A run waits on an agent for minutes, so it gets a thread of its own.
            BlockingWork.start("roachnet.org.run") { [weak self] in self?.execute(companyId: companyId, runId: runId) }
        }
    }

    // MARK: Execution

    func runToken(_ runId: String) -> String {
        "rnrun_\(runId).\(HMACSHA256.hex(key: store.instance.runTokenSecret, message: runId))"
    }

    private func makeContext(_ state: OrgCompanyState, _ run: OrgRun) -> OrgRunContext? {
        guard let agent = state.agents.first(where: { $0.id == run.agentId }) else { return nil }
        let issue = run.issueId.flatMap { id in state.issues.first { $0.id == id } }
        let timeout = min(max(OrgBody(agent.adapterConfig).int("timeoutSec") ?? 900, 10), 6 * 3_600)
        let port = service.runtime.listenPort
        return OrgRunContext(
            company: state.company, agent: agent, run: run, issue: issue,
            project: issue?.projectId.flatMap { id in state.projects.first { $0.id == id } },
            comments: issue.map { current in Array(state.comments.filter { $0.issueId == current.id && $0.deletedAt == nil }.suffix(20)) } ?? [],
            children: issue.map { current in state.issues.filter { $0.parentId == current.id } } ?? [],
            assignedIssues: state.issues.filter { $0.assigneeAgentId == agent.id && !$0.isTerminal && $0.status != "backlog" },
            skills: state.skills.filter { agent.desiredSkills.contains($0.key) },
            agents: state.agents.filter { $0.status != "terminated" },
            wakeReasons: run.contextSnapshot["reasons"].array.compactMap { $0.stringValue },
            payload: run.contextSnapshot["payload"], runToken: runToken(run.id),
            apiBaseURL: port > 0 ? "http://127.0.0.1:\(port)" : "",
            deadline: Date().addingTimeInterval(Double(timeout)))
    }

    private func execute(companyId: String, runId: String) {
        guard let state = store.company(companyId), let run = state.runs.first(where: { $0.id == runId }), let context = makeContext(state, run) else {
            finalize(companyId: companyId, runId: runId, result: .failure("Run context unavailable.", code: "context_missing"))
            return
        }
        let io = OrgRunIO(service: service, engine: self, context: context)
        let tracer = service.runtime.tracer
        tracer.redactor.register(context.runToken)
        let trace = startTrace(tracer, context)
        io.trace = trace?.observation(.agent, context.agent.name, input: ["wakeReasons": JSON(context.wakeReasons), "issue": JSON(context.issue?.identifier)],
                                      metadata: JSONObject([("adapterType", JSON(context.agent.adapterType)), ("role", JSON(context.agent.role))]),
                                      model: OrgBody(context.agent.adapterConfig).string("model"))
        var result: OrgRunResult
        if isCancelled(runId) {
            result = OrgRunResult(); result.status = "cancelled"
        } else {
            let adapter = OrgAdapters.make(context.agent.adapterType)
            result = adapter.run(context, io)
        }
        if isCancelled(runId) && result.status == "succeeded" { result.status = "cancelled" }
        endTrace(trace, io.trace, result)
        finalize(companyId: companyId, runId: runId, result: result)
    }

    // MARK: RoachTrace

    private func startTrace(_ tracer: Tracer, _ context: OrgRunContext) -> TraceHandle? {
        let subject = context.issue.map { "\($0.identifier) \($0.title)" } ?? (context.wakeReasons.first ?? "run")
        var input: JSONObject = JSONObject([("wakeReasons", JSON(context.wakeReasons))])
        if let issue = context.issue {
            input["issue"] = ["identifier": JSON(issue.identifier), "title": JSON(issue.title), "status": JSON(issue.status)]
        }
        if let payload = context.payload.objectValue, !payload.isEmpty { input["payload"] = .object(payload) }
        return tracer.startTrace(kind: "org_run", name: "\(context.agent.name): \(subject)", companyId: context.company.id, agentId: context.agent.id,
                                 issueId: context.issue?.id, runId: context.run.id, sessionId: context.issue?.id ?? "agent:\(context.agent.id)",
                                 tags: [context.agent.adapterType] + context.wakeReasons, input: .object(input),
                                 metadata: JSONObject([("company", JSON(context.company.name)), ("invocationSource", JSON(context.run.invocationSource))]))
    }

    private func endTrace(_ trace: TraceHandle?, _ root: ObservationHandle?, _ result: OrgRunResult) {
        guard let trace else { return }
        // Adapters that report usage only for the whole run (process, http,
        // CLI agents without a per-turn stream) still get a generation.
        let generations = trace.tracer.store.observations(trace.traceId).filter { $0.type == .generation }
        if generations.isEmpty, let usage = result.usage, !usage.traceUsage.isEmpty || result.costCents > 0 {
            let cost = result.billingType == "local" ? TraceCost.local
                : (result.costCents > 0 ? TraceCost(totalUsd: Double(result.costCents) / 100, status: result.costStatus, billingType: result.billingType)
                    : trace.tracer.price(model: usage.model, usage: usage.traceUsage, billingType: result.billingType))
            let generation = root?.child(.generation, "reported usage", model: usage.model, provider: usage.provider)
            generation?.end(usage: usage.traceUsage, cost: cost, metadata: JSONObject([("source", "adapter result")]))
        }
        let failed = result.status == "failed" || result.status == "timed_out"
        root?.end(output: ["status": JSON(result.status), "summary": JSON(result.summary)], level: failed ? .error : nil,
                  statusMessage: result.error, metadata: JSONObject([("errorCode", JSON(result.errorCode)), ("exitCode", JSON(result.exitCode))]))
        trace.end(status: failed ? "error" : (result.status == "cancelled" ? "cancelled" : "ok"), output: JSON(result.summary), message: result.error)
    }

    private func finalize(companyId: String, runId: String, result: OrgRunResult) {
        var agentId: String?
        try? store.mutateCompany(companyId) { company in
            guard let runIndex = company.runs.firstIndex(where: { $0.id == runId }) else { return }
            let stamp = now
            var run = company.runs[runIndex]
            run.status = result.status
            run.finishedAt = stamp
            run.summary = result.summary.map { String($0.prefix(8_000)) }
            run.error = result.error.map { String($0.prefix(4_000)) }
            run.errorCode = result.errorCode
            run.exitCode = result.exitCode
            run.usage = result.usage
            run.costCents = result.costCents
            run.sessionIdAfter = result.sessionState?["sessionId"].stringValue ?? run.sessionIdBefore
            company.runs[runIndex] = run
            agentId = run.agentId
            if let usage = result.usage, usage.inputTokens.orgAdding(usage.outputTokens) > 0 || result.costCents > 0 {
                let issue = run.issueId.flatMap { id in company.issues.first { $0.id == id } }
                service.applyCostEvent(&company, OrgCostEvent(
                    id: OrgIDs.make("cost"), companyId: companyId, agentId: run.agentId, issueId: run.issueId, projectId: issue?.projectId, runId: runId,
                    provider: usage.provider ?? run.adapterType, model: usage.model ?? "unknown", inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                    cachedInputTokens: usage.cachedInputTokens, costCents: result.costCents, costStatus: result.costStatus, billingType: result.billingType, occurredAt: stamp))
            }
            if let agentIndex = company.agents.firstIndex(where: { $0.id == run.agentId }) {
                let stillRunning = company.runs.contains { $0.agentId == run.agentId && $0.status == "running" }
                if company.agents[agentIndex].status == "running" && !stillRunning {
                    company.agents[agentIndex].status = result.status == "failed" || result.status == "timed_out" ? "error" : "idle"
                }
                company.agents[agentIndex].errorReason = result.status == "failed" || result.status == "timed_out" ? result.error : nil
                company.agents[agentIndex].lastHeartbeatAt = stamp
                if let session = result.sessionState { company.agents[agentIndex].sessionState = session }
            }
            if let issueId = run.issueId, let issueIndex = company.issues.firstIndex(where: { $0.id == issueId }) {
                if company.issues[issueIndex].executionRunId == runId { company.issues[issueIndex].executionRunId = nil; company.issues[issueIndex].executionLockedAt = nil }
                if company.issues[issueIndex].checkoutRunId == runId { company.issues[issueIndex].checkoutRunId = nil }
            }
            if let wakeIndex = company.wakeRequests.firstIndex(where: { $0.runId == runId && $0.status == "claimed" }) {
                company.wakeRequests[wakeIndex].status = result.status == "succeeded" ? "completed" : (result.status == "cancelled" ? "cancelled" : "failed")
                company.wakeRequests[wakeIndex].finishedAt = stamp
            }
            for index in company.wakeRequests.indices where company.wakeRequests[index].status == "deferred_issue_execution" && company.wakeRequests[index].agentId == run.agentId {
                let lockHeld = company.wakeRequests[index].issueId.flatMap { id in company.issues.first { $0.id == id }?.executionRunId } != nil
                if !lockHeld { company.wakeRequests[index].status = "queued" }
            }
        }
        cancelLock.lock(); cancelled.remove(runId); cancelLock.unlock()
        let actor = OrgActor(kind: .system, userId: nil, agentId: agentId, companyId: companyId, runId: runId, source: "engine")
        service.record(companyId, actor, "run.\(result.status)", "run", runId, ["summary": JSON(result.summary.map { String($0.prefix(500)) }), "error": JSON(result.error)])
        store.removeRunLogs(companyId: companyId, keeping: Set((store.company(companyId)?.runs ?? []).map { $0.id }))
        kick(companyId)
    }

    // MARK: Scheduler

    /// One scheduler pass: budget rollover, heartbeats, due routines and queue drain.
    func tick(_ date: Date = Date()) -> JSON {
        queue.sync { tickOnQueue(date) }
    }

    @discardableResult
    private func tickOnQueue(_ date: Date) -> JSON {
        var heartbeats = 0, routines = 0
        for state in store.allCompanies() {
            let companyId = state.company.id
            if state.budgetIncidents.contains(where: { $0.status == "open" && $0.windowStart < orgMonthStart(date) }) {
                try? store.mutateCompany(companyId) { company in _ = service.rolloverBudgets(&company) }
            }
            guard let current = store.company(companyId), current.company.status == "active" else { continue }
            for agent in current.agents where agent.heartbeat.enabled && (agent.status == "idle" || agent.status == "error") {
                let last = agent.lastHeartbeatAt.flatMap(JS.parseDate) ?? 0
                guard date.timeIntervalSince1970 * 1_000 - last >= Double(agent.heartbeat.intervalSec) * 1_000 else { continue }
                let actionable = current.issues.contains { $0.assigneeAgentId == agent.id && ["todo", "in_progress", "in_review"].contains($0.status) }
                if agent.heartbeat.skipTimerWhenNoActionableWork && !actionable {
                    try? store.mutateCompany(companyId) { company in
                        if let index = company.agents.firstIndex(where: { $0.id == agent.id }) { company.agents[index].lastHeartbeatAt = JS.iso(date) }
                    }
                    continue
                }
                try? store.mutateCompany(companyId) { company in
                    if let index = company.agents.firstIndex(where: { $0.id == agent.id }) { company.agents[index].lastHeartbeatAt = JS.iso(date) }
                }
                if enqueue(OrgWakeIntent(companyId: companyId, agentId: agent.id, source: "timer", reason: "heartbeat", requestedByType: "system", requestedById: nil))?.status == "queued" {
                    heartbeats += 1
                }
            }
            for routine in current.routines where routine.status == "active" {
                for trigger in routine.triggers where trigger.kind == "schedule" && trigger.enabled {
                    guard let nextText = trigger.nextRunAt, let next = JS.parseDate(nextText), next <= date.timeIntervalSince1970 * 1_000,
                          let cron = try? OrgCron(trigger.cronExpression ?? "", timezone: trigger.timezone ?? "UTC") else { continue }
                    var fires = 1
                    if routine.catchUpPolicy == "enqueue_missed_with_cap" {
                        var cursor = Date(timeIntervalSince1970: next / 1_000)
                        while fires < 3, let following = cron.next(after: cursor), following <= date { fires += 1; cursor = following }
                    }
                    for _ in 0..<fires {
                        if (try? service.fireRoutine(companyId, routine.id, triggerId: trigger.id, source: "schedule", payload: .object(JSONObject()), actor: .system)) != nil { routines += 1 }
                    }
                    try? store.mutateCompany(companyId) { company in
                        guard let routineIndex = company.routines.firstIndex(where: { $0.id == routine.id }),
                              let triggerIndex = company.routines[routineIndex].triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
                        company.routines[routineIndex].triggers[triggerIndex].nextRunAt = cron.next(after: date).map(JS.iso)
                    }
                }
            }
            dispatchCompany(companyId)
        }
        lastTick = date
        return ["heartbeatsQueued": JSON(heartbeats), "routinesFired": JSON(routines), "at": JSON(JS.iso(date))]
    }
}
