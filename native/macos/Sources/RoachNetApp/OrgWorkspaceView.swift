import AppKit
import SwiftUI
import RoachNetCore
import RoachNetDesign

// MARK: - Models (lenient views of /api/org responses)

struct OrgDeskCompany: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let status: String?
}

struct OrgDeskApproval: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let status: String
    let payload: [String: OrgDeskValue]?
    let decisionNote: String?
    let createdAt: String?

    var isOpen: Bool { status == "pending" || status == "revision_requested" }

    var headline: String {
        for key in ["title", "summary", "name", "agentName", "strategy", "reason"] {
            if let text = payload?[key]?.text { return text }
        }
        return typeTitle
    }

    var typeTitle: String {
        switch type {
        case "hire_agent": return "Hire an agent"
        case "approve_ceo_strategy": return "CEO strategy"
        case "budget_override_required": return "Budget override"
        default: return "Board approval"
        }
    }

    var details: [(String, String)] {
        (payload ?? [:]).keys.sorted().compactMap { key in
            guard !["title", "summary"].contains(key), let text = payload?[key]?.text else { return nil }
            return (key.replacingOccurrences(of: "_", with: " ").capitalized, text)
        }
    }
}

enum OrgDeskValue: Decodable, Hashable {
    case text(String), number(Double), flag(Bool), other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .text(v) }
        else if let v = try? c.decode(Bool.self) { self = .flag(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else { self = .other }
    }

    var text: String? {
        switch self {
        case .text(let v): return v.isEmpty ? nil : v
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .flag(let v): return v ? "Yes" : "No"
        case .other: return nil
        }
    }
}

struct OrgDeskAgent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let title: String?
    let status: String
}

struct OrgDeskJoinRequest: Decodable, Identifiable, Hashable {
    let id: String
    let requestType: String?
    let status: String
    let userName: String?
    let agentName: String?
    let email: String?
    let createdAt: String?
}

struct OrgDeskDashboard: Decodable {
    let company: OrgDeskCompany
    let issuesByStatus: [String: Int]?
    let agentsByStatus: [String: Int]?
    let pendingApprovals: Int?
    let runningRuns: Int?
    let monthSpendCents: Int?
    let companyBudgetCents: Int?

    var openIssues: Int { (issuesByStatus ?? [:]).filter { !["done", "cancelled"].contains($0.key) }.values.reduce(0, +) }
}

// MARK: - Store

@MainActor
final class OrgDeskStore: ObservableObject {
    @Published var companies: [OrgDeskCompany] = []
    @Published var selectedCompanyID: String?
    @Published var dashboard: OrgDeskDashboard?
    @Published var approvals: [OrgDeskApproval] = []
    @Published var agents: [OrgDeskAgent] = []
    @Published var joinRequests: [OrgDeskJoinRequest] = []
    @Published var lastInvite: (token: String, link: String, role: String)?
    @Published var isLoading = false
    @Published var unsupported = false
    @Published var message: String?
    @Published var errorMessage: String?

    private let decoder = JSONDecoder()

    func refresh(using config: RoachNetInstallerConfig) async {
        isLoading = true
        defer { isLoading = false }
        do {
            struct List: Decodable { let companies: [OrgDeskCompany] }
            let list: List = try await get("/api/org/companies", config)
            companies = list.companies
            unsupported = false
            if selectedCompanyID == nil || !companies.contains(where: { $0.id == selectedCompanyID }) {
                selectedCompanyID = companies.first?.id
            }
            guard let cid = selectedCompanyID else {
                dashboard = nil; approvals = []; agents = []; joinRequests = []
                return
            }
            struct Approvals: Decodable { let approvals: [OrgDeskApproval] }
            struct Agents: Decodable { let agents: [OrgDeskAgent] }
            struct Joins: Decodable { let joinRequests: [OrgDeskJoinRequest] }
            dashboard = try await get("/api/org/companies/\(cid)/dashboard", config)
            approvals = (try await get("/api/org/companies/\(cid)/approvals", config) as Approvals).approvals
            agents = (try await get("/api/org/companies/\(cid)/agents", config) as Agents).agents
            joinRequests = ((try? await get("/api/org/companies/\(cid)/join-requests", config)) as Joins?)?.joinRequests ?? []
            errorMessage = nil
        } catch let error as NSError where error.domain == "RoachNetOrg" && error.code == 404 {
            unsupported = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createCompany(name: String, using config: RoachNetInstallerConfig) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await act(config, success: "\(trimmed) is open for business.") {
            struct Created: Decodable { let company: OrgDeskCompany }
            let created: Created = try await self.post("/api/org/companies", ["name": trimmed], config)
            self.selectedCompanyID = created.company.id
        }
    }

    func decide(_ approval: OrgDeskApproval, _ decision: String, note: String, using config: RoachNetInstallerConfig) async {
        guard let cid = selectedCompanyID else { return }
        let body: [String: Any] = note.isEmpty ? [:] : ["note": note]
        let done = decision == "approve" ? "Approved." : decision == "reject" ? "Rejected." : "Sent back for changes."
        await act(config, success: done) {
            let _: OrgDeskIgnored = try await self.post("/api/org/companies/\(cid)/approvals/\(approval.id)/\(decision)", body, config)
        }
    }

    func setAgent(_ agent: OrgDeskAgent, _ action: String, using config: RoachNetInstallerConfig) async {
        guard let cid = selectedCompanyID else { return }
        await act(config, success: action == "pause" ? "\(agent.name) paused." : "\(agent.name) is back to work.") {
            let _: OrgDeskIgnored = try await self.post("/api/org/companies/\(cid)/agents/\(agent.id)/\(action)", [:], config)
        }
    }

    func createInvite(role: String, using config: RoachNetInstallerConfig) async {
        guard let cid = selectedCompanyID else { return }
        await act(config, success: "Invite ready. It works once and expires in 72 hours.") {
            struct Invite: Decodable { let token: String }
            let invite: Invite = try await self.post("/api/org/companies/\(cid)/invites", ["role": role], config)
            let link = "roachnet://org-invite?token=\(invite.token)"
            self.lastInvite = (invite.token, link, role)
        }
    }

    func decideJoin(_ request: OrgDeskJoinRequest, approve: Bool, using config: RoachNetInstallerConfig) async {
        guard let cid = selectedCompanyID else { return }
        let who = request.userName ?? request.agentName ?? "They"
        await act(config, success: approve ? "\(who) is in." : "\(who) was turned away.") {
            let _: OrgDeskIgnored = try await self.post("/api/org/companies/\(cid)/join-requests/\(request.id)/\(approve ? "approve" : "reject")", [:], config)
        }
    }

    private func act(_ config: RoachNetInstallerConfig, success: String, _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            message = success
            errorMessage = nil
            await refresh(using: config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func get<T: Decodable>(_ path: String, _ config: RoachNetInstallerConfig) async throws -> T {
        let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: path)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], _ config: RoachNetInstallerConfig) async throws -> T {
        let json = try JSONSerialization.data(withJSONObject: body)
        let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: path, method: "POST", jsonBody: json)
        return try decoder.decode(T.self, from: data)
    }
}

private struct OrgDeskIgnored: Decodable {}

// MARK: - View

/// RoachClaw Org on the Mac: the owner's desk for the agent company running in
/// roachnet-runtime. Approvals and joins decided here show up on paired phones too.
struct OrgWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var store = OrgDeskStore()
    @State private var newCompanyName = ""
    @State private var inviteRole = "operator"
    @State private var notes: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RoachSectionHeader(
                    "RoachClaw Org",
                    title: store.dashboard?.company.name ?? "Your agent company.",
                    detail: "Hire agents, set budgets and approve their work. It all runs on this Mac; paired phones can approve too."
                )
                banners
                if store.unsupported {
                    RoachNotice(title: "Org isn't running", detail: "This runtime has no RoachClaw Org. Update roachnet-runtime to 1.1 or later.", accent: RoachPalette.bronze)
                } else if store.companies.isEmpty && !store.isLoading {
                    createCompany
                } else {
                    companyPicker
                    metrics
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 18) {
                            approvalsPanel
                            agentsPanel
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 18) {
                            invitePanel
                            joinPanel
                        }
                        .frame(width: 340, alignment: .topLeading)
                    }
                }
            }
            .padding(24)
        }
        .task { await store.refresh(using: model.config) }
        .accessibilityIdentifier("pane.org")
    }

    @ViewBuilder
    private var banners: some View {
        if let error = store.errorMessage {
            RoachNotice(title: "That didn't go through", detail: error, accent: RoachPalette.magenta)
        } else if let message = store.message {
            RoachNotice(title: message, detail: "Phones paired over RoachTail see this too.", accent: RoachPalette.green, systemName: "checkmark.circle.fill")
        }
    }

    private var createCompany: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachKicker("Start one")
                Text("No company yet. Name it and RoachClaw sets up the org chart, issues and budgets.")
                    .foregroundStyle(RoachPalette.muted)
                HStack {
                    TextField("Company name", text: $newCompanyName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Button("Create company") { Task { await store.createCompany(name: newCompanyName, using: model.config) } }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(newCompanyName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var companyPicker: some View {
        HStack(spacing: 10) {
            if store.companies.count > 1 {
                Picker("Company", selection: Binding(
                    get: { store.selectedCompanyID ?? "" },
                    set: { id in store.selectedCompanyID = id; Task { await store.refresh(using: model.config) } }
                )) {
                    ForEach(store.companies) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 280)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await store.refresh(using: model.config) } }
                .buttonStyle(RoachSecondaryButtonStyle())
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            RoachMetricCard(label: "Approvals", value: "\(store.approvals.filter(\.isOpen).count)", detail: "Waiting on you")
            RoachMetricCard(label: "Agents", value: "\(store.agents.filter { $0.status != "terminated" }.count)", detail: "On the books")
            RoachMetricCard(label: "Open issues", value: "\(store.dashboard?.openIssues ?? 0)", detail: "Across projects")
            RoachMetricCard(label: "Running", value: "\(store.dashboard?.runningRuns ?? 0)", detail: "Heartbeats live")
        }
    }

    private var approvalsPanel: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachKicker("Waiting on you")
                let open = store.approvals.filter(\.isOpen)
                if open.isEmpty {
                    Text("Nothing waiting. The agents are behaving.").foregroundStyle(RoachPalette.muted)
                }
                ForEach(open) { approval in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            RoachTag(approval.typeTitle, accent: RoachPalette.magenta)
                            if approval.status == "revision_requested" { RoachTag("Sent back", accent: RoachPalette.bronze) }
                            Spacer()
                        }
                        Text(approval.headline).font(.headline).foregroundStyle(RoachPalette.text)
                        ForEach(approval.details, id: \.0) { line in
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.0).font(.caption.monospaced()).foregroundStyle(RoachPalette.muted).frame(width: 90, alignment: .leading)
                                Text(line.1).foregroundStyle(RoachPalette.text)
                            }
                        }
                        TextField("Note for the agent (optional)", text: Binding(get: { notes[approval.id] ?? "" }, set: { notes[approval.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Approve") { decide(approval, "approve") }.buttonStyle(RoachPrimaryButtonStyle())
                            Button("Send back") { decide(approval, "request-revision") }.buttonStyle(RoachSecondaryButtonStyle())
                            Button("Reject") { decide(approval, "reject") }.buttonStyle(RoachUtilityButtonStyle())
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func decide(_ approval: OrgDeskApproval, _ decision: String) {
        let note = (notes[approval.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await store.decide(approval, decision, note: note, using: model.config)
            notes[approval.id] = nil
        }
    }

    private var agentsPanel: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachKicker("Agents")
                if store.agents.isEmpty {
                    Text("No agents hired yet. Agents can request hires; you approve them above.").foregroundStyle(RoachPalette.muted)
                }
                ForEach(store.agents) { agent in
                    HStack {
                        RoachStatusRow(title: "\(agent.name) · \(agent.title ?? agent.role?.uppercased() ?? "Agent")", value: agent.status.capitalized,
                                       accent: agent.status == "running" ? RoachPalette.green : agent.status == "paused" ? RoachPalette.bronze : RoachPalette.cyan)
                        if agent.status != "terminated" {
                            Button(agent.status == "paused" ? "Resume" : "Pause") {
                                Task { await store.setAgent(agent, agent.status == "paused" ? "resume" : "pause", using: model.config) }
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var invitePanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachKicker("Invite a person")
                Text("Send the link to a phone paired over RoachTail. They ask to join; you approve below.")
                    .font(.callout).foregroundStyle(RoachPalette.muted)
                Picker("Role", selection: $inviteRole) {
                    Text("Viewer").tag("viewer")
                    Text("Operator").tag("operator")
                    Text("Admin (can approve)").tag("admin")
                }
                Button("Create invite") { Task { await store.createInvite(role: inviteRole, using: model.config) } }
                    .buttonStyle(RoachPrimaryButtonStyle())
                if let invite = store.lastInvite {
                    Text(invite.link)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(3)
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.link, forType: .string)
                        store.message = "Invite link copied."
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }
            }
        }
    }

    private var joinPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachKicker("Asking to join")
                let pending = store.joinRequests.filter { $0.status == "pending_approval" }
                if pending.isEmpty {
                    Text("Nobody waiting at the door.").font(.callout).foregroundStyle(RoachPalette.muted)
                }
                ForEach(pending) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.userName ?? request.agentName ?? "Someone").font(.headline).foregroundStyle(RoachPalette.text)
                        if let email = request.email { Text(email).font(.caption).foregroundStyle(RoachPalette.muted) }
                        HStack {
                            Button("Let them in") { Task { await store.decideJoin(request, approve: true, using: model.config) } }
                                .buttonStyle(RoachPrimaryButtonStyle())
                            Button("Turn away") { Task { await store.decideJoin(request, approve: false, using: model.config) } }
                                .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }
}
