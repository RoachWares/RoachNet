import Foundation

extension OrgService {
    func resolveActor(_ request: HTTPRequest) throws -> OrgActor {
        if let key = request.header("x-roachnet-org-key")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            if key.hasPrefix("rnrun_") { return try resolveRunToken(key) }
            if key.hasPrefix("rnorg_") { return try resolveAPIKey(key) }
            throw requestError("Unrecognized Org key.", 401)
        }
        switch request.header("x-roachtail-auth-kind")?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "":
            return OrgActor(
                kind: .owner, userId: OrgService.ownerUserId, agentId: nil, companyId: nil, runId: nil, source: "local")
        case "primary":
            return OrgActor(
                kind: .owner, userId: OrgService.ownerUserId, agentId: nil, companyId: nil, runId: nil,
                source: "roachtail_primary")
        case "peer":
            let peerId = request.header("x-roachtail-peer-id") ?? ""
            let user = store.instance.users.first { !peerId.isEmpty && $0.roachTailPeerIds.contains(peerId) }
            return OrgActor(
                kind: .user, userId: user?.id, agentId: nil, companyId: nil, runId: nil,
                source: user == nil ? "roachtail_peer_unlinked" : "roachtail_peer")
        default:
            throw orgForbidden("Pair this device with RoachTail before using RoachClaw Org.")
        }
    }

    private func resolveRunToken(_ token: String) throws -> OrgActor {
        let body = token.dropFirst("rnrun_".count)
        let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw requestError("Malformed run token.", 401) }
        let expected = HMACSHA256.hex(key: store.instance.runTokenSecret, message: parts[0])
        guard orgConstantTimeEquals(expected, parts[1]) else { throw requestError("Invalid run token.", 401) }
        for state in store.allCompanies() {
            if let run = state.runs.first(where: { $0.id == parts[0] }) {
                guard run.status == "running" else {
                    throw requestError("This run has finished; its token is no longer valid.", 401)
                }
                return OrgActor(
                    kind: .agent, userId: nil, agentId: run.agentId, companyId: state.company.id, runId: run.id,
                    source: "run_token")
            }
        }
        throw requestError("Unknown run.", 401)
    }

    private func resolveAPIKey(_ key: String) throws -> OrgActor {
        let hash = SHA256Digest.hex(key)
        for state in store.allCompanies() {
            guard let found = state.apiKeys.first(where: { orgConstantTimeEquals($0.keyHash, hash) }) else { continue }
            guard found.revokedAt == nil else { throw requestError("This key was revoked.", 401) }
            let last = found.lastUsedAt.flatMap(JS.parseDate) ?? 0
            if JS.nowMs() - last > 300_000 {
                try? store.mutateCompany(state.company.id) { company in
                    if let index = company.apiKeys.firstIndex(where: { $0.id == found.id }) {
                        company.apiKeys[index].lastUsedAt = JS.isoNow()
                    }
                }
            }
            if found.principalType == "agent" {
                guard state.agents.contains(where: { $0.id == found.principalId && $0.status != "terminated" }) else {
                    throw requestError("This agent is terminated.", 401)
                }
                return OrgActor(
                    kind: .agent, userId: nil, agentId: found.principalId, companyId: found.companyId, runId: nil,
                    source: "api_key")
            }
            let isOwner = found.principalId == OrgService.ownerUserId
            return OrgActor(
                kind: isOwner ? .owner : .user, userId: found.principalId, agentId: nil, companyId: found.companyId,
                runId: nil, source: "api_key")
        }
        throw requestError("Unknown Org key.", 401)
    }
}

extension NativeRuntime {
    func routeOrg(_ request: inout HTTPRequest, url: WebURL) throws -> HTTPResponse {
        let org = orgService
        let method = request.method
        let query = orgQuery(url.query)
        let segments = url.pathname.split(separator: "/").dropFirst(2).map {
            String($0).removingPercentEncoding ?? String($0)
        }
        func ok(_ value: JSON, _ status: Int = 200) -> HTTPResponse { .json(status, value) }
        func body() throws -> OrgBody { OrgBody(try readRequestJSON(&request)) }

        if method == "POST" && segments.count == 2 && segments[0] == "routine-triggers" {
            let raw = (try? request.body()) ?? Data()
            return ok(try org.handleRoutineWebhook(segments[1], headers: request.headers, rawBody: raw))
        }
        let actor = try org.resolveActor(request)
        if method == "POST" && segments == ["invites", "accept"] {
            let peer = actor.source.hasPrefix("roachtail_peer") ? request.header("x-roachtail-peer-id") : nil
            return ok(try org.acceptInvite(actor, try body(), peerId: peer), 201)
        }
        if method == "POST" && segments.count == 3 && segments[0] == "join-requests" && segments[2] == "claim" {
            return ok(try org.claimJoinRequest(actor, segments[1], try body()))
        }
        if actor.kind == .user && actor.userId == nil {
            throw orgForbidden("This RoachTail device is not linked to a person yet. Ask the owner for an invite.")
        }

        if method == "GET" && (segments.isEmpty || segments == ["health"]) {
            return ok(org.health())
        }
        if segments == ["me"] && method == "GET" { return ok(org.me(actor)) }
        if segments.first == "adapters" {
            guard actor.isOwner else {
                throw orgForbidden("Only the RoachNet owner can see the agents installed on this Mac.")
            }
            if segments.count == 1 && method == "GET" {
                return ok(["adapters": .array(OrgCLIDetector.detectAll(refresh: query["refresh"] == "1").map(\.json))])
            }
            if segments.count == 3 && segments[2] == "test" && method == "POST" {
                guard let kind = OrgCLIKind.from(segments[1]) else { throw orgNotFound("Adapter") }
                return ok(OrgCLIProbe.test(kind, try body()))
            }
            throw orgNotFound("Org route")
        }
        if segments == ["users"] {
            if method == "GET" { return ok(try org.listUsers(actor)) }
            if method == "POST" { return ok(try org.createUser(actor, try body()), 201) }
        }
        if segments.count == 2 && segments[0] == "users" && method == "PATCH" {
            return ok(try org.updateUser(actor, segments[1], try body()))
        }
        if segments == ["engine", "tick"] && method == "POST" {
            guard actor.isOwner else { throw orgForbidden() }
            return ok(org.engine.tick())
        }
        if segments == ["companies", "import"] && method == "POST" {
            return ok(try org.importCompany(actor, try body()), 201)
        }
        if segments == ["companies"] {
            if method == "GET" { return ok(org.listCompanies(actor)) }
            if method == "POST" { return ok(try org.createCompany(actor, try body()), 201) }
        }
        guard segments.count >= 2 && segments[0] == "companies" else { throw orgNotFound("Org route") }
        let cid = segments[1]
        let rest = Array(segments.dropFirst(2))

        switch (method, rest.count) {
        case ("GET", 0): return ok(try org.getCompany(actor, cid))
        case ("PATCH", 0): return ok(try org.updateCompany(actor, cid, try body()))
        default: break
        }
        let head = rest.first ?? ""
        let id = rest.count > 1 ? rest[1] : ""
        let tail = rest.count > 2 ? rest[2] : ""

        switch (method, head, rest.count) {
        case ("POST", "pause", 1), ("POST", "resume", 1), ("POST", "archive", 1):
            return ok(try org.setCompanyStatus(actor, cid, head))
        case ("GET", "dashboard", 1): return ok(try org.dashboard(actor, cid))
        case ("GET", "export", 1): return ok(try org.exportCompany(actor, cid))
        case ("GET", "activity", 1): return ok(try org.listActivity(actor, cid, query))
        case ("GET", "inbox", 1): return ok(try org.inbox(actor, cid))
        case ("GET", "org-chart", 1): return ok(try org.orgChart(actor, cid))

        case ("GET", "members", 1): return ok(try org.listMembers(actor, cid))
        case ("POST", "members", 1): return ok(try org.addMember(actor, cid, try body()), 201)
        case ("PATCH", "members", 2): return ok(try org.updateMember(actor, cid, id, try body()))
        case ("GET", "invites", 1): return ok(try org.listInvites(actor, cid))
        case ("POST", "invites", 1): return ok(try org.createInvite(actor, cid, try body()), 201)
        case ("POST", "invites", 3) where tail == "revoke": return ok(try org.revokeInvite(actor, cid, id))
        case ("GET", "join-requests", 1): return ok(try org.listJoinRequests(actor, cid))
        case ("POST", "join-requests", 3) where tail == "approve" || tail == "reject":
            return ok(try org.decideJoinRequest(actor, cid, id, approve: tail == "approve"))
        case ("GET", "keys", 1): return ok(try org.listKeys(actor, cid))
        case ("POST", "keys", 1): return ok(try org.createKey(actor, cid, try body()), 201)
        case ("POST", "keys", 3) where tail == "revoke": return ok(try org.revokeKey(actor, cid, id))

        case ("GET", "agents", 1): return ok(try org.listAgents(actor, cid))
        case ("POST", "agents", 1): return ok(try org.createAgent(actor, cid, try body()), 201)
        case ("GET", "agents", 2): return ok(try org.getAgent(actor, cid, id))
        case ("PATCH", "agents", 2): return ok(try org.updateAgent(actor, cid, id, try body()))
        case ("POST", "agents", 3) where ["pause", "resume", "terminate"].contains(tail):
            return ok(try org.setAgentStatus(actor, cid, id, tail))
        case ("POST", "agents", 3) where tail == "wake": return ok(try org.wakeAgent(actor, cid, id, try body()), 202)
        case ("GET", "agents", 3) where tail == "revisions": return ok(try org.listRevisions(actor, cid, id))
        case ("POST", "agents", 5) where tail == "revisions" && rest[4] == "rollback":
            return ok(try org.rollbackRevision(actor, cid, id, rest[3]))

        case ("GET", "goals", 1): return ok(try org.listGoals(actor, cid))
        case ("POST", "goals", 1): return ok(try org.saveGoal(actor, cid, nil, try body()), 201)
        case ("PATCH", "goals", 2): return ok(try org.saveGoal(actor, cid, id, try body()))
        case ("GET", "projects", 1): return ok(try org.listProjects(actor, cid))
        case ("POST", "projects", 1): return ok(try org.saveProject(actor, cid, nil, try body()), 201)
        case ("PATCH", "projects", 2): return ok(try org.saveProject(actor, cid, id, try body()))
        case ("GET", "labels", 1): return ok(try org.listLabels(actor, cid))
        case ("POST", "labels", 1): return ok(try org.createLabel(actor, cid, try body()), 201)
        case ("DELETE", "labels", 2): return ok(try org.deleteLabel(actor, cid, id))

        case ("GET", "issues", 1): return ok(try org.listIssues(actor, cid, query))
        case ("POST", "issues", 1): return ok(try org.createIssue(actor, cid, try body()), 201)
        case ("GET", "issues", 2): return ok(try org.getIssue(actor, cid, id))
        case ("PATCH", "issues", 2): return ok(try org.updateIssue(actor, cid, id, try body()))
        case ("GET", "issues", 3) where tail == "comments": return ok(try org.listComments(actor, cid, id))
        case ("POST", "issues", 3) where tail == "comments":
            return ok(try org.addComment(actor, cid, id, try body()), 201)
        case ("POST", "issues", 3) where tail == "checkout":
            return ok(try org.checkoutIssue(actor, cid, id, try body()))
        case ("POST", "issues", 3) where tail == "release": return ok(try org.releaseIssue(actor, cid, id))
        case ("POST", "issues", 3) where tail == "review": return ok(try org.reviewIssue(actor, cid, id, try body()))
        case ("POST", "issues", 3) where tail == "work-products":
            return ok(try org.addWorkProduct(actor, cid, id, try body()), 201)
        case ("GET", "issues", 3) where tail == "documents": return ok(try org.listDocuments(actor, cid, id))
        case ("GET", "issues", 4) where tail == "documents":
            return ok(try org.getDocument(actor, cid, id, rest[3], revision: query["revision"].flatMap { Int($0) }))
        case ("PUT", "issues", 4) where tail == "documents":
            return ok(try org.putDocument(actor, cid, id, rest[3], try body()))

        case ("GET", "approvals", 1): return ok(try org.listApprovals(actor, cid, query))
        case ("POST", "approvals", 1): return ok(try org.requestApproval(actor, cid, try body()), 201)
        case ("POST", "approvals", 3) where tail == "comments":
            return ok(try org.commentOnApproval(actor, cid, id, try body()))
        case ("POST", "approvals", 3) where ["approve", "reject", "request-revision", "cancel"].contains(tail):
            return ok(try org.decideApproval(actor, cid, id, tail, try body()))

        case ("GET", "budgets", 1): return ok(try org.listBudgets(actor, cid))
        case ("POST", "budgets", 1): return ok(try org.saveBudget(actor, cid, nil, try body()), 201)
        case ("PATCH", "budgets", 2): return ok(try org.saveBudget(actor, cid, id, try body()))
        case ("POST", "budget-incidents", 3) where tail == "resolve":
            return ok(try org.resolveIncident(actor, cid, id, try body()))
        case ("GET", "costs", 1): return ok(try org.costSummary(actor, cid, query))

        case ("GET", "traces", 1):
            try org.requireRead(try org.company(cid), actor)
            return ok(listTraces(url, companyId: cid))
        case ("GET", "traces", 2) where id == "metrics":
            try org.requireRead(try org.company(cid), actor)
            return ok(traceMetrics(url, companyId: cid))
        case ("GET", "traces", 2):
            try org.requireRead(try org.company(cid), actor)
            return ok(try traceDetail(id, companyId: cid))
        case ("POST", "traces", 3) where tail == "scores":
            try org.requireWrite(try org.company(cid), actor)
            return ok(
                try addTraceScore(id, try body().raw, authorId: actor.userId ?? actor.agentId, companyId: cid), 201)
        case ("POST", "cost-events", 1): return ok(try org.reportCost(actor, cid, try body()), 201)

        case ("GET", "routines", 1): return ok(try org.listRoutines(actor, cid))
        case ("POST", "routines", 1): return ok(try org.saveRoutine(actor, cid, nil, try body()), 201)
        case ("PATCH", "routines", 2): return ok(try org.saveRoutine(actor, cid, id, try body()))
        case ("POST", "routines", 3) where tail == "run":
            return ok(try org.runRoutineNow(actor, cid, id, try body()), 202)
        case ("GET", "routines", 3) where tail == "runs": return ok(try org.listRoutineRuns(actor, cid, id))

        case ("GET", "skills", 1): return ok(try org.listSkills(actor, cid))
        case ("POST", "skills", 1): return ok(try org.saveSkill(actor, cid, nil, try body()), 201)
        case ("PUT", "skills", 2): return ok(try org.saveSkill(actor, cid, id, try body()))
        case ("DELETE", "skills", 2): return ok(try org.deleteSkill(actor, cid, id))
        case ("GET", "secrets", 1): return ok(try org.listSecrets(actor, cid))
        case ("PUT", "secrets", 2): return ok(try org.putSecret(actor, cid, id, try body()))
        case ("DELETE", "secrets", 2): return ok(try org.deleteSecret(actor, cid, id))

        case ("GET", "runs", 1): return ok(try org.listRuns(actor, cid, query))
        case ("GET", "runs", 2): return ok(try org.getRun(actor, cid, id, includeLog: false))
        case ("GET", "runs", 3) where tail == "log": return ok(try org.getRun(actor, cid, id, includeLog: true))
        case ("POST", "runs", 3) where tail == "cancel": return ok(try org.cancelRun(actor, cid, id), 202)
        case ("GET", "wake-requests", 1): return ok(try org.listWakes(actor, cid))
        default:
            throw orgNotFound("Org route")
        }
    }
}
