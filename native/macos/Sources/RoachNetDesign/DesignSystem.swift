import AppKit
import SwiftUI

public enum RoachPalette {
    public static let green = Color(red: 0.24, green: 0.98, blue: 0.54)
    public static let magenta = Color(red: 0.82, green: 0.40, blue: 0.98)
    public static let bronze = Color(red: 0.98, green: 0.74, blue: 0.20)
    public static let cyan = Color(red: 0.40, green: 0.84, blue: 1.0)
    public static let background = Color(red: 0.035, green: 0.036, blue: 0.044)
    public static let panel = Color(red: 0.088, green: 0.091, blue: 0.103)
    public static let panelRaised = Color(red: 0.108, green: 0.111, blue: 0.126)
    public static let panelSoft = Color(red: 0.150, green: 0.154, blue: 0.172)
    public static let panelGlass = Color.white.opacity(0.045)
    public static let border = Color.white.opacity(0.085)
    public static let borderStrong = Color.white.opacity(0.14)
    public static let text = Color.white.opacity(0.97)
    public static let muted = Color.white.opacity(0.68)
    public static let success = Color(red: 0.24, green: 0.98, blue: 0.54)
    public static let warning = Color(red: 0.93, green: 0.73, blue: 0.26)
    public static let shadow = Color.black.opacity(0.24)
}

public struct RoachBackground: View {
    @State private var drift = false

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    RoachPalette.background,
                    Color(red: 0.045, green: 0.048, blue: 0.060),
                    RoachPalette.background,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(RoachPalette.green.opacity(0.085))
                .frame(width: 440, height: 440)
                .blur(radius: 126)
                .offset(x: drift ? -18 : -122, y: drift ? -52 : -136)

            Circle()
                .fill(RoachPalette.magenta.opacity(0.092))
                .frame(width: 410, height: 410)
                .blur(radius: 116)
                .offset(x: drift ? 138 : 88, y: drift ? -106 : -68)

            Circle()
                .fill(RoachPalette.cyan.opacity(0.045))
                .frame(width: 240, height: 240)
                .blur(radius: 96)
                .offset(x: drift ? -132 : -78, y: drift ? 182 : 236)

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
                            Color.white.opacity(0.02),
                            Color.clear,
                            Color.white.opacity(0.016),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.screen)
                .opacity(0.12)

            RadialGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.24),
                ],
                center: .center,
                startRadius: 120,
                endRadius: 780
            )

            Canvas { context, size in
                let cell: CGFloat = 36
                let rows = Int(ceil(size.height / cell))
                let columns = Int(ceil(size.width / cell))

                for row in 0...rows {
                    let y = CGFloat(row) * cell
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        path,
                        with: .color(Color.white.opacity(row.isMultiple(of: 2) ? 0.01 : 0.004)),
                        lineWidth: 1
                    )
                }

                for column in 0...columns {
                    let x = CGFloat(column) * cell
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        path,
                        with: .color(Color.white.opacity(column.isMultiple(of: 2) ? 0.006 : 0.003)),
                        lineWidth: 1
                    )
                }
            }
            .opacity(0.11)
            .blendMode(.overlay)
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panel.opacity(0.92),
                                RoachPalette.panelRaised.opacity(0.86),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.05),
                                Color.clear,
                                Color.white.opacity(0.015),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color.white.opacity(0.025), lineWidth: 1)
            )
            .shadow(color: RoachPalette.shadow.opacity(0.88), radius: 30, x: 0, y: 16)
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
            .tracking(1.6)
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
            .font(.system(size: 14, weight: .semibold, design: .rounded))
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
                                    RoachPalette.green.opacity(hovered ? 0.88 : 0.74),
                                    RoachPalette.magenta.opacity(hovered ? 0.58 : 0.46),
                                    Color.white.opacity(hovered ? 0.24 : 0.16),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.0
                        )
                }
            )
            .shadow(color: RoachPalette.green.opacity(configuration.isPressed ? 0.09 : (hovered ? 0.20 : 0.14)), radius: hovered ? 24 : 18, x: 0, y: hovered ? 14 : 10)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.016 : 1.0))
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
            .font(.system(size: 14, weight: .medium, design: .rounded))
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
                    .stroke(hovered ? RoachPalette.green.opacity(0.18) : RoachPalette.border, lineWidth: 1)
            )
            .shadow(color: hovered ? RoachPalette.green.opacity(0.07) : .clear, radius: hovered ? 16 : 0, x: 0, y: hovered ? 10 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : (hovered ? 1.01 : 1.0))
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
            .scaleEffect(configuration.isPressed ? 0.985 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .shadow(
                color: RoachPalette.green.opacity(configuration.isPressed ? 0.04 : (hovered ? 0.10 : 0.05)),
                radius: hovered ? 18 : 12,
                x: 0,
                y: hovered ? 12 : 8
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
                .fill(index == activeIndex ? RoachPalette.panelSoft.opacity(0.76) : RoachPalette.panelRaised.opacity(0.44))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(index == activeIndex ? RoachPalette.green.opacity(0.28) : RoachPalette.border, lineWidth: 1)
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
                .tracking(1.1)
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
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(0.68),
                                RoachPalette.panelSoft.opacity(0.56),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
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

private func roachRuntimeImage(named name: String) -> NSImage? {
    let resourceName = (name as NSString).deletingPathExtension
    let resourceExtension = (name as NSString).pathExtension
    let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks

    for bundle in bundles {
        if let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension.isEmpty ? nil : resourceExtension
        ), let image = NSImage(contentsOf: url) {
            return image
        }

        if let directResource = bundle.resourceURL?.appendingPathComponent(name),
           let image = NSImage(contentsOf: directResource) {
            return image
        }
    }

    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(name),
        Bundle.main.resourceURL?.appendingPathComponent("RoachNetMac_RoachNetApp.bundle/\(name)"),
        Bundle.main.resourceURL?.appendingPathComponent("RoachNetMac_RoachNetSetup.bundle/\(name)"),
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"),
    ].compactMap { $0 }

    for candidate in candidates {
        if let image = NSImage(contentsOf: candidate) {
            return image
        }
    }

    return nil
}

private func roachTemplateImage(from image: NSImage) -> NSImage {
    let template = (image.copy() as? NSImage) ?? image
    template.isTemplate = true
    return template
}

public struct RoachModuleMark: View {
    private let systemName: String
    private let assetName: String?
    private let size: CGFloat
    private let isSelected: Bool
    private let glow: Bool

    public init(
        systemName: String,
        assetName: String? = nil,
        size: CGFloat,
        isSelected: Bool = false,
        glow: Bool = false
    ) {
        self.systemName = systemName
        self.assetName = assetName
        self.size = size
        self.isSelected = isSelected
        self.glow = glow
    }

    public var body: some View {
        Group {
            if let assetName, let image = roachRuntimeImage(named: assetName) {
                if glow || isSelected {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .shadow(
                            color: RoachPalette.magenta.opacity(glow ? 0.24 : 0.14),
                            radius: glow ? size * 0.52 : size * 0.18,
                            y: glow ? size * 0.09 : size * 0.04
                        )
                } else {
                    Image(nsImage: roachTemplateImage(from: image))
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .foregroundStyle(RoachPalette.muted)
                }
            } else {
                Image(systemName: systemName)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.green : RoachPalette.muted)
            }
        }
    }
}

public struct RoachOrbitMark: View {
    @State private var breathe = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let haloSize = size * 0.96
            let iconSize = size * 0.90

            ZStack {
                Circle()
                    .fill(RoachPalette.green.opacity(0.20))
                    .frame(width: haloSize, height: haloSize)
                    .blur(radius: size * 0.18)
                    .offset(x: breathe ? -size * 0.04 : -size * 0.11, y: breathe ? -size * 0.05 : -size * 0.13)

                Circle()
                    .fill(RoachPalette.magenta.opacity(0.22))
                    .frame(width: haloSize * 0.88, height: haloSize * 0.88)
                    .blur(radius: size * 0.18)
                    .offset(x: breathe ? size * 0.08 : size * 0.04, y: breathe ? size * 0.08 : size * 0.03)

                Circle()
                    .fill(RoachPalette.cyan.opacity(0.08))
                    .frame(width: haloSize * 0.64, height: haloSize * 0.64)
                    .blur(radius: size * 0.12)
                    .offset(y: size * 0.03)

                if let iconImage = roachRuntimeImage(named: "RoachNet.icns") {
                    Image(nsImage: iconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: RoachPalette.green.opacity(0.18), radius: size * 0.16, y: size * 0.05)
                        .shadow(color: RoachPalette.magenta.opacity(0.14), radius: size * 0.18, y: size * 0.04)
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
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineSpacing(1.1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(2)
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
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)

            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.68),
                                    RoachPalette.panelSoft.opacity(0.56),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: 1)
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
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.16), accent.opacity(0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [RoachPalette.panelGlass, Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RoachPalette.green)
            }
            .frame(width: 36, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
                Text(prompt)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
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
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.06), Color.white.opacity(0.025)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.78),
                            RoachPalette.panel.opacity(0.70),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(RoachPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: RoachPalette.shadow.opacity(0.16), radius: 24, x: 0, y: 12)
    }
}

public struct RoachSidebarTile: View {
    private let title: String
    private let subtitle: String
    private let isSelected: Bool
    private let systemName: String
    private let assetName: String?
    private let isCompact: Bool
    @State private var hovered = false

    public init(
        title: String,
        subtitle: String,
        systemName: String,
        assetName: String? = nil,
        isSelected: Bool,
        isCompact: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemName = systemName
        self.assetName = assetName
        self.isSelected = isSelected
        self.isCompact = isCompact
    }

    public var body: some View {
        Group {
            if isCompact {
                    RoachModuleMark(
                        systemName: systemName,
                        assetName: assetName,
                        size: assetName == nil ? 16 : 18,
                        isSelected: isSelected
                    )
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    isSelected
                                        ? RoachPalette.panelSoft.opacity(hovered ? 0.88 : 0.76)
                                        : RoachPalette.panelRaised.opacity(hovered ? 0.72 : 0.56)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isSelected ? RoachPalette.green.opacity(0.28) : (hovered ? RoachPalette.green.opacity(0.12) : RoachPalette.border), lineWidth: 1)
                        )
                        .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.16 : 0.10) : .clear, radius: hovered ? 18 : 14, x: 0, y: hovered ? 10 : 8)
            } else {
                HStack(spacing: 12) {
                    RoachModuleMark(
                        systemName: systemName,
                        assetName: assetName,
                        size: assetName == nil ? 15 : 16,
                        isSelected: isSelected
                    )
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
                                        ? RoachPalette.panelSoft.opacity(hovered ? 0.88 : 0.74)
                                        : RoachPalette.panel.opacity(hovered ? 0.50 : 0.34)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(isSelected ? RoachPalette.green.opacity(0.22) : (hovered ? RoachPalette.green.opacity(0.10) : RoachPalette.border), lineWidth: 1)
                        )
                        .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.14 : 0.08) : .clear, radius: hovered ? 18 : 14, x: 0, y: hovered ? 10 : 8)
            }
        }
        .scaleEffect(isCompact ? (hovered ? 1.05 : 1.0) : (hovered ? 1.01 : 1.0))
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
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [RoachPalette.green.opacity(0.92), RoachPalette.magenta.opacity(0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 42, height: 4)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
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
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.72),
                            RoachPalette.panelSoft.opacity(0.56),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(RoachPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: RoachPalette.shadow.opacity(0.16), radius: 16, x: 0, y: 8)
    }
}

public struct RoachInsetPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.84),
                            RoachPalette.panel.opacity(0.80),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(RoachPalette.borderStrong, lineWidth: 1)
            )
            .shadow(color: RoachPalette.shadow.opacity(0.14), radius: 16, x: 0, y: 8)
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
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.16), accent.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [RoachPalette.panelRaised.opacity(0.76), RoachPalette.panel.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: RoachPalette.shadow.opacity(0.14), radius: 16, x: 0, y: 8)
    }
}
