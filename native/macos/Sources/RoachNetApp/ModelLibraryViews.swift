import RoachNetCore
import RoachNetDesign
import SwiftUI

struct ModelLibrarySection: View {
    @ObservedObject var model: WorkspaceModel
    @State private var filter: Filter = .fits

    enum Filter: String, CaseIterable, Identifiable {
        case fits = "Fits this Mac"
        case all = "All"
        case code = "Code"
        case chat = "Chat"

        var id: String { rawValue }

        func includes(_ entry: RoachModelLibraryEntry) -> Bool {
            switch self {
            case .all: return true
            case .fits: return entry.fitsThisMac
            case .code: return entry.isCodeModel
            case .chat: return !entry.isCodeModel
            }
        }
    }

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        header
                        Spacer(minLength: 12)
                        filterPicker.frame(maxWidth: 380)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        filterPicker
                    }
                }

                content
            }
        }
        .task { await model.watchModelLibrary() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODEL LIBRARY")
                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)
            Text(summaryLine)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Show models")
    }

    private var summaryLine: String {
        guard let library = model.modelLibrary else {
            return "Models RoachClaw can run on this Mac, downloaded one at a time and checked before use."
        }
        let onMac = library.models.filter { $0.installed == true }.count
        let fitting = library.models.filter(\.fitsThisMac).count
        return
            "\(RoachCopy.count(library.models.count, "model")) · \(onMac) on this Mac · \(fitting) fit its memory. Each download is checked against its published SHA-256 before RoachClaw uses it."
    }

    @ViewBuilder
    private var content: some View {
        if let library = model.modelLibrary {
            let rows = RoachModelLibraryEntry.displayOrder(library.models).filter(filter.includes)
            if rows.isEmpty {
                Text(
                    filter == .fits
                        ? "None of these models fit this Mac's memory. Show All to see them anyway."
                        : "No models match this filter."
                )
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { entry in
                        ModelLibraryRow(
                            entry: entry,
                            pull: library.pull(for: entry.name),
                            isDefault: entry.name == model.displayedRoachClawDefaultModel,
                            isBusy: model.modelLibraryRequests.contains(entry.name),
                            download: { Task { await model.downloadLibraryModel(entry) } },
                            stop: { Task { await model.stopLibraryModelDownload(entry) } },
                            makeDefault: { Task { await model.makeLibraryModelDefault(entry) } }
                        )
                    }
                }
            }
            Text(
                "This Mac gives models up to \(ByteCountFormatter.string(fromByteCount: library.budgetBytes, countStyle: .memory)) of its \(ByteCountFormatter.string(fromByteCount: library.memoryBytes, countStyle: .memory))."
            )
            .font(.roach(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(RoachPalette.muted)
        } else if let notice = model.modelLibraryNotice {
            RoachNotice(
                title: "Model library not loaded", detail: notice, accent: RoachPalette.warning,
                systemName: "shippingbox")
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the model library.")
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
            }
        }
    }
}

struct ModelLibraryRow: View {
    let entry: RoachModelLibraryEntry
    let pull: RoachModelPull?
    let isDefault: Bool
    let isBusy: Bool
    let download: () -> Void
    let stop: () -> Void
    let makeDefault: () -> Void

    private var installed: Bool { entry.installed == true }
    private var downloading: Bool { pull?.isActive == true }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.isCodeModel ? "chevron.left.forwardslash.chevron.right" : "text.bubble")
                    .font(.roach(size: 13, weight: .semibold))
                    .foregroundStyle(installed ? RoachPalette.signal : RoachPalette.muted)
                    .frame(width: 30, height: 30)
                    .roachSurface(.sunken, radius: 9)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    RoachFlowLayout(spacing: 6, rowSpacing: 6) {
                        Text(entry.title)
                            .font(.roach(size: 13.5, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        if entry.recommended {
                            RoachTag("Best fit", accent: RoachPalette.accent)
                                .accessibilityLabel("Best fit for this Mac")
                        }
                        if installed { RoachTag("On this Mac", accent: RoachPalette.cyan) }
                    }
                    Text(entry.specLine)
                        .font(.roach(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                    HStack(spacing: 7) {
                        RoachLED(fitColor, size: 6)
                        Text("\(entry.fitLabel). \(entry.fitDetail)")
                            .font(.roach(size: 11.5, weight: .medium))
                            .foregroundStyle(RoachPalette.text.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(entry.makerLine)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                action
                    .fixedSize()
            }

            if let pull, pull.isActive || pull.state == "failed" || pull.state == "stopped" {
                progress(pull)
            }
        }
        .padding(12)
        .background(shape.fill(RoachPalette.panelRaised.opacity(installed ? 0.66 : 0.46)))
        .overlay(shape.strokeBorder(borderColor, lineWidth: RoachMetrics.line(1)))
        .opacity(entry.fitsThisMac || installed ? 1 : 0.72)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(entry.title), \(entry.useLabel.lowercased()) model, \(entry.downloadSizeLabel). \(entry.fitLabel).")
    }

    @ViewBuilder
    private var action: some View {
        if downloading {
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(isBusy)
            .accessibilityHint("Stops downloading \(entry.title). What has arrived is kept.")
        } else if installed {
            if isDefault {
                Label("Default", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.signal)
                    .padding(.horizontal, 6)
                    .accessibilityLabel("\(entry.title) is RoachClaw's default model")
            } else {
                Button(action: makeDefault) {
                    Text("Make default")
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(isBusy)
            }
        } else if entry.fitsThisMac {
            Button(action: download) {
                Label(
                    pull?.state == "stopped" ? "Resume" : (pull?.state == "failed" ? "Try again" : "Download"),
                    systemImage: "arrow.down.circle.fill"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachPrimaryButtonStyle())
            .disabled(isBusy)
            .accessibilityHint("Downloads \(entry.downloadSizeLabel) to this Mac.")
        } else {
            Text("Too big")
                .font(.roach(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.muted)
                .padding(.horizontal, 6)
                .accessibilityLabel("\(entry.title) is too big for this Mac")
        }
    }

    private func progress(_ pull: RoachModelPull) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if pull.isActive {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(RoachPalette.border.opacity(0.7))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(RoachPalette.signal)
                                .frame(width: max(8, proxy.size.width * CGFloat(pull.fraction ?? 0.02)))
                        }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityLabel("Download progress")
                .accessibilityValue(pull.progressLine)
            }
            Text(pull.progressLine)
                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(pull.state == "failed" ? RoachPalette.warning : RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 42)
        .roachAnimation(.medium, .assemble, value: pull.completed)
    }

    private var fitColor: Color {
        switch entry.fit {
        case "good": return RoachPalette.signal
        case "tight": return RoachPalette.warning
        default: return RoachPalette.danger
        }
    }

    private var borderColor: Color {
        if downloading { return RoachPalette.signal.opacity(0.45) }
        if isDefault && installed { return RoachPalette.signal.opacity(0.32) }
        return RoachPalette.border
    }
}
