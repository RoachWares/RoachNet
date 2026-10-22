import Foundation

struct OrgWakeIntent {
    var companyId: String
    var agentId: String
    var source: String
    var reason: String
    var issueId: String?
    var payload: JSON = .object(JSONObject())
    var requestedByType: String
    var requestedById: String?
}

final class OrgService {
    static let adapterTypes: Set<String> = Set(
        ["roachclaw_local", "openai_compatible", "http", "process"] + OrgCLIKind.allCases.map(\.rawValue))
    static let hostAdapterTypes: Set<String> = Set(["process"] + OrgCLIKind.allCases.map(\.rawValue))

    static func usesPlanModel(adapterType: String, adapterConfig: JSON) -> Bool {
        adapterType == "roachclaw_local"
            && SubscriptionModels.parse(OrgBody(adapterConfig).string("model") ?? "") != nil
    }

    static func ownerOnlyAdapter(type: String, config: JSON) -> Bool {
        hostAdapterTypes.contains(type) || usesPlanModel(adapterType: type, adapterConfig: config)
    }

    private func soloOwnerCompany(_ state: OrgCompanyState) -> Bool {
        !state.memberships.contains { $0.principalType == "user" && $0.principalId != OrgService.ownerUserId }
    }

    private func aspectChosenByOwner(_ agent: OrgAgent, _ aspect: (JSON) -> String?) -> Bool {
        guard let value = aspect(OrgService.agentConfig(agent)) else { return true }
        guard let state = try? company(agent.companyId) else { return false }
        if let setter = state.configRevisions.last(where: {
            $0.agentId == agent.id && aspect($0.afterConfig) == value && aspect($0.beforeConfig) != value
        }) {
            return setter.createdBy == OrgService.ownerUserId || setter.createdBy == "system"
        }
        return soloOwnerCompany(state)
    }

    func planModelChosenByOwner(_ agent: OrgAgent) -> Bool {
        let explicit = OrgBody(agent.adapterConfig).string("model")
        guard SubscriptionModels.parse(explicit ?? runtime.defaultModel) != nil else { return true }
        if explicit == nil { return agentDefaultPlanAllowed(agent) }
        return aspectChosenByOwner(agent) { OrgBody($0["adapterConfig"]).string("model") }
    }

    private func agentDefaultPlanAllowed(_ agent: OrgAgent) -> Bool {
        guard let state = try? company(agent.companyId) else { return false }
        if soloOwnerCompany(state) { return true }
        guard let creation = state.configRevisions.first(where: { $0.agentId == agent.id && $0.source == "create" })
        else { return false }
        return creation.createdBy == OrgService.ownerUserId || creation.createdBy == "system"
    }

    func localEndpointChosenByOwner(_ agent: OrgAgent) -> Bool {
        aspectChosenByOwner(agent) {
            OrgAdapters.localEndpointHost(type: $0["adapterType"].stringValue ?? "", config: $0["adapterConfig"])
        }
    }
    static let memberRoles: Set<String> = ["owner", "admin", "operator", "viewer"]
    static let grants: Set<String> = [
        "agents:create", "users:invite", "users:manage_permissions", "tasks:assign", "joins:approve", "budgets:manage",
        "secrets:manage",
    ]
    static let ownerUserId = "user_local_owner"

    unowned let runtime: NativeRuntime
    let store: OrgStore
    private(set) var engine: OrgEngine!

    init(runtime: NativeRuntime, root: String? = nil) {
        self.runtime = runtime
        let base = root ?? Path.join(runtime.storageRoot, "RoachClaw", "org")
        store = OrgStore(root: base)
        ensureOwnerUser()
        engine = OrgEngine(service: self)
    }

    var root: String { store.root }
    var now: String { JS.isoNow() }

    private func ensureOwnerUser() {
        guard !store.instance.users.contains(where: { $0.id == OrgService.ownerUserId }) else { return }
        let name = ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? "Owner"
        try? store.mutateInstance { state in
            state.users.insert(
                OrgUser(id: OrgService.ownerUserId, name: name, email: nil, roachTailPeerIds: [], createdAt: now), at: 0
            )
        }
    }

    func record(
        _ companyId: String, _ actor: OrgActor, _ action: String, _ entityType: String, _ entityId: String,
        _ details: JSON = .object(JSONObject())
    ) {
        store.appendActivity(
            OrgActivity(
                id: OrgIDs.make("act"), companyId: companyId, actorType: actor.actorType, actorId: actor.actorId,
                action: action, entityType: entityType, entityId: entityId, agentId: actor.agentId, runId: actor.runId,
                details: details, createdAt: now))
    }

    func dispatch(_ wakes: [OrgWakeIntent]) {
        for wake in wakes { engine.enqueue(wake) }
    }

    func health() -> JSON {
        let problems = store.instanceProblem.map { [$0.json] } ?? []
        return [
            "status": JSON(problems.isEmpty ? "ok" : "degraded"), "engine": "native",
            "companies": JSON(store.companyIds.count), "problems": .array(problems),
        ]
    }

    func company(_ id: String) throws -> OrgCompanyState {
        guard let state = store.company(id) else { throw orgNotFound("Company") }
        return state
    }

    func membership(_ state: OrgCompanyState, _ actor: OrgActor) -> OrgMembership? {
        guard let userId = actor.userId else { return nil }
        return state.memberships.first {
            $0.principalType == "user" && $0.principalId == userId && $0.status == "active"
        }
    }

    func scopeAllows(_ state: OrgCompanyState, _ actor: OrgActor) -> Bool {
        actor.companyId == nil || actor.companyId == state.company.id
    }

    func canRead(_ state: OrgCompanyState, _ actor: OrgActor) -> Bool {
        guard scopeAllows(state, actor) else { return false }
        if actor.isOwner { return true }
        if actor.kind == .agent { return state.agents.contains { $0.id == actor.agentId && $0.status != "terminated" } }
        return membership(state, actor) != nil
    }

    func requireRead(_ state: OrgCompanyState, _ actor: OrgActor) throws {
        guard canRead(state, actor) else {
            throw store.company(state.company.id) == nil ? orgNotFound("Company") : orgForbidden()
        }
    }

    func requireWrite(_ state: OrgCompanyState, _ actor: OrgActor) throws {
        try requireRead(state, actor)
        if actor.isOwner || actor.kind == .agent { return }
        guard let role = membership(state, actor)?.role, role != "viewer" else {
            throw orgForbidden("Viewers cannot change this company.")
        }
    }

    func isBoard(_ state: OrgCompanyState, _ actor: OrgActor) -> Bool {
        guard scopeAllows(state, actor) else { return false }
        if actor.isOwner { return true }
        guard actor.kind == .user, let role = membership(state, actor)?.role else { return false }
        return role == "owner" || role == "admin"
    }

    func requireBoard(_ state: OrgCompanyState, _ actor: OrgActor) throws {
        try requireRead(state, actor)
        guard isBoard(state, actor) else { throw orgForbidden("Only the company board (owner or admin) can do that.") }
    }

    func hasGrant(_ state: OrgCompanyState, _ actor: OrgActor, _ grant: String) -> Bool {
        guard scopeAllows(state, actor) else { return false }
        if isBoard(state, actor) { return true }
        if actor.kind == .agent, let agent = state.agents.first(where: { $0.id == actor.agentId }) {
            switch grant {
            case "agents:create": return agent.canCreateAgents
            case "tasks:assign": return agent.canAssignTasks
            default: return false
            }
        }
        guard let member = membership(state, actor) else { return false }
        if member.grants.contains(grant) { return true }
        return member.role == "operator" && grant == "tasks:assign"
    }

    func requireGrant(_ state: OrgCompanyState, _ actor: OrgActor, _ grant: String) throws {
        try requireRead(state, actor)
        guard hasGrant(state, actor, grant) else { throw orgForbidden("Missing permission \(grant).") }
    }

    static func roleRank(_ role: String?) -> Int {
        switch role {
        case "owner": return 3
        case "admin": return 2
        case "operator": return 1
        default: return 0
        }
    }

    static func isSelf(_ actor: OrgActor, principalType: String, principalId: String) -> Bool {
        switch actor.kind {
        case .agent: return principalType == "agent" && actor.agentId == principalId
        case .user, .owner: return principalType == "user" && actor.userId == principalId
        case .system: return false
        }
    }

    func authorizeMembershipChange(
        _ state: OrgCompanyState, _ actor: OrgActor, target: OrgMembership?, newRole: String?, newGrants: [String]?,
        newStatus: String? = nil
    ) throws {
        try requireGrant(state, actor, "users:manage_permissions")
        if let target, target.principalType != "user", newRole != nil || newGrants != nil {
            throw orgInvalid("Roles and grants are for people. An agent's permissions come from its own settings.")
        }
        if actor.isOwner { return }
        guard actor.kind == .user, let mine = membership(state, actor) else { throw orgForbidden() }
        if let target, OrgService.isSelf(actor, principalType: target.principalType, principalId: target.principalId) {
            throw orgForbidden("You can't change your own membership.")
        }
        let rank = OrgService.roleRank(mine.role)
        if let target, OrgService.roleRank(target.role) >= rank {
            throw orgForbidden("You can change only members ranked below you.")
        }
        if let newRole, OrgService.roleRank(newRole) >= rank, !(newRole == "owner" && mine.role == "owner") {
            throw orgForbidden("You can't give a role at or above your own.")
        }
        if let newGrants, rank < OrgService.roleRank("admin") {
            let changed = Set(target?.grants ?? []).symmetricDifference(newGrants)
            let mayHandOut = Set(mine.grants).subtracting(["users:manage_permissions"])
            guard changed.isSubset(of: mayHandOut) else {
                throw orgForbidden("You can hand out only grants you hold, and never users:manage_permissions.")
            }
        }
        if newStatus != nil, let target, rank < OrgService.roleRank("admin") {
            let mayManage = Set(mine.grants).subtracting(["users:manage_permissions"])
            guard Set(target.grants).isSubset(of: mayManage) else {
                throw orgForbidden(
                    "You can change the status only of members whose grants you hold, and never of one that may manage permissions."
                )
            }
        }
    }

    func requireRanksAbove(_ state: OrgCompanyState, _ actor: OrgActor, _ role: String, _ why: String) throws {
        if actor.isOwner { return }
        guard actor.kind == .user, let mine = membership(state, actor) else { throw orgForbidden() }
        guard OrgService.roleRank(role) < OrgService.roleRank(mine.role) else { throw orgForbidden(why) }
    }

    func me(_ actor: OrgActor) -> JSON {
        var result = actor.json.object
        if let userId = actor.userId, let user = store.instance.users.first(where: { $0.id == userId }) {
            result["user"] = OrgCodec.json(user)
        }
        let companies = store.allCompanies().filter { canRead($0, actor) }.map { state -> JSON in
            [
                "id": JSON(state.company.id), "name": JSON(state.company.name), "board": JSON(isBoard(state, actor)),
                "role": JSON(actor.isOwner ? "owner" : membership(state, actor)?.role),
            ]
        }
        result["companies"] = .array(companies)
        return .object(result)
    }

    func listUsers(_ actor: OrgActor) throws -> JSON {
        guard actor.isOwner || actor.kind == .user else { throw orgForbidden() }
        return ["users": .array(store.instance.users.map { OrgCodec.json($0) })]
    }

    func createUser(_ actor: OrgActor, _ body: OrgBody) throws -> JSON {
        guard actor.isOwner else { throw orgForbidden("Only the RoachNet owner can add people.") }
        let name = try body.required("name", max: 120)
        let peers = body.strings("roachTailPeerIds") ?? []
        try assertPeersUnclaimed(peers, except: nil)
        let user = OrgUser(
            id: OrgIDs.make("user"), name: name, email: body.string("email", max: 200), roachTailPeerIds: peers,
            createdAt: now)
        try store.mutateInstance { $0.users.append(user) }
        return ["user": OrgCodec.json(user)]
    }

    func updateUser(_ actor: OrgActor, _ userId: String, _ body: OrgBody) throws -> JSON {
        guard actor.isOwner || actor.userId == userId else { throw orgForbidden() }
        let updated: OrgUser = try store.mutateInstance { state in
            guard let index = state.users.firstIndex(where: { $0.id == userId }) else { throw orgNotFound("User") }
            if let name = body.string("name", max: 120) { state.users[index].name = name }
            if let email = body.nullable("email", max: 200) { state.users[index].email = email }
            if let peers = body.strings("roachTailPeerIds") {
                guard actor.isOwner else { throw orgForbidden("Only the owner can link RoachTail devices.") }
                for peer in peers
                where state.users.contains(where: { $0.id != userId && $0.roachTailPeerIds.contains(peer) }) {
                    throw orgConflict("RoachTail device \(peer) is already linked to another person.")
                }
                state.users[index].roachTailPeerIds = peers
            }
            return state.users[index]
        }
        return ["user": OrgCodec.json(updated)]
    }

    private func assertPeersUnclaimed(_ peers: [String], except userId: String?) throws {
        for peer in peers
        where store.instance.users.contains(where: { $0.id != userId && $0.roachTailPeerIds.contains(peer) }) {
            throw orgConflict("RoachTail device \(peer) is already linked to another person.")
        }
    }

    func listCompanies(_ actor: OrgActor) -> JSON {
        ["companies": .array(store.allCompanies().filter { canRead($0, actor) }.map { OrgCodec.json($0.company) })]
    }

    func createCompany(_ actor: OrgActor, _ body: OrgBody) throws -> JSON {
        guard actor.isOwner || actor.kind == .user, actor.userId != nil || actor.isOwner else {
            throw orgForbidden("Only people can create companies.")
        }
        let name = try body.required("name", max: 120)
        var prefix = (body.string("issuePrefix", max: 8) ?? OrgIDs.issuePrefix(name)).uppercased()
        prefix = String(
            prefix.unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
        if prefix.isEmpty { prefix = "ORG" }
        let stamp = now
        let company = OrgCompany(
            id: OrgIDs.make("co"), name: name, description: body.text("description", max: 4_000),
            issuePrefix: prefix, budgetMonthlyCents: body.amount("budgetMonthlyCents") ?? 0,
            requireBoardApprovalForNewAgents: body.bool("requireBoardApprovalForNewAgents") ?? false,
            createdAt: stamp, updatedAt: stamp)
        var state = OrgCompanyState(company: company)
        let creator = actor.userId ?? OrgService.ownerUserId
        state.memberships.append(
            OrgMembership(
                id: OrgIDs.make("mem"), companyId: company.id, principalType: "user", principalId: creator,
                role: "owner", grants: Array(OrgService.grants), createdAt: stamp, updatedAt: stamp))
        if company.budgetMonthlyCents > 0 {
            upsertImplicitBudget(&state, scopeType: "company", scopeId: company.id, cents: company.budgetMonthlyCents)
        }
        try store.insertCompany(state)
        record(company.id, actor, "company.created", "company", company.id, ["name": JSON(name)])
        return ["company": OrgCodec.json(company)]
    }

    func getCompany(_ actor: OrgActor, _ id: String) throws -> JSON {
        let state = try company(id)
        try requireRead(state, actor)
        return ["company": OrgCodec.json(state.company)]
    }

    func updateCompany(_ actor: OrgActor, _ id: String, _ body: OrgBody) throws -> JSON {
        try requireBoard(try company(id), actor)
        let updated: OrgCompany = try store.mutateCompany(id) { state in
            if let name = body.string("name", max: 120) { state.company.name = name }
            if body.has("description") { state.company.description = body.text("description", max: 4_000) }
            if let value = body.bool("requireBoardApprovalForNewAgents") {
                state.company.requireBoardApprovalForNewAgents = value
            }
            if let cents = body.amount("budgetMonthlyCents") {
                state.company.budgetMonthlyCents = max(0, cents)
                upsertImplicitBudget(&state, scopeType: "company", scopeId: state.company.id, cents: max(0, cents))
            }
            return state.company
        }
        record(id, actor, "company.updated", "company", id)
        return ["company": OrgCodec.json(updated)]
    }

    func setCompanyStatus(_ actor: OrgActor, _ id: String, _ action: String) throws -> JSON {
        try requireBoard(try company(id), actor)
        let updated: OrgCompany = try store.mutateCompany(id) { state in
            switch action {
            case "pause":
                guard state.company.status == "active" else { throw orgConflict("Company is not active.") }
                state.company.status = "paused"
                state.company.pauseReason = "manual"
                state.company.pausedAt = now
            case "resume":
                guard state.company.status == "paused" else { throw orgConflict("Company is not paused.") }
                state.company.status = "active"
                state.company.pauseReason = nil
                state.company.pausedAt = nil
            case "archive":
                state.company.status = "archived"
                state.company.pauseReason = "company_archived"
                state.company.pausedAt = now
            default: throw orgNotFound("Action")
            }
            return state.company
        }
        record(id, actor, "company.\(action)", "company", id)
        if action == "resume" { engine.kick(id) }
        return ["company": OrgCodec.json(updated)]
    }

    func listMembers(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let users = store.instance.users
        let members = state.memberships.map { member -> JSON in
            var json = OrgCodec.json(member).object
            if member.principalType == "user", let user = users.first(where: { $0.id == member.principalId }) {
                json["user"] = ["id": JSON(user.id), "name": JSON(user.name), "email": JSON(user.email)]
            }
            return .object(json)
        }
        return ["members": .array(members)]
    }

    func addMember(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        try requireGrant(try company(companyId), actor, "users:manage_permissions")
        let userId = try body.required("userId")
        if let problem = store.instanceProblem { throw orgUnavailable(problem.message) }
        guard store.instance.users.contains(where: { $0.id == userId }) else { throw orgNotFound("User") }
        let role = try body.oneOf("role", OrgService.memberRoles) ?? "operator"
        let grants = try validatedGrants(body.strings("grants") ?? [])
        let member: OrgMembership = try store.mutateCompany(companyId) { state in
            try authorizeMembershipChange(state, actor, target: nil, newRole: role, newGrants: grants)
            if state.memberships.contains(where: {
                $0.principalType == "user" && $0.principalId == userId && $0.status != "archived"
            }) {
                throw orgConflict("That person is already a member.")
            }
            let member = OrgMembership(
                id: OrgIDs.make("mem"), companyId: companyId, principalType: "user", principalId: userId, role: role,
                grants: grants, createdAt: now, updatedAt: now)
            state.memberships.append(member)
            return member
        }
        record(companyId, actor, "member.added", "membership", member.id, ["userId": JSON(userId), "role": JSON(role)])
        return ["member": OrgCodec.json(member)]
    }

    func updateMember(_ actor: OrgActor, _ companyId: String, _ memberId: String, _ body: OrgBody) throws -> JSON {
        try requireGrant(try company(companyId), actor, "users:manage_permissions")
        let role = try body.oneOf("role", OrgService.memberRoles)
        let status = try body.oneOf("status", ["active", "suspended", "archived"])
        let grants = try body.strings("grants").map(validatedGrants)
        let member: OrgMembership = try store.mutateCompany(companyId) { state in
            guard let index = state.memberships.firstIndex(where: { $0.id == memberId }) else {
                throw orgNotFound("Member")
            }
            let current = state.memberships[index]
            try authorizeMembershipChange(
                state, actor, target: current, newRole: role, newGrants: grants, newStatus: status)
            if let status, status != "archived",
                state.memberships.contains(where: {
                    $0.id != current.id && $0.principalType == current.principalType
                        && $0.principalId == current.principalId && $0.status != "archived"
                })
            {
                throw orgConflict(
                    "This member has another membership in this company that isn't archived. Archive that one first.")
            }
            let removesOwner =
                current.principalType == "user" && current.role == "owner"
                && ((role != nil && role != "owner") || (status != nil && status != "active"))
            let activeOwners = state.memberships.filter {
                $0.principalType == "user" && $0.role == "owner" && $0.status == "active"
            }.count
            if removesOwner && activeOwners <= 1 {
                throw orgConflict("A company needs at least one active owner.")
            }
            if let role { state.memberships[index].role = role }
            if let status { state.memberships[index].status = status }
            if let grants { state.memberships[index].grants = grants }
            state.memberships[index].updatedAt = now
            return state.memberships[index]
        }
        record(companyId, actor, "member.updated", "membership", memberId)
        return ["member": OrgCodec.json(member)]
    }

    private func validatedGrants(_ grants: [String]) throws -> [String] {
        for grant in grants where !OrgService.grants.contains(grant) { throw orgInvalid("Unknown grant \(grant).") }
        return Array(Set(grants)).sorted()
    }

    func createInvite(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        try requireGrant(try company(companyId), actor, "users:invite")
        let role = try body.oneOf("role", ["admin", "operator", "viewer"]) ?? "operator"
        let joinTypes = try body.oneOf("allowedJoinTypes", ["human", "agent", "both"]) ?? "human"
        let hours = min(max(body.int("expiresInHours") ?? 72, 1), 24 * 30)
        let token = "rninv_\(JS.randomHex(40))"
        let invite = OrgInvite(
            id: OrgIDs.make("inv"), companyId: companyId, tokenHash: SHA256Digest.hex(token), role: role,
            allowedJoinTypes: joinTypes, expiresAt: JS.iso(Date().addingTimeInterval(Double(hours) * 3600)),
            invitedByUserId: actor.userId ?? OrgService.ownerUserId, createdAt: now)
        try store.mutateCompany(companyId) { state in
            try requireGrant(state, actor, "users:invite")
            try requireRanksAbove(state, actor, role, "You can invite people only to a role below your own.")
            state.invites.append(invite)
        }
        record(companyId, actor, "invite.created", "invite", invite.id, ["role": JSON(role)])
        return ["invite": redactInvite(invite), "token": JSON(token)]
    }

    func redactInvite(_ invite: OrgInvite) -> JSON {
        var json = OrgCodec.json(invite).object
        json["tokenHash"] = .undefined
        return .object(json)
    }

    func listInvites(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireGrant(state, actor, "users:invite")
        return ["invites": .array(state.invites.map(redactInvite))]
    }

    func revokeInvite(_ actor: OrgActor, _ companyId: String, _ inviteId: String) throws -> JSON {
        try requireGrant(try company(companyId), actor, "users:invite")
        let invite: OrgInvite = try store.mutateCompany(companyId) { state in
            guard let index = state.invites.firstIndex(where: { $0.id == inviteId }) else {
                throw orgNotFound("Invite")
            }
            state.invites[index].revokedAt = state.invites[index].revokedAt ?? now
            return state.invites[index]
        }
        record(companyId, actor, "invite.revoked", "invite", inviteId)
        return ["invite": redactInvite(invite)]
    }

    func acceptInvite(_ actor: OrgActor, _ body: OrgBody, peerId: String?) throws -> JSON {
        let token = try body.required("token", max: 128)
        let hash = SHA256Digest.hex(token)
        guard
            let state = store.allCompanies().first(where: {
                $0.invites.contains { orgConstantTimeEquals($0.tokenHash, hash) }
            }),
            let invite = state.invites.first(where: { orgConstantTimeEquals($0.tokenHash, hash) })
        else {
            throw orgNotFound("Invite")
        }
        guard invite.revokedAt == nil, invite.acceptedAt == nil else {
            throw orgConflict("This invite is no longer valid.")
        }
        guard (JS.parseDate(invite.expiresAt) ?? 0) > JS.nowMs() else { throw orgConflict("This invite has expired.") }
        let requestType = try body.oneOf("requestType", ["human", "agent"]) ?? "human"
        guard invite.allowedJoinTypes == "both" || invite.allowedJoinTypes == requestType else {
            throw orgInvalid("This invite does not allow \(requestType) joins.")
        }
        var request = OrgJoinRequest(
            id: OrgIDs.make("join"), companyId: state.company.id, inviteId: invite.id, requestType: requestType,
            createdAt: now)
        var claimSecret: String?
        if requestType == "human" {
            request.userName = try body.required("userName", max: 120)
            request.email = body.string("email", max: 200)
            request.roachTailPeerId = peerId
        } else {
            request.agentName = try body.required("agentName", max: 120)
            request.adapterType = try body.oneOf("adapterType", ["http", "openai_compatible"]) ?? "http"
            let secret = "rnclaim_\(JS.randomHex(32))"
            request.claimSecretHash = SHA256Digest.hex(secret)
            claimSecret = secret
        }
        try store.mutateCompany(state.company.id) { company in
            company.joinRequests.append(request)
            if let index = company.invites.firstIndex(where: { $0.id == invite.id }) {
                company.invites[index].acceptedAt = now
            }
        }
        record(state.company.id, actor, "join.requested", "join_request", request.id, ["type": JSON(requestType)])
        return [
            "joinRequest": redactJoin(request), "claimSecret": JSON(claimSecret),
            "companyName": JSON(state.company.name),
        ]
    }

    func redactJoin(_ request: OrgJoinRequest) -> JSON {
        var json = OrgCodec.json(request).object
        json["claimSecretHash"] = .undefined
        return .object(json)
    }

    func joinRole(_ request: OrgJoinRequest, _ state: OrgCompanyState) -> String {
        state.invites.first(where: { $0.id == request.inviteId })?.role ?? "operator"
    }

    func joinForApprovers(_ request: OrgJoinRequest, _ state: OrgCompanyState) -> JSON {
        var json = redactJoin(request).object
        json["role"] = request.requestType == "human" ? JSON(joinRole(request, state)) : .null
        return .object(json)
    }

    func listJoinRequests(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireGrant(state, actor, "joins:approve")
        return ["joinRequests": .array(state.joinRequests.map { joinForApprovers($0, state) })]
    }

    func decideJoinRequest(_ actor: OrgActor, _ companyId: String, _ requestId: String, approve: Bool) throws -> JSON {
        let decided: JSON = try store.mutateCompany(companyId) { company in
            try requireGrant(company, actor, "joins:approve")
            guard let index = company.joinRequests.firstIndex(where: { $0.id == requestId }) else {
                throw orgNotFound("Join request")
            }
            let request = company.joinRequests[index]
            guard request.status == "pending_approval" else { throw orgConflict("This request was already decided.") }
            let role = joinRole(request, company)
            if approve, request.requestType != "agent" {
                try requireRanksAbove(company, actor, role, "You can approve joins only to a role below your own.")
            }
            company.joinRequests[index].status = approve ? "approved" : "rejected"
            company.joinRequests[index].decidedAt = now
            company.joinRequests[index].decidedByUserId = actor.userId ?? OrgService.ownerUserId
            if approve && request.requestType == "human" {
                let user: OrgUser
                if let peer = request.roachTailPeerId,
                    let existing = store.instance.users.first(where: { $0.roachTailPeerIds.contains(peer) })
                {
                    user = existing
                } else {
                    user = OrgUser(
                        id: OrgIDs.make("user"), name: request.userName ?? "Member", email: request.email,
                        roachTailPeerIds: request.roachTailPeerId.map { [$0] } ?? [], createdAt: now)
                    try store.mutateInstance { $0.users.append(user) }
                }
                if !company.memberships.contains(where: { $0.principalId == user.id }) {
                    company.memberships.append(
                        OrgMembership(
                            id: OrgIDs.make("mem"), companyId: companyId, principalType: "user", principalId: user.id,
                            role: role, createdAt: now, updatedAt: now))
                }
                company.joinRequests[index].createdUserId = user.id
            }
            if approve && request.requestType == "agent" {
                var agent = newAgent(company, name: request.agentName ?? "Agent", role: "general")
                agent.adapterType = request.adapterType ?? "http"
                agent.reportsTo = company.agents.first(where: { $0.role == "ceo" && $0.status != "terminated" })?.id
                company.agents.append(agent)
                company.memberships.append(
                    OrgMembership(
                        id: OrgIDs.make("mem"), companyId: companyId, principalType: "agent", principalId: agent.id,
                        role: nil, createdAt: now, updatedAt: now))
                company.joinRequests[index].createdAgentId = agent.id
            }
            return joinForApprovers(company.joinRequests[index], company)
        }
        record(companyId, actor, approve ? "join.approved" : "join.rejected", "join_request", requestId)
        return ["joinRequest": decided]
    }

    func claimJoinRequest(_ actor: OrgActor, _ requestId: String, _ body: OrgBody) throws -> JSON {
        let secret = try body.required("claimSecret", max: 128)
        guard let state = store.allCompanies().first(where: { $0.joinRequests.contains { $0.id == requestId } }),
            let request = state.joinRequests.first(where: { $0.id == requestId })
        else { throw orgNotFound("Join request") }
        guard let hash = request.claimSecretHash, orgConstantTimeEquals(hash, SHA256Digest.hex(secret)) else {
            throw orgForbidden("Invalid claim secret.")
        }
        guard request.status == "approved", let agentId = request.createdAgentId else {
            throw orgConflict("This request has not been approved.")
        }
        guard request.claimedAt == nil else { throw orgConflict("This request was already claimed.") }
        let (key, plaintext) = makeAPIKey(
            companyId: state.company.id, principalType: "agent", principalId: agentId, name: "join claim")
        try store.mutateCompany(state.company.id) { company in
            guard let index = company.joinRequests.firstIndex(where: { $0.id == requestId }) else {
                throw orgNotFound("Join request")
            }
            guard company.joinRequests[index].status == "approved",
                company.joinRequests[index].createdAgentId == agentId
            else {
                throw orgConflict("This request has not been approved.")
            }
            guard company.joinRequests[index].claimedAt == nil else {
                throw orgConflict("This request was already claimed.")
            }
            company.apiKeys.append(key)
            company.joinRequests[index].claimedAt = now
        }
        record(state.company.id, actor, "join.claimed", "join_request", requestId)
        return [
            "apiKey": redactKey(key), "key": JSON(plaintext), "agentId": JSON(agentId),
            "companyId": JSON(state.company.id),
        ]
    }

    func makeAPIKey(companyId: String?, principalType: String, principalId: String, name: String) -> (OrgAPIKey, String)
    {
        let plaintext = "rnorg_\(JS.randomHex(40))"
        let key = OrgAPIKey(
            id: OrgIDs.make("key"), companyId: companyId, principalType: principalType, principalId: principalId,
            name: name, keyHash: SHA256Digest.hex(plaintext), prefix: String(plaintext.prefix(12)), createdAt: now)
        return (key, plaintext)
    }

    func redactKey(_ key: OrgAPIKey) -> JSON {
        var json = OrgCodec.json(key).object
        json["keyHash"] = .undefined
        return .object(json)
    }

    func listKeys(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let visible = state.apiKeys.filter { key in
            isBoard(state, actor) || (key.principalType == "user" && key.principalId == actor.userId)
        }
        return ["keys": .array(visible.map(redactKey))]
    }

    func createKey(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard actor.kind != .agent else { throw orgForbidden("Agents cannot mint keys.") }
        let name = body.string("name", max: 80) ?? "API key"
        var principalType = "user"
        var principalId = actor.userId ?? OrgService.ownerUserId
        if let agentId = body.string("agentId") {
            try requireBoard(state, actor)
            guard state.agents.contains(where: { $0.id == agentId && $0.status != "terminated" }) else {
                throw orgNotFound("Agent")
            }
            principalType = "agent"
            principalId = agentId
        }
        let (key, plaintext) = makeAPIKey(
            companyId: companyId, principalType: principalType, principalId: principalId, name: name)
        try store.mutateCompany(companyId) { $0.apiKeys.append(key) }
        record(companyId, actor, "key.created", "api_key", key.id, ["principalType": JSON(principalType)])
        return ["apiKey": redactKey(key), "key": JSON(plaintext)]
    }

    func revokeKey(_ actor: OrgActor, _ companyId: String, _ keyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let key = state.apiKeys.first(where: { $0.id == keyId }) else { throw orgNotFound("Key") }
        guard isBoard(state, actor) || (key.principalType == "user" && key.principalId == actor.userId) else {
            throw orgForbidden()
        }
        let revoked: OrgAPIKey = try store.mutateCompany(companyId) { company in
            guard let index = company.apiKeys.firstIndex(where: { $0.id == keyId }) else { throw orgNotFound("Key") }
            company.apiKeys[index].revokedAt = company.apiKeys[index].revokedAt ?? now
            return company.apiKeys[index]
        }
        record(companyId, actor, "key.revoked", "api_key", keyId)
        return ["apiKey": redactKey(revoked)]
    }

    func newAgent(_ state: OrgCompanyState, name: String, role: String) -> OrgAgent {
        var urlKey = OrgIDs.slug(name, fallback: "agent")
        var suffix = 2
        let base = urlKey
        while state.agents.contains(where: { $0.urlKey == urlKey }) {
            urlKey = "\(base)-\(suffix)"
            suffix += 1
        }
        let stamp = now
        return OrgAgent(
            id: OrgIDs.make("agent"), companyId: state.company.id, name: name, urlKey: urlKey, role: role,
            createdAt: stamp, updatedAt: stamp)
    }

    func findAgent(_ state: OrgCompanyState, _ ref: String) -> OrgAgent? {
        state.agents.first { $0.id == ref || $0.urlKey == ref.lowercased() }
    }

    static func agentConfig(_ agent: OrgAgent) -> JSON {
        [
            "name": JSON(agent.name), "role": JSON(agent.role), "title": JSON(agent.title), "icon": JSON(agent.icon),
            "reportsTo": JSON(agent.reportsTo), "capabilities": JSON(agent.capabilities),
            "adapterType": JSON(agent.adapterType), "adapterConfig": agent.adapterConfig,
            "heartbeat": OrgCodec.json(agent.heartbeat), "budgetMonthlyCents": JSON(agent.budgetMonthlyCents),
            "canCreateAgents": JSON(agent.canCreateAgents), "canAssignTasks": JSON(agent.canAssignTasks),
            "desiredSkills": JSON(agent.desiredSkills), "instructions": JSON(agent.instructions),
        ]
    }

    func listAgents(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["agents": .array(state.agents.map { presentAgent($0, state, actor) })]
    }

    func presentAgent(_ agent: OrgAgent, _ state: OrgCompanyState, _ actor: OrgActor) -> JSON {
        var json = OrgCodec.json(agent).object
        if !isBoard(state, actor) && actor.agentId != agent.id {
            json["adapterConfig"] = .undefined
            json["sessionState"] = .undefined
        }
        json["activeRunCount"] = JSON(state.runs.filter { $0.agentId == agent.id && $0.status == "running" }.count)
        return .object(json)
    }

    func getAgent(_ actor: OrgActor, _ companyId: String, _ ref: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        guard let agent = findAgent(state, ref) else { throw orgNotFound("Agent") }
        return ["agent": presentAgent(agent, state, actor)]
    }

    private func applyAgentFields(
        _ agent: inout OrgAgent, _ body: OrgBody, _ state: OrgCompanyState, _ actor: OrgActor, creating: Bool
    ) throws -> [String] {
        var changed: [String] = []
        if let name = body.string("name", max: 120) {
            agent.name = name
            changed.append("name")
        }
        if let role = try body.oneOf("role", OrgAgent.roles) {
            agent.role = role
            changed.append("role")
        }
        if body.has("title") {
            agent.title = body.string("title", max: 120)
            changed.append("title")
        }
        if body.has("icon") {
            agent.icon = body.string("icon", max: 64)
            changed.append("icon")
        }
        if body.has("capabilities") {
            agent.capabilities = body.text("capabilities", max: 8_000)
            changed.append("capabilities")
        }
        if body.has("instructions") {
            agent.instructions = body.text("instructions", max: 64_000)
            changed.append("instructions")
        }
        if let skills = body.strings("desiredSkills") {
            agent.desiredSkills = skills
            changed.append("desiredSkills")
        }
        if body.has("reportsTo") {
            let target = body.string("reportsTo")
            if let target {
                guard let manager = findAgent(state, target), manager.status != "terminated" else {
                    throw orgInvalid("reportsTo must name an agent in this company.")
                }
                var cursor: String? = manager.id
                var hops = 0
                while let current = cursor, hops < 512 {
                    if current == agent.id { throw orgInvalid("That reporting line would create a cycle.") }
                    cursor = state.agents.first(where: { $0.id == current })?.reportsTo
                    hops += 1
                }
                agent.reportsTo = manager.id
            } else {
                agent.reportsTo = nil
            }
            changed.append("reportsTo")
        }
        let wantsAdapterChange = body.has("adapterType") || body.has("adapterConfig")
        if wantsAdapterChange {
            guard actor.kind != .agent else { throw orgForbidden("Agents cannot change adapter settings.") }
            if let type = try body.oneOf("adapterType", OrgService.adapterTypes) {
                agent.adapterType = type
                changed.append("adapterType")
            }
            if body.has("adapterConfig") {
                guard body.raw["adapterConfig"].isObject else { throw orgInvalid("adapterConfig must be an object.") }
                agent.adapterConfig = body.raw["adapterConfig"]
                changed.append("adapterConfig")
            }
            if OrgService.hostAdapterTypes.contains(agent.adapterType) && !actor.isOwner {
                throw orgForbidden("Only the RoachNet owner can set up agents that run programs on this Mac.")
            }
            if OrgService.usesPlanModel(adapterType: agent.adapterType, adapterConfig: agent.adapterConfig)
                && !actor.isOwner
            {
                throw orgForbidden("Only the RoachNet owner can give an agent a Claude or ChatGPT plan model.")
            }
            if !actor.isOwner,
                let host = OrgAdapters.localEndpointHost(type: agent.adapterType, config: agent.adapterConfig)
            {
                throw orgForbidden(
                    "Only the RoachNet owner can point an agent at \(host), on this Mac or a private network.")
            }
        }
        if body.raw["heartbeat"].isObject {
            let hb = OrgBody(body.raw["heartbeat"])
            if let value = hb.bool("enabled") { agent.heartbeat.enabled = value }
            if let value = hb.int("intervalSec") { agent.heartbeat.intervalSec = min(max(value, 60), 7 * 86_400) }
            if let value = hb.bool("wakeOnDemand") { agent.heartbeat.wakeOnDemand = value }
            if let value = hb.int("maxConcurrentRuns") { agent.heartbeat.maxConcurrentRuns = min(max(value, 1), 8) }
            if let value = hb.bool("skipTimerWhenNoActionableWork") {
                agent.heartbeat.skipTimerWhenNoActionableWork = value
            }
            if hb.has("maxDailyRuns") { agent.heartbeat.maxDailyRuns = hb.int("maxDailyRuns").map { max(0, $0) } }
            if hb.has("maxDailyCostCents") { agent.heartbeat.maxDailyCostCents = hb.amount("maxDailyCostCents") }
            changed.append("heartbeat")
        }
        if let cents = body.amount("budgetMonthlyCents") {
            agent.budgetMonthlyCents = cents
            changed.append("budgetMonthlyCents")
        }
        if body.has("canCreateAgents") || body.has("canAssignTasks") {
            guard isBoard(state, actor) else { throw orgForbidden("Only the board can change agent permissions.") }
            if let value = body.bool("canCreateAgents") {
                agent.canCreateAgents = value
                changed.append("canCreateAgents")
            }
            if let value = body.bool("canAssignTasks") {
                agent.canAssignTasks = value
                changed.append("canAssignTasks")
            }
        }
        return changed
    }

    func createAgent(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireGrant(state, actor, "agents:create")
        let name = try body.required("name", max: 120)
        let isFirst = !state.agents.contains { $0.status != "terminated" }
        var agent = newAgent(state, name: name, role: isFirst ? "ceo" : "general")
        _ = try applyAgentFields(&agent, body, state, actor, creating: true)
        if isFirst {
            agent.role = "ceo"
            agent.reportsTo = nil
            agent.canCreateAgents = body.bool("canCreateAgents") ?? true
        }
        if !isFirst && agent.reportsTo == nil {
            agent.reportsTo =
                actor.kind == .agent
                ? actor.agentId : state.agents.first(where: { $0.role == "ceo" && $0.status != "terminated" })?.id
        }
        let needsApproval = actor.kind == .agent && state.company.requireBoardApprovalForNewAgents
        if needsApproval { agent.status = "pending_approval" }
        var approval: OrgApproval?
        let created: OrgAgent = try store.mutateCompany(companyId) { company in
            company.agents.append(agent)
            company.memberships.append(
                OrgMembership(
                    id: OrgIDs.make("mem"), companyId: companyId, principalType: "agent", principalId: agent.id,
                    role: nil, createdAt: now, updatedAt: now))
            if agent.budgetMonthlyCents > 0 {
                upsertImplicitBudget(&company, scopeType: "agent", scopeId: agent.id, cents: agent.budgetMonthlyCents)
            }
            company.configRevisions.append(
                OrgConfigRevision(
                    id: OrgIDs.make("rev"), companyId: companyId, agentId: agent.id,
                    createdBy: actor.actorId ?? "system", source: "create", changedKeys: [], beforeConfig: .null,
                    afterConfig: OrgService.agentConfig(agent), createdAt: now))
            if needsApproval {
                let pending = OrgApproval(
                    id: OrgIDs.make("apr"), companyId: companyId, type: "hire_agent",
                    payload: [
                        "agentId": JSON(agent.id), "name": JSON(agent.name), "role": JSON(agent.role),
                        "reason": JSON(body.string("reason", max: 2_000)),
                    ],
                    requestedByAgentId: actor.agentId, createdAt: now, updatedAt: now)
                company.approvals.append(pending)
                approval = pending
            }
            return agent
        }
        record(
            companyId, actor, "agent.created", "agent", created.id,
            ["name": JSON(created.name), "role": JSON(created.role), "pendingApproval": JSON(needsApproval)])
        let fresh = try company(companyId)
        return ["agent": presentAgent(created, fresh, actor), "approval": approval.map { OrgCodec.json($0) } ?? .null]
    }

    func updateAgent(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let existing = findAgent(state, ref) else { throw orgNotFound("Agent") }
        let isSelf = actor.kind == .agent && actor.agentId == existing.id
        guard isBoard(state, actor) || hasGrant(state, actor, "agents:create") || isSelf else { throw orgForbidden() }
        if isSelf {
            let allowed: Set<String> = ["instructions", "capabilities", "desiredSkills", "title", "icon"]
            for (key, _) in body.raw.object where !allowed.contains(key) {
                throw orgForbidden(
                    "Agents may only update their own instructions, capabilities, skills, title and icon.")
            }
        }
        let updated: OrgAgent = try store.mutateCompany(companyId) { company in
            guard let index = company.agents.firstIndex(where: { $0.id == existing.id }) else {
                throw orgNotFound("Agent")
            }
            var agent = company.agents[index]
            let before = OrgService.agentConfig(agent)
            let changed = try applyAgentFields(&agent, body, company, actor, creating: false)
            agent.updatedAt = now
            company.agents[index] = agent
            if changed.contains("budgetMonthlyCents") {
                upsertImplicitBudget(&company, scopeType: "agent", scopeId: agent.id, cents: agent.budgetMonthlyCents)
            }
            if !changed.isEmpty {
                company.configRevisions.append(
                    OrgConfigRevision(
                        id: OrgIDs.make("rev"), companyId: companyId, agentId: agent.id,
                        createdBy: actor.actorId ?? "system", changedKeys: changed, beforeConfig: before,
                        afterConfig: OrgService.agentConfig(agent), createdAt: now))
            }
            return agent
        }
        record(companyId, actor, "agent.updated", "agent", updated.id)
        return ["agent": presentAgent(updated, try company(companyId), actor)]
    }

    func listRevisions(_ actor: OrgActor, _ companyId: String, _ ref: String) throws -> JSON {
        let state = try company(companyId)
        try requireBoard(state, actor)
        guard let agent = findAgent(state, ref) else { throw orgNotFound("Agent") }
        return [
            "revisions": .array(
                state.configRevisions.filter { $0.agentId == agent.id }.reversed().map { OrgCodec.json($0) })
        ]
    }

    func rollbackRevision(_ actor: OrgActor, _ companyId: String, _ ref: String, _ revisionId: String) throws -> JSON {
        let state = try company(companyId)
        try requireBoard(state, actor)
        guard let agent = findAgent(state, ref),
            let revision = state.configRevisions.first(where: { $0.id == revisionId && $0.agentId == agent.id })
        else {
            throw orgNotFound("Revision")
        }
        guard revision.beforeConfig.isObject else { throw orgConflict("The creation revision cannot be rolled back.") }
        let updated: OrgAgent = try store.mutateCompany(companyId) { company in
            guard let index = company.agents.firstIndex(where: { $0.id == agent.id }) else {
                throw orgNotFound("Agent")
            }
            let before = OrgService.agentConfig(company.agents[index])
            var restored = company.agents[index]
            let config = OrgBody(revision.beforeConfig)
            let restoredType = config.string("adapterType") ?? restored.adapterType
            let restoredConfig =
                revision.beforeConfig["adapterConfig"].isObject
                ? revision.beforeConfig["adapterConfig"] : restored.adapterConfig
            if OrgService.hostAdapterTypes.contains(restoredType) && !actor.isOwner {
                throw orgForbidden("Only the owner can restore an agent that runs programs on this Mac.")
            }
            if OrgService.usesPlanModel(adapterType: restoredType, adapterConfig: restoredConfig) && !actor.isOwner {
                throw orgForbidden("Only the owner can restore an agent that uses a Claude or ChatGPT plan model.")
            }
            if !actor.isOwner, let host = OrgAdapters.localEndpointHost(type: restoredType, config: restoredConfig) {
                throw orgForbidden(
                    "Only the owner can restore an agent pointed at \(host), on this Mac or a private network.")
            }
            restored.name = config.string("name") ?? restored.name
            restored.role = config.string("role") ?? restored.role
            restored.title = config.string("title")
            restored.icon = config.string("icon")
            restored.reportsTo = config.string("reportsTo")
            restored.capabilities = config.text("capabilities")
            restored.adapterType = config.string("adapterType") ?? restored.adapterType
            restored.adapterConfig =
                revision.beforeConfig["adapterConfig"].isObject
                ? revision.beforeConfig["adapterConfig"] : restored.adapterConfig
            if let heartbeat = try? OrgCodec.decode(OrgHeartbeatConfig.self, from: revision.beforeConfig["heartbeat"]) {
                restored.heartbeat = heartbeat
            }
            restored.budgetMonthlyCents = config.amount("budgetMonthlyCents") ?? restored.budgetMonthlyCents
            restored.canCreateAgents = config.bool("canCreateAgents") ?? restored.canCreateAgents
            restored.canAssignTasks = config.bool("canAssignTasks") ?? restored.canAssignTasks
            restored.desiredSkills = config.strings("desiredSkills") ?? restored.desiredSkills
            restored.instructions = config.text("instructions")
            restored.updatedAt = now
            company.agents[index] = restored
            company.configRevisions.append(
                OrgConfigRevision(
                    id: OrgIDs.make("rev"), companyId: companyId, agentId: agent.id,
                    createdBy: actor.actorId ?? "system", source: "rollback", rolledBackFromRevisionId: revisionId,
                    changedKeys: revision.changedKeys, beforeConfig: before,
                    afterConfig: OrgService.agentConfig(restored), createdAt: now))
            return restored
        }
        record(companyId, actor, "agent.rolled_back", "agent", agent.id, ["revisionId": JSON(revisionId)])
        return ["agent": presentAgent(updated, try company(companyId), actor)]
    }

    func setAgentStatus(_ actor: OrgActor, _ companyId: String, _ ref: String, _ action: String) throws -> JSON {
        let state = try company(companyId)
        guard let agent = findAgent(state, ref) else { throw orgNotFound("Agent") }
        let managesAgent =
            isBoard(state, actor) || (actor.kind == .agent && isManager(state, actor.agentId, of: agent.id))
        try requireRead(state, actor)
        guard managesAgent else { throw orgForbidden("Only the board or the agent's manager can do that.") }
        var cancelRuns: [String] = []
        let updated: OrgAgent = try store.mutateCompany(companyId) { company in
            guard let index = company.agents.firstIndex(where: { $0.id == agent.id }) else {
                throw orgNotFound("Agent")
            }
            switch action {
            case "pause":
                guard company.agents[index].status != "terminated" else { throw orgConflict("Agent is terminated.") }
                company.agents[index].status = "paused"
                company.agents[index].pauseReason = "manual"
                company.agents[index].pausedAt = now
            case "resume":
                guard company.agents[index].status == "paused" || company.agents[index].status == "error" else {
                    throw orgConflict("Agent is not paused.")
                }
                company.agents[index].status = "idle"
                company.agents[index].pauseReason = nil
                company.agents[index].pausedAt = nil
                company.agents[index].errorReason = nil
            case "terminate":
                company.agents[index].status = "terminated"
                cancelRuns = company.runs.filter { $0.agentId == agent.id && $0.status == "running" }.map { $0.id }
                for keyIndex in company.apiKeys.indices
                where company.apiKeys[keyIndex].principalId == agent.id && company.apiKeys[keyIndex].revokedAt == nil {
                    company.apiKeys[keyIndex].revokedAt = now
                }
                for wakeIndex in company.wakeRequests.indices
                where company.wakeRequests[wakeIndex].agentId == agent.id
                    && ["queued", "deferred_issue_execution"].contains(company.wakeRequests[wakeIndex].status)
                {
                    company.wakeRequests[wakeIndex].status = "cancelled"
                    company.wakeRequests[wakeIndex].finishedAt = now
                }
            default: throw orgNotFound("Action")
            }
            company.agents[index].updatedAt = now
            return company.agents[index]
        }
        for runId in cancelRuns { engine.cancel(runId) }
        record(companyId, actor, "agent.\(action)", "agent", agent.id)
        if action == "resume" { engine.kick(companyId) }
        return ["agent": presentAgent(updated, try company(companyId), actor)]
    }

    func isManager(_ state: OrgCompanyState, _ managerId: String?, of agentId: String) -> Bool {
        guard let managerId else { return false }
        var cursor = state.agents.first(where: { $0.id == agentId })?.reportsTo
        var hops = 0
        while let current = cursor, hops < 512 {
            if current == managerId { return true }
            cursor = state.agents.first(where: { $0.id == current })?.reportsTo
            hops += 1
        }
        return false
    }

    func wakeAgent(_ actor: OrgActor, _ companyId: String, _ ref: String, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        guard let agent = findAgent(state, ref) else { throw orgNotFound("Agent") }
        guard hasGrant(state, actor, "tasks:assign") || actor.agentId == agent.id else { throw orgForbidden() }
        var issueId: String?
        if let ref = body.string("issueId") {
            guard let issue = findIssue(state, ref) else { throw orgNotFound("Issue") }
            issueId = issue.id
        }
        let wake = engine.enqueue(
            OrgWakeIntent(
                companyId: companyId, agentId: agent.id, source: "on_demand",
                reason: body.string("reason", max: 200) ?? "manual",
                issueId: issueId, payload: body.raw["payload"].isObject ? body.raw["payload"] : .object(JSONObject()),
                requestedByType: actor.actorType, requestedById: actor.actorId))
        return ["wakeRequest": wake.map { OrgCodec.json($0) } ?? .null]
    }

    func orgChart(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let live = state.agents.filter { $0.status != "terminated" }
        func node(_ agent: OrgAgent, depth: Int) -> JSON {
            let reports = depth > 64 ? [] : live.filter { $0.reportsTo == agent.id }.map { node($0, depth: depth + 1) }
            return [
                "id": JSON(agent.id), "name": JSON(agent.name), "role": JSON(agent.role), "title": JSON(agent.title),
                "status": JSON(agent.status), "urlKey": JSON(agent.urlKey), "reports": .array(reports),
            ]
        }
        let roots = live.filter { agent in agent.reportsTo == nil || !live.contains(where: { $0.id == agent.reportsTo })
        }
        return ["roots": .array(roots.map { node($0, depth: 0) })]
    }

    func listGoals(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["goals": .array(state.goals.map { OrgCodec.json($0) })]
    }

    func saveGoal(_ actor: OrgActor, _ companyId: String, _ goalId: String?, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        let level = try body.oneOf("level", ["company", "team", "agent", "task"])
        let status = try body.oneOf("status", ["planned", "active", "achieved", "cancelled"])
        let goal: OrgGoal = try store.mutateCompany(companyId) { company in
            var goal: OrgGoal
            var index: Int?
            if let goalId {
                guard let found = company.goals.firstIndex(where: { $0.id == goalId }) else {
                    throw orgNotFound("Goal")
                }
                index = found
                goal = company.goals[found]
            } else {
                goal = OrgGoal(
                    id: OrgIDs.make("goal"), companyId: companyId, title: try body.required("title", max: 300),
                    createdAt: now, updatedAt: now)
            }
            if let title = body.string("title", max: 300) { goal.title = title }
            if body.has("description") { goal.description = body.text("description", max: 20_000) }
            if let level { goal.level = level }
            if let status { goal.status = status }
            if body.has("parentId") {
                let parent = body.string("parentId")
                if let parent {
                    guard parent != goal.id, company.goals.contains(where: { $0.id == parent }) else {
                        throw orgInvalid("parentId must be another goal.")
                    }
                }
                goal.parentId = parent
            }
            if body.has("ownerAgentId") {
                let owner = body.string("ownerAgentId")
                if let owner, findAgent(company, owner) == nil { throw orgNotFound("Agent") }
                goal.ownerAgentId = owner.flatMap { findAgent(company, $0)?.id }
            }
            goal.updatedAt = now
            if let index { company.goals[index] = goal } else { company.goals.append(goal) }
            return goal
        }
        record(companyId, actor, goalId == nil ? "goal.created" : "goal.updated", "goal", goal.id)
        return ["goal": OrgCodec.json(goal)]
    }

    func listProjects(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        let board = isBoard(state, actor)
        return [
            "projects": .array(
                state.projects.map { project -> JSON in
                    var json = OrgCodec.json(project).object
                    if !board {
                        json["env"] = .undefined
                        json["secretEnv"] = .undefined
                        json["workspacePath"] = .undefined
                    }
                    return .object(json)
                })
        ]
    }

    func saveProject(_ actor: OrgActor, _ companyId: String, _ projectId: String?, _ body: OrgBody) throws -> JSON {
        let state = try company(companyId)
        try requireWrite(state, actor)
        let status = try body.oneOf("status", ["backlog", "planned", "in_progress", "completed", "cancelled"])
        if body.has("workspacePath") || body.has("env") || body.has("secretEnv") || body.has("budgetMonthlyCents") {
            guard isBoard(state, actor) else {
                throw orgForbidden("Only the board can change project workspaces, environment or budgets.")
            }
        }
        let project: OrgProject = try store.mutateCompany(companyId) { company in
            var project: OrgProject
            var index: Int?
            if let projectId {
                guard let found = company.projects.firstIndex(where: { $0.id == projectId }) else {
                    throw orgNotFound("Project")
                }
                index = found
                project = company.projects[found]
            } else {
                project = OrgProject(
                    id: OrgIDs.make("proj"), companyId: companyId, name: try body.required("name", max: 200),
                    createdAt: now, updatedAt: now)
            }
            if let name = body.string("name", max: 200) { project.name = name }
            if body.has("description") { project.description = body.text("description", max: 20_000) }
            if let status { project.status = status }
            if let goals = body.strings("goalIds") {
                for goal in goals where !company.goals.contains(where: { $0.id == goal }) {
                    throw orgNotFound("Goal \(goal)")
                }
                project.goalIds = goals
            }
            if body.has("leadAgentId") {
                project.leadAgentId = body.string("leadAgentId").flatMap { findAgent(company, $0)?.id }
            }
            if body.has("targetDate") { project.targetDate = body.string("targetDate", max: 40) }
            if body.has("color") { project.color = body.string("color", max: 32) }
            if body.has("workspacePath") {
                let path = body.string("workspacePath", max: 1_024)
                if let path, !Path.isAbsolute(path) { throw orgInvalid("workspacePath must be absolute.") }
                project.workspacePath = path
            }
            if body.raw["env"].isObject {
                var env: [String: String] = [:]
                for (key, value) in body.raw["env"].object { if let text = value.stringValue { env[key] = text } }
                project.env = env
            }
            if body.raw["secretEnv"].isObject {
                var env: [String: String] = [:]
                for (key, value) in body.raw["secretEnv"].object { if let text = value.stringValue { env[key] = text } }
                project.secretEnv = env
            }
            if let archived = body.bool("archived") {
                project.archivedAt = archived ? (project.archivedAt ?? now) : nil
            }
            if let cents = body.amount("budgetMonthlyCents") {
                upsertImplicitBudget(&company, scopeType: "project", scopeId: project.id, cents: cents)
            }
            project.updatedAt = now
            if let index { company.projects[index] = project } else { company.projects.append(project) }
            return project
        }
        record(companyId, actor, projectId == nil ? "project.created" : "project.updated", "project", project.id)
        return ["project": OrgCodec.json(project)]
    }

    func listLabels(_ actor: OrgActor, _ companyId: String) throws -> JSON {
        let state = try company(companyId)
        try requireRead(state, actor)
        return ["labels": .array(state.labels.map { OrgCodec.json($0) })]
    }

    func createLabel(_ actor: OrgActor, _ companyId: String, _ body: OrgBody) throws -> JSON {
        try requireWrite(try company(companyId), actor)
        let label = OrgLabel(
            id: OrgIDs.make("lbl"), companyId: companyId, name: try body.required("name", max: 60),
            color: body.string("color", max: 32) ?? "#7c8cff")
        try store.mutateCompany(companyId) { company in
            if company.labels.contains(where: { $0.name.lowercased() == label.name.lowercased() }) {
                throw orgConflict("A label with that name exists.")
            }
            company.labels.append(label)
        }
        return ["label": OrgCodec.json(label)]
    }

    func deleteLabel(_ actor: OrgActor, _ companyId: String, _ labelId: String) throws -> JSON {
        try requireWrite(try company(companyId), actor)
        try store.mutateCompany(companyId) { company in
            guard company.labels.contains(where: { $0.id == labelId }) else { throw orgNotFound("Label") }
            company.labels.removeAll { $0.id == labelId }
            for index in company.issues.indices { company.issues[index].labelIds.removeAll { $0 == labelId } }
        }
        return ["deleted": true]
    }
}
