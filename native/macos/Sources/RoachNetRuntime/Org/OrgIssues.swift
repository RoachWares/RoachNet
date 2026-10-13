import Foundation

/// Issues: the unit of work agents and people pick up.
extension OrgService {
    static let maxRequestDepth = 8
    static let transitions: [String: Set<String>] = [
        "backlog": ["todo", "in_progress", "blocked", "done", "cancelled"],
        "todo": ["backlog", "in_progress", "blocked", "cancelled", "done"],
        "in_progress": ["todo", "in_review", "blocked", "done", "cancelled"],
        "in_review": ["in_progress", "todo", "blocked", "done", "cancelled"],
        "blocked": ["backlog", "todo", "in_progress", "cancelled"],
        "done": ["todo", "in_progress"],
        "cancelled": ["backlog", "todo"],
    ]

    func findIssue(_ state: OrgCompanyState, _ ref: String) -> OrgIssue? {
        let upper = ref.uppercased()
        return state.issues.first { $0.id == ref || $0.identifier == upper }
    }

    func unresolvedBlockers(_ state: OrgCompanyState, _ issue: OrgIssue) -> [OrgIssue] {
        issue.blockedByIssueIds.compactMap { id in state.issues.first { $0.id == id } }.filter { $0.status != "done" }
    }

    func presentIssue(_ issue: OrgIssue, _ state: OrgCompanyState) -> JSON {
        var json = OrgCodec.json(issue).object
        json["blockers"] = .array(unresolvedBlockers(state, issue).map { ["id": JSON($0.id), "identifier": JSON($0.identifier), "status": JSON($0.status)] })
        json["assigneeAgentName"] = JSON(issue.assigneeAgentId.flatMap { id in state.agents.first { $0.id == id }?.name })
        return .object(json)
    }

    func listIssues(_ actor: OrgActor, _ companyId: String, _ query: [String: String]) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        var issues = state.issues
        if let status = query["status"], !status.isEmpty {
            let wanted = Set(status.split(separator: ",").map(String.init))
            issues = issues.filter { wanted.contains($0.status) }
        }
        if let assignee = query["assignee"], !assignee.isEmpty {
            if assignee == "me" {
                issues = issues.filter { ($0.assigneeAgentId != nil && $0.assigneeAgentId == actor.agentId) || ($0.assigneeUserId != nil && $0.assigneeUserId == actor.userId) }
            } else {
                let agentId = findAgent(state, assignee)?.id
                issues = issues.filter { $0.assigneeAgentId == agentId || $0.assigneeUserId == assignee }
            }
        }
        if let project = query["projectId"], !project.isEmpty { issues = issues.filter { $0.projectId == project } }
        if let parent = query["parentId"], !parent.isEmpty {
            let parentId = findIssue(state, parent)?.id
            issues = issues.filter { $0.parentId == parentId }
        }
        if let label = query["labelId"], !label.isEmpty { issues = issues.filter { $0.labelIds.contains(label) } }
        if let text = query["q"]?.lowercased(), !text.isEmpty {
            issues = issues.filter { $0.title.lowercased().contains(text) || ($0.description ?? "").lowercased().contains(text) || $0.identifier.lowercased() == text }
        }
        let limit = min(max(Int(query["limit"] ?? "") ?? 200, 1), 1_000)
        let priorityRank = ["critical": 0, "high": 1, "medium": 2, "low": 3]
        issues.sort { lhs, rhs in
            let l = priorityRank[lhs.priority] ?? 9, r = priorityRank[rhs.priority] ?? 9
            return l != r ? l < r : lhs.number > rhs.number
        }
        return ["issues": .array(issues.prefix(limit).map { presentIssue($0, state) }), "total": JSON(issues.count)]
    }

    func getIssue(_ actor: OrgActor, _ companyId: String, _ ref: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        let comments = state.comments.filter { $0.issueId == issue.id && $0.deletedAt == nil }
        let documents = state.documents.filter { $0.issueId == issue.id }.map { doc -> JSON in
            ["key": JSON(doc.key), "title": JSON(doc.title), "revisionNumber": JSON(doc.revisionNumber), "revisionId": JSON(doc.revisionId), "updatedAt": JSON(doc.updatedAt)]
        }
        return [
            "issue": presentIssue(issue, state),
            "comments": .array(comments.map { OrgCodec.json($0) }),
            "documents": .array(documents),
            "workProducts": .array(state.workProducts.filter { $0.issueId == issue.id }.map { OrgCodec.json($0) }),
            "children": .array(state.issues.filter { $0.parentId == issue.id }.map { presentIssue($0, state) }),
            "approvals": .array(state.approvals.filter { $0.issueIds.contains(issue.id) }.map { OrgCodec.json($0) }),
        ]
    }

    private func assertCanAssign(_ state: OrgCompanyState, _ actor: OrgActor, agentId: String?, userId: String?) throws {
        if agentId == nil && userId == nil { return }
        if actor.kind == .agent && agentId == actor.agentId && userId == nil { return }
        if actor.kind != .agent && userId == actor.userId && agentId == nil { return }
        guard hasGrant(state, actor, "tasks:assign") else { throw orgForbidden("Missing permission tasks:assign.") }
        if let agentId {
            guard let agent = state.agents.first(where: { $0.id == agentId }) else { throw orgNotFound("Agent") }
            guard agent.status != "terminated" && agent.status != "pending_approval" else { throw orgConflict("\(agent.name) cannot take work right now.") }
        }
        if let userId {
            guard userId == OrgService.ownerUserId || state.memberships.contains(where: { $0.principalType == "user" && $0.principalId == userId && $0.status == "active" }) else {
                throw orgInvalid("That person is not a member of this company.")
            }
        }
    }

    private func resolveAssignee(_ state: OrgCompanyState, _ body: OrgBody) throws -> (agent: String??, user: String??) {
        var agent: String?? = nil
        var user: String?? = nil
        if let value = body.nullable("assigneeAgentId") {
            if let ref = value {
                guard let found = findAgent(state, ref) else { throw orgNotFound("Agent") }
                agent = .some(found.id)
            } else { agent = .some(nil) }
        }
        if let value = body.nullable("assigneeUserId") { user = .some(value) }
        return (agent, user)
    }

    private func validateExecutionPolicy(_ state: OrgCompanyState, _ raw: JSON) throws -> OrgExecutionPolicy? {
        if raw.isNull { return nil }
        guard raw.isObject else { throw orgInvalid("executionPolicy must be an object.") }
        var policy = OrgExecutionPolicy()
        policy.maxReviewRounds = min(max(OrgBody(raw).int("maxReviewRounds") ?? 3, 1), 20)
        for (index, stageJSON) in raw["stages"].array.prefix(8).enumerated() {
            let stage = OrgBody(stageJSON)
            let type = try stage.oneOf("type", ["review", "approval"]) ?? "review"
            var participants: [OrgParticipant] = []
            for participant in stageJSON["participants"].array.prefix(8) {
                let p = OrgBody(participant)
                let kind = try p.oneOf("type", ["agent", "user"]) ?? "agent"
                let ref = try p.required("id")
                if kind == "agent" {
                    guard let agent = findAgent(state, ref) else { throw orgNotFound("Reviewer agent") }
                    participants.append(OrgParticipant(type: "agent", id: agent.id))
                } else {
                    participants.append(OrgParticipant(type: "user", id: ref))
                }
            }
            guard !participants.isEmpty else { throw orgInvalid("Each stage needs at least one participant.") }
            policy.stages.append(OrgStage(id: stage.string("id") ?? "stage-\(index + 1)", type: type, participants: participants))
        }
        return policy.stages.isEmpty ? nil : policy
    }

    func createIssue(_ actor: OrgActor, _ companyId: String, _ body: OrgBody, origin: (kind: String, id: String?)? = nil) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        let title = try body.required("title", max: 300)
        let status = try body.oneOf("status", Set(OrgIssue.statuses)) ?? (body.has("assigneeAgentId") || body.has("assigneeUserId") ? "todo" : "backlog")
        let priority = try body.oneOf("priority", OrgIssue.priorities) ?? "medium"
        let workMode = try body.oneOf("workMode", ["standard", "planning", "ask"]) ?? "standard"
        let assignee = try resolveAssignee(state, body)
        let agentId = assignee.agent ?? nil
        let userId = assignee.user ?? nil
        try assertCanAssign(state, actor, agentId: agentId, userId: userId)
        var parent: OrgIssue?
        if let ref = body.string("parentId") {
            guard let found = findIssue(state, ref) else { throw orgNotFound("Parent issue") }
            parent = found
        }
        var depth = 0
        if actor.kind == .agent {
            depth = (parent?.requestDepth ?? 0) + 1
            guard depth <= OrgService.maxRequestDepth else { throw orgConflict("Delegation depth limit reached; ask the board instead.") }
        }
        if let project = body.string("projectId"), !state.projects.contains(where: { $0.id == project }) { throw orgNotFound("Project") }
        if let goal = body.string("goalId"), !state.goals.contains(where: { $0.id == goal }) { throw orgNotFound("Goal") }
        let labels = body.strings("labelIds") ?? []
        for label in labels where !state.labels.contains(where: { $0.id == label }) { throw orgNotFound("Label") }
        let policy = body.has("executionPolicy") ? try validateExecutionPolicy(state, body.raw["executionPolicy"]) : nil
        var wakes: [OrgWakeIntent] = []
        let created: OrgIssue = try store.mutateCompany(companyId) { company in
            company.company.issueCounter += 1
            let number = company.company.issueCounter
            let stamp = now
            var issue = OrgIssue(id: OrgIDs.make("iss"), companyId: companyId, number: number, identifier: "\(company.company.issuePrefix)-\(number)",
                                 projectId: body.string("projectId") ?? parent?.projectId, goalId: body.string("goalId") ?? parent?.goalId,
                                 parentId: parent?.id, title: title, description: body.text("description", max: 100_000),
                                 status: status, priority: priority, workMode: workMode, assigneeAgentId: agentId, assigneeUserId: userId,
                                 createdByAgentId: actor.kind == .agent ? actor.agentId : nil, createdByUserId: actor.kind == .agent ? nil : (actor.userId ?? OrgService.ownerUserId),
                                 labelIds: labels, originKind: origin?.kind ?? (actor.kind == .agent ? "agent" : "manual"), originId: origin?.id,
                                 requestDepth: depth, reviewPolicy: try body.oneOf("reviewPolicy", ["anyone", "not_creator", "human_only"]),
                                 executionPolicy: policy, createdAt: stamp, updatedAt: stamp)
            if issue.status == "in_progress" { issue.startedAt = stamp }
            if issue.status == "in_progress" && issue.assigneeAgentId == nil && issue.assigneeUserId == nil { issue.status = "todo" }
            if let blockers = body.strings("blockedByIssueIds") {
                issue.blockedByIssueIds = try validatedBlockers(company, issue.id, blockers)
                if !unresolvedBlockers(company, issue).isEmpty && ["todo", "in_progress"].contains(issue.status) { issue.status = "blocked" }
            }
            company.issues.append(issue)
            if let agent = issue.assigneeAgentId, !issue.isTerminal, issue.status != "backlog", agent != actor.agentId {
                wakes.append(OrgWakeIntent(companyId: companyId, agentId: agent, source: "assignment", reason: "assigned", issueId: issue.id, requestedByType: actor.actorType, requestedById: actor.actorId))
            }
            return issue
        }
        record(companyId, actor, "issue.created", "issue", created.id, ["identifier": JSON(created.identifier), "title": JSON(created.title)])
        dispatch(wakes)
        return ["issue": presentIssue(created, try company(companyId))]
    }

    private func validatedBlockers(_ state: OrgCompanyState, _ issueId: String, _ refs: [String]) throws -> [String] {
        var ids: [String] = []
        for ref in refs {
            guard let blocker = findIssue(state, ref) else { throw orgNotFound("Blocking issue \(ref)") }
            guard blocker.id != issueId else { throw orgInvalid("An issue cannot block itself.") }
            if !ids.contains(blocker.id) { ids.append(blocker.id) }
        }
        // Reject cycles: walking the blockers of each blocker must never reach issueId.
        var stack = ids
        var seen = Set<String>()
        while let current = stack.popLast() {
            if current == issueId { throw orgInvalid("Those blockers would create a dependency cycle.") }
            guard seen.insert(current).inserted else { continue }
            stack.append(contentsOf: state.issues.first(where: { $0.id == current })?.blockedByIssueIds ?? [])
        }
        return ids
    }

    /// Applies a status change plus its side effects. Returns false if nothing changed.
    @discardableResult
    func applyStatus(_ company: inout OrgCompanyState, _ index: Int, _ requested: String, _ actor: OrgActor, force: Bool, wakes: inout [OrgWakeIntent]) throws -> Bool {
        var target = requested
        let current = company.issues[index].status
        guard target != current else { return false }
        if !force { guard OrgService.transitions[current]?.contains(target) == true else { throw orgConflict("Cannot move an issue from \(current) to \(target).") } }
        let issue = company.issues[index]
        if ["in_progress", "done", "in_review"].contains(target) && !unresolvedBlockers(company, issue).isEmpty && !force {
            throw orgConflict("\(issue.identifier) is blocked by \(unresolvedBlockers(company, issue).map { $0.identifier }.joined(separator: ", ")).")
        }
        if target == "in_progress" && issue.assigneeAgentId == nil && issue.assigneeUserId == nil {
            throw orgConflict("Assign the issue before starting it.")
        }
        // Execution policies route completion through review/approval stages.
        if target == "done", let policy = issue.executionPolicy, !policy.stages.isEmpty, issue.executionState?.status != "completed", !force {
            target = "in_review"
            beginStage(&company, index, 0, wakes: &wakes, actor: actor)
        }
        let stamp = now
        company.issues[index].status = target
        company.issues[index].statusVersion += 1
        company.issues[index].updatedAt = stamp
        if target == "in_progress" && company.issues[index].startedAt == nil { company.issues[index].startedAt = stamp }
        if target == "done" { company.issues[index].completedAt = stamp }
        if target == "cancelled" { company.issues[index].cancelledAt = stamp }
        if !["done", "cancelled"].contains(target) { company.issues[index].completedAt = nil; company.issues[index].cancelledAt = nil }
        if target == "done" || target == "cancelled" {
            company.issues[index].checkoutRunId = nil
            afterTerminal(&company, company.issues[index], actor: actor, wakes: &wakes)
        }
        return true
    }

    private func afterTerminal(_ company: inout OrgCompanyState, _ finished: OrgIssue, actor: OrgActor, wakes: inout [OrgWakeIntent]) {
        // Dependents whose blockers are now all resolved resume and wake their assignee.
        if finished.status == "done" {
            for dependentIndex in company.issues.indices where company.issues[dependentIndex].blockedByIssueIds.contains(finished.id) {
                let dependent = company.issues[dependentIndex]
                guard !dependent.isTerminal, unresolvedBlockers(company, dependent).isEmpty else { continue }
                if dependent.status == "blocked" {
                    company.issues[dependentIndex].status = "todo"
                    company.issues[dependentIndex].statusVersion += 1
                    company.issues[dependentIndex].updatedAt = now
                }
                if let agent = dependent.assigneeAgentId {
                    wakes.append(OrgWakeIntent(companyId: company.company.id, agentId: agent, source: "automation", reason: "blockers_resolved", issueId: dependent.id, requestedByType: "system", requestedById: nil))
                }
            }
        }
        // A parent whose children are all closed wakes its assignee to wrap up.
        if let parentId = finished.parentId, let parent = company.issues.first(where: { $0.id == parentId }), !parent.isTerminal {
            let children = company.issues.filter { $0.parentId == parentId }
            if children.allSatisfy({ $0.isTerminal }), let agent = parent.assigneeAgentId {
                wakes.append(OrgWakeIntent(companyId: company.company.id, agentId: agent, source: "automation", reason: "children_completed", issueId: parent.id, requestedByType: "system", requestedById: nil))
            }
        }
        // Routine-created issues close their routine run.
        if finished.originKind == "routine" {
            for runIndex in company.routineRuns.indices where company.routineRuns[runIndex].linkedIssueId == finished.id && company.routineRuns[runIndex].completedAt == nil {
                company.routineRuns[runIndex].status = finished.status == "done" ? "completed" : "failed"
                company.routineRuns[runIndex].completedAt = now
            }
        }
    }

    private func beginStage(_ company: inout OrgCompanyState, _ index: Int, _ stageIndex: Int, wakes: inout [OrgWakeIntent], actor: OrgActor) {
        guard let policy = company.issues[index].executionPolicy, stageIndex < policy.stages.count else { return }
        var state = company.issues[index].executionState ?? OrgExecutionState()
        if state.status == "idle" || state.status == "completed" {
            state = OrgExecutionState()
            state.returnAssigneeAgentId = company.issues[index].assigneeAgentId
            state.returnAssigneeUserId = company.issues[index].assigneeUserId
        }
        let participant = policy.stages[stageIndex].participants[0]
        state.status = "pending"
        state.currentStageIndex = stageIndex
        state.currentParticipant = participant
        company.issues[index].executionState = state
        if participant.type == "agent" {
            company.issues[index].assigneeAgentId = participant.id
            company.issues[index].assigneeUserId = nil
            wakes.append(OrgWakeIntent(companyId: company.company.id, agentId: participant.id, source: "automation", reason: "review_requested", issueId: company.issues[index].id,
                                       payload: ["stageId": JSON(policy.stages[stageIndex].id), "stageType": JSON(policy.stages[stageIndex].type)], requestedByType: actor.actorType, requestedById: actor.actorId))
        } else {
            company.issues[index].assigneeUserId = participant.id
            company.issues[index].assigneeAgentId = nil
        }
    }

    /// The current stage participant approves or requests changes.
    func reviewIssue(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        let decision = try body.oneOf("decision", ["approve", "request_changes"]) ?? "approve"
        guard let execution = issue.executionState, execution.status == "pending", let participant = execution.currentParticipant else {
            throw orgConflict("\(issue.identifier) is not waiting for review.")
        }
        let isParticipant = (participant.type == "agent" && actor.agentId == participant.id)
            || (participant.type == "user" && (actor.userId == participant.id || isBoard(state, actor)))
        guard isParticipant else { throw orgForbidden("Only the current reviewer can decide this stage.") }
        if issue.reviewPolicy == "not_creator", actor.actorId != nil, actor.actorId == (issue.createdByAgentId ?? issue.createdByUserId) {
            throw orgForbidden("This issue's review policy does not allow its creator to review it.")
        }
        if issue.reviewPolicy == "human_only" && actor.kind == .agent { throw orgForbidden("This issue requires a human reviewer.") }
        var wakes: [OrgWakeIntent] = []
        let updated: OrgIssue = try store.mutateCompany(companyId) { company in
            guard let index = company.issues.firstIndex(where: { $0.id == issue.id }), var exec = company.issues[index].executionState,
                  let policy = company.issues[index].executionPolicy, let stageIndex = exec.currentStageIndex else { throw orgNotFound("Issue") }
            // Decide only the stage this caller was checked against. Two approvals
            // sent at once both pass the check above; the second must not land
            // on the next stage, whose reviewer may be someone else.
            guard exec.status == "pending", exec.currentParticipant == participant, stageIndex == execution.currentStageIndex else {
                throw orgConflict("\(issue.identifier) is no longer waiting for this review.")
            }
            if let note = body.text("comment", max: 20_000), !note.isEmpty {
                company.comments.append(OrgComment(id: OrgIDs.make("cmt"), companyId: companyId, issueId: issue.id, authorType: actor.actorType, authorId: actor.actorId, body: note, runId: actor.runId, createdAt: now))
            }
            let returnAgent = exec.returnAssigneeAgentId, returnUser = exec.returnAssigneeUserId
            if decision == "approve" {
                exec.completedStageIds.append(policy.stages[stageIndex].id)
                company.issues[index].executionState = exec
                if stageIndex + 1 < policy.stages.count {
                    beginStage(&company, index, stageIndex + 1, wakes: &wakes, actor: actor)
                } else {
                    exec.status = "completed"; exec.currentParticipant = nil; exec.currentStageIndex = nil
                    company.issues[index].executionState = exec
                    company.issues[index].assigneeAgentId = returnAgent
                    company.issues[index].assigneeUserId = returnUser
                    try applyStatus(&company, index, "done", actor, force: true, wakes: &wakes)
                }
            } else {
                exec.changesRequestedCount += 1
                exec.status = "changes_requested"; exec.currentParticipant = nil; exec.currentStageIndex = nil
                company.issues[index].executionState = exec
                company.issues[index].assigneeAgentId = returnAgent
                company.issues[index].assigneeUserId = returnUser
                if exec.changesRequestedCount > policy.maxReviewRounds {
                    company.issues[index].unblockOwner = "board"
                    company.issues[index].unblockAction = "Review rounds exceeded; the board must decide."
                    try applyStatus(&company, index, "blocked", actor, force: true, wakes: &wakes)
                } else {
                    try applyStatus(&company, index, "in_progress", actor, force: true, wakes: &wakes)
                    if let agent = returnAgent {
                        wakes.append(OrgWakeIntent(companyId: companyId, agentId: agent, source: "automation", reason: "changes_requested", issueId: issue.id, requestedByType: actor.actorType, requestedById: actor.actorId))
                    }
                }
            }
            company.issues[index].updatedAt = now
            return company.issues[index]
        }
        record(companyId, actor, "issue.review_\(decision)", "issue", issue.id)
        dispatch(wakes)
        return ["issue": presentIssue(updated, try company(companyId))]
    }

    func updateIssue(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let existing = findIssue(state, ref) else { throw orgNotFound("Issue") }
        let assignee = try resolveAssignee(state, body)
        if assignee.agent != nil || assignee.user != nil {
            try assertCanAssign(state, actor, agentId: assignee.agent ?? existing.assigneeAgentId, userId: assignee.user ?? existing.assigneeUserId)
        }
        let status = try body.oneOf("status", Set(OrgIssue.statuses))
        let priority = try body.oneOf("priority", OrgIssue.priorities)
        let workMode = try body.oneOf("workMode", ["standard", "planning", "ask"])
        let force = (body.bool("force") ?? false) && isBoard(state, actor)
        if let expected = body.int("expectedStatusVersion"), expected != existing.statusVersion {
            throw orgConflict("The issue changed since you last read it (statusVersion \(existing.statusVersion)).")
        }
        if actor.kind == .agent, let lock = existing.checkoutRunId, lock != actor.runId,
           state.runs.contains(where: { $0.id == lock && $0.status == "running" }) {
            throw orgConflict("\(existing.identifier) is checked out by another run.")
        }
        let policy = body.has("executionPolicy") ? try validateExecutionPolicy(state, body.raw["executionPolicy"]) : nil
        var wakes: [OrgWakeIntent] = []
        let updated: OrgIssue = try store.mutateCompany(companyId) { company in
            guard let index = company.issues.firstIndex(where: { $0.id == existing.id }) else { throw orgNotFound("Issue") }
            let previousAgent = company.issues[index].assigneeAgentId
            if let title = body.string("title", max: 300) { company.issues[index].title = title }
            if body.has("description") { company.issues[index].description = body.text("description", max: 100_000) }
            if let priority { company.issues[index].priority = priority }
            if let workMode { company.issues[index].workMode = workMode }
            if let agent = assignee.agent { company.issues[index].assigneeAgentId = agent }
            if let user = assignee.user { company.issues[index].assigneeUserId = user }
            if body.has("projectId") {
                let project = body.string("projectId")
                if let project, !company.projects.contains(where: { $0.id == project }) { throw orgNotFound("Project") }
                company.issues[index].projectId = project
            }
            if body.has("goalId") {
                let goal = body.string("goalId")
                if let goal, !company.goals.contains(where: { $0.id == goal }) { throw orgNotFound("Goal") }
                company.issues[index].goalId = goal
            }
            if let labels = body.strings("labelIds") {
                for label in labels where !company.labels.contains(where: { $0.id == label }) { throw orgNotFound("Label") }
                company.issues[index].labelIds = labels
            }
            if let blockers = body.strings("blockedByIssueIds") {
                company.issues[index].blockedByIssueIds = try validatedBlockers(company, existing.id, blockers)
                let issue = company.issues[index]
                if !unresolvedBlockers(company, issue).isEmpty && ["todo", "in_progress"].contains(issue.status) && status == nil {
                    try applyStatus(&company, index, "blocked", actor, force: true, wakes: &wakes)
                }
            }
            if body.has("executionPolicy") { company.issues[index].executionPolicy = policy }
            if body.has("unblockOwner") { company.issues[index].unblockOwner = body.string("unblockOwner", max: 200) }
            if body.has("unblockAction") { company.issues[index].unblockAction = body.text("unblockAction", max: 2_000) }
            if let reviewPolicy = try body.oneOf("reviewPolicy", ["anyone", "not_creator", "human_only"]) { company.issues[index].reviewPolicy = reviewPolicy }
            if let status { try applyStatus(&company, index, status, actor, force: force, wakes: &wakes) }
            if let note = body.text("comment", max: 20_000), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                company.comments.append(OrgComment(id: OrgIDs.make("cmt"), companyId: companyId, issueId: existing.id, authorType: actor.actorType, authorId: actor.actorId, body: note, runId: actor.runId, createdAt: now))
            }
            company.issues[index].updatedAt = now
            let issue = company.issues[index]
            if let agent = issue.assigneeAgentId, agent != previousAgent, agent != actor.agentId, !issue.isTerminal, issue.status != "backlog" {
                wakes.append(OrgWakeIntent(companyId: companyId, agentId: agent, source: "assignment", reason: "assigned", issueId: issue.id, requestedByType: actor.actorType, requestedById: actor.actorId))
            }
            return issue
        }
        record(companyId, actor, "issue.updated", "issue", existing.id, ["status": JSON(updated.status)])
        dispatch(wakes)
        return ["issue": presentIssue(updated, try company(companyId))]
    }

    // MARK: Comments

    func listComments(_ actor: OrgActor, _ companyId: String, _ ref: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        return ["comments": .array(state.comments.filter { $0.issueId == issue.id && $0.deletedAt == nil }.map { OrgCodec.json($0) })]
    }

    func addComment(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        guard let text = body.text("body", max: 50_000), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw requestError("body is required.") }
        let comment = OrgComment(id: OrgIDs.make("cmt"), companyId: companyId, issueId: issue.id, authorType: actor.actorType, authorId: actor.actorId, body: text, runId: actor.runId, createdAt: now)
        var wakes: [OrgWakeIntent] = []
        try store.mutateCompany(companyId) { company in
            company.comments.append(comment)
            if let index = company.issues.firstIndex(where: { $0.id == issue.id }) { company.issues[index].updatedAt = now }
        }
        if let agent = issue.assigneeAgentId, agent != actor.agentId, !issue.isTerminal {
            wakes.append(OrgWakeIntent(companyId: companyId, agentId: agent, source: "automation", reason: "comment", issueId: issue.id, payload: ["commentId": JSON(comment.id)], requestedByType: actor.actorType, requestedById: actor.actorId))
        }
        for mentioned in mentions(in: text, state) where mentioned != actor.agentId && mentioned != issue.assigneeAgentId {
            wakes.append(OrgWakeIntent(companyId: companyId, agentId: mentioned, source: "automation", reason: "mention", issueId: issue.id, payload: ["commentId": JSON(comment.id)], requestedByType: actor.actorType, requestedById: actor.actorId))
        }
        record(companyId, actor, "comment.created", "issue", issue.id, ["commentId": JSON(comment.id)])
        dispatch(wakes)
        return ["comment": OrgCodec.json(comment)]
    }

    func mentions(in text: String, _ state: OrgCompanyState) -> [String] {
        var found: [String] = []
        let tokens = text.split(whereSeparator: { $0.isWhitespace || ",.;:!?()[]".contains($0) })
        for token in tokens where token.hasPrefix("@") && token.count > 1 {
            let key = String(token.dropFirst()).lowercased()
            if let agent = state.agents.first(where: { $0.urlKey == key && $0.status != "terminated" }), !found.contains(agent.id) { found.append(agent.id) }
        }
        return found
    }

    // MARK: Checkout

    /// Atomically claims an issue for an agent run.
    func checkoutIssue(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        var agentId = actor.agentId
        if let ref = body.string("agentId") {
            guard let agent = findAgent(state, ref) else { throw orgNotFound("Agent") }
            if agent.id != actor.agentId { try requireGrant(state, actor, "tasks:assign") }
            agentId = agent.id
        }
        guard let agentId else { throw orgInvalid("agentId is required.") }
        if let expected = body.strings("expectedStatuses"), !expected.contains(issue.status) {
            throw orgConflict("\(issue.identifier) is \(issue.status), not \(expected.joined(separator: "/")).")
        }
        var wakes: [OrgWakeIntent] = []
        let updated: OrgIssue = try store.mutateCompany(companyId) { company in
            guard let index = company.issues.firstIndex(where: { $0.id == issue.id }) else { throw orgNotFound("Issue") }
            let current = company.issues[index]
            if let lock = current.checkoutRunId, lock != actor.runId, company.runs.contains(where: { $0.id == lock && $0.status == "running" }) {
                throw orgConflict("\(current.identifier) is already checked out by run \(lock).")
            }
            if current.assigneeAgentId != nil && current.assigneeAgentId != agentId && actor.kind == .agent {
                throw orgConflict("\(current.identifier) is assigned to another agent.")
            }
            guard !current.isTerminal else { throw orgConflict("\(current.identifier) is closed.") }
            guard unresolvedBlockers(company, current).isEmpty else { throw orgConflict("\(current.identifier) is blocked.") }
            company.issues[index].assigneeAgentId = agentId
            company.issues[index].assigneeUserId = nil
            company.issues[index].checkoutRunId = actor.runId
            if current.status != "in_progress" && current.status != "in_review" {
                try applyStatus(&company, index, "in_progress", actor, force: true, wakes: &wakes)
            }
            company.issues[index].updatedAt = now
            return company.issues[index]
        }
        record(companyId, actor, "issue.checked_out", "issue", issue.id, ["agentId": JSON(agentId)])
        dispatch(wakes)
        return ["issue": presentIssue(updated, try company(companyId))]
    }

    func releaseIssue(_ actor: OrgActor, _ companyId: String, _ ref: String) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        guard isBoard(state, actor) || issue.assigneeAgentId == actor.agentId else { throw orgForbidden() }
        let updated: OrgIssue = try store.mutateCompany(companyId) { company in
            guard let index = company.issues.firstIndex(where: { $0.id == issue.id }) else { throw orgNotFound("Issue") }
            company.issues[index].checkoutRunId = nil
            company.issues[index].updatedAt = now
            return company.issues[index]
        }
        record(companyId, actor, "issue.released", "issue", issue.id)
        return ["issue": presentIssue(updated, try company(companyId))]
    }

    // MARK: Documents and work products

    func listDocuments(_ actor: OrgActor, _ companyId: String, _ ref: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        return ["documents": .array(state.documents.filter { $0.issueId == issue.id }.map { doc -> JSON in
            var json = OrgCodec.json(doc).object
            json["revisions"] = .undefined
            return .object(json)
        })]
    }

    func getDocument(_ actor: OrgActor, _ companyId: String, _ ref: String, _ key: String, revision: Int?) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let issue = findIssue(state, ref), let doc = state.documents.first(where: { $0.issueId == issue.id && $0.key == key }) else { throw orgNotFound("Document") }
        if let revision {
            guard let rev = doc.revisions.first(where: { $0.number == revision }) else { throw orgNotFound("Revision") }
            return ["revision": OrgCodec.json(rev)]
        }
        var json = OrgCodec.json(doc).object
        json["revisions"] = .array(doc.revisions.map { ["id": JSON($0.id), "number": JSON($0.number), "changeSummary": JSON($0.changeSummary), "createdBy": JSON($0.createdBy), "createdAt": JSON($0.createdAt)] })
        return ["document": .object(json)]
    }

    /// Writes a document revision; `baseRevisionId` gives compare-and-swap semantics.
    func putDocument(_ actor: OrgActor, _ companyId: String, _ ref: String, _ key: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        let cleanKey = OrgIDs.slug(key, fallback: "")
        guard !cleanKey.isEmpty else { throw orgInvalid("Document keys use letters, digits and dashes.") }
        guard let text = body.text("body", max: 1_000_000) else { throw requestError("body is required.") }
        let author = "\(actor.actorType):\(actor.actorId ?? "system")"
        let doc: OrgDocument = try store.mutateCompany(companyId) { company in
            let stamp = now
            if let index = company.documents.firstIndex(where: { $0.issueId == issue.id && $0.key == cleanKey }) {
                if let base = body.string("baseRevisionId"), base != company.documents[index].revisionId {
                    throw orgConflict("Document changed; latest revision is \(company.documents[index].revisionId).")
                }
                if let lockedBy = company.documents[index].lockedBy, lockedBy != author { throw orgConflict("Document is locked by \(lockedBy).") }
                let number = company.documents[index].revisionNumber + 1
                let revision = OrgDocumentRevision(id: OrgIDs.make("rev"), number: number, title: body.string("title", max: 300) ?? company.documents[index].title, body: text, changeSummary: body.string("changeSummary", max: 500), createdBy: author, createdAt: stamp)
                company.documents[index].revisions.append(revision)
                company.documents[index].revisions.orgCap(100)
                company.documents[index].title = revision.title
                company.documents[index].body = text
                company.documents[index].revisionNumber = number
                company.documents[index].revisionId = revision.id
                company.documents[index].updatedAt = stamp
                return company.documents[index]
            }
            let revision = OrgDocumentRevision(id: OrgIDs.make("rev"), number: 1, title: body.string("title", max: 300) ?? cleanKey, body: text, changeSummary: body.string("changeSummary", max: 500), createdBy: author, createdAt: stamp)
            let doc = OrgDocument(id: OrgIDs.make("doc"), companyId: companyId, issueId: issue.id, key: cleanKey, title: revision.title, body: text, revisionNumber: 1, revisionId: revision.id, revisions: [revision], createdAt: stamp, updatedAt: stamp)
            company.documents.append(doc)
            return doc
        }
        record(companyId, actor, "document.saved", "issue", issue.id, ["key": JSON(cleanKey), "revision": JSON(doc.revisionNumber)])
        var json = OrgCodec.json(doc).object
        json["revisions"] = .undefined
        return ["document": .object(json)]
    }

    func addWorkProduct(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
        let type = try body.oneOf("type", ["artifact", "document", "branch", "commit", "pull_request", "preview_url"]) ?? "artifact"
        let product = OrgWorkProduct(id: OrgIDs.make("wp"), companyId: companyId, issueId: issue.id, type: type, title: try body.required("title", max: 300),
                                     url: body.string("url", max: 2_000), summary: body.text("summary", max: 10_000), createdByRunId: actor.runId, createdAt: now)
        try store.mutateCompany(companyId) { $0.workProducts.append(product) }
        record(companyId, actor, "work_product.created", "issue", issue.id, ["type": JSON(type)])
        return ["workProduct": OrgCodec.json(product)]
    }

    // MARK: Inbox

    func inbox(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let mine = state.issues.filter { issue in
            !issue.isTerminal && ((actor.agentId != nil && issue.assigneeAgentId == actor.agentId) || (actor.kind != .agent && issue.assigneeUserId == (actor.userId ?? OrgService.ownerUserId)))
        }
        let reviews = state.issues.filter { issue in
            guard let participant = issue.executionState?.currentParticipant, issue.executionState?.status == "pending" else { return false }
            return (participant.type == "agent" && participant.id == actor.agentId) || (participant.type == "user" && participant.id == (actor.userId ?? OrgService.ownerUserId))
        }
        let approvals = isBoard(state, actor) ? state.approvals.filter { $0.status == "pending" || $0.status == "revision_requested" } : []
        let joins = hasGrant(state, actor, "joins:approve") ? state.joinRequests.filter { $0.status == "pending_approval" } : []
        let blockedForBoard = isBoard(state, actor) ? state.issues.filter { $0.status == "blocked" && $0.unblockOwner == "board" } : []
        return [
            "assigned": .array(mine.map { presentIssue($0, state) }),
            "reviews": .array(reviews.map { presentIssue($0, state) }),
            "approvals": .array(approvals.map { OrgCodec.json($0) }),
            "joinRequests": .array(joins.map(redactJoin)),
            "blockedForBoard": .array(blockedForBoard.map { presentIssue($0, state) }),
        ]
    }
}
