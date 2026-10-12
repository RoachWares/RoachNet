import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

/// Settings › RoachClaw › Subscriptions (ROA-52). A Claude or ChatGPT plan
/// becomes a set of RoachNet models (claude:…, codex:…) through the person's
/// own Claude Code or Codex. Off until they turn it on.
struct RoachSubscriptionsSection: View {
    let config: RoachNetInstallerConfig

    struct Subscription: Decodable, Identifiable {
        let provider: String
        let providerLabel: String
        let label: String
        let enabled: Bool
        let installed: Bool
        let signedIn: Bool?
        let plan: String?
        let detail: String
        let modelNames: [String]
        let signInCommand: [String]
        var id: String { provider }
    }

    private struct List: Decodable { let subscriptions: [Subscription] }

    @State private var subscriptions: [Subscription] = []
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("SUBSCRIPTIONS")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
                Text("Use the Claude or ChatGPT plan you already pay for as RoachNet models: in RoachClaw chat, for Org agents, and on RoachNet's OpenAI and Ollama-compatible API. Replies come from your own Claude Code or Codex, signed in to your plan. RoachNet never sees your account's credentials, and each reply counts against your plan's limits.")
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if subscriptions.isEmpty {
                    Text("Checking for Claude Code and Codex…")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
                ForEach(subscriptions) { row($0) }
                if let message {
                    Text(message)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await load() }
        .accessibilityIdentifier("settings.subscriptions")
    }

    private func row(_ item: Subscription) -> some View {
        let usable = item.installed && item.signedIn != false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.providerLabel) via \(item.label)")
                        .font(.roach(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text(item.detail)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(usable ? RoachPalette.muted : RoachPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(item.providerLabel, isOn: Binding(get: { item.enabled }, set: { value in Task { await set(item, value) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(busy || (!usable && !item.enabled))
                    .accessibilityIdentifier("settings.subscriptions.\(item.provider)")
            }
            if item.installed, item.signedIn == false, !item.signInCommand.isEmpty {
                Button("Sign In in Terminal") { OrgTerminalHandoff.run(item.signInCommand, title: "Sign in to \(item.label)") }
                    .buttonStyle(RoachSecondaryButtonStyle())
            }
            if item.enabled, usable {
                RoachFlowLayout(spacing: 6) {
                    ForEach(item.modelNames, id: \.self) { RoachTag($0, accent: RoachPalette.cyan) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(RoachPalette.panelRaised.opacity(0.54)))
    }

    private func load() async {
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/roachclaw/subscriptions")
            subscriptions = try JSONDecoder().decode(List.self, from: data).subscriptions
        } catch {
            message = "Couldn't check subscriptions: \(error.localizedDescription)"
        }
    }

    private func set(_ item: Subscription, _ enabled: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: [item.provider: enabled])
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/roachclaw/subscriptions", method: "PUT", jsonBody: body)
            subscriptions = try JSONDecoder().decode(List.self, from: data).subscriptions
            message = enabled
                ? "\(item.providerLabel) models are on. Pick one in RoachClaw's model list, or name it as an agent's model."
                : "\(item.providerLabel) models are off."
        } catch {
            message = "Couldn't change it: \(error.localizedDescription)"
        }
    }
}

/// How the chat picker names a model that comes from a plan.
enum RoachPlanModel {
    static func label(_ name: String) -> String? {
        if name.hasPrefix("claude:") { return "Claude plan · \(name.dropFirst("claude:".count))" }
        if name.hasPrefix("codex:") { return "ChatGPT plan · \(name.dropFirst("codex:".count))" }
        return nil
    }
}
