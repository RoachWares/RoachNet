import RoachNetCore
import RoachNetDesign
import SwiftUI

// MARK: - Models (RoachTrace API shapes)

/// Any JSON value, kept as pretty text for display.
struct OrgTraceJSON: Decodable, Hashable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { text = nil; return }
        if let string = try? container.decode(String.self) { text = string; return }
        let value = try container.decode(OrgTraceAny.self)
        let data = try? JSONSerialization.data(withJSONObject: value.object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        text = data.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private struct OrgTraceAny: Decodable {
    let object: Any

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var items: [Any] = []
            while !array.isAtEnd { items.append(try array.decode(OrgTraceAny.self).object) }
            object = items
        } else if let keyed = try? decoder.container(keyedBy: OrgTraceKey.self) {
            var dictionary: [String: Any] = [:]
            for key in keyed.allKeys { dictionary[key.stringValue] = try keyed.decode(OrgTraceAny.self, forKey: key).object }
            object = dictionary
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { object = NSNull() }
            else if let flag = try? single.decode(Bool.self) { object = flag }
            else if let number = try? single.decode(Double.self) { object = number }
            else { object = (try? single.decode(String.self)) ?? "" }
        }
    }
}

private struct OrgTraceKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct OrgTraceUsage: Decodable, Hashable {
    let input: Int
    let output: Int
    let cachedInput: Int
    let total: Int
}

struct OrgTraceCost: Decodable, Hashable {
    let totalUsd: Double
    let status: String
    let billingType: String
}

struct OrgTraceSummary: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
    let status: String
    let statusMessage: String?
    let agentId: String?
    let issueId: String?
    let startTime: String?
    let latencyMs: Int?
    let usage: OrgTraceUsage?
    let costUsd: Double?
    let unpriced: Bool?
    let observationCount: Int?
    let tags: [String]?
}

struct OrgTraceObservation: Decodable, Identifiable, Hashable {
    let id: String
    let parentObservationId: String?
    let type: String
    let name: String
    let level: String
    let statusMessage: String?
    let startTime: String?
    let endTime: String?
    let latencyMs: Int?
    let timeToFirstTokenMs: Int?
    let model: String?
    let provider: String?
    let usage: OrgTraceUsage?
    let cost: OrgTraceCost?
    let outputTokensPerSecond: Double?
    let promptTokensPerSecond: Double?
    let input: OrgTraceJSON?
    let output: OrgTraceJSON?
}

struct OrgTraceScore: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let value: Double?
    let stringValue: String?
    let comment: String?
}

struct OrgTraceDetail: Decodable, Hashable {
    let id: String
    let name: String
    let status: String
    let statusMessage: String?
    let startTime: String?
    let latencyMs: Int?
    let usage: OrgTraceUsage?
    let costUsd: Double?
    let input: OrgTraceJSON?
    let output: OrgTraceJSON?
    let observations: [OrgTraceObservation]
    let scores: [OrgTraceScore]
}

struct OrgTraceMetricRow: Decodable, Hashable {
    let key: String?
    let count: Int
    let errors: Int
    let usage: OrgTraceUsage
    let costUsd: Double
    let latencyP50Ms: Int?
    let latencyP95Ms: Int?
    let timeToFirstTokenP50Ms: Int?
    let outputTokensPerSecond: Double?
}

struct OrgTraceMetrics: Decodable, Hashable {
    let totals: OrgTraceMetricRow
    let groups: [OrgTraceMetricRow]
}

enum OrgTraceFormat {
    static func duration(_ ms: Int?) -> String {
        guard let ms else { return "–" }
        if ms < 1_000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1_000) }
        return "\(ms / 60_000)m \((ms % 60_000) / 1_000)s"
    }

    static func tokens(_ count: Int) -> String {
        count >= 10_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    static func cost(_ usd: Double?, unpriced: Bool = false) -> String {
        guard let usd, usd > 0 else { return unpriced ? "unpriced" : "$0" }
        return usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    static func accent(_ status: String) -> Color {
        switch status {
        case "ok": return RoachPalette.green
        case "error": return RoachPalette.warning
        case "running": return RoachPalette.cyan
        default: return RoachPalette.muted
        }
    }

    static func typeAccent(_ type: String) -> Color {
        switch type {
        case "generation": return RoachPalette.cyan
        case "tool": return RoachPalette.bronze
        case "agent": return RoachPalette.green
        default: return RoachPalette.muted
        }
    }
}

// MARK: - Store

@MainActor
final class OrgTraceStore: ObservableObject {
    @Published var traces: [OrgTraceSummary] = []
    @Published var metrics: OrgTraceMetrics?
    @Published var detail: OrgTraceDetail?
    @Published var selectedID: String?
    @Published var agentFilter = ""
    @Published var statusFilter = ""
    @Published var errorMessage: String?
    @Published var isLoading = false
    /// The company the lists belong to; nil until the first load lands.
    @Published private(set) var loadedCompanyID: String?

    private let decoder = JSONDecoder()

    func load(company cid: String, using config: RoachNetInstallerConfig) async {
        isLoading = true
        defer { isLoading = false }
        if loadedCompanyID != cid {
            traces = []; metrics = nil; detail = nil; selectedID = nil
        }
        var query = "limit=100"
        if !agentFilter.isEmpty { query += "&agentId=\(agentFilter)" }
        if !statusFilter.isEmpty { query += "&status=\(statusFilter)" }
        do {
            struct Page: Decodable { let traces: [OrgTraceSummary] }
            traces = (try await request("GET", "/api/org/companies/\(cid)/traces?\(query)", nil, config) as Page).traces
            metrics = try await request("GET", "/api/org/companies/\(cid)/traces/metrics?groupBy=agent\(agentFilter.isEmpty ? "" : "&agentId=\(agentFilter)")", nil, config)
            if let selectedID, traces.contains(where: { $0.id == selectedID }) {
                await open(selectedID, company: cid, using: config)
            } else if selectedID == nil, let first = traces.first {
                await open(first.id, company: cid, using: config)
            }
            loadedCompanyID = cid
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ id: String, company cid: String, using config: RoachNetInstallerConfig) async {
        selectedID = id
        do {
            detail = try await request("GET", "/api/org/companies/\(cid)/traces/\(id)", nil, config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func score(_ helpful: Bool, company cid: String, using config: RoachNetInstallerConfig) async {
        guard let id = selectedID else { return }
        do {
            let _: OrgTraceScore = try await request("POST", "/api/org/companies/\(cid)/traces/\(id)/scores",
                                                     ["name": "helpful", "value": helpful, "source": "human"], config)
            await open(id, company: cid, using: config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func request<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any]?, _ config: RoachNetInstallerConfig) async throws -> T {
        let json = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: path, method: method, jsonBody: json)
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Board

struct OrgTracesBoard: View {
    @ObservedObject var store: OrgTraceStore
    let companyID: String
    let agents: [OrgDeskAgent]
    let config: RoachNetInstallerConfig

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = store.errorMessage {
                RoachNotice(title: "Traces didn't load", detail: error, accent: RoachPalette.warning)
            }
            if let totals = store.metrics?.totals { tiles(totals) }
            HStack(alignment: .top, spacing: 18) {
                list.frame(width: 380, alignment: .topLeading)
                detail.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let groups = store.metrics?.groups, groups.count > 1 { perAgent(groups) }
        }
    }

    private func agentName(_ id: String?) -> String {
        guard let id else { return "No agent" }
        return agents.first { $0.id == id }?.name ?? id
    }

    private func tiles(_ totals: OrgTraceMetricRow) -> some View {
        HStack(spacing: 12) {
            tile("Runs traced", "\(totals.count)", detail: totals.errors > 0 ? "\(totals.errors) failed" : "none failed")
            tile("Tokens", "\(OrgTraceFormat.tokens(totals.usage.input)) in · \(OrgTraceFormat.tokens(totals.usage.output)) out",
                 detail: totals.usage.cachedInput > 0 ? "\(OrgTraceFormat.tokens(totals.usage.cachedInput)) reused from cache" : "no cache reuse")
            tile("Cost", OrgTraceFormat.cost(totals.costUsd), detail: "local models are free")
            tile("Latency", OrgTraceFormat.duration(totals.latencyP50Ms), detail: "p95 \(OrgTraceFormat.duration(totals.latencyP95Ms))")
            tile("First token", OrgTraceFormat.duration(totals.timeToFirstTokenP50Ms),
                 detail: totals.outputTokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "speed not reported")
        }
    }

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 4) {
                RoachKicker(title)
                Text(value).font(.roach(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(RoachPalette.text)
                Text(detail).font(.roach(size: 11)).foregroundStyle(RoachPalette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var list: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoachKicker("Runs")
                    Spacer()
                    Picker("Agent", selection: $store.agentFilter) {
                        Text("Every agent").tag("")
                        ForEach(agents) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Picker("Status", selection: $store.statusFilter) {
                        Text("Any").tag("")
                        Text("Finished").tag("ok")
                        Text("Failed").tag("error")
                    }
                    .labelsHidden()
                    .frame(width: 96)
                }
                .onChange(of: store.agentFilter) { _, _ in Task { await store.load(company: companyID, using: config) } }
                .onChange(of: store.statusFilter) { _, _ in Task { await store.load(company: companyID, using: config) } }
                if store.traces.isEmpty {
                    if store.loadedCompanyID == companyID {
                        OrgBoardEmptyLine(systemName: "waveform.path.ecg", text: "No traces yet. Every agent run lands here with its model calls, actions, tokens and timing.")
                    } else {
                        OrgBoardEmptyLine(systemName: "hourglass", text: "Loading traces…")
                    }
                }
                ForEach(store.traces) { trace in
                    Button {
                        Task { await store.open(trace.id, company: companyID, using: config) }
                    } label: {
                        traceRow(trace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("org.trace.\(trace.id)")
                }
            }
        }
    }

    private func traceRow(_ trace: OrgTraceSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(OrgTraceFormat.accent(trace.status)).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(trace.name).font(.roach(size: 13, weight: .semibold)).foregroundStyle(RoachPalette.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(OrgDeskFormat.relative(trace.startTime) ?? "").font(.roach(size: 11)).foregroundStyle(RoachPalette.muted)
            }
            Text([OrgTraceFormat.duration(trace.latencyMs),
                  "\(OrgTraceFormat.tokens(trace.usage?.total ?? 0)) tokens",
                  OrgTraceFormat.cost(trace.costUsd, unpriced: trace.unpriced ?? false),
                  "\(trace.observationCount ?? 0) steps"].joined(separator: " · "))
                .font(.roach(size: 11, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(store.selectedID == trace.id ? RoachPalette.cyan.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trace.name), \(trace.status == "ok" ? "finished" : trace.status)")
    }

    @ViewBuilder
    private var detail: some View {
        RoachPanel {
            if let detail = store.detail {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        RoachTag(detail.status == "ok" ? "Finished" : detail.status.capitalized, accent: OrgTraceFormat.accent(detail.status))
                        Text(detail.name).font(.roach(size: 15, weight: .semibold)).foregroundStyle(RoachPalette.text).lineLimit(2)
                        Spacer()
                        Button { Task { await store.score(true, company: companyID, using: config) } } label: { Image(systemName: "hand.thumbsup") }
                            .buttonStyle(RoachSecondaryButtonStyle()).help("This run was helpful").accessibilityLabel("Mark helpful")
                        Button { Task { await store.score(false, company: companyID, using: config) } } label: { Image(systemName: "hand.thumbsdown") }
                            .buttonStyle(RoachSecondaryButtonStyle()).help("This run was not helpful").accessibilityLabel("Mark not helpful")
                    }
                    Text([OrgTraceFormat.duration(detail.latencyMs),
                          "\(detail.usage?.input ?? 0) in / \(detail.usage?.output ?? 0) out",
                          OrgTraceFormat.cost(detail.costUsd)].joined(separator: " · "))
                        .font(.roach(size: 12, design: .monospaced)).foregroundStyle(RoachPalette.muted)
                    if let message = detail.statusMessage, !message.isEmpty {
                        Text(message).font(.roach(size: 12)).foregroundStyle(RoachPalette.warning)
                    }
                    if let last = detail.scores.last {
                        Text("Scored \(last.name): \(last.value == 1 ? "yes" : last.value == 0 ? "no" : last.stringValue ?? "\(last.value ?? 0)")")
                            .font(.roach(size: 11)).foregroundStyle(RoachPalette.muted)
                    }
                    Divider().overlay(RoachPalette.border)
                    waterfall(detail)
                }
            } else {
                OrgBoardEmptyLine(systemName: "sidebar.right", text: "Pick a run to see each step.")
            }
        }
    }

    /// Observations in tree order with a bar for when each ran within the trace.
    private func waterfall(_ detail: OrgTraceDetail) -> some View {
        let ordered = depthFirst(detail.observations)
        let starts = detail.observations.compactMap { OrgTraceTime.ms($0.startTime) }
        let ends = detail.observations.compactMap { OrgTraceTime.ms($0.endTime) }
        let origin = starts.min() ?? 0
        let span = max((ends.max() ?? origin + 1) - origin, 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(ordered, id: \.0.id) { item, depth in
                let start = (OrgTraceTime.ms(item.startTime) ?? origin) - origin
                let length = max(Double(item.latencyMs ?? 0), 1)
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    } label: {
                        HStack(spacing: 8) {
                            RoachTag(item.type, accent: OrgTraceFormat.typeAccent(item.type))
                            Text(item.name).font(.roach(size: 12, weight: .medium)).foregroundStyle(item.level == "ERROR" ? RoachPalette.warning : RoachPalette.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(observationFacts(item)).font(.roach(size: 11, design: .monospaced)).foregroundStyle(RoachPalette.muted).lineLimit(1)
                        }
                        .padding(.leading, CGFloat(depth) * 14)
                    }
                    .buttonStyle(.plain)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        Capsule()
                            .fill(OrgTraceFormat.typeAccent(item.type).opacity(0.55))
                            .frame(width: max(width * CGFloat(length / span), 3), height: 4)
                            .offset(x: width * CGFloat(start / span))
                    }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                    if expanded.contains(item.id) { content(item) }
                }
            }
        }
    }

    private func observationFacts(_ item: OrgTraceObservation) -> String {
        var parts = [OrgTraceFormat.duration(item.latencyMs)]
        if let usage = item.usage { parts.append("\(usage.input)→\(usage.output)") }
        if let ttft = item.timeToFirstTokenMs { parts.append("TTFT \(OrgTraceFormat.duration(ttft))") }
        if let rate = item.outputTokensPerSecond { parts.append(String(format: "%.0f tok/s", rate)) }
        if let cost = item.cost, cost.totalUsd > 0 { parts.append(OrgTraceFormat.cost(cost.totalUsd)) }
        return parts.joined(separator: " · ")
    }

    private func content(_ item: OrgTraceObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = item.model { Text("Model: \(model)\(item.provider.map { " · \($0)" } ?? "")").font(.roach(size: 11)).foregroundStyle(RoachPalette.muted) }
            if let message = item.statusMessage { Text(message).font(.roach(size: 11)).foregroundStyle(RoachPalette.warning) }
            if let input = item.input?.text { block("Input", input) }
            if let output = item.output?.text { block("Output", output) }
        }
        .padding(.leading, 14)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RoachKicker(title)
            Text(String(text.prefix(4_000)))
                .font(.roach(size: 11, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(RoachPalette.border.opacity(0.35)))
        }
    }

    private func depthFirst(_ items: [OrgTraceObservation]) -> [(OrgTraceObservation, Int)] {
        let ids = Set(items.map(\.id))
        var children: [String: [OrgTraceObservation]] = [:]
        var roots: [OrgTraceObservation] = []
        for item in items {
            if let parent = item.parentObservationId, ids.contains(parent) { children[parent, default: []].append(item) } else { roots.append(item) }
        }
        var out: [(OrgTraceObservation, Int)] = []
        func visit(_ item: OrgTraceObservation, _ depth: Int) {
            out.append((item, depth))
            for child in children[item.id] ?? [] { visit(child, depth + 1) }
        }
        for root in roots { visit(root, 0) }
        return out
    }

    private func perAgent(_ groups: [OrgTraceMetricRow]) -> some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 8) {
                RoachKicker("By agent")
                ForEach(groups, id: \.key) { group in
                    HStack {
                        Text(agentName(group.key)).font(.roach(size: 13, weight: .semibold)).foregroundStyle(RoachPalette.text)
                        Spacer()
                        Text("\(group.count) runs · \(OrgTraceFormat.tokens(group.usage.total)) tokens · \(OrgTraceFormat.cost(group.costUsd)) · p50 \(OrgTraceFormat.duration(group.latencyP50Ms))")
                            .font(.roach(size: 12, design: .monospaced)).foregroundStyle(RoachPalette.muted)
                    }
                }
            }
        }
    }
}

enum OrgTraceTime {
    static func ms(_ iso: String?) -> Double? {
        guard let iso else { return nil }
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? style.parse(iso) { return date.timeIntervalSince1970 * 1_000 }
        if let date = try? Date.ISO8601FormatStyle().parse(iso) { return date.timeIntervalSince1970 * 1_000 }
        return nil
    }
}
