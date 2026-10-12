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

    /// Payload fields worth showing under the headline, with readable labels
    /// ("monthlyBudgetCents" → "Monthly budget" / "$40.00").
    var details: [(String, String)] {
        (payload ?? [:]).keys.sorted().compactMap { key in
            guard !["title", "summary", "agentId"].contains(key), let value = payload?[key] else { return nil }
            if key.hasSuffix("Cents"), let cents = value.cents {
                return (OrgDeskFormat.label(String(key.dropLast(5))), OrgDeskFormat.dollars(cents))
            }
            guard let text = value.text else { return nil }
            // Roles and statuses come through as identifiers ("writer"); show them as words.
            let shown = ["role", "status", "strategy"].contains(key) && !text.contains(" ") ? text.capitalized : text
            return (OrgDeskFormat.label(key), shown)
        }
    }
}

enum OrgDeskFormat {
    /// "monthlyBudget" / "monthly_budget" → "Monthly budget".
    static func label(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key.replacingOccurrences(of: "_", with: " ") {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character).lowercased()
            } else if character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return key }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    static func dollars(_ cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "$\(cents / 100)"
    }

    static func relative(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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

    /// Money fields arrive as numbers or numeric strings depending on who filed the approval.
    var cents: Int? {
        switch self {
        case .number(let v): return Int(v)
        case .text(let v): return Int(v.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

struct OrgDeskAgent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let title: String?
    let status: String
    let errorReason: String?

    /// Why the last heartbeat failed, in words someone can act on.
    var problem: String? {
        guard status == "error" else { return nil }
        guard let reason = errorReason, !reason.isEmpty else { return "Its last heartbeat failed." }
        if reason.contains("returned 404") {
            return "Its model isn't on this Mac. Pull one in RoachClaw, then try again."
        }
        return reason
    }
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
    @StateObject private var board = OrgBoardStore()
    @StateObject private var traceStore = OrgTraceStore()
    @State private var section: OrgBoardSection = .desk
    @State private var newCompanyName = ""
    @State private var inviteRole = "operator"
    @State private var notes: [String: String] = [:]

    /// Agents file approvals and phones answer them while this pane sits open,
    /// so it re-reads the desk on a slow cadence instead of waiting for Refresh.
    private let refreshCadence: Duration = .seconds(20)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                banners
                if store.unsupported {
                    RoachNotice(
                        title: "Org isn't running",
                        detail: "This runtime has no RoachClaw Org. Update roachnet-runtime to 1.1 or later.",
                        accent: RoachPalette.bronze
                    )
                } else if store.companies.isEmpty && !store.isLoading {
                    emptyDesk
                } else if store.companies.isEmpty {
                    loadingDesk
                } else {
                    companyCard
                    metrics
                    sectionPicker
                    sectionContent
                }
            }
            .padding(24)
        }
        .task {
            if let pending = OrgBoardRequest.pending {
                section = pending
                OrgBoardRequest.pending = nil
            }
            await store.refresh(using: model.config)
            await loadBoard()
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshCadence)
                guard !Task.isCancelled, !store.isLoading else { continue }
                await store.refresh(using: model.config)
                if !board.isLoading { await loadBoard() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .roachOrgSectionRequest)) { note in
            if let raw = note.object as? String, let requested = OrgBoardSection(rawValue: raw) {
                section = requested
                OrgBoardRequest.pending = nil
            }
        }
        .onChange(of: section) { _, _ in
            board.message = nil
            Task { await loadBoard() }
        }
        .onChange(of: store.selectedCompanyID) { _, _ in
            Task { await loadBoard() }
        }
        .accessibilityIdentifier("pane.org")
    }

    // MARK: Sections

    private func loadBoard() async {
        guard section != .desk, let cid = store.selectedCompanyID else { return }
        if section == .traces {
            await traceStore.load(company: cid, using: model.config)
            return
        }
        await board.load(section, company: cid, using: model.config)
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(OrgBoardSection.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 660)
        .accessibilityIdentifier("org.section")
    }

    @ViewBuilder
    private var sectionContent: some View {
        if let cid = store.selectedCompanyID {
            switch section {
            case .desk:
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
            case .issues:
                OrgIssuesBoard(store: board, companyID: cid, agents: store.agents, config: model.config)
            case .chart:
                OrgChartBoard(store: board)
            case .routines:
                OrgRoutinesBoard(store: board, companyID: cid, agents: store.agents, config: model.config)
            case .budgets:
                OrgBudgetsBoard(store: board, companyID: cid, agents: store.agents, config: model.config)
            case .traces:
                OrgTracesBoard(store: traceStore, companyID: cid, agents: store.agents, config: model.config)
            }
        }
    }

    // MARK: Header and banners

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            RoachSectionHeader(
                "RoachClaw Org",
                title: store.dashboard?.company.name ?? "Your agent company.",
                detail: "Hire agents, set budgets and approve their work. It all runs on this Mac; paired phones can approve too."
            )
            Spacer(minLength: 12)
            if !store.companies.isEmpty {
                HStack(spacing: 10) {
                    if store.companies.count > 1 {
                        Picker("Company", selection: Binding(
                            get: { store.selectedCompanyID ?? "" },
                            set: { id in store.selectedCompanyID = id; Task { await store.refresh(using: model.config) } }
                        )) {
                            ForEach(store.companies) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Company")
                    }
                    if store.isLoading { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await store.refresh(using: model.config) } }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .accessibilityIdentifier("org.refresh")
                }
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let error = board.errorMessage ?? store.errorMessage {
            RoachNotice(title: "That didn't go through", detail: error, accent: RoachPalette.magenta)
        } else if let message = board.message {
            RoachNotice(
                title: message,
                detail: "Agents see the change at their next heartbeat.",
                accent: RoachPalette.green,
                systemName: "checkmark.circle.fill"
            )
        } else if let error = store.errorMessage {
            RoachNotice(title: "That didn't go through", detail: error, accent: RoachPalette.magenta)
        } else if let message = store.message {
            RoachNotice(
                title: message,
                detail: "Phones paired over RoachTail see this too.",
                accent: RoachPalette.green,
                systemName: "checkmark.circle.fill"
            )
        }
    }

    // MARK: Empty and loading desks

    private var loadingDesk: some View {
        RoachPanel {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Opening the desk…").foregroundStyle(RoachPalette.muted)
            }
        }
    }

    /// First run: say what the Org does, then take a name. Fills the pane
    /// instead of leaving a lone field at the top of an empty canvas.
    private var emptyDesk: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.magenta) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        RoachKicker("Start one")
                        Text("A company of agents. You hold the pen.")
                            .font(.roach(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Name it and RoachClaw sets up the org chart, issues and budgets. Agents propose hires and spend; nothing happens until you say so, here or on a paired phone.")
                            .font(.roach(size: 14))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .bottom, spacing: 12) {
                            RoachInlineField(title: "Company name", value: $newCompanyName, placeholder: "RoachWares Studio")
                                .frame(maxWidth: 360)
                                .onSubmit { createCompany() }
                                .accessibilityIdentifier("org.companyName")
                            Button("Create company") { createCompany() }
                                .buttonStyle(RoachPrimaryButtonStyle())
                                .disabled(newCompanyName.trimmingCharacters(in: .whitespaces).isEmpty)
                                .padding(.bottom, 6)
                                .accessibilityIdentifier("org.createCompany")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "person.3.sequence.fill")
                        .font(.roach(size: 64, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [RoachPalette.magenta, RoachPalette.green], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .shadow(color: RoachPalette.magenta.opacity(RoachMetrics.glow(0.35)), radius: 24, y: 8)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .accessibilityHidden(true)
                }
                .padding(14)
            }

            HStack(alignment: .top, spacing: 14) {
                RoachFeatureTile(
                    "Approvals",
                    title: "Hires, budgets, strategy",
                    detail: "Agents ask; you approve, send back or reject with a note they can read.",
                    systemName: "checkmark.seal.fill",
                    accent: RoachPalette.magenta
                )
                RoachFeatureTile(
                    "Agents",
                    title: "Local models on the books",
                    detail: "Every agent runs on this Mac's RoachInference lane. Pause one and it stops mid-heartbeat.",
                    systemName: "cpu.fill",
                    accent: RoachPalette.green
                )
                RoachFeatureTile(
                    "Phones",
                    title: "Approve from your pocket",
                    detail: "Invite people over RoachTail. Admins can decide approvals from the iOS companion.",
                    systemName: "iphone.gen3",
                    accent: RoachPalette.cyan
                )
            }
        }
    }

    private func createCompany() {
        let name = newCompanyName
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await store.createCompany(name: name, using: model.config)
            if store.errorMessage == nil { newCompanyName = "" }
        }
    }

    // MARK: Company and metrics

    private var companyCard: some View {
        RoachInsetPanel {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "building.2.fill")
                    .font(.roach(size: 20, weight: .semibold))
                    .foregroundStyle(RoachPalette.magenta)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(RoachPalette.magenta.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(store.dashboard?.company.name ?? store.companies.first(where: { $0.id == store.selectedCompanyID })?.name ?? "Company")
                            .font(.roach(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                        let status = store.dashboard?.company.status ?? "active"
                        RoachTag(status.capitalized, accent: status == "active" ? RoachPalette.green : RoachPalette.bronze)
                    }
                    Text(companySubtitle)
                        .font(.roach(size: 12))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if let budget = store.dashboard?.companyBudgetCents, budget > 0 {
                    let spend = store.dashboard?.monthSpendCents ?? 0
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(OrgDeskFormat.dollars(spend)) of \(OrgDeskFormat.dollars(budget))")
                            .font(.roach(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(spend > budget ? RoachPalette.warning : RoachPalette.text)
                        Text("This month's budget")
                            .font(.roach(size: 11))
                            .foregroundStyle(RoachPalette.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var companySubtitle: String {
        if let description = store.dashboard?.company.description, !description.isEmpty { return description }
        return "Runs on this Mac. Approvals and joins sync to paired phones."
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            RoachMetricCard(label: "Approvals", value: "\(openApprovals.count)", detail: openApprovals.isEmpty ? "Nothing waiting" : "Waiting on you")
            RoachMetricCard(label: "Agents", value: "\(activeAgents.count)", detail: "On the books")
            RoachMetricCard(label: "Open issues", value: "\(store.dashboard?.openIssues ?? 0)", detail: "Across projects")
            RoachMetricCard(label: "Running", value: "\(store.dashboard?.runningRuns ?? 0)", detail: "Heartbeats live")
        }
    }

    private var openApprovals: [OrgDeskApproval] { store.approvals.filter(\.isOpen) }
    private var activeAgents: [OrgDeskAgent] { store.agents.filter { $0.status != "terminated" } }
    private var pendingJoins: [OrgDeskJoinRequest] { store.joinRequests.filter { $0.status == "pending_approval" } }

    // MARK: Approvals

    private var approvalsPanel: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RoachKicker("Waiting on you")
                    Spacer()
                    if !openApprovals.isEmpty {
                        RoachTag("\(openApprovals.count) open", accent: RoachPalette.magenta)
                    }
                }
                if openApprovals.isEmpty {
                    emptyLine("checkmark.circle", "Nothing waiting. The agents are behaving.")
                }
                ForEach(Array(openApprovals.enumerated()), id: \.element.id) { index, approval in
                    if index > 0 { Divider().overlay(RoachPalette.border) }
                    approvalRow(approval)
                }
            }
        }
    }

    private func approvalRow(_ approval: OrgDeskApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoachTag(approval.typeTitle, accent: RoachPalette.magenta)
                if approval.status == "revision_requested" { RoachTag("Sent back", accent: RoachPalette.bronze) }
                Spacer()
                if let when = OrgDeskFormat.relative(approval.createdAt) {
                    Text(when)
                        .font(.roach(size: 11, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
            Text(approval.headline)
                .font(.roach(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .fixedSize(horizontal: false, vertical: true)
            if !approval.details.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(approval.details, id: \.0) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.0)
                                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .frame(width: 120, alignment: .leading)
                            Text(line.1)
                                .font(.roach(size: 13))
                                .foregroundStyle(RoachPalette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(RoachPalette.shade.opacity(0.22)))
            }
            RoachInlineField(
                title: "Note for the agent (optional)",
                value: Binding(get: { notes[approval.id] ?? "" }, set: { notes[approval.id] = $0 }),
                placeholder: "Why, or what to change"
            )
            HStack(spacing: 8) {
                Button("Approve") { decide(approval, "approve") }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .accessibilityIdentifier("org.approve")
                Button("Send back") { decide(approval, "request-revision") }
                    .buttonStyle(RoachSecondaryButtonStyle())
                Button("Reject") { decide(approval, "reject") }
                    .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.warning))
            }
        }
        .padding(.vertical, 4)
    }

    private func decide(_ approval: OrgDeskApproval, _ decision: String) {
        let note = (notes[approval.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await store.decide(approval, decision, note: note, using: model.config)
            notes[approval.id] = nil
        }
    }

    private func emptyLine(_ systemName: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .foregroundStyle(RoachPalette.green)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(RoachPalette.muted)
        }
        .font(.roach(size: 13))
        .padding(.vertical, 2)
    }

    // MARK: Agents

    private var agentsPanel: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoachKicker("Agents")
                    Spacer()
                    if !activeAgents.isEmpty {
                        Text("\(activeAgents.count) on the books")
                            .font(.roach(size: 11, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }
                if store.agents.isEmpty {
                    emptyLine("person.badge.plus", "No agents hired yet. Agents can request hires; you approve them above.")
                }
                ForEach(store.agents) { agent in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            RoachStatusRow(
                                title: "\(agent.name) · \(agent.title ?? agent.role?.uppercased() ?? "Agent")",
                                value: OrgDeskWords.status(agent.status),
                                accent: agentAccent(agent.status)
                            )
                            if agent.status != "terminated" {
                                let resumes = agent.status == "paused" || agent.status == "error"
                                Button(agent.status == "error" ? "Try again" : resumes ? "Resume" : "Pause") {
                                    Task { await store.setAgent(agent, resumes ? "resume" : "pause", using: model.config) }
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                                .accessibilityLabel("\(agent.status == "error" ? "Try again with" : resumes ? "Resume" : "Pause") \(agent.name)")
                            }
                        }
                        if let problem = agent.problem {
                            Text(problem)
                                .font(.roach(size: 11))
                                .foregroundStyle(RoachPalette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func agentAccent(_ status: String) -> Color {
        switch status {
        case "running", "active": return RoachPalette.green
        case "paused": return RoachPalette.bronze
        case "error": return RoachPalette.warning
        case "terminated": return RoachPalette.muted
        default: return RoachPalette.cyan
        }
    }

    // MARK: Invites and joins

    private var invitePanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                RoachKicker("Invite a person")
                Text("Send the link to a phone paired over RoachTail. They ask to join; you approve below.")
                    .font(.callout).foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Role", selection: $inviteRole) {
                    Text("Viewer").tag("viewer")
                    Text("Operator").tag("operator")
                    Text("Admin").tag("admin")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Invite role")
                Text(inviteRoleHint)
                    .font(.roach(size: 11))
                    .foregroundStyle(RoachPalette.muted)
                Button("Create invite") { Task { await store.createInvite(role: inviteRole, using: model.config) } }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .accessibilityIdentifier("org.createInvite")
                if let invite = store.lastInvite {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            RoachTag(invite.role.capitalized, accent: RoachPalette.cyan)
                            Text("One use · 72 hours")
                                .font(.roach(size: 11, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }
                        Text(invite.link)
                            .font(.roach(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(invite.link, forType: .string)
                            store.message = "Invite link copied."
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(RoachPalette.shade.opacity(0.22)))
                }
            }
        }
    }

    private var inviteRoleHint: String {
        switch inviteRole {
        case "viewer": return "Viewers watch the board and read issues."
        case "admin": return "Admins can approve hires, budgets and joins from their phone."
        default: return "Operators work issues and talk to agents, but can't approve."
        }
    }

    private var joinPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoachKicker("Asking to join")
                    Spacer()
                    if !pendingJoins.isEmpty { RoachTag("\(pendingJoins.count)", accent: RoachPalette.cyan) }
                }
                if pendingJoins.isEmpty {
                    emptyLine("door.left.hand.closed", "Nobody waiting at the door.")
                }
                ForEach(pendingJoins) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(request.userName ?? request.agentName ?? "Someone")
                                .font(.roach(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(RoachPalette.text)
                            if request.requestType == "agent" { RoachTag("Agent", accent: RoachPalette.bronze) }
                            Spacer()
                            if let when = OrgDeskFormat.relative(request.createdAt) {
                                Text(when).font(.roach(size: 11, design: .monospaced)).foregroundStyle(RoachPalette.muted)
                            }
                        }
                        if let email = request.email { Text(email).font(.caption).foregroundStyle(RoachPalette.muted) }
                        HStack(spacing: 8) {
                            Button("Let them in") { Task { await store.decideJoin(request, approve: true, using: model.config) } }
                                .buttonStyle(RoachPrimaryButtonStyle())
                            Button("Turn away") { Task { await store.decideJoin(request, approve: false, using: model.config) } }
                                .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
