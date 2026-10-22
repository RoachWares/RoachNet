import Foundation
import Observation
import SwiftUI
import os

public final class RoachThemeRuntime: Observable, @unchecked Sendable {
    public static let shared = RoachThemeRuntime()

    public static let didChangeNotification = Notification.Name("RoachThemeRuntimeDidChange")

    private let registrar = ObservationRegistrar()
    private let state: OSAllocatedUnfairLock<RoachResolvedTheme>

    public init(initial: RoachResolvedTheme? = nil) {
        state = OSAllocatedUnfairLock(initialState: initial ?? Self.defaultTheme())
    }

    public static func defaultTheme() -> RoachResolvedTheme {
        RoachThemeResolver.resolve(
            document: RoachBuiltInThemes.defaultTheme,
            settings: RoachThemeSettings(),
            systemIsDark: true,
            fontIsInstalled: { _ in false }
        )
    }

    public var theme: RoachResolvedTheme {
        registrar.access(self, keyPath: \.theme)
        return state.withLock { $0 }
    }

    public var untrackedTheme: RoachResolvedTheme {
        state.withLock { $0 }
    }

    public func apply(_ theme: RoachResolvedTheme) {
        registrar.withMutation(of: self, keyPath: \.theme) {
            state.withLock { $0 = theme }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

extension Font {
    public static func roach(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let theme = RoachThemeRuntime.shared.theme
        let scaled = size * CGFloat(theme.typography.scale)
        let face: RoachFontFace
        switch design {
        case .monospaced:
            face = theme.typography.mono
        case .rounded:
            if case .bundled = theme.typography.display, scaled < RoachFonts.displayMinimumSize {
                face = theme.typography.body
            } else {
                face = theme.typography.display
            }
        case .serif:
            face = .systemSerif
        default:
            face = theme.typography.body
        }
        return face.font(size: scaled, weight: weight)
    }
}

public enum RoachMetrics {
    public static func radius(_ value: CGFloat) -> CGFloat {
        value * CGFloat(RoachThemeRuntime.shared.theme.radiusScale)
    }

    public static func line(_ value: CGFloat) -> CGFloat {
        value * CGFloat(RoachThemeRuntime.shared.theme.borderWidth)
    }

    public static func glow(_ opacity: Double) -> Double {
        opacity * RoachThemeRuntime.shared.theme.glow
    }

    public static var textScale: CGFloat {
        CGFloat(RoachThemeRuntime.shared.theme.typography.scale)
    }
}

private struct RoachThemedRoot: ViewModifier {
    func body(content: Content) -> some View {
        let theme = RoachThemeRuntime.shared.theme
        content
            .preferredColorScheme(theme.colorScheme)
            .tint(theme[.accent])
    }
}

extension View {
    public func roachThemed() -> some View {
        modifier(RoachThemedRoot())
    }
}
