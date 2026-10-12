import Foundation

// RoachClaw Org: a native agent-company control plane (companies, org charts,
// goals, issues, heartbeats, approvals, budgets, routines, skills). Modelled on
// the Paperclip design reference; implemented entirely in RoachNet code.

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSON].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSON].self) {
            self = .object(JSONObject(value.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .undefined, .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let object):
            var dictionary: [String: JSON] = [:]
            for (key, value) in object where !value.isUndefined { dictionary[key] = value }
            try container.encode(dictionary)
        }
    }
}

enum OrgCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder = JSONDecoder()

    static func json<T: Encodable>(_ value: T) -> JSON {
        guard let data = try? encoder.encode(value), let parsed = try? JSON.parse(data) else { return .null }
        return parsed
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSON) throws -> T {
        try decoder.decode(type, from: value.serializedData())
    }
}

struct OrgCompany: Codable {
    var id: String
    var name: String
    var description: String?
    var status: String = "active"            // active | paused | archived
    var pauseReason: String?                  // manual | budget | system | company_archived | import
    var pausedAt: String?
    var issuePrefix: String
    var issueCounter: Int = 0
    var budgetMonthlyCents: Int = 0
    var requireBoardApprovalForNewAgents: Bool = false
    var createdAt: String
    var updatedAt: String
}

struct OrgUser: Codable {
    var id: String
    var name: String
    var email: String?
    /// RoachTail peers (paired devices) that act as this user.
    var roachTailPeerIds: [String] = []
    var createdAt: String
}

struct OrgMembership: Codable {
    var id: String
    var companyId: String
    var principalType: String                 // user | agent
    var principalId: String
    var status: String = "active"             // pending | active | suspended | archived
    var role: String?                         // owner | admin | operator | viewer
    var grants: [String] = []
    var createdAt: String
    var updatedAt: String
}

struct OrgAPIKey: Codable {
    var id: String
    var companyId: String?
    var principalType: String                 // user | agent
    var principalId: String
    var name: String
    var keyHash: String
    var prefix: String
    var createdAt: String
    var lastUsedAt: String?
    var revokedAt: String?
}

struct OrgInvite: Codable {
    var id: String
    var companyId: String
    var tokenHash: String
    var role: String = "operator"
    var allowedJoinTypes: String = "human"   // human | agent | both
    var expiresAt: String
    var invitedByUserId: String
    var acceptedAt: String?
    var revokedAt: String?
    var createdAt: String
}

struct OrgJoinRequest: Codable {
    var id: String
    var companyId: String
    var inviteId: String
    var requestType: String                   // human | agent
    var status: String = "pending_approval"  // pending_approval | approved | rejected
    var userName: String?
    var email: String?
    var roachTailPeerId: String?
    var agentName: String?
    var adapterType: String?
    var claimSecretHash: String?
    var claimedAt: String?
    var createdUserId: String?
    var createdAgentId: String?
    var decidedByUserId: String?
    var decidedAt: String?
    var createdAt: String
}

struct OrgHeartbeatConfig: Codable {
    var enabled: Bool = false
    var intervalSec: Int = 3600
    var wakeOnDemand: Bool = true
    var maxConcurrentRuns: Int = 1
    var skipTimerWhenNoActionableWork: Bool = true
    var maxDailyRuns: Int?
    var maxDailyCostCents: Int?
}

struct OrgAgent: Codable {
    static let roles: Set<String> = ["ceo", "cto", "cmo", "cfo", "security", "engineer", "designer", "pm", "qa", "devops", "researcher", "general"]
    static let statuses: Set<String> = ["active", "paused", "idle", "running", "error", "pending_approval", "terminated"]

    var id: String
    var companyId: String
    var name: String
    var urlKey: String
    var role: String = "general"
    var title: String?
    var icon: String?
    var status: String = "idle"
    var reportsTo: String?
    var capabilities: String?
    var adapterType: String = "roachclaw_local"
    var adapterConfig: JSON = .object(JSONObject())
    var heartbeat = OrgHeartbeatConfig()
    var budgetMonthlyCents: Int = 0
    var pauseReason: String?
    var pausedAt: String?
    var errorReason: String?
    var canCreateAgents: Bool = false
    var canAssignTasks: Bool = true
    var desiredSkills: [String] = []
    var instructions: String?
    var lastHeartbeatAt: String?
    var sessionState: JSON?
    var createdAt: String
    var updatedAt: String
}

struct OrgConfigRevision: Codable {
    var id: String
    var companyId: String
    var agentId: String
    var createdBy: String
    var source: String = "patch"
    var rolledBackFromRevisionId: String?
    var changedKeys: [String]
    var beforeConfig: JSON
    var afterConfig: JSON
    var createdAt: String
}

struct OrgGoal: Codable {
    var id: String
    var companyId: String
    var title: String
    var description: String?
    var level: String = "task"                // company | team | agent | task
    var status: String = "planned"            // planned | active | achieved | cancelled
    var parentId: String?
    var ownerAgentId: String?
    var createdAt: String
    var updatedAt: String
}

struct OrgProject: Codable {
    var id: String
    var companyId: String
    var name: String
    var description: String?
    var status: String = "backlog"            // backlog | planned | in_progress | completed | cancelled
    var goalIds: [String] = []
    var leadAgentId: String?
    var targetDate: String?
    var color: String?
    var workspacePath: String?
    var env: [String: String] = [:]
    var secretEnv: [String: String] = [:]      // ENV_NAME -> secret key
    var pauseReason: String?
    var archivedAt: String?
    var createdAt: String
    var updatedAt: String
}

struct OrgLabel: Codable {
    var id: String
    var companyId: String
    var name: String
    var color: String
}

struct OrgParticipant: Codable, Equatable {
    var type: String                          // agent | user
    var id: String
}

struct OrgStage: Codable {
    var id: String
    var type: String                          // review | approval
    var participants: [OrgParticipant]
}

struct OrgExecutionPolicy: Codable {
    var stages: [OrgStage] = []
    var maxReviewRounds: Int = 3
}

struct OrgExecutionState: Codable {
    var status: String = "idle"               // idle | pending | changes_requested | completed
    var currentStageIndex: Int?
    var currentParticipant: OrgParticipant?
    var returnAssigneeAgentId: String?
    var returnAssigneeUserId: String?
    var completedStageIds: [String] = []
    var changesRequestedCount: Int = 0
}

struct OrgIssue: Codable {
    static let statuses: [String] = ["backlog", "todo", "in_progress", "in_review", "done", "blocked", "cancelled"]
    static let priorities: Set<String> = ["critical", "high", "medium", "low"]

    var id: String
    var companyId: String
    var number: Int
    var identifier: String
    var projectId: String?
    var goalId: String?
    var parentId: String?
    var title: String
    var description: String?
    var status: String = "backlog"
    var priority: String = "medium"
    var workMode: String = "standard"         // standard | planning | ask
    var assigneeAgentId: String?
    var assigneeUserId: String?
    var createdByAgentId: String?
    var createdByUserId: String?
    var responsibleUserId: String?
    var labelIds: [String] = []
    var blockedByIssueIds: [String] = []
    var checkoutRunId: String?
    var executionRunId: String?
    var executionLockedAt: String?
    var unblockOwner: String?
    var unblockAction: String?
    var originKind: String = "manual"
    var originId: String?
    var requestDepth: Int = 0
    var reviewPolicy: String?                 // anyone | not_creator | human_only
    var executionPolicy: OrgExecutionPolicy?
    var executionState: OrgExecutionState?
    var startedAt: String?
    var completedAt: String?
    var cancelledAt: String?
    var statusVersion: Int = 0
    var createdAt: String
    var updatedAt: String

    var isTerminal: Bool { status == "done" || status == "cancelled" }
}

struct OrgComment: Codable {
    var id: String
    var companyId: String
    var issueId: String
    var authorType: String                    // user | agent | system
    var authorId: String?
    var body: String
    var runId: String?
    var createdAt: String
    var deletedAt: String?
}

struct OrgDocumentRevision: Codable {
    var id: String
    var number: Int
    var title: String
    var body: String
    var changeSummary: String?
    var createdBy: String
    var createdAt: String
}

struct OrgDocument: Codable {
    var id: String
    var companyId: String
    var issueId: String
    var key: String
    var title: String
    var body: String
    var revisionNumber: Int
    var revisionId: String
    var revisions: [OrgDocumentRevision]
    var lockedBy: String?
    var createdAt: String
    var updatedAt: String
}

struct OrgWorkProduct: Codable {
    var id: String
    var companyId: String
    var issueId: String
    var type: String                          // artifact | document | branch | commit | pull_request | preview_url
    var title: String
    var url: String?
    var summary: String?
    var status: String = "active"
    var createdByRunId: String?
    var createdAt: String
}

struct OrgApprovalComment: Codable {
    var id: String
    var authorType: String
    var authorId: String?
    var body: String
    var createdAt: String
}

struct OrgApproval: Codable {
    static let types: Set<String> = ["hire_agent", "approve_ceo_strategy", "budget_override_required", "request_board_approval"]

    var id: String
    var companyId: String
    var type: String
    var status: String = "pending"            // pending | revision_requested | approved | rejected | cancelled
    var payload: JSON
    var requestedByAgentId: String?
    var requestedByUserId: String?
    var decisionNote: String?
    var decidedByUserId: String?
    var decidedAt: String?
    var issueIds: [String] = []
    var comments: [OrgApprovalComment] = []
    var createdAt: String
    var updatedAt: String
}

struct OrgUsage: Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var provider: String?
    var model: String?
    var costUsd: Double?
}

extension OrgUsage {
    var traceUsage: TraceUsage { TraceUsage(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens) }
}

struct OrgRun: Codable {
    var id: String
    var companyId: String
    var agentId: String
    var issueId: String?
    var taskKey: String
    var invocationSource: String              // timer | assignment | on_demand | automation
    var wakeReason: String
    var status: String = "queued"             // queued | running | succeeded | failed | cancelled | timed_out
    var contextSnapshot: JSON = .object(JSONObject())
    var adapterType: String
    var startedAt: String?
    var finishedAt: String?
    var error: String?
    var errorCode: String?
    var exitCode: Int?
    var usage: OrgUsage?
    var costCents: Int = 0
    var summary: String?
    var sessionIdBefore: String?
    var sessionIdAfter: String?
    var coalescedCount: Int = 0
    var retryOfRunId: String?
    var createdAt: String
}

struct OrgWakeRequest: Codable {
    var id: String
    var companyId: String
    var agentId: String
    var source: String
    var reason: String
    var status: String                        // queued | claimed | coalesced | skipped | deferred_issue_execution | completed | failed | cancelled
    var issueId: String?
    var payload: JSON = .object(JSONObject())
    var runId: String?
    var requestedByType: String
    var requestedById: String?
    var coalescedCount: Int = 0
    var createdAt: String
    var finishedAt: String?
}

struct OrgCostEvent: Codable {
    var id: String
    var companyId: String
    var agentId: String?
    var issueId: String?
    var projectId: String?
    var runId: String?
    var provider: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var costCents: Int
    var costStatus: String                    // reported | estimated | unpriced
    var billingType: String                   // local | metered_api | subscription_included | unknown
    var occurredAt: String
}

struct OrgBudgetPolicy: Codable {
    var id: String
    var companyId: String
    var scopeType: String                     // company | agent | project
    var scopeId: String
    var windowKind: String                    // calendar_month_utc | lifetime
    var amountCents: Int
    var warnPercent: Int = 80
    var hardStopEnabled: Bool = true
    var unpricedUsagePolicy: String = "allow" // allow | block
    var isActive: Bool = true
    var createdAt: String
    var updatedAt: String
}

struct OrgBudgetIncident: Codable {
    var id: String
    var companyId: String
    var policyId: String
    var scopeType: String
    var scopeId: String
    var windowStart: String
    var thresholdType: String                 // soft | hard
    var amountLimit: Int
    var amountObserved: Int
    var status: String = "open"               // open | resolved | dismissed
    var approvalId: String?
    var createdAt: String
    var resolvedAt: String?
}

struct OrgRoutineVariable: Codable {
    var name: String
    var label: String?
    var type: String = "text"
    var required: Bool = false
    var defaultValue: String?
}

struct OrgRoutineTrigger: Codable {
    var id: String
    var kind: String                          // schedule | webhook | api
    var label: String?
    var enabled: Bool = true
    var cronExpression: String?
    var timezone: String?
    var nextRunAt: String?
    var lastFiredAt: String?
    var publicId: String?
    var signingMode: String = "bearer"       // bearer | hmac_sha256 | none
    var replayWindowSec: Int = 300
    var lastResult: String?
}

struct OrgRoutine: Codable {
    var id: String
    var companyId: String
    var projectId: String?
    var goalId: String?
    var parentIssueId: String?
    var title: String
    var description: String?
    var assigneeAgentId: String?
    var priority: String = "medium"
    var status: String = "active"             // active | paused | archived
    var concurrencyPolicy: String = "coalesce_if_active"  // coalesce_if_active | always_enqueue | skip_if_active
    var catchUpPolicy: String = "skip_missed"             // skip_missed | enqueue_missed_with_cap
    var variables: [OrgRoutineVariable] = []
    var triggers: [OrgRoutineTrigger] = []
    var lastTriggeredAt: String?
    var createdAt: String
    var updatedAt: String
}

struct OrgRoutineRun: Codable {
    var id: String
    var companyId: String
    var routineId: String
    var triggerId: String?
    var source: String                        // schedule | manual | api | webhook
    var status: String = "received"           // received | issue_created | coalesced | skipped | completed | failed
    var triggeredAt: String
    var linkedIssueId: String?
    var failureReason: String?
    var payload: JSON?
    var completedAt: String?
}

struct OrgSkillVersion: Codable {
    var id: String
    var number: Int
    var markdown: String
    var createdBy: String
    var createdAt: String
}

struct OrgSkill: Codable {
    var id: String
    var companyId: String
    var key: String
    var slug: String
    var name: String
    var description: String
    var markdown: String
    var currentVersion: Int
    var versions: [OrgSkillVersion]
    var createdAt: String
    var updatedAt: String
}

struct OrgSecret: Codable {
    var id: String
    var companyId: String
    var key: String
    var name: String
    var description: String?
    var status: String = "active"
    var latestVersion: Int = 1
    var valueSha256: String
    var createdAt: String
    var updatedAt: String
    var lastRotatedAt: String?
}

struct OrgActivity: Codable {
    var id: String
    var companyId: String
    var actorType: String                     // user | agent | system
    var actorId: String?
    var action: String
    var entityType: String
    var entityId: String
    var agentId: String?
    var runId: String?
    var details: JSON
    var createdAt: String
}

/// Everything that belongs to one company; persisted as one file.
struct OrgCompanyState: Codable {
    var company: OrgCompany
    var memberships: [OrgMembership] = []
    var agents: [OrgAgent] = []
    var configRevisions: [OrgConfigRevision] = []
    var goals: [OrgGoal] = []
    var projects: [OrgProject] = []
    var labels: [OrgLabel] = []
    var issues: [OrgIssue] = []
    var comments: [OrgComment] = []
    var documents: [OrgDocument] = []
    var workProducts: [OrgWorkProduct] = []
    var approvals: [OrgApproval] = []
    var runs: [OrgRun] = []
    var wakeRequests: [OrgWakeRequest] = []
    var costEvents: [OrgCostEvent] = []
    var budgetPolicies: [OrgBudgetPolicy] = []
    var budgetIncidents: [OrgBudgetIncident] = []
    var routines: [OrgRoutine] = []
    var routineRuns: [OrgRoutineRun] = []
    var skills: [OrgSkill] = []
    var secrets: [OrgSecret] = []
    var invites: [OrgInvite] = []
    var joinRequests: [OrgJoinRequest] = []
    var apiKeys: [OrgAPIKey] = []
}

struct OrgInstanceState: Codable {
    var users: [OrgUser] = []
    var runTokenSecret: String = JS.randomHex(64)
    var schemaVersion: Int = 1
}
