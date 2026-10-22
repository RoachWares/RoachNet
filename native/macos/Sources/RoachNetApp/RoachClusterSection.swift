import AppKit
import RoachNetCore
import RoachNetDesign
import SwiftUI

struct RoachClusterSection: View {
    let config: RoachNetInstallerConfig

    struct Memory: Decodable {
        let total: Double
        let budget: Double
        let free: Double
    }
    struct Peer: Decodable, Identifiable {
        let address: String
        let reachable: Bool?
        let name: String?
        let chip: String?
        let memory: Memory?
        let error: String?
        var id: String { address }
    }
    struct Stage: Decodable {
        let name: String
        let layers: String
    }
    struct SplitModel: Decodable, Identifiable {
        let model: String
        let broken: Bool
        let stages: [Stage]
        var id: String { model }
    }
    struct Status: Decodable {
        let enabled: Bool
        let name: String
        let mode: String
        let port: Int
        let listening: Bool
        let code: String?
        let fingerprint: String?
        let chip: String
        let memory: Memory
        let peers: [Peer]
        let models: [SplitModel]
    }
    struct Nearby: Decodable, Identifiable {
        let name: String
        let address: String
        let sameCluster: Bool
        let added: Bool
        var id: String { address }
    }
    private struct NearbyList: Decodable { let macs: [Nearby] }

    @State private var status: Status?
    @State private var nearby: [Nearby] = []
    @State private var name = ""
    @State private var joinCode = ""
    @State private var address = ""
    @State private var message: String?
    @State private var busy = false
    @State private var confirmReset = false

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                kicker("RoachNet Cluster")
                Text(
                    "Run a model that's too big for one Mac across several. Each Mac holds part of the model's layers, and this Mac does the talking, so every app and agent uses the model as usual. Only Macs with this cluster's pairing code can join, and everything between them is encrypted."
                )
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                if let status {
                    toggleRow(status)
                    if status.enabled { details(status) }
                } else {
                    Text("Checking the cluster…")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
                if let message {
                    Text(message)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await load(refresh: true) }
        .confirmationDialog("Replace the pairing code?", isPresented: $confirmReset) {
            Button("Replace pairing code", role: .destructive) {
                Task {
                    await save(
                        ["resetPairing": true],
                        done: "This Mac has a new pairing code. Give it to the Macs that should join.")
                }
            }
        } message: {
            Text("The other Macs stop trusting this one until they join again with the new code.")
        }
        .accessibilityIdentifier("settings.cluster")
    }

    private func kicker(_ text: String) -> some View {
        RoachKicker(text)
    }

    private func toggleRow(_ status: Status) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cluster")
                    .font(.roach(size: 13, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(
                    status.enabled
                        ? (status.listening
                            ? "On. Other Macs on your network reach this one on port \(String(status.port))."
                            : "On, but another app is using port \(String(status.port)), so other Macs can't reach this one.")
                        : "Off. This Mac runs its models alone and accepts no cluster connections."
                )
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(status.enabled && !status.listening ? RoachPalette.warning : RoachPalette.muted)
            }
            Spacer(minLength: 12)
            Toggle(
                "Cluster",
                isOn: Binding(
                    get: { status.enabled },
                    set: { value in
                        Task { await save(["enabled": value], done: value ? "Cluster is on." : "Cluster is off.") }
                    })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(busy)
            .accessibilityIdentifier("settings.cluster.enabled")
        }
    }

    @ViewBuilder
    private func details(_ status: Status) -> some View {
        kicker("This Mac")
        RoachFlowLayout(spacing: 8) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { Task { await save(["name": name], done: "Renamed.") } }
                .accessibilityIdentifier("settings.cluster.name")
            RoachTag(status.chip.isEmpty ? "Apple silicon" : status.chip, accent: RoachPalette.cyan)
            RoachTag("\(gigabytes(status.memory.free)) free for models", accent: RoachPalette.green)
        }

        kicker("Pairing")
        if let code = status.code {
            HStack(spacing: 10) {
                Text(code)
                    .font(.roach(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.cluster.code")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    message = "Pairing code copied. On the other Mac, paste it into “Join a cluster” and click Join."
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                Button("New code…") { confirmReset = true }
                    .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
        RoachFlowLayout(spacing: 8) {
            TextField("Join a cluster: another Mac's pairing code", text: $joinCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .accessibilityIdentifier("settings.cluster.join")
            Button("Join") {
                Task {
                    await save(["code": joinCode], done: "This Mac joined that cluster.")
                    joinCode = ""
                }
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(busy || joinCode.filter { $0.isLetter || $0.isNumber }.count != 26)
        }

        kicker("Splitting")
        Picker(
            "Split",
            selection: Binding(
                get: { status.mode },
                set: { mode in
                    Task {
                        await save(
                            ["mode": mode],
                            done: mode == "always"
                                ? "Every model is spread across the cluster."
                                : "Only models too big for this Mac are split.")
                    }
                })
        ) {
            Text("Only models too big for this Mac").tag("auto")
            Text("Every model").tag("always")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .accessibilityIdentifier("settings.cluster.mode")

        kicker("Other Macs")
        ForEach(status.peers) { peerRow($0) }
        RoachFlowLayout(spacing: 8) {
            TextField("studio.local or 192.168.1.20", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { Task { await add(address) } }
                .accessibilityIdentifier("settings.cluster.address")
            Button("Add Mac") { Task { await add(address) } }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Find Macs nearby") { Task { await findNearby() } }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(busy)
            Button("Check again") { Task { await load(refresh: true) } }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(busy)
        }
        ForEach(nearby.filter { !$0.added }) { found in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.name).font(.roach(size: 12, weight: .semibold)).foregroundStyle(RoachPalette.text)
                    Text(
                        found.sameCluster
                            ? "\(found.address) · in this cluster"
                            : "\(found.address) · needs this cluster's pairing code"
                    )
                    .font(.roach(size: 11, weight: .medium)).foregroundStyle(RoachPalette.muted)
                }
                Spacer(minLength: 12)
                Button("Add") { Task { await add(found.address) } }
                    .buttonStyle(RoachSecondaryButtonStyle())
            }
        }

        if !status.models.isEmpty {
            kicker("Running across Macs")
            ForEach(status.models) { split in
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        split.broken
                            ? "\(split.model) · a Mac stopped answering; it reloads on the next request" : split.model
                    )
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(split.broken ? RoachPalette.warning : RoachPalette.text)
                    RoachFlowLayout(spacing: 6) {
                        ForEach(Array(split.stages.enumerated()), id: \.offset) { _, stage in
                            RoachTag(
                                "\(stage.name) · layers \(stage.layers.split(separator: ",").first.map(String.init) ?? stage.layers)",
                                accent: RoachPalette.magenta)
                        }
                    }
                }
            }
        }
    }

    private func peerRow(_ peer: Peer) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name ?? peer.address)
                    .font(.roach(size: 13, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(peerDetail(peer))
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(peer.reachable == false ? RoachPalette.warning : RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Remove") { Task { await remove(peer.address) } }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(busy)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous).fill(
                RoachPalette.panelRaised.opacity(0.54)))
    }

    private func peerDetail(_ peer: Peer) -> String {
        guard let reachable = peer.reachable else { return peer.address }
        guard reachable else { return peer.error ?? "\(peer.address) isn't answering." }
        let free = peer.memory.map { " · \(gigabytes($0.free)) free" } ?? ""
        return "\(peer.address) · \(peer.chip ?? "Mac")\(free)"
    }

    private func gigabytes(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

    private func load(refresh: Bool) async {
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: refresh ? "/api/cluster?refresh=1" : "/api/cluster")
            let decoded = try JSONDecoder().decode(Status.self, from: data)
            status = decoded
            if name.isEmpty || name != decoded.name { name = decoded.name }
        } catch {
            message = "Couldn't check the cluster: \(error.localizedDescription)"
        }
    }

    private func save(_ change: [String: Any], done: String) async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: change)
            _ = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/cluster", method: "PUT", jsonBody: body)
            await load(refresh: change["peers"] != nil || change["code"] != nil)
            message = done
        } catch {
            message = "Couldn't change that setting: \(error.localizedDescription)"
        }
    }

    private func add(_ raw: String) async {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["address": value])
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/cluster/peers", method: "POST", jsonBody: body)
            status = try JSONDecoder().decode(Status.self, from: data)
            address = ""
            nearby.removeAll { $0.address == value }
            let added = status?.peers.first { $0.address == value }
            message =
                added?.reachable == true
                ? "\(added?.name ?? value) is in the cluster."
                : "Added \(value). It isn't answering yet: \(added?.error ?? "check that Cluster is on there, with this pairing code.")"
        } catch {
            message = "Couldn't add that Mac: \(error.localizedDescription)"
        }
    }

    private func remove(_ value: String) async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["address": value])
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(
                using: config, path: "/api/cluster/peers", method: "DELETE", jsonBody: body)
            status = try JSONDecoder().decode(Status.self, from: data)
            message = "Removed \(value)."
        } catch {
            message = "Couldn't remove that Mac: \(error.localizedDescription)"
        }
    }

    private func findNearby() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await ManagedAppRuntimeBridge.shared.orgRequest(using: config, path: "/api/cluster/nearby")
            nearby = try JSONDecoder().decode(NearbyList.self, from: data).macs
            message = nearby.isEmpty ? "No other Macs with Cluster on were found on this network." : nil
        } catch {
            message = "Couldn't look for Macs: \(error.localizedDescription)"
        }
    }
}
