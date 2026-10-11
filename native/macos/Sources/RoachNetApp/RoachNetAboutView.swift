import SwiftUI
import RoachNetDesign

fileprivate struct AboutAction: Identifiable {
    let title: String
    let detail: String
    let url: String
    let systemImage: String
    let accent: Color

    var id: String { title }
}

struct RoachNetAboutView: View {
    @State private var revealed = false

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? shortVersion
    }

    /// The source commit the build script stamped into Info.plist (ROA-40),
    /// shortened, with "-dirty" kept when the tree had uncommitted changes.
    private var buildLabel: String {
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "RoachNetSourceCommit") as? String,
              commit.count >= 12 else { return buildVersion }
        let dirty = commit.hasSuffix("-dirty")
        return "\(buildVersion) · \(commit.prefix(10))\(dirty ? "-dirty" : "")"
    }

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var supportActions: [AboutAction] {
        [
            AboutAction(
                title: "RoachNet.org",
                detail: "Product home and install rails.",
                url: "https://roachnet.org/",
                systemImage: "network",
                accent: RoachPalette.green
            ),
            AboutAction(
                title: "GitHub Repo",
                detail: "Source, releases, and issue trail.",
                url: "https://github.com/RoachWares/RoachNet",
                systemImage: "chevron.left.forwardslash.chevron.right",
                accent: RoachPalette.magenta
            ),
            AboutAction(
                title: "RoachWares.org",
                detail: "Company home and public record.",
                url: "https://roachwares.org/",
                systemImage: "building.2.crop.circle.fill",
                accent: RoachPalette.cyan
            ),
            AboutAction(
                title: "Donate",
                detail: "Keep the release lane fed.",
                url: "https://www.paypal.com/ncp/payment/ZV8RL9DWQXHGE",
                systemImage: "heart.circle.fill",
                accent: RoachPalette.bronze
            ),
        ]
    }

    var body: some View {
        ZStack {
            AboutBackdropView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSpotlightPanel(accent: RoachPalette.green) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 18) {
                                aboutHeroCopy
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                aboutHeroSignal
                                    .frame(width: 310, alignment: .topLeading)
                            }

                            VStack(alignment: .leading, spacing: 16) {
                                aboutHeroCopy
                                aboutHeroSignal
                            }
                        }
                    }
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 12)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            aboutCapabilitiesPanel
                                .frame(maxWidth: .infinity, alignment: .leading)
                            aboutManifestPanel
                                .frame(width: 260, alignment: .topLeading)
                            aboutLinksPanel
                                .frame(width: 280, alignment: .topLeading)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            aboutManifestPanel
                            aboutCapabilitiesPanel
                            aboutLinksPanel
                        }
                    }
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 16)

                    aboutCreditsPanel
                    .opacity(revealed ? 1 : 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 480, idealWidth: 900, maxWidth: 1020, minHeight: 440, idealHeight: 640)
        .onAppear {
            withAnimation(.spring(response: 0.56, dampingFraction: 0.88, blendDuration: 0.08)) {
                revealed = true
            }
        }
    }

    private var aboutHeroCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoachKicker("About RoachNet")
            Text("One native shell for AI, vault, games, maps, and dev.")
                .font(.roach(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .fixedSize(horizontal: false, vertical: true)

            Text("Local-first, native, and kept under one roof.")
                .font(.roach(size: 13, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                RoachTag("v\(shortVersion)", accent: RoachPalette.green)
                RoachTag("build \(buildVersion)", accent: RoachPalette.magenta)
                RoachTag("macOS \(macOSVersion)", accent: RoachPalette.cyan)
                RoachTag(RoachNetGlobalHotKey.hint, accent: RoachPalette.bronze)
            }
        }
    }

    private var aboutHeroSignal: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    AboutSignalMark()
                        .frame(width: 104, height: 96)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Manifest")
                            .font(.roach(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.green)
                        Text("Native shell. Global bar. Contained services.")
                            .font(.roach(size: 15, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Command bar: \(RoachNetGlobalHotKey.hint)")
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    aboutFeatureLine("RoachClaw", detail: "Chat-first workbench")
                    aboutFeatureLine("RoachAtlas", detail: "Offline packs and phone GPS")
                    aboutFeatureLine("Dev Desk", detail: "Editor and shell in one desk")
                }
            }
        }
    }

    private var aboutCapabilitiesPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Capabilities",
                    title: "The useful rooms.",
                    detail: "Native surfaces. No rented lobby."
                )

                VStack(alignment: .leading, spacing: 10) {
                    AboutCapabilityRow(
                        title: "RoachClaw",
                        detail: "Private-first AI lane with memory, context, and voice.",
                        systemImage: "sparkles",
                        accent: RoachPalette.magenta
                    )
                    AboutCapabilityRow(
                        title: "Vault",
                        detail: "Notes, docs, captures, books, and media under one shelf.",
                        systemImage: "books.vertical.fill",
                        accent: RoachPalette.green
                    )
                    AboutCapabilityRow(
                        title: "RoachArcade",
                        detail: "ROMs, macOS games, mods, and cheats tied to your files.",
                        systemImage: "gamecontroller.fill",
                        accent: RoachPalette.magenta
                    )
                    AboutCapabilityRow(
                        title: "RoachAtlas",
                        detail: "Offline map packs and Bluetooth phone tracking.",
                        systemImage: "map.fill",
                        accent: RoachPalette.cyan
                    )
                    AboutCapabilityRow(
                        title: "Dev Desk",
                        detail: "Editor, shell, and coding assist without leaving the desk.",
                        systemImage: "terminal.fill",
                        accent: RoachPalette.bronze
                    )
                }
            }
        }
    }

    private var aboutManifestPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Manifest",
                    title: "Version and command surface.",
                    detail: "Core product facts."
                )

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    AboutStatCard(label: "Version", value: shortVersion, accent: RoachPalette.green)
                    AboutStatCard(label: "Build", value: buildLabel, accent: RoachPalette.magenta)
                    AboutStatCard(label: "Platform", value: "Apple Silicon", accent: RoachPalette.cyan)
                    AboutStatCard(label: "Command Bar", value: RoachNetGlobalHotKey.hint, accent: RoachPalette.bronze)
                }

                RoachNotice(
                    title: "Native shell",
                    detail: "The same bar runs in-shell and globally.",
                    accent: RoachPalette.cyan,
                    systemName: "command"
                )
            }
        }
    }

    private var aboutLinksPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Links",
                    title: "Public rails and support.",
                    detail: "Product, source, and support."
                )

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(supportActions) { action in
                        AboutActionLink(action: action)
                    }
                }
            }
        }
    }

    private var aboutCreditsPanel: some View {
        RoachInsetPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    RoachWaresHeartMark()
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("RoachWares LLC")
                            .font(.roach(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(RoachPalette.green)
                        creditLine
                    }

                    Spacer(minLength: 18)

                    Text("Offline first. Apple Silicon native.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        RoachWaresHeartMark()
                            .frame(width: 34, height: 34)
                        Text("RoachWares LLC")
                            .font(.roach(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(RoachPalette.green)
                    }
                    creditLine
                    Text("Offline first. Apple Silicon native.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
    }

    private var creditLine: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Independently built and maintained with")
            RoachWaresHeartMark()
                .frame(width: 18, height: 18)
            Text("by Brennan Lesher.")
        }
        .font(.roach(size: 12, weight: .medium))
        .foregroundStyle(RoachPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func aboutFeatureLine(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .frame(width: 96, alignment: .leading)
            Text(detail)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RoachWaresHeartMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: RoachMetrics.radius(9), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.green.opacity(0.22),
                            RoachPalette.magenta.opacity(0.18),
                            RoachPalette.panelRaised.opacity(0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(9), style: .continuous)
                        .stroke(RoachPalette.green.opacity(pulse ? 0.46 : 0.22), lineWidth: RoachMetrics.line(1))
                )
                .shadow(color: RoachPalette.green.opacity(RoachMetrics.glow(pulse ? 0.24 : 0.08)), radius: pulse ? 12 : 4)

            Image(systemName: "heart.fill")
                .font(.roach(size: 10, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [RoachPalette.green, RoachPalette.bronze],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(pulse ? 1.08 : 0.96)
        }
        .onAppear {
            updatePulse(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            updatePulse(reduceMotion: isEnabled)
        }
    }

    private func updatePulse(reduceMotion: Bool) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pulse = false
            }
        } else {
            withAnimation(.easeInOut(duration: 1.55).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct AboutBackdropView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    RoachPalette.shade,
                    RoachPalette.panel.opacity(0.94),
                    RoachPalette.backgroundRaised.opacity(0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ForEach(0..<9, id: \.self) { index in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                (index.isMultiple(of: 2) ? RoachPalette.green : RoachPalette.magenta).opacity(0.040),
                                Color.clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .rotationEffect(.degrees(-10))
                    .offset(
                        x: drift ? CGFloat(index * 7) : CGFloat(index * -5),
                        y: CGFloat(index * 64 - 250)
                    )
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [RoachPalette.ink.opacity(0.02), Color.clear, RoachPalette.ink.opacity(0.012)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.screen)
                .opacity(0.14)
        }
        .ignoresSafeArea()
        .onAppear {
            updateDrift(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            updateDrift(reduceMotion: isEnabled)
        }
    }

    private func updateDrift(reduceMotion: Bool) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                drift = false
            }
        } else {
            withAnimation(.easeInOut(duration: 9.0).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

private struct AboutSignalMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        ZStack {
            RoachOrbitMark()

            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(RoachPalette.ink.opacity(0.08), lineWidth: RoachMetrics.line(1))

            VStack(alignment: .leading, spacing: 8) {
                Text("LIVE")
                    .font(.roach(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.green)

                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 18.0, paused: reduceMotion)) { context in
                    let now = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(0..<8, id: \.self) { index in
                            let strength = 0.28 + (abs(sin(now * 1.5 + Double(index) * 0.42)) * 0.72)
                            Capsule(style: .continuous)
                                .fill(index.isMultiple(of: 2) ? RoachPalette.green : RoachPalette.magenta)
                                .frame(width: 7, height: 14 + strength * 28)
                        }
                    }
                }
                .frame(height: 44)

                Text(phase ? "native · local · command" : "local · native · command")
                    .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(12)
        }
        .onAppear {
            updatePhase(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            updatePhase(reduceMotion: isEnabled)
        }
    }

    private func updatePhase(reduceMotion: Bool) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                phase = false
            }
        } else {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

private struct AboutCapabilityRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.roach(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .fill(accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.roach(size: 14, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: RoachMetrics.line(1))
        )
    }
}

private struct AboutStatCard: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.roach(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.roach(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: RoachMetrics.line(1))
        )
    }
}

private struct AboutActionLink: View {
    let action: AboutAction
    @State private var hovered = false

    var body: some View {
        if let url = URL(string: action.url) {
            Link(destination: url) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: action.systemImage)
                        .font(.roach(size: 14, weight: .semibold))
                        .foregroundStyle(action.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                                .fill(action.accent.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.roach(size: 14, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(action.detail)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    Image(systemName: "arrow.up.right")
                        .font(.roach(size: 11, weight: .bold))
                        .foregroundStyle(action.accent.opacity(hovered ? 1 : 0.72))
                        .offset(x: hovered ? 1 : 0, y: hovered ? -1 : 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.60))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                        .stroke(action.accent.opacity(hovered ? 0.22 : 0.12), lineWidth: RoachMetrics.line(1))
                )
                .scaleEffect(hovered ? 1.01 : 1)
                .offset(y: hovered ? -1 : 0)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }
}
