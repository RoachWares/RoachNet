import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

/// Settings › RoachClaw › Tracing (RoachTrace, ROA-50). Org runs, chats and
/// model-server calls are recorded as Langfuse-shaped traces on this Mac. Copying
/// them to a collector (Langfuse, any OTLP endpoint) is off until the person sets it up.
struct RoachTraceSettingsSection: View {
    let config: RoachNetInstallerConfig

    struct Settings: Decodable {
        struct LastResult: Decodable {
            let status: Int?
            let at: String?
            let sent: Int?
            let error: String?
        }

        struct Export: Decodable {
            var enabled: Bool
            var endpoint: String
            var includeContent: Bool
            var headerNames: [String]
            var serviceName: String
            var environment: String
            var pending: Int?
            var lastResult: LastResult?
        }

        struct Price: Decodable {
            let inputPerMTok: Double
            let outputPerMTok: Double
            let cachedInputPerMTok: Double?
        }

        var enabled: Bool
        var captureContent: Bool
        var maxContentChars: Int
        var retentionDays: Int
        var traceModelServer: Bool
        var export: Export
        var pricing: [String: Price]
        var storagePath: String?
    }

    private struct TestResult: Decodable {
        let ok: Bool
        let error: String?
        let result: Settings.LastResult?
        let pending: Int?
    }

    /// Where people usually send traces. The runtime adds /v1/traces itself.
    private static let presets: [(label: String, endpoint: String)] = [
        ("Langfuse Cloud (EU)", "https://cloud.langfuse.com/api/public/otel"),
        ("Langfuse Cloud (US)", "https://us.cloud.langfuse.com/api/public/otel"),
        ("Langfuse on this Mac", "http://localhost:3000/api/public/otel"),
        ("OTLP collector on this Mac", "http://localhost:4318"),
    ]

    private static let retentionChoices = [7, 14, 30, 90, 365]

    @State private var settings: Settings?
    @State private var endpoint = ""
    @State private var environment = ""
    @State private var langfusePublicKey = ""
    @State private var langfuseSecretKey = ""
    @State private var headerName = ""
    @State private var headerValue = ""
    @State private var priceModel = ""
    @State private var priceInput = ""
    @State private var priceOutput = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                kicker("TRACING")
                Text("Every Org run, chat and model call can be kept as a trace: each step, tool call and generation with its tokens, time to first token, speed and cost. Traces stay in RoachNet's storage on this Mac unless you set up an export below.")
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if let settings {
                    recording(settings)
                    Divider().overlay(RoachPalette.border)
                    exporting(settings)
                    Divider().overlay(RoachPalette.border)
                    prices(settings)
                } else {
                    Text("Loading tracing settings…")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }

                if let message {
                    Text(message)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.tracing.message")
                }
            }
        }
        .task { await load() }
        .accessibilityIdentifier("settings.tracing")
    }

    // MARK: Recording

    @ViewBuilder
    private func recording(_ settings: Settings) -> some View {
        toggle("Record traces", detail: "Org runs, RoachClaw chat and API calls.", isOn: settings.enabled) {
            await save(["enabled": $0], done: $0 ? "Tracing is on." : "Tracing is off. Nothing new is recorded.")
        }
        .accessibilityIdentifier("settings.tracing.enabled")
        toggle("Keep prompts and replies", detail: "Off keeps only timings, tokens and costs. Secrets RoachNet knows about are blanked either way.", isOn: settings.captureContent) {
            await save(["captureContent": $0], done: $0 ? "Traces keep prompts and replies (up to \(settings.maxContentChars) characters each)." : "Traces keep timings, tokens and costs only.")
        }
        .disabled(!settings.enabled)
        toggle("Trace the model server", detail: "Calls other apps make to RoachNet's OpenAI and Ollama-compatible API.", isOn: settings.traceModelServer) {
            await save(["traceModelServer": $0], done: $0 ? "Model server calls are traced." : "Model server calls are no longer traced on their own.")
        }
        .disabled(!settings.enabled)

        RoachFlowLayout(spacing: 8) {
            Text("Keep traces for")
                .font(.roach(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
            Picker("Keep traces for", selection: Binding(
                get: { settings.retentionDays },
                set: { days in Task { await save(["retentionDays": days], done: "Traces older than \(days) days are deleted.") } }
            )) {
                ForEach(Array(Set(Self.retentionChoices + [settings.retentionDays])).sorted(), id: \.self) { days in
                    Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityIdentifier("settings.tracing.retention")
            if let path = settings.storagePath {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .help(path)
            }
        }
    }

    // MARK: Export

    @ViewBuilder
    private func exporting(_ settings: Settings) -> some View {
        kicker("EXPORT")
        Text("Copy finished traces to Langfuse or any OpenTelemetry collector over OTLP. RoachNet sends to https addresses, or plain http only on this Mac. Header values are stored on this Mac and never shown again.")
            .font(.roach(size: 12, weight: .medium))
            .foregroundStyle(RoachPalette.muted)
            .fixedSize(horizontal: false, vertical: true)

        RoachFlowLayout(spacing: 8) {
            TextField("https://cloud.langfuse.com/api/public/otel", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .accessibilityIdentifier("settings.tracing.endpoint")
            Menu("Presets") {
                ForEach(Self.presets, id: \.endpoint) { preset in
                    Button(preset.label) { endpoint = preset.endpoint }
                }
            }
            .frame(width: 100)
            Button("Save Address") {
                Task { await save(["export": ["endpoint": endpoint]], done: endpoint.isEmpty ? "Export address cleared." : "Export address saved.") }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(busy || endpoint == settings.export.endpoint)
        }

        toggle("Send traces", detail: settings.export.endpoint.isEmpty ? "Save an address first." : "Finished traces go to \(settings.export.endpoint).", isOn: settings.export.enabled) {
            await save(["export": ["enabled": $0]], done: $0 ? "Export is on." : "Export is off. Queued traces stay on this Mac.")
        }
        .disabled(settings.export.endpoint.isEmpty)
        .accessibilityIdentifier("settings.tracing.export")
        toggle("Include prompts and replies", detail: "Off sends timings, tokens and costs only.", isOn: settings.export.includeContent) {
            await save(["export": ["includeContent": $0]], done: $0 ? "Exports include prompts and replies." : "Exports leave out prompts and replies.")
        }
        .disabled(settings.export.endpoint.isEmpty)

        VStack(alignment: .leading, spacing: 6) {
            Text("Langfuse keys")
                .font(.roach(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
            RoachFlowLayout(spacing: 8) {
                TextField("pk-lf-…", text: $langfusePublicKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                SecureField("sk-lf-…", text: $langfuseSecretKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Save Keys") { Task { await saveLangfuseKeys() } }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(busy || langfusePublicKey.trimmingCharacters(in: .whitespaces).isEmpty || langfuseSecretKey.isEmpty)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Other headers")
                .font(.roach(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
            RoachFlowLayout(spacing: 8) {
                TextField("Header, e.g. x-api-key", text: $headerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                SecureField("Value", text: $headerValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Add Header") { Task { await addHeader() } }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(busy || headerName.trimmingCharacters(in: .whitespaces).isEmpty || headerValue.isEmpty)
            }
            if !settings.export.headerNames.isEmpty {
                RoachFlowLayout(spacing: 6) {
                    ForEach(settings.export.headerNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                            Button {
                                Task { await save(["export": ["headers": [name: ""]]], done: "Removed \(name).") }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RoachPalette.muted)
                            .help("Remove \(name)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(RoachPalette.panelRaised))
                    }
                }
            }
        }

        RoachFlowLayout(spacing: 8) {
            TextField("Environment", text: $environment)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit { Task { await save(["export": ["environment": environment]], done: "Environment saved.") } }
            Button("Test Export") { Task { await test() } }
                .buttonStyle(RoachPrimaryButtonStyle())
                .disabled(busy || settings.export.endpoint.isEmpty)
                .accessibilityIdentifier("settings.tracing.test")
            Button("Send Queued Now") { Task { await flush() } }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(busy || !settings.export.enabled)
            Text(exportStatus(settings.export))
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(settings.export.lastResult?.error == nil ? RoachPalette.muted : RoachPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Prices

    @ViewBuilder
    private func prices(_ settings: Settings) -> some View {
        kicker("PRICES")
        Text("Models on this Mac cost $0. RoachNet ships no price list, so add the prices you pay for cloud models (US dollars per million tokens) and traces show what each run cost.")
            .font(.roach(size: 12, weight: .medium))
            .foregroundStyle(RoachPalette.muted)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(settings.pricing.keys.sorted(), id: \.self) { model in
            if let price = settings.pricing[model] {
                HStack(spacing: 10) {
                    Text(model)
                        .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("in \(Self.dollars(price.inputPerMTok)) · out \(Self.dollars(price.outputPerMTok))\(price.cachedInputPerMTok.map { " · cached \(Self.dollars($0))" } ?? "")")
                        .font(.roach(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                    Button("Remove") {
                        var table = Self.table(settings.pricing)
                        table.removeValue(forKey: model)
                        Task { await save(["pricing": table], done: "Removed the price for \(model).") }
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(busy)
                }
            }
        }

        RoachFlowLayout(spacing: 8) {
            TextField("Model, e.g. gpt-5.1", text: $priceModel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            TextField("Input $/M", text: $priceInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            TextField("Output $/M", text: $priceOutput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            Button("Add Price") { Task { await addPrice(settings) } }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(busy || priceModel.trimmingCharacters(in: .whitespaces).isEmpty || Double(priceInput) == nil || Double(priceOutput) == nil)
        }
    }

    // MARK: Pieces

    private func kicker(_ text: String) -> some View {
        Text(text)
            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(RoachPalette.muted)
    }

    private func toggle(_ title: String, detail: String, isOn: Bool, change: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { value in Task { await change(value) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.roach(size: 13, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .disabled(busy)
    }

    private func exportStatus(_ export: Settings.Export) -> String {
        var parts: [String] = []
        if let pending = export.pending, pending > 0 { parts.append("\(pending) waiting") }
        if let result = export.lastResult, let at = result.at {
            let when = Self.short(at)
            if let error = result.error, !error.isEmpty {
                parts.append("last try \(when): \(result.status.map { "HTTP \($0) " } ?? "")\(error.prefix(160))")
            } else {
                parts.append("last sent \(when): \(result.sent ?? 0) spans, HTTP \(result.status ?? 0)")
            }
        }
        return parts.isEmpty ? "Nothing sent yet." : parts.joined(separator: " · ")
    }

    private static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...4)))
    }

    private static func short(_ iso: String) -> String {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = (try? fractional.parse(iso)) ?? (try? Date.ISO8601FormatStyle().parse(iso)) else { return iso }
        return date.formatted(date: .omitted, time: .standard)
    }

    private static func table(_ pricing: [String: Settings.Price]) -> [String: Any] {
        var table: [String: Any] = [:]
        for (model, price) in pricing {
            var entry: [String: Any] = ["inputPerMTok": price.inputPerMTok, "outputPerMTok": price.outputPerMTok]
            if let cached = price.cachedInputPerMTok { entry["cachedInputPerMTok"] = cached }
            table[model] = entry
        }
        return table
    }

    // MARK: Requests

    private func load() async {
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/traces/settings")
            apply(try JSONDecoder().decode(Settings.self, from: data))
        } catch {
            message = "Couldn't load tracing settings: \(error.localizedDescription)"
        }
    }

    private func apply(_ next: Settings) {
        settings = next
        endpoint = next.export.endpoint
        environment = next.export.environment
    }

    private func save(_ body: [String: Any], done: String) async {
        busy = true
        defer { busy = false }
        do {
            let json = try JSONSerialization.data(withJSONObject: body)
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/traces/settings", method: "PATCH", jsonBody: json)
            apply(try JSONDecoder().decode(Settings.self, from: data))
            message = done
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func saveLangfuseKeys() async {
        let publicKey = langfusePublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = langfuseSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Langfuse's OTLP endpoint takes HTTP Basic auth: public key as the user, secret key as the password.
        let credential = Data("\(publicKey):\(secretKey)".utf8).base64EncodedString()
        await save(["export": ["headers": ["authorization": "Basic \(credential)"]]], done: "Langfuse keys saved. Run Test Export to check them.")
        langfusePublicKey = ""
        langfuseSecretKey = ""
    }

    private func addHeader() async {
        let name = headerName.trimmingCharacters(in: .whitespaces).lowercased()
        await save(["export": ["headers": [name: headerValue]]], done: "Saved \(name).")
        headerName = ""
        headerValue = ""
    }

    private func addPrice(_ settings: Settings) async {
        guard let input = Double(priceInput), let output = Double(priceOutput), input >= 0, output >= 0 else { return }
        let model = priceModel.trimmingCharacters(in: .whitespaces)
        var table = Self.table(settings.pricing)
        table[model] = ["inputPerMTok": input, "outputPerMTok": output]
        await save(["pricing": table], done: "Traces now price \(model).")
        priceModel = ""
        priceInput = ""
        priceOutput = ""
    }

    private func test() async {
        if endpoint != settings?.export.endpoint {
            await save(["export": ["endpoint": endpoint]], done: "Export address saved.")
        }
        busy = true
        defer { busy = false }
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/traces/export/test", method: "POST", jsonBody: Data("{}".utf8))
            let result = try JSONDecoder().decode(TestResult.self, from: data)
            if result.ok {
                message = "The collector took the test trace (HTTP \(result.result?.status ?? 200)). Look for \"RoachNet export test\"."
            } else {
                message = "Test failed: \(result.error ?? result.result?.error ?? "no answer") \(result.result?.status.map { "(HTTP \($0))" } ?? "")"
            }
        } catch {
            message = "Test failed: \(error.localizedDescription)"
        }
        busy = false
        await load()
    }

    private func flush() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/traces/export/flush", method: "POST", jsonBody: Data("{}".utf8))
            let result = try JSONDecoder().decode(TestResult.self, from: data)
            message = result.ok ? "Sent. \(result.pending ?? 0) still waiting." : "Couldn't send: \(result.result?.error ?? "the collector didn't answer")."
        } catch {
            message = "Couldn't send: \(error.localizedDescription)"
        }
        busy = false
        await load()
    }
}
