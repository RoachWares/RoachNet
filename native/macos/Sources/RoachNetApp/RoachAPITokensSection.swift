import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

struct RoachAPITokensSection: View {
    let config: RoachNetInstallerConfig

    struct Token: Identifiable, Decodable {
        let id: String
        let name: String?
        let scopes: [String]?
        let isActive: Bool?
        let createdAt: String?
        let lastUsedAt: String?
    }

    private struct TokenList: Decodable { let tokens: [Token] }
    private struct Minted: Decodable { let token: String }

    enum Scope: String, CaseIterable, Identifiable {
        case chat, read, admin
        var id: String { rawValue }
        var label: String {
            switch self {
            case .chat: return "Chat"
            case .read: return "Read"
            case .admin: return "Full access"
            }
        }
        var help: String {
            switch self {
            case .chat: return "RoachClaw chat endpoints only."
            case .read: return "Read anything, change nothing."
            case .admin: return "Everything RoachNet itself can do. Keep it to scripts you wrote."
            }
        }
    }

    @State private var tokens: [Token] = []
    @State private var name = ""
    @State private var scope: Scope = .chat
    @State private var revealed: String?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachKicker("API tokens")
                Text(
                    "RoachNet's local API answers only RoachNet and callers with a token. Make one for a script or another app, then send it as Authorization: Bearer rn_…."
                )
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

                RoachFlowLayout(spacing: 8) {
                    TextField("Name, e.g. Raycast", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Picker("Access", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .help(scope.help)
                    Button("Create token") { Task { await create() } }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(scope.help)
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(scope == .admin ? RoachPalette.warning : RoachPalette.muted)

                if let revealed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copy it now. RoachNet keeps only a hash and can't show it again.")
                            .font(.roach(size: 11, weight: .semibold))
                            .foregroundStyle(RoachPalette.warning)
                        HStack(spacing: 8) {
                            Text(revealed)
                                .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(revealed, forType: .string)
                                message = "Copied."
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            Button("Done") { self.revealed = nil }
                                .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(
                            RoachPalette.panelRaised))
                }

                if tokens.isEmpty {
                    Text("No tokens yet.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                } else {
                    ForEach(tokens) { token in
                        HStack(spacing: 10) {
                            Image(systemName: "key.horizontal")
                                .foregroundStyle(RoachPalette.magenta)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(token.name ?? "API token")
                                    .font(.roach(size: 13, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                Text(detail(token))
                                    .font(.roach(size: 11, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                            }
                            Spacer(minLength: 8)
                            Button("Revoke") { Task { await revoke(token) } }
                                .buttonStyle(RoachSecondaryButtonStyle())
                                .disabled(busy)
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
        .task { await load() }
    }

    private func detail(_ token: Token) -> String {
        let scopes = (token.scopes ?? []).joined(separator: ", ")
        let used = token.lastUsedAt.map { "last used \(Self.short($0))" } ?? "never used"
        return "\(scopes.isEmpty ? "no scopes" : scopes) · \(used)"
    }

    private static func short(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.fractional().date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/roachclaw/tokens")
            tokens = try JSONDecoder().decode(TokenList.self, from: data).tokens
        } catch {
            message = "Couldn't load tokens: \(error.localizedDescription)"
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "name": name.trimmingCharacters(in: .whitespaces), "scopes": [scope.rawValue],
            ])
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/roachclaw/tokens", method: "POST", jsonBody: body)
            revealed = try JSONDecoder().decode(Minted.self, from: data).token
            name = ""
            message = nil
            await load()
        } catch {
            message = "Couldn't create the token: \(error.localizedDescription)"
        }
    }

    private func revoke(_ token: Token) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/roachclaw/tokens/\(token.id)", method: "DELETE")
            message = "Revoked \(token.name ?? "the token"). Anything using it is locked out now."
            await load()
        } catch {
            message = "Couldn't revoke the token, so it may still work. Try again. \(error.localizedDescription)"
        }
    }
}

extension ISO8601DateFormatter {
    fileprivate static func fractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
