import Foundation
import Observation
import os
import SwiftUI

/// Holds the theme every RoachNet view draws with.
///
/// `RoachPalette`, `Font.roach` and `RoachMetrics` read `theme` while a view's
/// body runs, so Observation re-renders exactly the views that used a token
/// when a new theme is applied. The theme itself is an immutable object behind
/// a lock, so background renderers (Canvas closures) can read it from any
/// thread.
public final class RoachThemeRuntime: Observable, @unchecked Sendable {
    public static let shared = RoachThemeRuntime()

    /// Posted on the main thread after `apply(_:)`, for AppKit views that
    /// cannot observe SwiftUI state.
    public static let didChangeNotification = Notification.Name("RoachThemeRuntimeDidChange")

    private let registrar = ObservationRegistrar()
    private let state: OSAllocatedUnfairLock<RoachResolvedTheme>

    public init(initial: RoachResolvedTheme? = nil) {
        state = OSAllocatedUnfairLock(initialState: initial ?? Self.defaultTheme())
    }

    /// Signal, dark: what RoachNet looks like before any setting is read.
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

    /// The current theme without registering an Observation dependency.
    public var untrackedTheme: RoachResolvedTheme {
        state.withLock { $0 }
    }

    /// Swaps in a new theme. Call on the main thread.
    public func apply(_ theme: RoachResolvedTheme) {
        registrar.withMutation(of: self, keyPath: \.theme) {
            state.withLock { $0 = theme }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

public extension Font {
    /// A themed font. A drop-in for `.system(size:weight:design:)`: the design
    /// picks the theme's face (rounded → display, monospaced → mono, anything
    /// else → body) and the size follows the theme's text scale.
    static func roach(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let theme = RoachThemeRuntime.shared.theme
        let face: RoachFontFace
        switch design {
        case .monospaced:
            face = theme.typography.mono
        case .rounded:
            face = theme.typography.display
        case .serif:
            face = .systemSerif
        default:
            face = theme.typography.body
        }
        return face.font(size: size * CGFloat(theme.typography.scale), weight: weight)
    }
}

/// Theme-scaled geometry.
public enum RoachMetrics {
    /// A corner radius scaled by the theme (0 is square, 2 is very round).
    public static func radius(_ value: CGFloat) -> CGFloat {
        value * CGFloat(RoachThemeRuntime.shared.theme.radiusScale)
    }

    /// A hairline width scaled by the theme.
    public static func line(_ value: CGFloat) -> CGFloat {
        value * CGFloat(RoachThemeRuntime.shared.theme.borderWidth)
    }

    /// An accent-glow opacity scaled by the theme.
    public static func glow(_ opacity: Double) -> Double {
        opacity * RoachThemeRuntime.shared.theme.glow
    }

    /// The text scale, for sizes computed outside `Font.roach`.
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

public extension View {
    /// Applies the theme's color scheme and accent tint. Put it on each
    /// window's root view.
    func roachThemed() -> some View {
        modifier(RoachThemedRoot())
    }
}
