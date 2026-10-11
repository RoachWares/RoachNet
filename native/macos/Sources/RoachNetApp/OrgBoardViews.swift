import SwiftUI
import RoachNetCore
import RoachNetDesign

// The Org desk's working boards (ROA-31): issues, the org chart, routines and
// budgets. Each one reads and writes the same /api/org routes the agents and
// paired phones use, so nothing here keeps state of its own.

enum OrgBoardSection: String, CaseIterable, Identifiable {
    case desk = "Desk"
    case issues = "Issues"
    case chart = "Org chart"
    case routines = "Routines"
    case budgets = "Budgets"

    var id: String { rawValue }
}

extension Notification.Name {
    /// Object: an `OrgBoardSection` raw value. Opens that board on the Org desk.
    static let roachOrgSectionRequest = Notification.Name("org.roachnet.org.section-request")
}

/// A section asked for before the Org pane was on screen; the desk picks it up when it appears.
@MainActor
enum OrgBoardRequest {
    static var pending: OrgBoardSection?
}

// MARK: - Models

struct OrgDeskIssue: Decodable, Identifiable, Hashable {
    let id: String
    let identifier: String
    let title: String
    let description: String?
    let status: String
    let priority: String
    let assigneeAgentId: String?
    let assigneeAgentName: String?
    let updatedAt: String?

    var isOpen: Bool { !["done", "cancelled"].contains(status) }
}

struct OrgDeskComment: Decodable, Identifiable, Hashable {
    let id: String
    let body: String
    let authorType: String
    let authorId: String?
    let createdAt: String?
}

struct OrgDeskChartNode: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let title: String?
    let status: String
    let reports: [OrgDeskChartNode]
}

struct OrgDeskRoutineTrigger: Decodable, Hashable {
    let id: String
    let kind: String
    let enabled: Bool?
    let cronExpression: String?
    let timezone: String?
    let nextRunAt: String?
    let lastFiredAt: String?
}

struct OrgDeskRoutine: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let assigneeAgentId: String?
    let priority: String?
    let status: String
    let triggers: [OrgDeskRoutineTrigger]
    let lastTriggeredAt: String?

    var schedule: OrgDeskRoutineTrigger? { triggers.first { $0.kind == "schedule" } }
}

struct OrgDeskBudget: Decodable, Identifiable, Hashable {
    let id: String
    let scopeType: String
    let scopeId: String
    let windowKind: String
    let amountCents: Int
    let warnPercent: Int?
    let hardStopEnabled: Bool?
    let isActive: Bool?
    let observedCents: Int?

    var share: Double { amountCents > 0 ? Double(observedCents ?? 0) / Double(amountCents) : 0 }
}

struct OrgDeskIncident: Decodable, Identifiable, Hashable {
    let id: String
    let policyId: String
    let thresholdType: String
    let amountLimit: Int
    let amountObserved: Int
    let status: String
    let createdAt: String?
}

enum OrgDeskWords {
    static let issueStatuses = ["backlog", "todo", "in_progress", "in_review", "blocked", "done", "cancelled"]
    static let priorities = ["critical", "high", "medium", "low"]

    static func status(_ raw: String) -> String {
        switch raw {
        case "todo": return "To do"
        case "in_progress": return "In progress"
        case "in_review": return "In review"
        case "pending_approval": return "Waiting for approval"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func statusAccent(_ raw: String) -> Color {
        switch raw {
        case "in_progress", "running", "active": return RoachPalette.green
        case "in_review", "todo", "idle": return RoachPalette.cyan
        case "blocked", "error", "paused": return RoachPalette.bronze
        case "done": return RoachPalette.magenta
        default: return RoachPalette.muted
        }
    }

    static func priorityAccent(_ raw: String) -> Color {
        switch raw {
        case "critical": return RoachPalette.warning
        case "high": return RoachPalette.bronze
        case "low": return RoachPalette.muted
        default: return RoachPalette.cyan
        }
    }

    /// Plain words for the cron presets the routine form offers; anything else is shown as written.
    static let schedulePresets: [(label: String, cron: String)] = [
        ("Every hour", "0 * * * *"),
        ("Every day at 9:00", "0 9 * * *"),
        ("Weekdays at 9:00", "0 9 * * 1-5"),
        ("Mondays at 9:00", "0 9 * * 1"),
        ("First of the month at 9:00", "0 9 1 * *"),
    ]

    static func schedule(_ cron: String?) -> String {
        guard let cron else { return "No schedule" }
        return schedulePresets.first { $0.cron == cron }?.label ?? cron
    }
}

// MARK: - Store

@MainActor
final class OrgBoardStore: ObservableObject {
    @Published var issues: [OrgDeskIssue] = []
    @Published var issueTotal = 0
    @Published var comments: [String: [OrgDeskComment]] = [:]
    @Published var chart: [OrgDeskChartNode] = []
    @Published var routines: [OrgDeskRoutine] = []
    @Published var budgets: [OrgDeskBudget] = []
    @Published var incidents: [OrgDeskIncident] = []
    @Published var isLoading = false
    @Published var message: String?
    @Published var errorMessage: String?

    private let decoder = JSONDecoder()

    func load(_ section: OrgBoardSection, company cid: String, using config: RoachNetInstallerConfig) async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch section {
            case .desk:
                break
            case .issues:
                struct List: Decodable { let issues: [OrgDeskIssue]; let total: Int? }
                let list: List = try await request("GET", "/api/org/companies/\(cid)/issues?limit=300", nil, config)
                issues = list.issues
                issueTotal = list.total ?? list.issues.count
            case .chart:
                struct Chart: Decodable { let roots: [OrgDeskChartNode] }
                chart = (try await request("GET", "/api/org/companies/\(cid)/org-chart", nil, config) as Chart).roots
            case .routines:
                struct List: Decodable { let routines: [OrgDeskRoutine] }
                routines = (try await request("GET", "/api/org/companies/\(cid)/routines", nil, config) as List).routines
            case .budgets:
                struct List: Decodable { let policies: [OrgDeskBudget]; let incidents: [OrgDeskIncident] }
                let list: List = try await request("GET", "/api/org/companies/\(cid)/budgets", nil, config)
                budgets = list.policies
                incidents = list.incidents
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadComments(_ issue: OrgDeskIssue, company cid: String, using config: RoachNetInstallerConfig) async {
        struct List: Decodable { let comments: [OrgDeskComment] }
        if let list: List = try? await request("GET", "/api/org/companies/\(cid)/issues/\(issue.id)/comments", nil, config) {
            comments[issue.id] = list.comments
        }
    }

    /// Runs a write, says what happened, and re-reads the section it touched.
    func act(
        _ section: OrgBoardSection, company cid: String, using config: RoachNetInstallerConfig,
        success: String, _ method: String, _ path: String, _ body: [String: Any]
    ) async {
        do {
            let _: OrgBoardIgnored = try await request(method, "/api/org/companies/\(cid)\(path)", body, config)
            message = success
            errorMessage = nil
            await load(section, company: cid, using: config)
        } catch {
            message = nil
            errorMessage = error.localizedDescription
        }
    }

    private func request<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any]?, _ config: RoachNetInstallerConfig) async throws -> T {
        let json = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: path, method: method, jsonBody: json)
        return try decoder.decode(T.self, from: data)
    }
}

private struct OrgBoardIgnored: Decodable {}

// MARK: - Issues

struct OrgIssuesBoard: View {
    @ObservedObject var store: OrgBoardStore
    let companyID: String
    let agents: [OrgDeskAgent]
    let config: RoachNetInstallerConfig

    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open", review = "In review", blocked = "Blocked", done = "Done", all = "All"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .open
    @State private var newTitle = ""
    @State private var newPriority = "medium"
    @State private var newAssignee = ""
    @State private var expanded: String?
    @State private var replies: [String: String] = [:]

    private var shown: [OrgDeskIssue] {
        switch filter {
        case .open: return store.issues.filter(\.isOpen)
        case .review: return store.issues.filter { $0.status == "in_review" }
        case .blocked: return store.issues.filter { $0.status == "blocked" }
        case .done: return store.issues.filter { !$0.isOpen }
        case .all: return store.issues
        }
    }

    private var hireable: [OrgDeskAgent] { agents.filter { !["terminated", "pending_approval"].contains($0.status) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            newIssuePanel
            RoachPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        RoachKicker("Issues")
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 420)
                        .accessibilityIdentifier("org.issues.filter")
                        Spacer()
                        Text("\(shown.count) of \(store.issueTotal)")
                            .font(.roach(size: 11, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                    }
                    if shown.isEmpty {
                        OrgBoardEmptyLine(systemName: "tray", text: filter == .open ? "No open issues. File one above or let an agent pick up a routine." : "Nothing here.")
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, issue in
                        if index > 0 { Divider().overlay(RoachPalette.border) }
                        issueRow(issue)
                    }
                }
            }
        }
    }

    private var newIssuePanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachKicker("File an issue")
                HStack(alignment: .bottom, spacing: 12) {
                    RoachInlineField(title: "Title", value: $newTitle, placeholder: "Write the launch checklist")
                        .onSubmit(create)
                        .accessibilityIdentifier("org.issue.title")
                    Picker("Priority", selection: $newPriority) {
                        ForEach(OrgDeskWords.priorities, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .frame(width: 150)
                    .padding(.bottom, 4)
                    Picker("Assign to", selection: $newAssignee) {
                        Text("Nobody yet").tag("")
                        ForEach(hireable) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 200)
                    .padding(.bottom, 4)
                    Button("File it", action: create)
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("org.issue.create")
                }
                Text(newAssignee.isEmpty
                     ? "Unassigned issues wait in the backlog."
                     : "The agent wakes up and starts on it at its next heartbeat.")
                    .font(.roach(size: 11))
                    .foregroundStyle(RoachPalette.muted)
            }
        }
    }

    private func create() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var body: [String: Any] = ["title": title, "priority": newPriority]
        if !newAssignee.isEmpty { body["assigneeAgentId"] = newAssignee }
        Task {
            await store.act(.issues, company: companyID, using: config, success: "Filed \(title).", "POST", "/issues", body)
            if store.errorMessage == nil { newTitle = "" }
        }
    }

    private func issueRow(_ issue: OrgDeskIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(issue.identifier)
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
                    .frame(width: 70, alignment: .leading)
                Button {
                    expanded = expanded == issue.id ? nil : issue.id
                    if expanded == issue.id { Task { await store.loadComments(issue, company: companyID, using: config) } }
                } label: {
                    Text(issue.title)
                        .font(.roach(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the description and comments")
                RoachTag(issue.priority.capitalized, accent: OrgDeskWords.priorityAccent(issue.priority))
                statusMenu(issue)
                assigneeMenu(issue)
            }
            if expanded == issue.id { issueDetail(issue) }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("org.issue.\(issue.identifier)")
    }

    private func statusMenu(_ issue: OrgDeskIssue) -> some View {
        Menu {
            ForEach(OrgDeskWords.issueStatuses, id: \.self) { status in
                Button(OrgDeskWords.status(status)) {
                    Task {
                        await store.act(.issues, company: companyID, using: config, success: "\(issue.identifier) is \(OrgDeskWords.status(status).lowercased()).",
                                        "PATCH", "/issues/\(issue.id)", ["status": status])
                    }
                }
                .disabled(status == issue.status)
            }
        } label: {
            Text(OrgDeskWords.status(issue.status))
                .font(.roach(size: 11, weight: .semibold))
                .foregroundStyle(OrgDeskWords.statusAccent(issue.status))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Status of \(issue.identifier): \(OrgDeskWords.status(issue.status))")
    }

    private func assigneeMenu(_ issue: OrgDeskIssue) -> some View {
        Menu {
            ForEach(hireable) { agent in
                Button(agent.name) {
                    Task {
                        await store.act(.issues, company: companyID, using: config, success: "\(issue.identifier) went to \(agent.name).",
                                        "PATCH", "/issues/\(issue.id)", ["assigneeAgentId": agent.id])
                    }
                }
                .disabled(agent.id == issue.assigneeAgentId)
            }
        } label: {
            Text(issue.assigneeAgentName ?? "Unassigned")
                .font(.roach(size: 11))
                .foregroundStyle(issue.assigneeAgentName == nil ? RoachPalette.muted : RoachPalette.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(hireable.isEmpty)
        .accessibilityLabel("Assignee of \(issue.identifier): \(issue.assigneeAgentName ?? "nobody")")
    }

    private func issueDetail(_ issue: OrgDeskIssue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = issue.description, !description.isEmpty {
                Text(description)
                    .font(.roach(size: 13))
                    .foregroundStyle(RoachPalette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let thread = store.comments[issue.id] ?? []
            if thread.isEmpty {
                Text("No comments yet.").font(.roach(size: 12)).foregroundStyle(RoachPalette.muted)
            }
            ForEach(thread) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(commentAuthor(comment))
                            .font(.roach(size: 11, weight: .semibold))
                            .foregroundStyle(comment.authorType == "agent" ? RoachPalette.green : RoachPalette.cyan)
                        if let when = OrgDeskFormat.relative(comment.createdAt) {
                            Text(when).font(.roach(size: 10, design: .monospaced)).foregroundStyle(RoachPalette.muted)
                        }
                    }
                    Text(comment.body)
                        .font(.roach(size: 12))
                        .foregroundStyle(RoachPalette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                RoachInlineField(
                    title: "Comment",
                    value: Binding(get: { replies[issue.id] ?? "" }, set: { replies[issue.id] = $0 }),
                    placeholder: "Notes for whoever picks this up"
                )
                Button("Post") {
                    let text = (replies[issue.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task {
                        await store.act(.issues, company: companyID, using: config, success: "Comment posted on \(issue.identifier).",
                                        "POST", "/issues/\(issue.id)/comments", ["body": text])
                        replies[issue.id] = nil
                        await store.loadComments(issue, company: companyID, using: config)
                    }
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .padding(.bottom, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(RoachPalette.shade.opacity(0.22)))
    }

    private func commentAuthor(_ comment: OrgDeskComment) -> String {
        switch comment.authorType {
        case "agent": return agents.first { $0.id == comment.authorId }?.name ?? "Agent"
        case "system": return "RoachClaw"
        default: return comment.authorId == "user_local_owner" ? "You" : "A member"
        }
    }
}

struct OrgBoardEmptyLine: View {
    let systemName: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .foregroundStyle(RoachPalette.green)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(RoachPalette.muted)
        }
        .font(.roach(size: 13))
        .padding(.vertical, 2)
    }
}

// MARK: - Org chart

struct OrgChartBoard: View {
    @ObservedObject var store: OrgBoardStore

    var body: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachKicker("Who reports to whom")
                if store.chart.isEmpty {
                    OrgBoardEmptyLine(systemName: "person.3", text: "No agents yet. Approve a hire and it shows up here.")
                }
                ForEach(store.chart) { root in
                    OrgChartBranch(node: root, depth: 0)
                }
            }
        }
        .accessibilityIdentifier("org.chart")
    }
}

private struct OrgChartBranch: View {
    let node: OrgDeskChartNode
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if depth > 0 {
                    Rectangle()
                        .fill(RoachPalette.border)
                        .frame(width: 18, height: 1)
                        .accessibilityHidden(true)
                }
                Circle()
                    .fill(OrgDeskWords.statusAccent(node.status))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.roach(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text([node.title ?? node.role?.uppercased(), OrgDeskWords.status(node.status)].compactMap { $0 }.joined(separator: " · "))
                        .font(.roach(size: 11))
                        .foregroundStyle(RoachPalette.muted)
                }
                Spacer(minLength: 0)
                if !node.reports.isEmpty {
                    Text("\(node.reports.count) report\(node.reports.count == 1 ? "" : "s")")
                        .font(.roach(size: 11, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous).fill(RoachPalette.shade.opacity(depth == 0 ? 0.28 : 0.16)))
            .accessibilityElement(children: .combine)
            if !node.reports.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(node.reports) { OrgChartBranch(node: $0, depth: depth + 1) }
                }
                .padding(.leading, 22)
                .overlay(alignment: .leading) {
                    Rectangle().fill(RoachPalette.border).frame(width: 1).padding(.leading, 22).padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - Routines

struct OrgRoutinesBoard: View {
    @ObservedObject var store: OrgBoardStore
    let companyID: String
    let agents: [OrgDeskAgent]
    let config: RoachNetInstallerConfig

    @State private var title = ""
    @State private var assignee = ""
    @State private var cron = OrgDeskWords.schedulePresets[1].cron

    private var workers: [OrgDeskAgent] { agents.filter { !["terminated", "pending_approval"].contains($0.status) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 10) {
                    RoachKicker("New routine")
                    HStack(alignment: .bottom, spacing: 12) {
                        RoachInlineField(title: "What to do", value: $title, placeholder: "Summarize yesterday's issues")
                            .accessibilityIdentifier("org.routine.title")
                        Picker("When", selection: $cron) {
                            ForEach(OrgDeskWords.schedulePresets, id: \.cron) { Text($0.label).tag($0.cron) }
                        }
                        .frame(width: 230)
                        .padding(.bottom, 4)
                        Picker("Who", selection: $assignee) {
                            Text("Pick an agent").tag("")
                            ForEach(workers) { Text($0.name).tag($0.id) }
                        }
                        .frame(width: 200)
                        .padding(.bottom, 4)
                        Button("Add routine", action: create)
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || assignee.isEmpty)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("org.routine.create")
                    }
                    Text("Each run files an issue for the agent, on this Mac's clock (\(TimeZone.current.identifier)). A run that finds the last one still open folds into it.")
                        .font(.roach(size: 11))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RoachPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachKicker("Routines")
                    if store.routines.isEmpty {
                        OrgBoardEmptyLine(systemName: "clock.arrow.circlepath", text: "No routines. Add one above to put recurring work on an agent's calendar.")
                    }
                    ForEach(Array(store.routines.filter { $0.status != "archived" }.enumerated()), id: \.element.id) { index, routine in
                        if index > 0 { Divider().overlay(RoachPalette.border) }
                        routineRow(routine)
                    }
                }
            }
        }
    }

    private func create() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assignee.isEmpty else { return }
        let body: [String: Any] = [
            "title": text,
            "assigneeAgentId": assignee,
            "triggers": [["kind": "schedule", "cronExpression": cron, "timezone": TimeZone.current.identifier]],
        ]
        Task {
            await store.act(.routines, company: companyID, using: config, success: "Routine added: \(text).", "POST", "/routines", body)
            if store.errorMessage == nil { title = "" }
        }
    }

    private func routineRow(_ routine: OrgDeskRoutine) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(routine.title)
                        .font(.roach(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    RoachTag(routine.status.capitalized, accent: routine.status == "active" ? RoachPalette.green : RoachPalette.bronze)
                }
                Text(routineDetail(routine))
                    .font(.roach(size: 11))
                    .foregroundStyle(RoachPalette.muted)
            }
            Spacer(minLength: 12)
            Button("Run now") {
                Task { await store.act(.routines, company: companyID, using: config, success: "\(routine.title) is running.", "POST", "/routines/\(routine.id)/run", [:]) }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(routine.status != "active")
            Button(routine.status == "active" ? "Pause" : "Resume") {
                let next = routine.status == "active" ? "paused" : "active"
                Task {
                    await store.act(.routines, company: companyID, using: config, success: next == "paused" ? "\(routine.title) paused." : "\(routine.title) resumed.",
                                    "PATCH", "/routines/\(routine.id)", ["status": next])
                }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("org.routine.\(routine.id)")
    }

    private func routineDetail(_ routine: OrgDeskRoutine) -> String {
        var parts = [OrgDeskWords.schedule(routine.schedule?.cronExpression)]
        if let agent = agents.first(where: { $0.id == routine.assigneeAgentId }) { parts.append(agent.name) }
        if routine.status == "active", let next = OrgDeskFormat.relative(routine.schedule?.nextRunAt) { parts.append("next \(next)") }
        if let last = OrgDeskFormat.relative(routine.lastTriggeredAt) { parts.append("last ran \(last)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Budgets

struct OrgBudgetsBoard: View {
    @ObservedObject var store: OrgBoardStore
    let companyID: String
    let agents: [OrgDeskAgent]
    let config: RoachNetInstallerConfig

    @State private var dollars = ""
    @State private var scope = "company"
    @State private var edits: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            openIncidents
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 10) {
                    RoachKicker("Set a monthly budget")
                    HStack(alignment: .bottom, spacing: 12) {
                        Picker("For", selection: $scope) {
                            Text("The whole company").tag("company")
                            ForEach(agents.filter { $0.status != "terminated" }) { Text($0.name).tag($0.id) }
                        }
                        .frame(width: 240)
                        .padding(.bottom, 4)
                        RoachInlineField(title: "Dollars a month", value: $dollars, placeholder: "40")
                            .frame(width: 160)
                            .accessibilityIdentifier("org.budget.amount")
                        Button("Save budget", action: create)
                            .buttonStyle(RoachPrimaryButtonStyle())
                            .disabled(cents(dollars) == nil)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("org.budget.create")
                    }
                    Text("At 80% you get a warning. At 100% the agent stops and asks for an override, which lands in your approvals.")
                        .font(.roach(size: 11))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
            RoachPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachKicker("Budgets")
                    if store.budgets.isEmpty {
                        OrgBoardEmptyLine(systemName: "dollarsign.circle", text: "No budgets yet. Local models cost nothing; budgets matter once an agent uses a paid provider.")
                    }
                    ForEach(Array(store.budgets.enumerated()), id: \.element.id) { index, budget in
                        if index > 0 { Divider().overlay(RoachPalette.border) }
                        budgetRow(budget)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var openIncidents: some View {
        let open = store.incidents.filter { $0.status == "open" }
        if !open.isEmpty {
            RoachPanel {
                VStack(alignment: .leading, spacing: 10) {
                    RoachKicker("Over budget")
                    ForEach(open) { incident in
                        HStack(spacing: 10) {
                            RoachTag(incident.thresholdType == "hard" ? "Stopped" : "Warning", accent: incident.thresholdType == "hard" ? RoachPalette.warning : RoachPalette.bronze)
                            Text("\(scopeName(policyID: incident.policyId)) spent \(OrgDeskFormat.dollars(incident.amountObserved)) of \(OrgDeskFormat.dollars(incident.amountLimit)).")
                                .font(.roach(size: 13))
                                .foregroundStyle(RoachPalette.text)
                            Spacer()
                            Button(incident.thresholdType == "hard" ? "Resolve and resume" : "Dismiss") {
                                Task {
                                    await store.act(.budgets, company: companyID, using: config, success: "Budget incident closed.",
                                                    "POST", "/budget-incidents/\(incident.id)/resolve", ["status": incident.thresholdType == "hard" ? "resolved" : "dismissed"])
                                }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func budgetRow(_ budget: OrgDeskBudget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(scopeName(budget))
                    .font(.roach(size: 14, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                RoachTag(budget.windowKind == "lifetime" ? "Lifetime" : "Monthly", accent: RoachPalette.cyan)
                if budget.isActive == false { RoachTag("Off", accent: RoachPalette.muted) }
                Spacer()
                Text("\(OrgDeskFormat.dollars(budget.observedCents ?? 0)) of \(OrgDeskFormat.dollars(budget.amountCents))")
                    .font(.roach(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(budget.share >= 1 ? RoachPalette.warning : RoachPalette.text)
            }
            ProgressView(value: min(budget.share, 1))
                .tint(budget.share >= 1 ? RoachPalette.warning : budget.share >= Double(budget.warnPercent ?? 80) / 100 ? RoachPalette.bronze : RoachPalette.green)
                .accessibilityLabel("\(Int(budget.share * 100)) percent of \(scopeName(budget))'s budget used")
            HStack(alignment: .bottom, spacing: 10) {
                RoachInlineField(
                    title: "New amount (dollars)",
                    value: Binding(get: { edits[budget.id] ?? "" }, set: { edits[budget.id] = $0 }),
                    placeholder: String(budget.amountCents / 100)
                )
                .frame(width: 180)
                Button("Update") {
                    guard let amount = cents(edits[budget.id] ?? "") else { return }
                    Task {
                        await store.act(.budgets, company: companyID, using: config, success: "\(scopeName(budget)) now has \(OrgDeskFormat.dollars(amount)).",
                                        "PATCH", "/budgets/\(budget.id)", ["amountCents": amount])
                        edits[budget.id] = nil
                    }
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(cents(edits[budget.id] ?? "") == nil)
                .padding(.bottom, 4)
                Toggle("Stop at the limit", isOn: Binding(
                    get: { budget.hardStopEnabled ?? true },
                    set: { on in
                        Task {
                            await store.act(.budgets, company: companyID, using: config, success: on ? "Hard stop on." : "Hard stop off: the agent keeps going and you get warnings.",
                                            "PATCH", "/budgets/\(budget.id)", ["hardStopEnabled": on])
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 3)
    }

    private func create() {
        guard let amount = cents(dollars) else { return }
        var body: [String: Any] = ["amountCents": amount, "windowKind": "calendar_month_utc"]
        if scope == "company" {
            body["scopeType"] = "company"
        } else {
            body["scopeType"] = "agent"
            body["scopeId"] = scope
        }
        let existing = store.budgets.first { $0.scopeType == body["scopeType"] as? String && ($0.scopeType == "company" || $0.scopeId == scope) && $0.windowKind == "calendar_month_utc" }
        Task {
            if let existing {
                await store.act(.budgets, company: companyID, using: config, success: "Budget updated.", "PATCH", "/budgets/\(existing.id)", ["amountCents": amount, "isActive": true])
            } else {
                await store.act(.budgets, company: companyID, using: config, success: "Budget set.", "POST", "/budgets", body)
            }
            if store.errorMessage == nil { dollars = "" }
        }
    }

    /// "40", "$40", "39.50" → cents; nil for anything that isn't a non-negative amount.
    private func cents(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, let value = Double(cleaned), value >= 0, value < 10_000_000 else { return nil }
        return Int((value * 100).rounded())
    }

    private func scopeName(_ budget: OrgDeskBudget) -> String {
        switch budget.scopeType {
        case "company": return "The company"
        case "agent": return agents.first { $0.id == budget.scopeId }?.name ?? "An agent"
        default: return "A project"
        }
    }

    private func scopeName(policyID: String) -> String {
        store.budgets.first { $0.id == policyID }.map(scopeName) ?? "A budget"
    }
}
