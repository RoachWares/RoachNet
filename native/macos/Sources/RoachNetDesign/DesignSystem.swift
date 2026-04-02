import AppKit
import SwiftUI

public enum RoachPalette {
    public static let green = Color(red: 0.20, green: 1.0, blue: 0.49)
    public static let magenta = Color(red: 0.75, green: 0.35, blue: 0.95)
    public static let bronze = Color(red: 1.00, green: 0.72, blue: 0.00)
    public static let cyan = Color(red: 0.38, green: 0.80, blue: 1.0)
    public static let background = Color(red: 0.05, green: 0.05, blue: 0.06)
    public static let panel = Color(red: 0.10, green: 0.10, blue: 0.11)
    public static let panelRaised = Color(red: 0.12, green: 0.12, blue: 0.14)
    public static let panelSoft = Color(red: 0.16, green: 0.16, blue: 0.18)
    public static let panelGlass = Color.white.opacity(0.04)
    public static let border = Color.white.opacity(0.08)
    public static let text = Color.white.opacity(0.96)
    public static let muted = Color.white.opacity(0.66)
    public static let success = Color(red: 0.20, green: 1.0, blue: 0.49)
    public static let warning = Color(red: 0.90, green: 0.70, blue: 0.22)
}

public struct RoachBackground: View {
    @State private var drift = false

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.06),
                    Color(red: 0.06, green: 0.06, blue: 0.08),
                    Color(red: 0.05, green: 0.05, blue: 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(RoachPalette.green.opacity(0.08))
                .frame(width: 380, height: 380)
                .blur(radius: 110)
                .offset(x: drift ? -20 : -90, y: drift ? -70 : -120)

            Circle()
                .fill(RoachPalette.magenta.opacity(0.08))
                .frame(width: 360, height: 360)
                .blur(radius: 104)
                .offset(x: drift ? 120 : 70, y: drift ? -110 : -60)

            Circle()
                .fill(RoachPalette.cyan.opacity(0.03))
                .frame(width: 220, height: 220)
                .blur(radius: 86)
                .offset(x: drift ? -110 : -70, y: drift ? 200 : 250)

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.012),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.015),
                            Color.clear,
                            Color.white.opacity(0.012),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.screen)
                .opacity(0.10)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

public struct RoachPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panel.opacity(0.84),
                                RoachPalette.panelRaised.opacity(0.76),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(RoachPalette.border, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color.white.opacity(0.025), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
    }
}

public struct RoachKicker: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(RoachPalette.muted)
    }
}

public struct RoachPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachPrimaryButtonBody(configuration: configuration)
    }
}

public struct RoachSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachSecondaryButtonBody(configuration: configuration)
    }
}

public struct RoachCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachCardButtonBody(configuration: configuration)
    }
}

private struct RoachPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(RoachPalette.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            RoachPalette.panelSoft.opacity(
                                configuration.isPressed ? 0.72 : (hovered ? 0.92 : 0.84)
                            )
                        )
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    RoachPalette.green.opacity(hovered ? 0.82 : 0.70),
                                    RoachPalette.magenta.opacity(hovered ? 0.54 : 0.44),
                                    Color.white.opacity(hovered ? 0.22 : 0.16),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.0
                        )
                }
            )
            .shadow(color: RoachPalette.green.opacity(configuration.isPressed ? 0.10 : (hovered ? 0.22 : 0.16)), radius: hovered ? 28 : 24, y: hovered ? 16 : 12)
            .scaleEffect(configuration.isPressed ? 0.982 : (hovered ? 1.018 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: hovered)
    }
}

private struct RoachSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(RoachPalette.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        RoachPalette.panelRaised.opacity(
                            configuration.isPressed ? 0.62 : (hovered ? 0.82 : 0.74)
                        )
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hovered ? RoachPalette.green.opacity(0.16) : RoachPalette.border, lineWidth: 1)
            )
            .shadow(color: hovered ? RoachPalette.green.opacity(0.08) : .clear, radius: hovered ? 18 : 0, y: hovered ? 10 : 0)
            .scaleEffect(configuration.isPressed ? 0.984 : (hovered ? 1.012 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: hovered)
    }
}

private struct RoachCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.986 : (hovered ? 1.012 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -2 : 0))
            .shadow(
                color: RoachPalette.green.opacity(configuration.isPressed ? 0.04 : (hovered ? 0.12 : 0.05)),
                radius: hovered ? 22 : 14,
                y: hovered ? 14 : 8
            )
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hovered)
    }
}

public struct RoachStageStrip: View {
    private let titles: [String]
    private let activeIndex: Int

    public init(titles: [String], activeIndex: Int) {
        self.titles = titles
        self.activeIndex = activeIndex
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Text(String(index + 1))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(index <= activeIndex ? RoachPalette.text : RoachPalette.muted)

                    if index == activeIndex {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(index == activeIndex ? RoachPalette.panelSoft.opacity(0.72) : RoachPalette.panelRaised.opacity(0.42))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(index == activeIndex ? RoachPalette.green.opacity(0.26) : RoachPalette.border, lineWidth: 1)
                )
            }
        }
    }
}

public struct RoachInfoPill: View {
    private let title: String
    private let value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(RoachPalette.panelRaised.opacity(0.64))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(RoachPalette.border, lineWidth: 1)
            )
    }
}

public struct RoachStatusRow: View {
    private let title: String
    private let value: String
    private let accent: Color

    public init(title: String, value: String, accent: Color) {
        self.title = title
        self.value = value
        self.accent = accent
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RoachPalette.text)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(accent.opacity(0.12))
                )
        }
    }
}

public struct RoachOrbitMark: View {
    @State private var breathe = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let plaqueSize = size * 0.94
            let iconSize = size * 0.76
            let radius = max(16, plaqueSize * 0.22)

            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.green.opacity(0.18),
                                RoachPalette.magenta.opacity(0.16),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: plaqueSize, height: plaqueSize)
                    .blur(radius: size * 0.11)
                    .scaleEffect(breathe ? 1.06 : 0.96)

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: plaqueSize, height: plaqueSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                if let iconImage = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RoachNet.icns")) {
                    Image(nsImage: iconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: RoachPalette.green.opacity(0.12), radius: size * 0.12, y: size * 0.05)
                } else {
                    VStack(spacing: size * 0.04) {
                        Image(systemName: "ant.fill")
                            .font(.system(size: size * 0.22, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [RoachPalette.green, RoachPalette.magenta],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("RN")
                            .font(.system(size: size * 0.08, weight: .black, design: .monospaced))
                            .tracking(size * 0.008)
                            .foregroundStyle(RoachPalette.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            withAnimation(.easeInOut(duration: 5.8).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

public struct RoachSectionHeader: View {
    private let kicker: String
    private let title: String
    private let detail: String?

    public init(_ kicker: String, title: String, detail: String? = nil) {
        self.kicker = kicker
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoachKicker(kicker)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(RoachPalette.text)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
            }
        }
    }
}

public struct RoachInlineField: View {
    private let title: String
    @Binding private var value: String
    private let placeholder: String

    public init(title: String, value: Binding<String>, placeholder: String) {
        self.title = title
        self._value = value
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(RoachPalette.muted)

            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.64))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RoachPalette.border, lineWidth: 1)
                )
        }
    }
}

public struct RoachTag: View {
    private let text: String
    private let accent: Color

    public init(_ text: String, accent: Color = RoachPalette.green) {
        self.text = text
        self.accent = accent
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            )
    }
}

public struct RoachCommandTray: View {
    private let label: String
    private let prompt: String
    private let keys: String

    public init(label: String, prompt: String, keys: String = "⌘K") {
        self.label = label
        self.prompt = prompt
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RoachPalette.green)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(RoachPalette.panelGlass)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(RoachPalette.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(RoachPalette.muted)
                Text(prompt)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
            }

            Spacer()

            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(RoachPalette.border, lineWidth: 1)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
        .shadow(color: RoachPalette.green.opacity(0.05), radius: 24, y: 12)
    }
}

public struct RoachSidebarTile: View {
    private let title: String
    private let subtitle: String
    private let isSelected: Bool
    private let systemName: String
    private let isCompact: Bool
    @State private var hovered = false

    public init(title: String, subtitle: String, systemName: String, isSelected: Bool, isCompact: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.systemName = systemName
        self.isSelected = isSelected
        self.isCompact = isCompact
    }

    public var body: some View {
        Group {
            if isCompact {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.green : RoachPalette.muted)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                isSelected
                                    ? RoachPalette.panelSoft.opacity(hovered ? 0.84 : 0.72)
                                    : RoachPalette.panelRaised.opacity(hovered ? 0.68 : 0.52)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelected ? RoachPalette.green.opacity(0.24) : (hovered ? RoachPalette.green.opacity(0.12) : RoachPalette.border), lineWidth: 1)
                    )
                    .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.18 : 0.12) : .clear, radius: hovered ? 22 : 18, y: hovered ? 10 : 8)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? RoachPalette.green : RoachPalette.muted)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(RoachPalette.panelGlass)
                        )
                        .shadow(color: isSelected ? RoachPalette.green.opacity(0.16) : .clear, radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            isSelected
                                ? RoachPalette.panelSoft.opacity(hovered ? 0.78 : 0.66)
                                : RoachPalette.panel.opacity(hovered ? 0.44 : 0.30)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(isSelected ? RoachPalette.green.opacity(0.20) : (hovered ? RoachPalette.green.opacity(0.10) : RoachPalette.border), lineWidth: 1)
                )
                .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.16 : 0.10) : .clear, radius: hovered ? 24 : 20, y: hovered ? 12 : 10)
            }
        }
        .scaleEffect(isCompact ? (hovered ? 1.05 : 1.0) : (hovered ? 1.012 : 1.0))
        .offset(y: hovered ? -1 : 0)
        .onHover { inside in
            hovered = inside
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: hovered)
    }
}

public struct RoachMetricCard: View {
    private let label: String
    private let value: String
    private let detail: String

    public init(label: String, value: String, detail: String) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
    }
}

public struct RoachInsetPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(RoachPalette.panelRaised.opacity(0.74))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(RoachPalette.border, lineWidth: 1)
            )
    }
}

public struct RoachNotice: View {
    private let title: String
    private let detail: String
    private let accent: Color
    private let systemName: String

    public init(title: String, detail: String, accent: Color = RoachPalette.magenta, systemName: String = "exclamationmark.triangle.fill") {
        self.title = title
        self.detail = detail
        self.accent = accent
        self.systemName = systemName
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        )
    }
}
