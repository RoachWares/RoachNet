import AppKit
import SwiftUI

/// The colors every RoachNet surface draws with, read from the active theme.
///
/// The original names (green, magenta, bronze, cyan) are the Signal theme's
/// colors for the four accent slots; other themes put their own colors there.
/// Reading a token inside a view body makes that view follow theme changes.
public enum RoachPalette {
    @inline(__always)
    private static func token(_ token: RoachColorToken) -> Color {
        RoachThemeRuntime.shared.theme[token]
    }

    /// Primary accent.
    public static var green: Color { token(.accent) }
    /// Second accent.
    public static var magenta: Color { token(.accentSecondary) }
    /// Third accent.
    public static var bronze: Color { token(.accentTertiary) }
    /// Info accent.
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
    /// Neutral tint for strokes and washes: white on dark themes.
    public static var ink: Color { token(.ink) }
    /// Neutral tint for recessed wells and vignettes: black on dark themes.
    public static var shade: Color { token(.shade) }
    /// Dimming layer behind sheets and overlays. `opacity` is the dark-theme
    /// strength; light themes dim less so the page underneath stays legible.
    public static func scrim(_ opacity: Double) -> Color {
        Color.black.opacity(isDark ? opacity : opacity * 0.5)
    }
    /// Tones down the animated backdrop behind a full window (Settings,
    /// About): darker on dark themes, washed toward the page on light ones.
    public static func backdropDim(_ opacity: Double) -> Color {
        isDark ? Color.black.opacity(opacity) : background.opacity(opacity)
    }
    /// Text on an accent fill.
    public static var onAccent: Color { token(.onAccent) }

    public static var isDark: Bool { RoachThemeRuntime.shared.theme.isDark }
    /// Blend mode for decorative dither and glow layers.
    public static var glowBlendMode: BlendMode { RoachThemeRuntime.shared.theme.glowBlendMode }
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
        case 0:
            return inks.secondary.opacity(alpha * 0.64)
        case 1, 5:
            return inks.info.opacity(alpha * 0.72)
        case 2:
            return accent.opacity(alpha * 0.92)
        default:
            return inks.primary.opacity(alpha)
        }
    }
}

private struct RoachAnimatedChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cornerRadius: CGFloat
    let accent: Color

    var body: some View {
        let theme = RoachThemeRuntime.shared.theme
        let inks = RoachBackgroundInks(accentsOf: theme)
        let ink = theme[.ink]
        let borderStrong = theme[.borderStrong]
        let lineWidth = CGFloat(theme.borderWidth)
        let glow = theme.glow
        let radius = RoachMetrics.radius(cornerRadius)

        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 16.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                let rounded = Path(roundedRect: rect, cornerRadius: radius)

                context.stroke(
                    rounded,
                    with: .linearGradient(
                        Gradient(colors: [
                            ink.opacity(0.08),
                            accent.opacity(0.18 * glow),
                            borderStrong,
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    ),
                    lineWidth: lineWidth
                )
                guard glow > 0 else { return }

                let cell: CGFloat = 5
                let columns = max(1, Int(ceil(size.width / cell)))
                let rows = max(1, Int(ceil(size.height / cell)))
                let pulse = 0.5 + 0.5 * sin(time * 0.9)

                for row in 0...rows {
                    for column in 0...columns {
                        let x = CGFloat(column) * cell
                        let y = CGFloat(row) * cell
                        let distanceToEdge = min(min(x, y), min(max(0, size.width - x), max(0, size.height - y)))
                        let edge = max(0, 1 - Double(distanceToEdge / 76))
                        let drift = 0.5 + 0.5 * sin((Double(column) * 0.18) + (Double(row) * 0.11) + (time * 0.7))
                        let threshold = RoachDither.threshold(row: row, column: column) * 0.42
                        let intensity = (edge * 0.11) + (drift * 0.030) + (pulse * 0.012)

                        guard intensity > threshold else { continue }

                        let fill = RoachDither.cellColor(
                            row: row,
                            column: column,
                            accent: accent,
                            intensity: min(0.14, intensity - threshold + 0.018) * glow,
                            inks: inks
                        )
                        let cellRect = CGRect(x: x, y: y, width: max(1, cell - 2), height: max(1, cell - 2))
                        context.fill(Path(roundedRect: cellRect, cornerRadius: 1), with: .color(fill))
                    }
                }
            }
            .blendMode(theme.isDark ? .normal : .multiply)
            .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(cornerRadius), style: .continuous))
        }
        .allowsHitTesting(false)
    }
}

public struct RoachPanel<Content: View>: View {
    private let content: Content
    private let radius: CGFloat = 16

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                    .fill(.ultraThinMaterial)
                    .allowsHitTesting(false)
            )
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panel.opacity(0.94),
                                RoachPalette.panelRaised.opacity(0.90),
                                RoachPalette.shade.opacity(0.28),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                    .stroke(RoachPalette.ink.opacity(0.09), lineWidth: RoachMetrics.line(1))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.ink.opacity(0.08),
                                Color.clear,
                                RoachPalette.ink.opacity(0.012),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                    .inset(by: 1)
                    .stroke(RoachPalette.ink.opacity(0.022), lineWidth: RoachMetrics.line(1))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoachAnimatedChrome(cornerRadius: radius, accent: RoachPalette.green)
            )
            .shadow(color: RoachPalette.shadow.opacity(0.48), radius: 22, x: 0, y: 12)
            .shadow(color: RoachPalette.green.opacity(RoachMetrics.glow(0.03)), radius: 28, x: 0, y: 14)
    }
}

public struct RoachSpotlightPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent: Color
    private let content: Content
    private let radius: CGFloat = 18

    public init(accent: Color = RoachPalette.magenta, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        let inks = RoachBackgroundInks(accentsOf: RoachThemeRuntime.shared.theme)
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.96),
                                    RoachPalette.panel.opacity(0.90),
                                    RoachPalette.shade.opacity(0.34),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.10),
                                    RoachPalette.green.opacity(0.035),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 18.0, paused: reduceMotion)) { timeline in
                        Canvas { context, size in
                            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                            let cell: CGFloat = size.width < 620 ? 6 : 7
                            let columns = max(1, Int(ceil(size.width / cell)))
                            let rows = max(1, Int(ceil(size.height / cell)))

                            for row in 0...rows {
                                for column in 0...columns {
                                    let nx = Double(column) / Double(columns)
                                    let ny = Double(row) / Double(rows)
                                    let topEdge = max(0, 1.0 - ny * 4.4)
                                    let leftEdge = max(0, 1.0 - nx * 3.7)
                                    let crawl = 0.5 + 0.5 * sin((nx * 8.2) + (ny * 12.0) + time * 0.9)
                                    let threshold = RoachDither.threshold(row: row, column: column) * 0.52
                                    let intensity = (topEdge * 0.18) + (leftEdge * 0.08) + (crawl * 0.035)

                                    guard intensity > threshold else { continue }

                                    let rect = CGRect(
                                        x: CGFloat(column) * cell,
                                        y: CGFloat(row) * cell,
                                        width: max(1, cell - 2),
                                        height: max(1, cell - 2)
                                    )
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: 1.1),
                                        with: .color(RoachDither.cellColor(row: row, column: column, accent: accent, intensity: min(0.16, intensity - threshold + 0.025), inks: inks))
                                    )
                                }
                            }
                        }
                        .blendMode(RoachPalette.glowBlendMode)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(radius), style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.26),
                                RoachPalette.ink.opacity(0.07),
                                RoachPalette.green.opacity(0.14),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoachAnimatedChrome(cornerRadius: radius, accent: accent)
            )
            .shadow(color: accent.opacity(RoachMetrics.glow(0.07)), radius: 18, x: 0, y: 10)
    }
}

public struct RoachKicker: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.roach(size: 11, weight: .bold, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        RoachPalette.muted,
                        RoachPalette.text.opacity(0.76),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
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

private struct RoachPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.roach(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.magenta.opacity(configuration.isPressed ? 0.84 : (hovered ? 0.94 : 0.88)),
                                    RoachPalette.green.opacity(configuration.isPressed ? 0.50 : (hovered ? 0.64 : 0.56)),
                                    RoachPalette.panelSoft.opacity(configuration.isPressed ? 0.86 : (hovered ? 0.92 : 0.88)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    RoachPalette.green.opacity(hovered ? 0.88 : 0.74),
                                    RoachPalette.magenta.opacity(hovered ? 0.58 : 0.46),
                                    RoachPalette.ink.opacity(hovered ? 0.24 : 0.16),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.0
                        )

                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.ink.opacity(hovered ? 0.22 : 0.14),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                }
            )
            .shadow(color: RoachPalette.magenta.opacity(RoachMetrics.glow(configuration.isPressed ? 0.10 : (hovered ? 0.20 : 0.13))), radius: hovered ? 18 : 10, x: 0, y: hovered ? 9 : 5)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: hovered)
            .roachDisabledAppearance()
    }
}

private struct RoachSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.roach(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(configuration.isPressed ? 0.72 : (hovered ? 0.84 : 0.76)),
                                    RoachPalette.panel.opacity(configuration.isPressed ? 0.68 : (hovered ? 0.76 : 0.70)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [RoachPalette.ink.opacity(0.10), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                    .stroke(hovered ? RoachPalette.green.opacity(0.20) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
            )
            .shadow(color: hovered ? RoachPalette.green.opacity(0.07) : .clear, radius: hovered ? 9 : 0, x: 0, y: hovered ? 5 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: hovered)
            .roachDisabledAppearance()
    }
}

private struct RoachUtilityButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.roach(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(hovered ? RoachPalette.text : tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 2)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(11), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(configuration.isPressed ? 0.76 : (hovered ? 0.88 : 0.78)),
                                    RoachPalette.panel.opacity(configuration.isPressed ? 0.72 : (hovered ? 0.82 : 0.72)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: RoachMetrics.radius(11), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(hovered ? 0.14 : 0.08),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(11), style: .continuous)
                    .stroke(hovered ? tint.opacity(0.24) : RoachPalette.ink.opacity(0.06), lineWidth: RoachMetrics.line(1))
            )
            .shadow(color: tint.opacity(RoachMetrics.glow(hovered ? 0.10 : 0.04)), radius: hovered ? 12 : 8, x: 0, y: hovered ? 7 : 4)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hovered)
            .roachDisabledAppearance()
    }
}

/// Buttons styled with the Roach button styles fade and desaturate when
/// SwiftUI disables them, so a greyed "Create" reads as "not yet".
private struct RoachDisabledAppearance: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.42)
            .saturation(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.18), value: isEnabled)
    }
}

private extension View {
    func roachDisabledAppearance() -> some View {
        modifier(RoachDisabledAppearance())
    }
}

private struct RoachCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.02 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -2 : 0))
            .shadow(
                color: RoachPalette.green.opacity(RoachMetrics.glow(configuration.isPressed ? 0.05 : (hovered ? 0.12 : 0.05))),
                radius: hovered ? 20 : 12,
                x: 0,
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
                        .font(.roach(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(index <= activeIndex ? RoachPalette.text : RoachPalette.muted)

                    if index == activeIndex {
                        Text(title)
                            .font(.roach(size: 12, weight: .semibold))
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
                        .stroke(index == activeIndex ? RoachPalette.green.opacity(0.28) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.green.opacity(0.90),
                                RoachPalette.magenta.opacity(0.52),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 26, height: 3)

                Text(title.uppercased())
                    .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
            }
            Text(value)
                .font(.roach(size: 14, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
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
                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
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
            HStack(spacing: 10) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(RoachMetrics.glow(0.34)), radius: 8)

                Text(title)
                    .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(RoachPalette.muted)
            }

            Spacer()

            Text(value)
                .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.18),
                                    accent.opacity(0.07),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: RoachMetrics.line(1))
                )
        }
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
            ZStack {
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.18), accent.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: systemName)
                    .font(.roach(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: RoachMetrics.line(1))
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.roach(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(RoachPalette.muted)

                Text(value)
                    .font(.roach(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Text(detail)
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)

                if !metadata.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            ForEach(Array(metadata.prefix(3)), id: \.self) { item in
                                roachDigestChip(item)
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(metadata.prefix(3)), id: \.self) { item in
                                roachDigestChip(item)
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
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.54),
                            RoachPalette.panelSoft.opacity(0.40),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: RoachMetrics.line(1))
        )
    }

    private func roachDigestChip(_ title: String) -> some View {
        Text(title)
            .font(.roach(size: 9, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(accent.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.16), lineWidth: RoachMetrics.line(1))
            )
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

private struct RoachFallbackBrandMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(1.4, size * 0.028)
            let inset = max(2, size * 0.08)

            ZStack {
                Canvas { context, canvasSize in
                    let rect = CGRect(
                        x: (canvasSize.width - size) * 0.5 + inset,
                        y: (canvasSize.height - size) * 0.5 + inset,
                        width: size - inset * 2,
                        height: size - inset * 2
                    )
                    let cut = rect.width * 0.17
                    var shield = Path()
                    shield.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    shield.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY + cut * 0.38))
                    shield.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - cut * 0.18))
                    shield.addLine(to: CGPoint(x: rect.maxX - cut * 0.48, y: rect.maxY - cut * 0.28))
                    shield.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    shield.addLine(to: CGPoint(x: rect.minX + cut * 0.48, y: rect.maxY - cut * 0.28))
                    shield.addLine(to: CGPoint(x: rect.minX, y: rect.midY - cut * 0.18))
                    shield.addLine(to: CGPoint(x: rect.minX + cut, y: rect.minY + cut * 0.38))
                    shield.closeSubpath()

                    let innerRect = rect.insetBy(dx: rect.width * 0.13, dy: rect.height * 0.13)
                    var inner = Path()
                    inner.move(to: CGPoint(x: innerRect.midX, y: innerRect.minY))
                    inner.addLine(to: CGPoint(x: innerRect.maxX - cut * 0.52, y: innerRect.minY + cut * 0.22))
                    inner.addLine(to: CGPoint(x: innerRect.maxX, y: innerRect.midY - cut * 0.1))
                    inner.addLine(to: CGPoint(x: innerRect.maxX - cut * 0.28, y: innerRect.maxY - cut * 0.2))
                    inner.addLine(to: CGPoint(x: innerRect.midX, y: innerRect.maxY))
                    inner.addLine(to: CGPoint(x: innerRect.minX + cut * 0.28, y: innerRect.maxY - cut * 0.2))
                    inner.addLine(to: CGPoint(x: innerRect.minX, y: innerRect.midY - cut * 0.1))
                    inner.addLine(to: CGPoint(x: innerRect.minX + cut * 0.52, y: innerRect.minY + cut * 0.22))
                    inner.closeSubpath()

                    context.stroke(shield, with: .color(RoachPalette.green.opacity(0.86)), lineWidth: lineWidth)
                    context.stroke(inner, with: .color(RoachPalette.text.opacity(0.46)), lineWidth: max(1, lineWidth * 0.72))

                    let railWidth = max(1, size * 0.032)
                    let railHeight = rect.height * 0.56
                    let railY = rect.midY - railHeight * 0.5
                    for offset in [CGFloat(-0.18), CGFloat(0.18)] {
                        let railRect = CGRect(
                            x: rect.midX + rect.width * offset - railWidth * 0.5,
                            y: railY,
                            width: railWidth,
                            height: railHeight
                        )
                        context.fill(
                            Path(roundedRect: railRect, cornerRadius: railWidth),
                            with: .color(RoachPalette.green.opacity(0.58))
                        )
                    }

                    let base = CGRect(
                        x: rect.midX - rect.width * 0.2,
                        y: rect.maxY - rect.height * 0.25,
                        width: rect.width * 0.4,
                        height: max(1, size * 0.024)
                    )
                    context.fill(
                        Path(roundedRect: base, cornerRadius: base.height),
                        with: .color(RoachPalette.magenta.opacity(0.68))
                    )
                }
                .shadow(color: RoachPalette.green.opacity(RoachMetrics.glow(0.28)), radius: size * 0.12, y: size * 0.04)

                Text("RN")
                    .font(.roach(size: max(9, size * 0.21), weight: .black, design: .monospaced))
                    .tracking(size * 0.006)
                    .foregroundStyle(RoachPalette.text)
                    .shadow(color: RoachPalette.green.opacity(RoachMetrics.glow(0.28)), radius: size * 0.07)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
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
                            color: RoachPalette.magenta.opacity(RoachMetrics.glow(glow ? 0.24 : 0.14)),
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
                    .font(.roach(size: size, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.green : RoachPalette.muted)
            }
        }
    }
}

public struct RoachOrbitMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        let inks = RoachBackgroundInks(accentsOf: RoachThemeRuntime.shared.theme)
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let iconSize = size * 0.90

            ZStack {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 18.0, paused: reduceMotion)) { timeline in
                    Canvas { context, canvasSize in
                        let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                        let cell = max(3.5, size * 0.036)
                        let columns = max(1, Int(ceil(canvasSize.width / cell)))
                        let rows = max(1, Int(ceil(canvasSize.height / cell)))
                        let center = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)

                        for row in 0...rows {
                            for column in 0...columns {
                                let point = CGPoint(x: CGFloat(column) * cell, y: CGFloat(row) * cell)
                                let dx = (point.x - center.x) / max(1, size * 0.48)
                                let dy = (point.y - center.y) / max(1, size * 0.48)
                                let radius = sqrt(dx * dx + dy * dy)
                                let ring = max(0, 1 - abs(Double(radius) - 0.72) * 3.2)
                                let crawl = 0.5 + 0.5 * sin(Double(column + row) * 0.36 + time * 1.3)
                                let threshold = RoachDither.threshold(row: row, column: column) * 0.44
                                let intensity = ring * (0.32 + crawl * 0.26)

                                guard intensity > threshold else { continue }

                                let rect = CGRect(x: point.x, y: point.y, width: max(1, cell - 1.5), height: max(1, cell - 1.5))
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: 1),
                                    with: .color(RoachDither.cellColor(row: row, column: column, accent: inks.primary, intensity: min(0.22, intensity - threshold + 0.04), inks: inks))
                                )
                            }
                        }
                    }
                    .blendMode(RoachPalette.glowBlendMode)
                }

                if let iconImage = roachRuntimeImage(named: "RoachNet.icns") {
                    Image(nsImage: iconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: RoachPalette.green.opacity(RoachMetrics.glow(0.20)), radius: size * 0.12, y: size * 0.04)
                } else {
                    RoachFallbackBrandMark()
                        .frame(width: iconSize, height: iconSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RoachNet logo")
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
        VStack(alignment: .leading, spacing: 4) {
            RoachKicker(kicker)
            Text(title)
                .font(.roach(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineSpacing(1.1)
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .allowsTightening(true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.roach(size: 10, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(2)
            }
        }
    }
}

public struct RoachFeatureTile: View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(label.uppercased())
                        .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(RoachPalette.muted)

                    Text(title)
                        .font(.roach(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)
                }

                Spacer(minLength: 10)

                ZStack {
                    Circle()
                        .fill(accent.opacity(hovered ? 0.20 : 0.14))
                        .frame(width: hovered ? 52 : 46, height: hovered ? 52 : 46)
                        .blur(radius: hovered ? 8 : 5)

                    Image(systemName: systemName)
                        .font(.roach(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                .fill(accent.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                .stroke(accent.opacity(hovered ? 0.28 : 0.18), lineWidth: RoachMetrics.line(1))
                        )
                }
            }

            Text(detail)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.92), accent.opacity(0.18)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: hovered ? 104 : 82, height: 3)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.roach(size: 11, weight: .bold))
                    .foregroundStyle(accent.opacity(hovered ? 0.92 : 0.54))
                    .offset(x: hovered ? 1 : 0, y: hovered ? -1 : 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(hovered ? 0.86 : 0.78),
                                RoachPalette.panel.opacity(hovered ? 0.78 : 0.68),
                                RoachPalette.shade.opacity(0.18),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(hovered ? 0.16 : 0.10),
                                Color.clear,
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(accent.opacity(hovered ? 0.24 : 0.14), lineWidth: RoachMetrics.line(1))
        )
        .overlay(
            RoachAnimatedChrome(cornerRadius: 16, accent: accent)
        )
        .shadow(color: accent.opacity(RoachMetrics.glow(hovered ? 0.10 : 0.04)), radius: hovered ? 24 : 18, x: 0, y: hovered ? 16 : 10)
        .scaleEffect(hovered ? 1.01 : 1.0)
        .offset(y: hovered ? -1 : 0)
        .onHover { inside in
            hovered = inside
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: hovered)
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
                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)

            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.roach(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
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
                        .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                        .allowsHitTesting(false)
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
            .font(.roach(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.55)
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.12), accent.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: RoachMetrics.line(1))
            )
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
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: RoachMetrics.radius(11), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelGlass,
                                RoachPalette.ink.opacity(hovered ? 0.05 : 0.03),
                                RoachPalette.green.opacity(hovered ? 0.10 : 0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "magnifyingglass")
                    .font(.roach(size: 14, weight: .semibold))
                    .foregroundStyle(RoachPalette.green)
            }
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(11), style: .continuous)
                    .stroke(hovered ? RoachPalette.green.opacity(0.32) : RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
            )
            .shadow(color: RoachPalette.green.opacity(RoachMetrics.glow(hovered ? 0.20 : 0.12)), radius: hovered ? 22 : 18, x: 0, y: hovered ? 12 : 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.roach(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(RoachPalette.muted)
                Text(prompt)
                    .font(.roach(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
            }

            Spacer(minLength: 8)

            Text(keys)
                .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(hovered ? RoachPalette.green : RoachPalette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [RoachPalette.ink.opacity(0.06), RoachPalette.ink.opacity(0.025)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(0.88),
                                RoachPalette.panel.opacity(0.78),
                                RoachPalette.shade.opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.green.opacity(0.10),
                                Color.clear,
                                RoachPalette.magenta.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(hovered ? RoachPalette.green.opacity(0.24) : RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
        )
        .overlay(
            RoachAnimatedChrome(cornerRadius: 16, accent: RoachPalette.green)
        )
        .shadow(color: RoachPalette.shadow.opacity(hovered ? 0.22 : 0.16), radius: hovered ? 28 : 24, x: 0, y: hovered ? 16 : 12)
        .scaleEffect(hovered ? 1.01 : 1)
        .offset(y: hovered ? -1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous))
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: hovered)
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
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isSelected
                                        ? [RoachPalette.panelSoft.opacity(hovered ? 0.84 : 0.72), RoachPalette.panelRaised.opacity(0.68)]
                                        : [RoachPalette.panelRaised.opacity(hovered ? 0.62 : 0.42), RoachPalette.panel.opacity(0.42)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .stroke(
                                isSelected ? RoachPalette.green.opacity(0.22) : (hovered ? RoachPalette.green.opacity(0.10) : RoachPalette.border.opacity(0.8)),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.12 : 0.06) : .clear, radius: hovered ? 14 : 10, x: 0, y: hovered ? 8 : 6)
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
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            isSelected ? RoachPalette.green.opacity(0.12) : RoachPalette.panelGlass,
                                            RoachPalette.ink.opacity(0.02),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: isSelected ? RoachPalette.green.opacity(0.16) : .clear, radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.roach(size: 14, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(subtitle)
                            .font(.roach(size: 11, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.roach(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? RoachPalette.green.opacity(0.88) : RoachPalette.muted.opacity(hovered ? 0.82 : 0.44))
                        .opacity(isSelected || hovered ? 1 : 0.75)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isSelected
                                    ? [RoachPalette.panelRaised.opacity(0.78), RoachPalette.panel.opacity(0.62)]
                                    : [RoachPalette.panel.opacity(hovered ? 0.34 : 0.12), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.green.opacity(isSelected ? 0.92 : (hovered ? 0.34 : 0.0)),
                                    accentlessSidebarGlow,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2.5, height: isSelected ? 30 : (hovered ? 16 : 0))
                        .padding(.leading, 4)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                        .stroke(isSelected ? RoachPalette.green.opacity(0.14) : RoachPalette.ink.opacity(hovered ? 0.08 : 0.03), lineWidth: RoachMetrics.line(1))
                )
                .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.08 : 0.03) : .clear, radius: hovered ? 12 : 8, x: 0, y: hovered ? 6 : 4)
            }
        }
        .scaleEffect(isCompact ? (hovered ? 1.05 : 1.0) : (hovered ? 1.005 : 1.0))
        .offset(y: hovered ? -0.5 : 0)
        .onHover { inside in
            hovered = inside
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: hovered)
    }

    private var accentlessSidebarGlow: Color {
        Color.clear
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
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.roach(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .allowsTightening(false)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.top, 17)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(
            // The glow and the accent bar are overlays so their fixed sizes never
            // size the background: a 110 pt glow inside a ZStack made the card's
            // fill taller than the card and pushed the bar over the row above.
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(hovered ? 0.74 : 0.64),
                            RoachPalette.panel.opacity(0.54),
                            RoachPalette.shade.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(RoachPalette.magenta.opacity(hovered ? 0.18 : 0.12))
                        .frame(width: 110, height: 110)
                        .blur(radius: 34)
                        .offset(x: hovered ? 108 : 120, y: hovered ? -26 : -20)
                }
                .overlay(alignment: .topLeading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [RoachPalette.green.opacity(0.86), RoachPalette.magenta.opacity(0.68)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: hovered ? 42 : 34, height: 3)
                        .padding(.leading, 9)
                        .padding(.top, 8)
                }
                // Keep the glow inside the card; unclipped it bleeds over whatever sits above the row.
                .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(hovered ? RoachPalette.green.opacity(0.16) : RoachPalette.ink.opacity(0.06), lineWidth: RoachMetrics.line(1))
        )
        .shadow(color: RoachPalette.shadow.opacity(hovered ? 0.14 : 0.10), radius: hovered ? 14 : 12, x: 0, y: hovered ? 10 : 8)
        .contentShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous))
        .help("\(label): \(value)\n\(detail)")
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: hovered)
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
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.84),
                                    RoachPalette.panel.opacity(0.80),
                                    RoachPalette.shade.opacity(0.12),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.magenta.opacity(0.07),
                                    Color.clear,
                                    RoachPalette.cyan.opacity(0.025),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .stroke(RoachPalette.ink.opacity(0.06), lineWidth: RoachMetrics.line(1))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [RoachPalette.ink.opacity(0.06), Color.clear, Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            )
            .shadow(color: RoachPalette.shadow.opacity(0.07), radius: 10, x: 0, y: 6)
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .font(.roach(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.16), accent.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(12), style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: RoachMetrics.line(1))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.roach(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 13, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [RoachPalette.panelRaised.opacity(0.76), RoachPalette.panel.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: RoachMetrics.line(1))
        )
        .overlay(
            RoachAnimatedChrome(cornerRadius: 18, accent: accent)
        )
        .shadow(color: RoachPalette.shadow.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}
