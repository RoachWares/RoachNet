import Foundation

/// Approvals, budgets and costs, skills, secrets, routines, dashboard,
/// activity and export/import for RoachClaw Org.
extension OrgService {
    // MARK: Approvals

    func listApprovals(_ actor: OrgActor, _ companyId: String, _ query: [String: String]) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        var approvals = state.approvals
        if let status = query["status"], !status.isEmpty { approvals = approvals.filter { $0.status == status } }
        if actor.kind == .agent && !isBoard(state, actor) { approvals = approvals.filter { $0.requestedByAgentId == actor.agentId } }
        return ["approvals": .array(approvals.reversed().map { OrgCodec.json($0) })]
    }

    func requestApproval(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        let type = try body.oneOf("type", ["approve_ceo_strategy", "request_board_approval"]) ?? "request_board_approval"
        var issueIds: [String] = []
        for ref in body.strings("issueIds") ?? [] {
            guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue \(ref)") }
            issueIds.append(issue.id)
        }
        let payload: JSON = body.raw["payload"].isObject ? body.raw["payload"] : ["summary": JSON(body.text("summary", max: 20_000))]
        let approval = OrgApproval(id: OrgIDs.make("apr"), companyId: companyId, type: type, payload: payload,
                                   requestedByAgentId: actor.kind == .agent ? actor.agentId : nil,
                                   requestedByUserId: actor.kind == .agent ? nil : actor.userId, issueIds: issueIds, createdAt: now, updatedAt: now)
        try store.mutateCompany(companyId) { $0.approvals.append(approval) }
        record(companyId, actor, "approval.requested", "approval", approval.id, ["type": JSON(type)])
        return ["approval": OrgCodec.json(approval)]
    }

    func commentOnApproval(_ actor: OrgActor, _ companyId: String, _ approvalId: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let approval = state.approvals.first(where: { $0.id == approvalId }) else { throw orgNotFound("Approval") }
        guard isBoard(state, actor) || approval.requestedByAgentId == actor.agentId || approval.requestedByUserId == actor.userId else { throw orgForbidden() }
        guard let text = body.text("body", max: 20_000), !text.isEmpty else { throw requestError("body is required.") }
        let comment = OrgApprovalComment(id: OrgIDs.make("acm"), authorType: actor.actorType, authorId: actor.actorId, body: text, createdAt: now)
        let updated: OrgApproval = try store.mutateCompany(companyId) { company in
            guard let index = company.approvals.firstIndex(where: { $0.id == approvalId }) else { throw orgNotFound("Approval") }
            company.approvals[index].comments.append(comment)
            if company.approvals[index].status == "revision_requested" && actor.kind == .agent { company.approvals[index].status = "pending" }
            company.approvals[index].updatedAt = now
            return company.approvals[index]
        }
        return ["approval": OrgCodec.json(updated)]
    }

    /// Board decision on an approval, with type-specific effects.
    func decideApproval(_ actor: OrgActor, _ companyId: String, _ approvalId: String, _ decision: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireBoard(state, actor)
        guard let approval = state.approvals.first(where: { $0.id == approvalId }) else { throw orgNotFound("Approval") }
        if decision == "cancel" {
            guard approval.requestedByAgentId == actor.agentId || approval.requestedByUserId == actor.userId || isBoard(state, actor) else { throw orgForbidden() }
        }
        guard approval.status == "pending" || approval.status == "revision_requested" else { throw orgConflict("This approval was already decided.") }
        let statusFor = ["approve": "approved", "reject": "rejected", "request-revision": "revision_requested", "cancel": "cancelled"]
        guard let newStatus = statusFor[decision] else { throw orgNotFound("Action") }
        var wakes: [OrgWakeIntent] = []
        let updated: OrgApproval = try store.mutateCompany(companyId) { company in
            guard let index = company.approvals.firstIndex(where: { $0.id == approvalId }) else { throw orgNotFound("Approval") }
            company.approvals[index].status = newStatus
            company.approvals[index].decisionNote = body.text("note", max: 20_000)
            company.approvals[index].decidedByUserId = actor.userId ?? OrgService.ownerUserId
            company.approvals[index].decidedAt = now
            company.approvals[index].updatedAt = now
            let current = company.approvals[index]
            switch current.type {
            case "hire_agent":
                if let agentId = current.payload["agentId"].stringValue, let agentIndex = company.agents.firstIndex(where: { $0.id == agentId }),
                   company.agents[agentIndex].status == "pending_approval" {
                    if newStatus == "approved" { company.agents[agentIndex].status = "idle" }
                    if newStatus == "rejected" { company.agents[agentIndex].status = "terminated" }
                    company.agents[agentIndex].updatedAt = now
                }
            case "budget_override_required":
                if newStatus == "approved", let incidentIndex = company.budgetIncidents.firstIndex(where: { $0.approvalId == approvalId }) {
                    company.budgetIncidents[incidentIndex].status = "resolved"
                    company.budgetIncidents[incidentIndex].resolvedAt = now
                    resumeBudgetScope(&company, scopeType: company.budgetIncidents[incidentIndex].scopeType, scopeId: company.budgetIncidents[incidentIndex].scopeId)
                }
            default: break
            }
            if let agent = current.requestedByAgentId, newStatus != "cancelled" {
                wakes.append(OrgWakeIntent(companyId: companyId, agentId: agent, source: "automation", reason: "approval_decided", issueId: current.issueIds.first,
                                           payload: ["approvalId": JSON(approvalId), "status": JSON(newStatus)], requestedByType: actor.actorType, requestedById: actor.actorId))
            }
            return current
        }
        record(companyId, actor, "approval.\(newStatus)", "approval", approvalId, ["type": JSON(approval.type)])
        dispatch(wakes)
        engine.kick(companyId)
        return ["approval": OrgCodec.json(updated)]
    }

    // MARK: Budgets and costs

    func upsertImplicitBudget(_ company: inout OrgCompanyState, scopeType: String, scopeId: String, cents: Int) {
        if let index = company.budgetPolicies.firstIndex(where: { $0.scopeType == scopeType && $0.scopeId == scopeId && $0.windowKind == "calendar_month_utc" }) {
            company.budgetPolicies[index].amountCents = cents
            company.budgetPolicies[index].isActive = cents > 0
            company.budgetPolicies[index].updatedAt = now
        } else if cents > 0 {
            company.budgetPolicies.append(OrgBudgetPolicy(id: OrgIDs.make("bud"), companyId: company.company.id, scopeType: scopeType, scopeId: scopeId,
                                                          windowKind: "calendar_month_utc", amountCents: cents, createdAt: now, updatedAt: now))
        }
    }

    func windowStart(_ policy: OrgBudgetPolicy) -> String {
        policy.windowKind == "lifetime" ? "1970-01-01T00:00:00.000Z" : orgMonthStart()
    }

    func eventMatches(_ event: OrgCostEvent, _ policy: OrgBudgetPolicy) -> Bool {
        switch policy.scopeType {
        case "company": return true
        case "agent": return event.agentId == policy.scopeId
        case "project": return event.projectId == policy.scopeId
        default: return false
        }
    }

    func observedSpend(_ company: OrgCompanyState, _ policy: OrgBudgetPolicy) -> (cents: Int, unpriced: Int) {
        let start = windowStart(policy)
        var cents = 0, unpriced = 0
        for event in company.costEvents where event.occurredAt >= start && eventMatches(event, policy) {
            cents += event.costCents
            if event.costStatus == "unpriced" { unpriced += 1 }
        }
        return (cents, unpriced)
    }

    /// Records a cost event and applies soft/hard budget thresholds.
    func applyCostEvent(_ company: inout OrgCompanyState, _ event: OrgCostEvent) {
        company.costEvents.append(event)
        evaluateBudgets(&company)
    }

    func evaluateBudgets(_ company: inout OrgCompanyState) {
        for policy in company.budgetPolicies where policy.isActive && policy.amountCents > 0 {
            let start = windowStart(policy)
            let (spent, unpriced) = observedSpend(company, policy)
            let incidents = company.budgetIncidents.filter { $0.policyId == policy.id && $0.windowStart == start }
            if spent * 100 >= policy.amountCents * policy.warnPercent && !incidents.contains(where: { $0.thresholdType == "soft" }) {
                company.budgetIncidents.append(OrgBudgetIncident(id: OrgIDs.make("inc"), companyId: company.company.id, policyId: policy.id, scopeType: policy.scopeType, scopeId: policy.scopeId,
                                                                 windowStart: start, thresholdType: "soft", amountLimit: policy.amountCents, amountObserved: spent, createdAt: now))
            }
            let overLimit = spent >= policy.amountCents || (policy.unpricedUsagePolicy == "block" && unpriced > 0)
            let hasHard = incidents.contains { $0.thresholdType == "hard" }
            if overLimit && policy.hardStopEnabled && !hasHard {
                let approval = OrgApproval(id: OrgIDs.make("apr"), companyId: company.company.id, type: "budget_override_required",
                                           payload: ["policyId": JSON(policy.id), "scopeType": JSON(policy.scopeType), "scopeId": JSON(policy.scopeId),
                                                     "limitCents": JSON(policy.amountCents), "observedCents": JSON(spent)], createdAt: now, updatedAt: now)
                company.approvals.append(approval)
                company.budgetIncidents.append(OrgBudgetIncident(id: OrgIDs.make("inc"), companyId: company.company.id, policyId: policy.id, scopeType: policy.scopeType, scopeId: policy.scopeId,
                                                                 windowStart: start, thresholdType: "hard", amountLimit: policy.amountCents, amountObserved: spent, approvalId: approval.id, createdAt: now))
                pauseBudgetScope(&company, scopeType: policy.scopeType, scopeId: policy.scopeId)
            }
        }
    }

    func pauseBudgetScope(_ company: inout OrgCompanyState, scopeType: String, scopeId: String) {
        let stamp = now
        switch scopeType {
        case "company":
            if company.company.status == "active" { company.company.status = "paused"; company.company.pauseReason = "budget"; company.company.pausedAt = stamp }
        case "agent":
            if let index = company.agents.firstIndex(where: { $0.id == scopeId }), !["terminated", "paused"].contains(company.agents[index].status) {
                company.agents[index].status = "paused"; company.agents[index].pauseReason = "budget"; company.agents[index].pausedAt = stamp
            }
        case "project":
            if let index = company.projects.firstIndex(where: { $0.id == scopeId }) { company.projects[index].pauseReason = "budget" }
        default: break
        }
    }

    func resumeBudgetScope(_ company: inout OrgCompanyState, scopeType: String, scopeId: String) {
        switch scopeType {
        case "company":
            if company.company.status == "paused" && company.company.pauseReason == "budget" { company.company.status = "active"; company.company.pauseReason = nil; company.company.pausedAt = nil }
        case "agent":
            if let index = company.agents.firstIndex(where: { $0.id == scopeId }), company.agents[index].status == "paused", company.agents[index].pauseReason == "budget" {
                company.agents[index].status = "idle"; company.agents[index].pauseReason = nil; company.agents[index].pausedAt = nil
            }
        case "project":
            if let index = company.projects.firstIndex(where: { $0.id == scopeId }), company.projects[index].pauseReason == "budget" { company.projects[index].pauseReason = nil }
        default: break
        }
    }

    /// Monthly rollover: hard stops from a previous month lift automatically.
    func rolloverBudgets(_ company: inout OrgCompanyState) -> Bool {
        let start = orgMonthStart()
        var changed = false
        for index in company.budgetIncidents.indices where company.budgetIncidents[index].status == "open" && company.budgetIncidents[index].windowStart < start {
            let policy = company.budgetPolicies.first { $0.id == company.budgetIncidents[index].policyId }
            guard policy?.windowKind != "lifetime" else { continue }
            company.budgetIncidents[index].status = "resolved"
            company.budgetIncidents[index].resolvedAt = now
            if company.budgetIncidents[index].thresholdType == "hard" {
                resumeBudgetScope(&company, scopeType: company.budgetIncidents[index].scopeType, scopeId: company.budgetIncidents[index].scopeId)
                if let approvalId = company.budgetIncidents[index].approvalId, let approvalIndex = company.approvals.firstIndex(where: { $0.id == approvalId && $0.status == "pending" }) {
                    company.approvals[approvalIndex].status = "cancelled"
                    company.approvals[approvalIndex].decisionNote = "Budget window rolled over."
                }
            }
            changed = true
        }
        return changed
    }

    func listBudgets(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let policies = state.budgetPolicies.map { policy -> JSON in
            var json = OrgCodec.json(policy).object
            let spend = observedSpend(state, policy)
            json["observedCents"] = JSON(spend.cents)
            json["windowStart"] = JSON(windowStart(policy))
            return .object(json)
        }
        return ["policies": .array(policies), "incidents": .array(state.budgetIncidents.reversed().map { OrgCodec.json($0) })]
    }

    func saveBudget(_ actor: OrgActor, _ companyId: String, _ policyId: String?, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireGrant(state, actor, "budgets:manage")
        guard actor.kind != .agent else { throw orgForbidden("Agents cannot change budgets.") }
        let policy: OrgBudgetPolicy = try store.mutateCompany(companyId) { company in
            var policy: OrgBudgetPolicy
            var index: Int?
            if let policyId {
                guard let found = company.budgetPolicies.firstIndex(where: { $0.id == policyId }) else { throw orgNotFound("Budget") }
                index = found
                policy = company.budgetPolicies[found]
            } else {
                let scopeType = try body.oneOf("scopeType", ["company", "agent", "project"]) ?? "company"
                var scopeId = body.string("scopeId") ?? company.company.id
                if scopeType == "agent" { guard let agent = findAgent(company, scopeId) else { throw orgNotFound("Agent") }; scopeId = agent.id }
                if scopeType == "project" && !company.projects.contains(where: { $0.id == scopeId }) { throw orgNotFound("Project") }
                if scopeType == "company" { scopeId = company.company.id }
                policy = OrgBudgetPolicy(id: OrgIDs.make("bud"), companyId: companyId, scopeType: scopeType, scopeId: scopeId,
                                         windowKind: try body.oneOf("windowKind", ["calendar_month_utc", "lifetime"]) ?? "calendar_month_utc",
                                         amountCents: max(0, try body.int("amountCents") ?? { throw requestError("amountCents is required.") }()), createdAt: now, updatedAt: now)
            }
            if let amount = body.int("amountCents") { policy.amountCents = max(0, amount) }
            if let warn = body.int("warnPercent") { policy.warnPercent = min(max(warn, 1), 100) }
            if let hard = body.bool("hardStopEnabled") { policy.hardStopEnabled = hard }
            if let unpriced = try body.oneOf("unpricedUsagePolicy", ["allow", "block"]) { policy.unpricedUsagePolicy = unpriced }
            if let active = body.bool("isActive") { policy.isActive = active }
            policy.updatedAt = now
            if let index { company.budgetPolicies[index] = policy } else { company.budgetPolicies.append(policy) }
            evaluateBudgets(&company)
            return policy
        }
        record(companyId, actor, policyId == nil ? "budget.created" : "budget.updated", "budget", policy.id)
        return ["policy": OrgCodec.json(policy)]
    }

    func resolveIncident(_ actor: OrgActor, _ companyId: String, _ incidentId: String, _ body: OrgBody) throws -> JSON {
        try requireGrant(try company(companyId), actor, "budgets:manage")
        let status = try body.oneOf("status", ["resolved", "dismissed"]) ?? "resolved"
        let incident: OrgBudgetIncident = try store.mutateCompany(companyId) { company in
            guard let index = company.budgetIncidents.firstIndex(where: { $0.id == incidentId }) else { throw orgNotFound("Incident") }
            company.budgetIncidents[index].status = status
            company.budgetIncidents[index].resolvedAt = now
            if company.budgetIncidents[index].thresholdType == "hard" {
                resumeBudgetScope(&company, scopeType: company.budgetIncidents[index].scopeType, scopeId: company.budgetIncidents[index].scopeId)
            }
            return company.budgetIncidents[index]
        }
        record(companyId, actor, "budget.incident_\(status)", "budget_incident", incidentId)
        engine.kick(companyId)
        return ["incident": OrgCodec.json(incident)]
    }

    /// External adapters (or the board) report usage for runs RoachNet did not price itself.
    func reportCost(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        let agentId = actor.kind == .agent ? actor.agentId : body.string("agentId").flatMap { findAgent(state, $0)?.id }
        let issueId = body.string("issueId").flatMap { findIssue(state, $0)?.id }
        let event = OrgCostEvent(id: OrgIDs.make("cost"), companyId: companyId, agentId: agentId, issueId: issueId,
                                 projectId: issueId.flatMap { id in state.issues.first { $0.id == id }?.projectId } ?? body.string("projectId"),
                                 runId: actor.runId ?? body.string("runId"), provider: body.string("provider", max: 80) ?? "external", model: body.string("model", max: 120) ?? "unknown",
                                 inputTokens: max(0, body.int("inputTokens") ?? 0), outputTokens: max(0, body.int("outputTokens") ?? 0), cachedInputTokens: max(0, body.int("cachedInputTokens") ?? 0),
                                 costCents: max(0, body.int("costCents") ?? 0), costStatus: body.has("costCents") ? "reported" : "unpriced",
                                 billingType: try body.oneOf("billingType", ["local", "metered_api", "subscription_included", "unknown"]) ?? "unknown", occurredAt: now)
        try store.mutateCompany(companyId) { applyCostEvent(&$0, event) }
        return ["costEvent": OrgCodec.json(event)]
    }

    func costSummary(_ actor: OrgActor, _ companyId: String, _ query: [String: String]) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let groupBy = query["groupBy"] ?? "agent"
        let start = query["window"] == "all" ? "" : orgMonthStart()
        var groups: [String: (cents: Int, input: Int, output: Int, events: Int)] = [:]
        var total = 0
        for event in state.costEvents where event.occurredAt >= start {
            let key: String
            switch groupBy {
            case "project": key = event.projectId ?? "none"
            case "model": key = "\(event.provider)/\(event.model)"
            case "day": key = String(event.occurredAt.prefix(10))
            case "billing": key = event.billingType
            default: key = event.agentId ?? "none"
            }
            var group = groups[key] ?? (0, 0, 0, 0)
            group.cents += event.costCents; group.input += event.inputTokens; group.output += event.outputTokens; group.events += 1
            groups[key] = group
            total += event.costCents
        }
        let rows = groups.sorted { $0.value.cents == $1.value.cents ? $0.key < $1.key : $0.value.cents > $1.value.cents }.map { key, value -> JSON in
            var label = key
            if groupBy == "agent", let agent = state.agents.first(where: { $0.id == key }) { label = agent.name }
            if groupBy == "project", let project = state.projects.first(where: { $0.id == key }) { label = project.name }
            return ["key": JSON(key), "label": JSON(label), "costCents": JSON(value.cents), "inputTokens": JSON(value.input), "outputTokens": JSON(value.output), "events": JSON(value.events)]
        }
        return ["groupBy": JSON(groupBy), "windowStart": JSON(start.isEmpty ? nil : start), "totalCents": JSON(total), "rows": .array(rows)]
    }

    // MARK: Skills

    func listSkills(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["skills": .array(state.skills.map { skill -> JSON in
            var json = OrgCodec.json(skill).object
            json["versions"] = .array(skill.versions.map { ["number": JSON($0.number), "createdBy": JSON($0.createdBy), "createdAt": JSON($0.createdAt)] })
            return .object(json)
        })]
    }

    func saveSkill(_ actor: OrgActor, _ companyId: String, _ key: String?, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard isBoard(state, actor) || hasGrant(state, actor, "agents:create") else { throw orgForbidden("Only the board or hiring agents manage the skill library.") }
        guard let markdown = body.text("markdown", max: 200_000), !markdown.isEmpty else { throw requestError("markdown is required.") }
        let slug = OrgIDs.slug(key ?? body.string("key") ?? body.string("name") ?? "", fallback: "")
        guard !slug.isEmpty else { throw requestError("key or name is required.") }
        let author = "\(actor.actorType):\(actor.actorId ?? "system")"
        let skill: OrgSkill = try store.mutateCompany(companyId) { company in
            let stamp = now
            if let index = company.skills.firstIndex(where: { $0.key == slug }) {
                let number = company.skills[index].currentVersion + 1
                company.skills[index].versions.append(OrgSkillVersion(id: OrgIDs.make("skv"), number: number, markdown: markdown, createdBy: author, createdAt: stamp))
                company.skills[index].versions.orgCap(50)
                company.skills[index].markdown = markdown
                company.skills[index].currentVersion = number
                if let name = body.string("name", max: 120) { company.skills[index].name = name }
                if let description = body.text("description", max: 2_000) { company.skills[index].description = description }
                company.skills[index].updatedAt = stamp
                return company.skills[index]
            }
            let skill = OrgSkill(id: OrgIDs.make("skill"), companyId: companyId, key: slug, slug: slug, name: body.string("name", max: 120) ?? slug,
                                 description: body.text("description", max: 2_000) ?? "", markdown: markdown, currentVersion: 1,
                                 versions: [OrgSkillVersion(id: OrgIDs.make("skv"), number: 1, markdown: markdown, createdBy: author, createdAt: stamp)], createdAt: stamp, updatedAt: stamp)
            company.skills.append(skill)
            return skill
        }
        record(companyId, actor, "skill.saved", "skill", skill.id, ["key": JSON(skill.key), "version": JSON(skill.currentVersion)])
        return ["skill": OrgCodec.json(skill)]
    }

    func deleteSkill(_ actor: OrgActor, _ companyId: String, _ key: String) throws -> JSON {
        try requireBoard(try company(companyId), actor)
        try store.mutateCompany(companyId) { company in
            guard company.skills.contains(where: { $0.key == key }) else { throw orgNotFound("Skill") }
            company.skills.removeAll { $0.key == key }
        }
        record(companyId, actor, "skill.deleted", "skill", key)
        return ["deleted": true]
    }

    // MARK: Secrets

    func listSecrets(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireGrant(state, actor, "secrets:manage")
        return ["secrets": .array(state.secrets.map { secret -> JSON in
            var json = OrgCodec.json(secret).object
            json["valueSha256"] = .undefined
            return .object(json)
        })]
    }

    func putSecret(_ actor: OrgActor, _ companyId: String, _ key: String, _ body: OrgBody) throws -> JSON {
        try requireGrant(try company(companyId), actor, "secrets:manage")
        guard actor.kind != .agent else { throw orgForbidden("Agents cannot write secrets.") }
        guard OrgStore.validSecretKey(key) else { throw orgInvalid("Secret keys may use letters, digits, '.', '_' and '-'.") }
        guard let value = body.raw["value"].stringValue, !value.isEmpty, value.utf8.count <= 64_000 else { throw requestError("value is required.") }
        try store.writeSecret(companyId: companyId, key: key, value: value)
        let secret: OrgSecret = try store.mutateCompany(companyId) { company in
            let stamp = now
            if let index = company.secrets.firstIndex(where: { $0.key == key }) {
                company.secrets[index].latestVersion += 1
                company.secrets[index].valueSha256 = SHA256Digest.hex(value)
                company.secrets[index].lastRotatedAt = stamp
                company.secrets[index].updatedAt = stamp
                if let name = body.string("name", max: 120) { company.secrets[index].name = name }
                if body.has("description") { company.secrets[index].description = body.text("description", max: 2_000) }
                return company.secrets[index]
            }
            let secret = OrgSecret(id: OrgIDs.make("sec"), companyId: companyId, key: key, name: body.string("name", max: 120) ?? key,
                                   description: body.text("description", max: 2_000), valueSha256: SHA256Digest.hex(value), createdAt: stamp, updatedAt: stamp)
            company.secrets.append(secret)
            return secret
        }
        record(companyId, actor, "secret.saved", "secret", key, ["version": JSON(secret.latestVersion)])
        var json = OrgCodec.json(secret).object
        json["valueSha256"] = .undefined
        return ["secret": .object(json)]
    }

    func deleteSecret(_ actor: OrgActor, _ companyId: String, _ key: String) throws -> JSON {
        try requireGrant(try company(companyId), actor, "secrets:manage")
        guard actor.kind != .agent else { throw orgForbidden() }
        try store.mutateCompany(companyId) { company in
            guard company.secrets.contains(where: { $0.key == key }) else { throw orgNotFound("Secret") }
            company.secrets.removeAll { $0.key == key }
        }
        store.deleteSecret(companyId: companyId, key: key)
        record(companyId, actor, "secret.deleted", "secret", key)
        return ["deleted": true]
    }

    /// Resolves `secret:KEY` references for adapters. Values never leave the runtime through the API.
    func resolveSecretReference(_ companyId: String, _ value: String) -> String? {
        guard value.hasPrefix("secret:") else { return value }
        return store.readSecret(companyId: companyId, key: String(value.dropFirst(7)))
    }

    // MARK: Routines

    func listRoutines(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["routines": .array(state.routines.map { OrgCodec.json($0) })]
    }

    func listRoutineRuns(_ actor: OrgActor, _ companyId: String, _ routineId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["runs": .array(state.routineRuns.filter { $0.routineId == routineId }.reversed().map { OrgCodec.json($0) })]
    }

    func saveRoutine(_ actor: OrgActor, _ companyId: String, _ routineId: String?, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard hasGrant(state, actor, "tasks:assign") else { throw orgForbidden("Missing permission tasks:assign.") }
        var newSecrets: [(String, String)] = []
        let routine: OrgRoutine = try store.mutateCompany(companyId) { company in
            var routine: OrgRoutine
            var index: Int?
            if let routineId {
                guard let found = company.routines.firstIndex(where: { $0.id == routineId }) else { throw orgNotFound("Routine") }
                index = found
                routine = company.routines[found]
            } else {
                routine = OrgRoutine(id: OrgIDs.make("rtn"), companyId: companyId, title: try body.required("title", max: 300), createdAt: now, updatedAt: now)
            }
            if let title = body.string("title", max: 300) { routine.title = title }
            if body.has("description") { routine.description = body.text("description", max: 20_000) }
            if body.has("assigneeAgentId") { routine.assigneeAgentId = try body.string("assigneeAgentId").map { ref in guard let agent = findAgent(company, ref) else { throw orgNotFound("Agent") }; return agent.id } }
            if body.has("projectId") { routine.projectId = body.string("projectId") }
            if body.has("goalId") { routine.goalId = body.string("goalId") }
            if body.has("parentIssueId") { routine.parentIssueId = body.string("parentIssueId").flatMap { findIssue(company, $0)?.id } }
            if let priority = try body.oneOf("priority", OrgIssue.priorities) { routine.priority = priority }
            if let status = try body.oneOf("status", ["active", "paused", "archived"]) { routine.status = status }
            if let policy = try body.oneOf("concurrencyPolicy", ["coalesce_if_active", "always_enqueue", "skip_if_active"]) { routine.concurrencyPolicy = policy }
            if let policy = try body.oneOf("catchUpPolicy", ["skip_missed", "enqueue_missed_with_cap"]) { routine.catchUpPolicy = policy }
            if let variables = body.raw["variables"].arrayValue {
                routine.variables = try variables.prefix(32).map { raw in
                    let v = OrgBody(raw)
                    return OrgRoutineVariable(name: try v.required("name", max: 64), label: v.string("label", max: 120), type: v.string("type", max: 32) ?? "text",
                                              required: v.bool("required") ?? false, defaultValue: v.string("defaultValue", max: 2_000))
                }
            }
            if let triggers = body.raw["triggers"].arrayValue {
                var next: [OrgRoutineTrigger] = []
                for raw in triggers.prefix(16) {
                    let t = OrgBody(raw)
                    let kind = try t.oneOf("kind", ["schedule", "webhook", "api"]) ?? "schedule"
                    let existing = t.string("id").flatMap { id in routine.triggers.first { $0.id == id } }
                    var trigger = existing ?? OrgRoutineTrigger(id: OrgIDs.make("trg"), kind: kind)
                    trigger.kind = kind
                    trigger.label = t.string("label", max: 120) ?? trigger.label
                    trigger.enabled = t.bool("enabled") ?? trigger.enabled
                    if kind == "schedule" {
                        let expression = try t.string("cronExpression", max: 120) ?? trigger.cronExpression ?? { throw requestError("Schedule triggers need cronExpression.") }()
                        let zone = t.string("timezone", max: 64) ?? trigger.timezone ?? "UTC"
                        let cron = try OrgCron(expression, timezone: zone)
                        trigger.cronExpression = expression
                        trigger.timezone = zone
                        trigger.nextRunAt = cron.next(after: Date()).map(JS.iso)
                    }
                    if kind == "webhook" {
                        trigger.signingMode = try t.oneOf("signingMode", ["bearer", "hmac_sha256", "none"]) ?? trigger.signingMode
                        trigger.replayWindowSec = min(max(t.int("replayWindowSec") ?? trigger.replayWindowSec, 30), 3_600)
                        if trigger.publicId == nil {
                            trigger.publicId = "rth_\(JS.randomHex(24))"
                            let secret = "rnwh_\(JS.randomHex(32))"
                            newSecrets.append((trigger.id, secret))
                        }
                    }
                    next.append(trigger)
                }
                routine.triggers = next
            }
            routine.updatedAt = now
            if let index { company.routines[index] = routine } else { company.routines.append(routine) }
            return routine
        }
        for (triggerId, secret) in newSecrets { try store.writeSecret(companyId: companyId, key: "routine-trigger-\(triggerId)", value: secret) }
        record(companyId, actor, routineId == nil ? "routine.created" : "routine.updated", "routine", routine.id)
        let secrets = newSecrets.map { ["triggerId": JSON($0.0), "secret": JSON($0.1)] as JSON }
        return ["routine": OrgCodec.json(routine), "webhookSecrets": .array(secrets)]
    }

    static func interpolate(_ template: String, _ values: [String: String]) -> String {
        var output = template
        for (key, value) in values { output = output.replacingOccurrences(of: "{{\(key)}}", with: value) }
        return output
    }

    /// Fires a routine: creates (or coalesces into) an issue for its assignee.
    @discardableResult
    func fireRoutine(_ companyId: String, _ routineId: String, triggerId: String?, source: String, payload: JSON, actor: OrgActor) throws -> OrgRoutineRun {
        var wakes: [OrgWakeIntent] = []
        let run: OrgRoutineRun = try store.mutateCompany(companyId) { company in
            guard let routineIndex = company.routines.firstIndex(where: { $0.id == routineId }) else { throw orgNotFound("Routine") }
            let routine = company.routines[routineIndex]
            guard routine.status == "active" else { throw orgConflict("Routine is \(routine.status).") }
            var run = OrgRoutineRun(id: OrgIDs.make("rrun"), companyId: companyId, routineId: routineId, triggerId: triggerId, source: source, triggeredAt: now, payload: payload)
            var values: [String: String] = [:]
            for variable in routine.variables {
                let provided = payload["variables"][variable.name]
                let value = provided.stringValue ?? (provided.numberValue.map { JSCoercion.format(number: $0) }) ?? variable.defaultValue
                if variable.required && (value ?? "").isEmpty {
                    run.status = "failed"; run.failureReason = "Missing variable \(variable.name)."; run.completedAt = now
                    company.routineRuns.append(run)
                    return run
                }
                values[variable.name] = value ?? ""
            }
            company.routines[routineIndex].lastTriggeredAt = now
            if let triggerId, let triggerIndex = company.routines[routineIndex].triggers.firstIndex(where: { $0.id == triggerId }) {
                company.routines[routineIndex].triggers[triggerIndex].lastFiredAt = now
            }
            let active = company.issues.last { $0.originKind == "routine" && $0.originId == routineId && !$0.isTerminal }
            if let active, routine.concurrencyPolicy != "always_enqueue" {
                if routine.concurrencyPolicy == "skip_if_active" {
                    run.status = "skipped"; run.failureReason = "\(active.identifier) is still open."; run.completedAt = now
                } else {
                    run.status = "coalesced"; run.linkedIssueId = active.id
                    company.comments.append(OrgComment(id: OrgIDs.make("cmt"), companyId: companyId, issueId: active.id, authorType: "system", authorId: nil,
                                                       body: "Routine \(routine.title) fired again (\(source)) while this issue was open.", createdAt: now))
                }
                company.routineRuns.append(run)
                return run
            }
            company.company.issueCounter += 1
            let number = company.company.issueCounter
            let stamp = now
            var issue = OrgIssue(id: OrgIDs.make("iss"), companyId: companyId, number: number, identifier: "\(company.company.issuePrefix)-\(number)",
                                 projectId: routine.projectId, goalId: routine.goalId, parentId: routine.parentIssueId,
                                 title: OrgService.interpolate(routine.title, values), description: routine.description.map { OrgService.interpolate($0, values) },
                                 status: routine.assigneeAgentId == nil ? "backlog" : "todo", priority: routine.priority, assigneeAgentId: routine.assigneeAgentId,
                                 originKind: "routine", originId: routineId, createdAt: stamp, updatedAt: stamp)
            if let agentId = routine.assigneeAgentId, !(company.agents.contains { $0.id == agentId && $0.status != "terminated" }) {
                issue.assigneeAgentId = nil; issue.status = "backlog"
            }
            company.issues.append(issue)
            run.status = "issue_created"; run.linkedIssueId = issue.id
            company.routineRuns.append(run)
            if let agent = issue.assigneeAgentId {
                wakes.append(OrgWakeIntent(companyId: companyId, agentId: agent, source: "automation", reason: "routine", issueId: issue.id,
                                           payload: ["routineId": JSON(routineId)], requestedByType: actor.actorType, requestedById: actor.actorId))
            }
            return run
        }
        record(companyId, actor, "routine.fired", "routine", routineId, ["source": JSON(source), "status": JSON(run.status)])
        dispatch(wakes)
        return run
    }

    func runRoutineNow(_ actor: OrgActor, _ companyId: String, _ routineId: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard hasGrant(state, actor, "tasks:assign") else { throw orgForbidden("Missing permission tasks:assign.") }
        let run = try fireRoutine(companyId, routineId, triggerId: nil, source: actor.kind == .agent ? "api" : "manual", payload: ["variables": body.raw["variables"].isObject ? body.raw["variables"] : .object(JSONObject())], actor: actor)
        return ["run": OrgCodec.json(run)]
    }

    /// Public webhook entry: authenticated only by the trigger's signing mode.
    func handleRoutineWebhook(_ publicId: String, headers: [String: String], rawBody: Data) throws -> JSON {
        for state in store.allCompanies() {
            for routine in state.routines {
                guard let trigger = routine.triggers.first(where: { $0.publicId == publicId && $0.kind == "webhook" }) else { continue }
                guard trigger.enabled else { throw orgConflict("Trigger is disabled.") }
                let secret = store.readSecret(companyId: state.company.id, key: "routine-trigger-\(trigger.id)") ?? ""
                switch trigger.signingMode {
                case "bearer":
                    let provided = (headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])
                    guard !secret.isEmpty, orgConstantTimeEquals(provided, secret) else { throw requestError("Invalid webhook token.", 401) }
                case "hmac_sha256":
                    guard let timestamp = headers["x-roachnet-timestamp"], let seconds = Double(timestamp),
                          abs(Date().timeIntervalSince1970 - seconds) <= Double(trigger.replayWindowSec) else { throw requestError("Stale or missing webhook timestamp.", 401) }
                    let expected = Encoding.hex(HMACSHA256.mac(key: Array(secret.utf8), message: Array("\(timestamp).".utf8) + Array(rawBody)))
                    let provided = (headers["x-roachnet-signature"] ?? "").replacingOccurrences(of: "sha256=", with: "")
                    guard !secret.isEmpty, orgConstantTimeEquals(provided.lowercased(), expected) else { throw requestError("Invalid webhook signature.", 401) }
                default: break
                }
                let payload = (try? JSON.parse(rawBody)) ?? .object(JSONObject())
                let run = try fireRoutine(state.company.id, routine.id, triggerId: trigger.id, source: "webhook",
                                          payload: ["variables": payload["variables"].isObject ? payload["variables"] : .object(JSONObject()), "body": payload], actor: .system)
                return ["run": OrgCodec.json(run)]
            }
        }
        throw orgNotFound("Trigger")
    }

    // MARK: Runs, wakes, activity, dashboard

    func listRuns(_ actor: OrgActor, _ companyId: String, _ query: [String: String]) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        var runs = state.runs
        if let agent = query["agentId"], !agent.isEmpty { let id = findAgent(state, agent)?.id; runs = runs.filter { $0.agentId == id } }
        if let issue = query["issueId"], !issue.isEmpty { let id = findIssue(state, issue)?.id; runs = runs.filter { $0.issueId == id } }
        if let status = query["status"], !status.isEmpty { runs = runs.filter { $0.status == status } }
        let limit = min(max(Int(query["limit"] ?? "") ?? 100, 1), 1_000)
        return ["runs": .array(runs.suffix(limit).reversed().map { OrgCodec.json($0) })]
    }

    func getRun(_ actor: OrgActor, _ companyId: String, _ runId: String, includeLog: Bool) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let run = state.runs.first(where: { $0.id == runId }) else { throw orgNotFound("Run") }
        var result = JSONObject([("run", OrgCodec.json(run))])
        if includeLog { result["log"] = .array(store.runLog(companyId: companyId, runId: runId)) }
        return .object(result)
    }

    func cancelRun(_ actor: OrgActor, _ companyId: String, _ runId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let run = state.runs.first(where: { $0.id == runId }) else { throw orgNotFound("Run") }
        guard isBoard(state, actor) || isManager(state, actor.agentId, of: run.agentId) || actor.agentId == run.agentId else { throw orgForbidden() }
        guard run.status == "running" || run.status == "queued" else { throw orgConflict("Run is \(run.status).") }
        engine.cancel(runId)
        record(companyId, actor, "run.cancel_requested", "run", runId)
        return ["cancelRequested": true]
    }

    func listWakes(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["wakeRequests": .array(state.wakeRequests.suffix(200).reversed().map { OrgCodec.json($0) })]
    }

    func listActivity(_ actor: OrgActor, _ companyId: String, _ query: [String: String]) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        var items = store.activity(companyId: companyId, limit: min(max(Int(query["limit"] ?? "") ?? 100, 1), OrgStore.activityMemoryCap))
        if let entity = query["entityId"], !entity.isEmpty { items = items.filter { $0.entityId == entity } }
        return ["activity": .array(items.map { OrgCodec.json($0) })]
    }

    func dashboard(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        var issuesByStatus = JSONObject()
        for status in OrgIssue.statuses { issuesByStatus[status] = JSON(state.issues.filter { $0.status == status }.count) }
        var agentsByStatus = JSONObject()
        for agent in state.agents { agentsByStatus[agent.status] = JSON(Int(agentsByStatus[agent.status].numberValue ?? 0) + 1) }
        let monthStart = orgMonthStart()
        let monthSpend = state.costEvents.filter { $0.occurredAt >= monthStart }.reduce(0) { $0 + $1.costCents }
        let monthTokens = state.costEvents.filter { $0.occurredAt >= monthStart }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        return [
            "company": OrgCodec.json(state.company),
            "issuesByStatus": .object(issuesByStatus),
            "agentsByStatus": .object(agentsByStatus),
            "pendingApprovals": JSON(state.approvals.filter { $0.status == "pending" }.count),
            "openIncidents": JSON(state.budgetIncidents.filter { $0.status == "open" }.count),
            "runningRuns": JSON(state.runs.filter { $0.status == "running" }.count),
            "queuedWakes": JSON(state.wakeRequests.filter { $0.status == "queued" }.count),
            "monthSpendCents": JSON(monthSpend),
            "monthTokens": JSON(monthTokens),
            "companyBudgetCents": JSON(state.company.budgetMonthlyCents),
            "recentRuns": .array(state.runs.suffix(10).reversed().map { OrgCodec.json($0) }),
            "recentActivity": .array(store.activity(companyId: companyId, limit: 15).map { OrgCodec.json($0) }),
        ]
    }

    // MARK: Export / import

    /// Portable company template: structure and work, never secrets, keys, invites or run history.
    func exportCompany(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        var state = try company(companyId)
        try requireBoard(state, actor)
        state.apiKeys = []; state.invites = []; state.joinRequests = []
        state.runs = []; state.wakeRequests = []; state.costEvents = []; state.budgetIncidents = []; state.routineRuns = []
        state.memberships = state.memberships.filter { $0.principalType == "agent" }
        for index in state.agents.indices { state.agents[index].sessionState = nil }
        for index in state.secrets.indices { state.secrets[index].valueSha256 = "" }
        for routineIndex in state.routines.indices {
            for triggerIndex in state.routines[routineIndex].triggers.indices { state.routines[routineIndex].triggers[triggerIndex].publicId = nil }
        }
        record(companyId, actor, "company.exported", "company", companyId)
        return ["format": "roachclaw-org-export", "version": 1, "exportedAt": JSON(now), "company": OrgCodec.json(state)]
    }

    func importCompany(_ actor: OrgActor, _ body: OrgBody) throws -> JSON {
        guard actor.isOwner else { throw orgForbidden("Only the RoachNet owner can import companies.") }
        guard body.raw["format"].stringValue == "roachclaw-org-export" else { throw orgInvalid("Not a RoachClaw Org export.") }
        var state = try OrgCodec.decode(OrgCompanyState.self, from: body.raw["company"])
        let oldId = state.company.id
        let newId = OrgIDs.make("co")
        let remapped = state.company.id == newId ? body.raw["company"].serialized() : OrgCodec.json(state).serialized().replacingOccurrences(of: "\"\(oldId)\"", with: "\"\(newId)\"")
        state = try OrgCodec.decode(OrgCompanyState.self, from: try JSON.parse(remapped))
        let stamp = now
        if let name = body.string("name", max: 120) { state.company.name = name }
        state.company.status = "paused"; state.company.pauseReason = "import"; state.company.pausedAt = stamp
        state.company.createdAt = stamp; state.company.updatedAt = stamp
        state.memberships.append(OrgMembership(id: OrgIDs.make("mem"), companyId: newId, principalType: "user", principalId: OrgService.ownerUserId, role: "owner", grants: Array(OrgService.grants), createdAt: stamp, updatedAt: stamp))
        for index in state.agents.indices where state.agents[index].status != "terminated" { state.agents[index].status = "idle" }
        for index in state.issues.indices { state.issues[index].checkoutRunId = nil; state.issues[index].executionRunId = nil }
        for routineIndex in state.routines.indices {
            for triggerIndex in state.routines[routineIndex].triggers.indices where state.routines[routineIndex].triggers[triggerIndex].kind == "webhook" {
                state.routines[routineIndex].triggers[triggerIndex].enabled = false
            }
        }
        state.secrets = []
        try store.insertCompany(state)
        record(newId, actor, "company.imported", "company", newId, ["sourceCompanyId": JSON(oldId)])
        return ["company": OrgCodec.json(state.company), "note": "Imported paused. Re-enter secrets and webhook triggers, then resume the company."]
    }
}
