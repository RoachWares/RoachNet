import AppKit
import SwiftUI

public enum RoachPalette {
    @inline(__always)
    private static func token(_ token: RoachColorToken) -> Color {
        RoachThemeRuntime.shared.theme[token]
    }

    public static var green: Color { token(.signal) }
    public static var magenta: Color { token(.accent) }
    public static var bronze: Color { token(.accentTertiary) }
    public static var cyan: Color { token(.accentInfo) }
    public static var background: Color { token(.background) }
    public static var backgroundRaised: Color { token(.backgroundRaised) }
    public static var panel: Color { token(.panel) }
    public static var panelRaised: Color { token(.panelRaised) }
    public static var panelSoft: Color { token(.panelSoft) }
    public static var panelGlass: Color { token(.glass) }
    public static var panelSpecular: Color { token(.specular) }
    public static var border: Color { token(.border) }
    public static var borderStrong: Color { token(.borderStrong) }
    public static var text: Color { token(.text) }
    public static var muted: Color { token(.muted) }
    public static var success: Color { token(.success) }
    public static var warning: Color { token(.warning) }
    public static var shadow: Color { token(.shadow) }

    public static var accent: Color { token(.accent) }
    public static var accentSecondary: Color { token(.accentSecondary) }
    public static var accentTertiary: Color { token(.accentTertiary) }
    public static var accentInfo: Color { token(.accentInfo) }
    public static var danger: Color { token(.danger) }
    public static var action: Color { token(.action) }
    public static var actionInk: Color { token(.actionInk) }
    public static var signal: Color { token(.signal) }
    public static var focus: Color { token(.focus) }
    public static var inputLine: Color { token(.inputLine) }
    public static var ink: Color { token(.ink) }
    public static var shade: Color { token(.shade) }
    public static func scrim(_ opacity: Double) -> Color {
        Color.black.opacity(isDark ? opacity : opacity * 0.5)
    }
    public static func backdropDim(_ opacity: Double) -> Color {
        isDark ? Color.black.opacity(opacity) : background.opacity(opacity)
    }
    public static var onAccent: Color { token(.onAccent) }

    public static var isDark: Bool { RoachThemeRuntime.shared.theme.isDark }
    public static var glowBlendMode: BlendMode { RoachThemeRuntime.shared.theme.glowBlendMode }

    public static var actionLight: Color {
        let action = RoachThemeRuntime.shared.theme.rgba(.action)
        return action.mixed(with: .white, amount: 0.28).color
    }

    public static var actionPress: Color {
        let action = RoachThemeRuntime.shared.theme.rgba(.action)
        return action.mixed(with: .black, amount: 0.18).color
    }
}

enum RoachDither {
    static let bayer4: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ]

    static func threshold(row: Int, column: Int) -> Double {
        bayer4[((row & 3) * 4) + (column & 3)] / 16.0
    }

    static func cellColor(row: Int, column: Int, accent: Color, intensity: Double, inks: RoachBackgroundInks) -> Color {
        let alpha = min(0.18, max(0.018, intensity))
        switch abs((row * 3 + column * 5) % 9) {
        case 0: return inks.secondary.opacity(alpha * 0.64)
        case 1, 5: return inks.info.opacity(alpha * 0.72)
        case 2: return accent.opacity(alpha * 0.92)
        default: return inks.primary.opacity(alpha)
        }
    }
}

public enum RoachMotion {
    public enum Duration: Double, Sendable {
        case quick = 0.12
        case short = 0.22
        case medium = 0.42
        case long = 0.76
        case scene = 1.2
    }

    public enum Curve: Sendable {
        case assemble
        case snap
        case gentle
    }

    public static func seconds(_ duration: Duration) -> Double {
        duration.rawValue * RoachThemeRuntime.shared.theme.tempo
    }

    public static func animation(_ duration: Duration = .short, _ curve: Curve = .assemble) -> Animation {
        let length = seconds(duration)
        switch curve {
        case .assemble: return .timingCurve(0.16, 1, 0.3, 1, duration: length)
        case .snap: return .timingCurve(0.34, 1.56, 0.64, 1, duration: length)
        case .gentle: return .timingCurve(0.4, 0, 0.2, 1, duration: length)
        }
    }

    public static func stagger(_ index: Int) -> Double { Double(index) * 0.06 * RoachThemeRuntime.shared.theme.tempo }
}

private struct RoachMotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let duration: RoachMotion.Duration
    let curve: RoachMotion.Curve
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : RoachMotion.animation(duration, curve), value: value)
    }
}

extension View {
    public func roachAnimation<Value: Equatable>(
        _ duration: RoachMotion.Duration = .short, _ curve: RoachMotion.Curve = .assemble, value: Value
    ) -> some View {
        modifier(RoachMotionModifier(duration: duration, curve: curve, value: value))
    }
}

public enum RoachSurfaceLevel: Sendable {
    case sunken
    case base
    case raised
    case overlay
}

private struct RoachSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let level: RoachSurfaceLevel
    let radius: CGFloat
    let glass: Bool
    let edge: Color?

    func body(content: Content) -> some View {
        let theme = RoachThemeRuntime.shared.theme
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
        let fill: Color
        switch level {
        case .sunken: fill = theme[.backgroundRaised]
        case .base: fill = theme[.panel]
        case .raised: fill = theme[.panelRaised]
        case .overlay: fill = theme[.panelSoft]
        }
        let lineColor = edge ?? (level == .base || level == .sunken ? theme[.border] : theme[.borderStrong])
        let seeThrough = glass && !reduceTransparency && theme.glass > 0.05 && level != .sunken
        return
            content
            .background {
                ZStack {
                    if seeThrough {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(theme[.glass])
                    } else {
                        shape.fill(fill)
                    }
                    if level != .sunken {
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: theme[.specular].opacity(0.55), location: 0),
                                    .init(color: .clear, location: 0.42),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                ZStack {
                    shape.strokeBorder(lineColor, lineWidth: RoachMetrics.line(1))
                    if level != .sunken {
                        shape.inset(by: 0.5)
                            .stroke(
                                LinearGradient(
                                    stops: [
                                        .init(color: theme[.specular], location: 0),
                                        .init(color: .clear, location: 0.08),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                }
                .allowsHitTesting(false)
            }
            .shadow(
                color: level == .sunken ? .clear : theme[.shadow].opacity(theme.shadow * 0.55),
                radius: level == .overlay ? 7 : (level == .raised ? 3 : 1.5), x: 0,
                y: level == .overlay ? 6 : (level == .raised ? 2 : 1)
            )
            .shadow(
                color: level == .sunken || level == .base ? .clear : theme[.shadow].opacity(theme.shadow * 0.45),
                radius: level == .overlay ? 34 : 18, x: 0, y: level == .overlay ? 24 : 12)
    }
}

extension View {
    public func roachSurface(
        _ level: RoachSurfaceLevel = .base, radius: CGFloat = 16, glass: Bool = false, edge: Color? = nil
    ) -> some View {
        modifier(RoachSurfaceModifier(level: level, radius: radius, glass: glass, edge: edge))
    }
}

public struct RoachPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roachSurface(.base, radius: 16, glass: true)
    }
}

public struct RoachSpotlightPanel<Content: View>: View {
    private let accent: Color
    private let content: Content

    public init(accent: Color = RoachPalette.magenta, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                GeometryReader { proxy in
                    RadialGradient(
                        colors: [accent.opacity(RoachMetrics.glow(RoachPalette.isDark ? 0.16 : 0.10)), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.9
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                .allowsHitTesting(false)
            }
            .roachSurface(.raised, radius: 18, glass: true)
    }
}

public struct RoachInsetPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roachSurface(.sunken, radius: 12)
    }
}

public struct RoachLED: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let color: Color?
    private let size: CGFloat
    private let pulses: Bool

    public init(_ color: Color? = nil, size: CGFloat = 7, pulses: Bool = false) {
        self.color = color
        self.size = size
        self.pulses = pulses
    }

    public var body: some View {
        let tint = color ?? RoachPalette.signal
        Group {
            if pulses {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { timeline in
                    dot(
                        tint,
                        glow: reduceMotion ? 0.7 : 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2.4))
                }
            } else {
                dot(tint, glow: 0.7)
            }
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityHidden(true)
    }

    private func dot(_ tint: Color, glow: Double) -> some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(tint.opacity(0.22), lineWidth: size * 0.36).frame(
                    width: size * 1.36, height: size * 1.36)
            )
            .shadow(color: tint.opacity(RoachMetrics.glow(0.4 + 0.3 * glow)), radius: size * 1.1)
    }
}

public struct RoachKicker: View {
    private let text: String
    private let led: Bool

    public init(_ text: String, led: Bool = false) {
        self.text = text
        self.led = led
    }

    public var body: some View {
        HStack(spacing: 6) {
            if led { RoachLED(size: 5) }
            Text(text.uppercased())
                .font(.roach(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(1.26)
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

public struct RoachDisplayTitle: View {
    private let text: String
    private let size: CGFloat
    private let color: Color?

    public init(_ text: String, size: CGFloat = 28, color: Color? = nil) {
        self.text = text
        self.size = size
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.roach(size: size, weight: .heavy, design: .rounded))
            .tracking(-size * 0.02)
            .foregroundStyle(color ?? RoachPalette.text)
            .lineSpacing(size * 0.02)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct RoachBadge: View {
    private let text: String
    private let isActive: Bool

    public init(_ text: String, isActive: Bool = false) {
        self.text = text
        self.isActive = isActive
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.roach(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(isActive ? RoachPalette.signal : RoachPalette.muted)
            .frame(minWidth: 30, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(5), style: .continuous)
                    .fill(isActive ? RoachPalette.signal.opacity(0.1) : RoachPalette.panelRaised.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(5), style: .continuous)
                    .strokeBorder(
                        isActive ? RoachPalette.signal.opacity(0.4) : RoachPalette.borderStrong,
                        lineWidth: RoachMetrics.line(1))
            )
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
        VStack(alignment: .leading, spacing: 5) {
            RoachKicker(kicker, led: true)
            Text(title)
                .font(.roach(size: 18, weight: .heavy, design: .rounded))
                .tracking(-0.3)
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .allowsTightening(true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.roach(size: 11.5, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

public struct RoachUtilityButtonStyle: ButtonStyle {
    private let tint: Color

    public init(tint: Color = RoachPalette.green) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        RoachUtilityButtonBody(configuration: configuration, tint: tint)
    }
}

public struct RoachCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachCardButtonBody(configuration: configuration)
    }
}

private struct RoachPressMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPressed: Bool
    let hovered: Bool
    var lift: CGFloat = 1
    var pressScale: CGFloat = 0.985

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || !isPressed ? 1 : pressScale)
            .offset(y: reduceMotion ? 0 : (isPressed ? 1 : (hovered ? -lift : 0)))
            .animation(reduceMotion ? nil : RoachMotion.animation(.quick, .gentle), value: isPressed)
            .animation(reduceMotion ? nil : RoachMotion.animation(.short, .assemble), value: hovered)
    }
}

private func roachSheen(_ color: Color, end: CGFloat) -> LinearGradient {
    LinearGradient(
        stops: [.init(color: color, location: 0), .init(color: .clear, location: end)],
        startPoint: .top,
        endPoint: .bottom
    )
}

private struct RoachPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        let pressed = configuration.isPressed
        let action = RoachPalette.action
        let light = RoachPalette.actionLight
        let pill = Capsule(style: .continuous)
        configuration.label
            .font(.roach(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(RoachPalette.actionInk)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background {
                ZStack {
                    pill.fill(pressed ? RoachPalette.actionPress : action)
                    pill.fill(roachSheen(light.opacity(0.32), end: 0.7))
                        .opacity(hovered && !pressed ? 1 : 0)
                    pill.strokeBorder(roachSheen(light.opacity(hovered ? 1 : 0.7), end: 0.4), lineWidth: 1)
                        .opacity(pressed ? 0 : 1)
                }
                .allowsHitTesting(false)
            }
            .overlay {
                pill.inset(by: -2)
                    .stroke(light.opacity(0.26), lineWidth: 4)
                    .opacity(hovered && !pressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: action.opacity(RoachMetrics.glow(pressed ? 0 : (hovered ? 0.5 : 0.34))),
                radius: hovered ? 12 : 9,
                x: 0,
                y: hovered ? 8 : 6
            )
            .contentShape(pill)
            .contentShape(.focusEffect, pill)
            .onHover { hovered = $0 }
            .modifier(RoachPressMotion(isPressed: pressed, hovered: hovered))
            .roachDisabledAppearance()
    }
}

private struct RoachSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        let pressed = configuration.isPressed
        let pill = Capsule(style: .continuous)
        configuration.label
            .font(.roach(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background {
                ZStack {
                    pill.fill(hovered && !pressed ? RoachPalette.panelSoft : RoachPalette.panelRaised)
                    pill.fill(roachSheen(RoachPalette.panelSpecular.opacity(pressed ? 0 : 0.55), end: 0.5))
                }
                .allowsHitTesting(false)
            }
            .overlay {
                pill.strokeBorder(
                    hovered ? RoachPalette.muted.opacity(0.75) : RoachPalette.borderStrong,
                    lineWidth: RoachMetrics.line(1)
                )
                .allowsHitTesting(false)
            }
            .shadow(color: RoachPalette.shadow.opacity(pressed ? 0 : 0.22), radius: 3, x: 0, y: 2)
            .contentShape(pill)
            .contentShape(.focusEffect, pill)
            .onHover { hovered = $0 }
            .modifier(RoachPressMotion(isPressed: pressed, hovered: hovered))
            .roachDisabledAppearance()
    }
}

private struct RoachUtilityButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @State private var hovered = false

    var body: some View {
        let pressed = configuration.isPressed
        let pill = Capsule(style: .continuous)
        configuration.label
            .font(.roach(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 2)
            .background {
                ZStack {
                    pill.fill(hovered ? RoachPalette.panelSoft : RoachPalette.panelRaised.opacity(0.72))
                    pill.fill(tint.opacity(pressed ? 0.18 : (hovered ? 0.12 : 0)))
                }
                .allowsHitTesting(false)
            }
            .overlay {
                pill.strokeBorder(hovered ? tint.opacity(0.45) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
                    .allowsHitTesting(false)
            }
            .contentShape(pill)
            .contentShape(.focusEffect, pill)
            .onHover { hovered = $0 }
            .modifier(RoachPressMotion(isPressed: pressed, hovered: hovered))
            .roachDisabledAppearance()
    }
}

private struct RoachDisabledAppearance: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.42)
            .saturation(isEnabled ? 1 : 0.35)
            .roachAnimation(.short, .gentle, value: isEnabled)
    }
}

extension View {
    fileprivate func roachDisabledAppearance() -> some View {
        modifier(RoachDisabledAppearance())
    }
}

private struct RoachCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .shadow(
                color: RoachPalette.shadow.opacity(hovered && !pressed ? 0.3 : 0),
                radius: 16,
                x: 0,
                y: 10
            )
            .onHover { hovered = $0 }
            .modifier(RoachPressMotion(isPressed: pressed, hovered: hovered, lift: 2, pressScale: 0.985))
    }
}

extension View {
    fileprivate func roachPlate(radius: CGFloat, fill: Color? = nil, edge: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
        return background {
            ZStack {
                shape.fill(fill ?? RoachPalette.panelRaised.opacity(0.72))
                shape.fill(roachSheen(RoachPalette.panelSpecular.opacity(0.4), end: 0.5))
            }
            .allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(edge ?? RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                .allowsHitTesting(false)
        }
    }

    fileprivate func roachChip(_ tint: Color, fill: Double = 0.1, edge: Double = 0.4) -> some View {
        let pill = Capsule(style: .continuous)
        return background(pill.fill(tint.opacity(fill)).allowsHitTesting(false))
            .overlay(pill.strokeBorder(tint.opacity(edge), lineWidth: RoachMetrics.line(1)).allowsHitTesting(false))
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
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                let isActive = index == activeIndex
                let isDone = index < activeIndex
                HStack(spacing: 7) {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.roach(size: 9.5, weight: .bold))
                            .foregroundStyle(RoachPalette.signal)
                    } else {
                        Text(String(format: "%02d", index + 1))
                            .font(.roach(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isActive ? RoachPalette.text : RoachPalette.muted)
                    }

                    if isActive {
                        RoachLED(size: 5, pulses: true)
                        Text(title)
                            .font(.roach(size: 12, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? RoachPalette.panelSoft : RoachPalette.panelRaised.opacity(0.7))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isActive ? RoachPalette.signal.opacity(0.45) : RoachPalette.borderStrong,
                            lineWidth: RoachMetrics.line(1))
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Step \(index + 1) of \(titles.count), \(title)"
                        + (isActive ? ", current" : (isDone ? ", done" : "")))
            }
        }
        .roachAnimation(.medium, .assemble, value: activeIndex)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Capsule(style: .continuous)
                    .fill(RoachPalette.signal)
                    .frame(width: 14, height: 2)
                    .shadow(color: RoachPalette.signal.opacity(RoachMetrics.glow(0.5)), radius: 3)

                Text(title.uppercased())
                    .font(.roach(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }
            Text(value)
                .font(.roach(size: 13.5, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roachPlate(radius: 12)
        .accessibilityElement(children: .combine)
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
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoachLED(accent, size: 6)
                Text(title)
                    .font(.roach(size: 11.5, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.roach(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .roachChip(accent)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct RoachDigestRow: View {
    private let label: String
    private let value: String
    private let detail: String
    private let systemName: String
    private let accent: Color
    private let metadata: [String]

    public init(
        _ label: String,
        value: String,
        detail: String,
        systemName: String,
        accent: Color = RoachPalette.green,
        metadata: [String] = []
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.systemName = systemName
        self.accent = accent
        self.metadata = metadata
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .roachPlate(radius: 9, fill: accent.opacity(0.1), edge: accent.opacity(0.35))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.roach(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(RoachPalette.muted)

                Text(value)
                    .font(.roach(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Text(detail)
                    .font(.roach(size: 11, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)

                if !metadata.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            ForEach(Array(metadata.prefix(3)), id: \.self) { item in
                                chip(item)
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(metadata.prefix(3)), id: \.self) { item in
                                chip(item)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roachPlate(radius: 14, fill: RoachPalette.panelRaised.opacity(0.56), edge: RoachPalette.border)
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.roach(size: 9, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .roachChip(accent)
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
            let image = NSImage(contentsOf: directResource)
        {
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
                            color: RoachPalette.signal.opacity(RoachMetrics.glow(glow ? 0.3 : 0.18)),
                            radius: glow ? size * 0.5 : size * 0.18,
                            y: glow ? size * 0.08 : size * 0.03
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
                    .font(.roach(size: size, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.signal : RoachPalette.muted)
                    .shadow(
                        color: isSelected ? RoachPalette.signal.opacity(RoachMetrics.glow(0.35)) : .clear,
                        radius: size * 0.4)
            }
        }
    }
}

public struct RoachOrbitMark: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                RoachPalette.action.opacity(RoachMetrics.glow(RoachPalette.isDark ? 0.42 : 0.2)),
                                RoachPalette.action.opacity(0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.5
                        )
                    )
                    .frame(width: size, height: size)

                RoachMark(.roach, label: nil)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .shadow(
                        color: Color.black.opacity(RoachPalette.isDark ? 0.4 : 0.18), radius: max(1, size * 0.04),
                        y: size * 0.025)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RoachNet logo")
    }
}

public struct RoachFeatureTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let label: String
    private let title: String
    private let detail: String
    private let systemName: String
    private let accent: Color
    @State private var hovered = false

    public init(
        _ label: String,
        title: String,
        detail: String,
        systemName: String,
        accent: Color = RoachPalette.green
    ) {
        self.label = label
        self.title = title
        self.detail = detail
        self.systemName = systemName
        self.accent = accent
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    RoachKicker(label)

                    Text(title)
                        .font(.roach(size: 17, weight: .heavy, design: .rounded))
                        .tracking(-0.3)
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.84)
                }

                Spacer(minLength: 10)

                Image(systemName: systemName)
                    .font(.roach(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .roachPlate(
                        radius: 10, fill: accent.opacity(hovered ? 0.16 : 0.1),
                        edge: accent.opacity(hovered ? 0.55 : 0.32)
                    )
                    .shadow(color: accent.opacity(RoachMetrics.glow(hovered ? 0.32 : 0)), radius: 10)
                    .accessibilityHidden(true)
            }

            Text(detail)
                .font(.roach(size: 12, weight: .regular))
                .foregroundStyle(RoachPalette.muted)
                .lineSpacing(1.5)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: hovered ? 96 : 64, height: 2)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.roach(size: 11, weight: .bold))
                    .foregroundStyle(hovered ? accent : RoachPalette.muted)
                    .offset(x: hovered && !reduceMotion ? 1.5 : 0, y: hovered && !reduceMotion ? -1.5 : 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            GeometryReader { proxy in
                RadialGradient(
                    colors: [accent.opacity(RoachMetrics.glow(hovered ? 0.14 : 0.08)), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.8
                )
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
        .roachSurface(.base, radius: 16, glass: true, edge: hovered ? accent.opacity(0.5) : nil)
        .offset(y: hovered && !reduceMotion ? -1 : 0)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .roachAnimation(.short, .assemble, value: hovered)
    }
}

public struct RoachInlineField: View {
    private let title: String
    @Binding private var value: String
    private let placeholder: String
    @FocusState private var focused: Bool
    @State private var hovered = false

    public init(title: String, value: Binding<String>, placeholder: String) {
        self.title = title
        self._value = value
        self.placeholder = placeholder
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.roach(size: 11.5, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .accessibilityHidden(true)

            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.roach(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    ZStack {
                        shape.fill(RoachPalette.backgroundRaised)
                        shape.fill(roachSheen(RoachPalette.shade.opacity(RoachPalette.isDark ? 0.45 : 0.12), end: 0.22))
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(
                        focused ? RoachPalette.focus : (hovered ? RoachPalette.muted : RoachPalette.inputLine),
                        lineWidth: RoachMetrics.line(focused ? 1.5 : 1)
                    )
                    .allowsHitTesting(false)
                }
                .background {
                    shape.inset(by: -3)
                        .strokeBorder(RoachPalette.focus.opacity(0.4), lineWidth: 3)
                        .opacity(focused ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .onHover { hovered = $0 }
                .accessibilityLabel(title)
                .roachAnimation(.short, .assemble, value: focused)
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
            .font(.roach(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .roachChip(accent)
    }
}

public struct RoachCommandTray: View {
    private let label: String
    private let prompt: String
    private let keys: String
    @State private var hovered = false

    public init(label: String, prompt: String, keys: String = "⌘K") {
        self.label = label
        self.prompt = prompt
        self.keys = keys
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(hovered ? RoachPalette.signal : RoachPalette.muted)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.roach(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
                Text(prompt)
                    .font(.roach(size: 12.5, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
            }

            Spacer(minLength: 8)

            Text(keys)
                .font(.roach(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(hovered ? RoachPalette.text : RoachPalette.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .roachPlate(radius: 6, fill: RoachPalette.panelRaised, edge: RoachPalette.borderStrong)
                .accessibilityLabel("Shortcut \(keys)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            ZStack {
                shape.fill(RoachPalette.backgroundRaised.opacity(0.92))
                shape.fill(roachSheen(RoachPalette.shade.opacity(RoachPalette.isDark ? 0.4 : 0.1), end: 0.25))
            }
            .allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(hovered ? RoachPalette.muted : RoachPalette.inputLine, lineWidth: RoachMetrics.line(1))
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .onHover { hovered = $0 }
        .roachAnimation(.short, .gentle, value: hovered)
    }
}

public struct RoachSidebarTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let subtitle: String
    private let isSelected: Bool
    private let systemName: String
    private let assetName: String?
    private let isCompact: Bool
    private let glyph: RoachGlyph?
    private let count: String?
    @State private var hovered = false

    public init(
        title: String,
        subtitle: String,
        systemName: String,
        assetName: String? = nil,
        isSelected: Bool,
        isCompact: Bool = false,
        glyph: RoachGlyph? = nil,
        count: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemName = systemName
        self.assetName = assetName
        self.isSelected = isSelected
        self.isCompact = isCompact
        self.glyph = glyph
        self.count = count
    }

    public var body: some View {
        Group {
            if isCompact {
                compact
            } else {
                row
            }
        }
        .onHover { hovered = $0 }
        .roachAnimation(.short, .assemble, value: hovered)
        .roachAnimation(.medium, .assemble, value: isSelected)
    }

    private var compact: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
        return Group {
            if let glyph {
                RoachGlyphView(
                    glyph, size: 20, isLit: isSelected,
                    ink: isSelected || hovered ? RoachPalette.text : RoachPalette.muted)
            } else {
                RoachModuleMark(
                    systemName: systemName,
                    assetName: assetName,
                    size: assetName == nil ? 16 : 18,
                    isSelected: isSelected
                )
            }
        }
        .frame(width: 48, height: 48)
        .background {
            ZStack {
                shape.fill(
                    isSelected ? RoachPalette.panelRaised : (hovered ? RoachPalette.ink.opacity(0.06) : Color.clear))
                if isSelected {
                    shape.fill(roachSheen(RoachPalette.panelSpecular.opacity(0.5), end: 0.45))
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(
                isSelected ? RoachPalette.borderStrong : (hovered ? RoachPalette.border : Color.clear),
                lineWidth: RoachMetrics.line(1)
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Capsule(style: .continuous)
                .fill(RoachPalette.signal)
                .frame(width: isSelected ? 14 : 0, height: 2)
                .shadow(color: RoachPalette.signal.opacity(RoachMetrics.glow(0.6)), radius: 4)
                .padding(.bottom, 5)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .scaleEffect(hovered && !reduceMotion && !isSelected ? 1.03 : 1)
        .help(title)
    }

    private var row: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous)
        return HStack(spacing: 10) {
            Group {
                if let glyph {
                    RoachGlyphTile(
                        glyph,
                        isLit: isSelected,
                        ink: isSelected || hovered ? RoachPalette.text : RoachPalette.muted
                    )
                } else {
                    RoachModuleMark(
                        systemName: systemName,
                        assetName: assetName,
                        size: assetName == nil ? 14 : 16,
                        isSelected: isSelected
                    )
                    .frame(width: 36, height: 26)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.roach(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected || hovered ? RoachPalette.text : RoachPalette.text.opacity(0.86))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.roach(size: 10.5, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let count, !count.isEmpty {
                Text(count)
                    .font(.roach(size: 10.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            } else {
                Image(systemName: "chevron.right")
                    .font(.roach(size: 9, weight: .semibold))
                    .foregroundStyle(RoachPalette.muted.opacity(isSelected ? 0.9 : (hovered ? 0.8 : 0.4)))
                    .offset(x: hovered && !reduceMotion ? 1.5 : 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background {
            ZStack {
                if isSelected {
                    shape.fill(RoachPalette.panelRaised)
                    shape.fill(RoachPalette.accent.opacity(0.14))
                } else if hovered {
                    shape.fill(RoachPalette.text.opacity(0.06))
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(RoachPalette.signal)
                .frame(width: 3)
                .padding(.vertical, isSelected ? 10 : 16)
                .shadow(color: RoachPalette.signal.opacity(RoachMetrics.glow(0.8)), radius: 4)
                .opacity(isSelected ? 1 : 0)
                .offset(x: -6)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
    }
}

public struct RoachMetricCard: View {
    private let label: String
    private let value: String
    private let detail: String
    @State private var hovered = false

    public init(label: String, value: String, detail: String) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.roach(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(1)
            Text(value)
                .font(.roach(size: 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .allowsTightening(false)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.roach(size: 11, weight: .regular))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.top, 17)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background {
            GeometryReader { proxy in
                RadialGradient(
                    colors: [RoachPalette.accent.opacity(RoachMetrics.glow(hovered ? 0.12 : 0.07)), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.9
                )
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
        .roachSurface(.raised, radius: 14, edge: hovered ? RoachPalette.muted.opacity(0.6) : nil)
        .overlay(alignment: .topLeading) {
            Capsule(style: .continuous)
                .fill(RoachPalette.signal)
                .frame(width: hovered ? 26 : 18, height: 2)
                .shadow(color: RoachPalette.signal.opacity(RoachMetrics.glow(0.5)), radius: 3)
                .padding(.leading, 10)
                .padding(.top, 9)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .help("\(label): \(value)\n\(detail)")
        .onHover { hovered = $0 }
        .roachAnimation(.short, .assemble, value: hovered)
        .accessibilityElement(children: .combine)
    }
}

public struct RoachNotice: View {
    private let title: String
    private let detail: String
    private let accent: Color
    private let systemName: String

    public init(
        title: String, detail: String, accent: Color = RoachPalette.magenta,
        systemName: String = "exclamationmark.triangle.fill"
    ) {
        self.title = title
        self.detail = detail
        self.accent = accent
        self.systemName = systemName
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .roachPlate(radius: 8, fill: accent.opacity(0.12), edge: accent.opacity(0.4))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.roach(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 12.5, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roachSurface(.raised, radius: 14, edge: accent.opacity(0.4))
        .accessibilityElement(children: .combine)
    }
}
