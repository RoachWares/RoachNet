import AppKit
import Foundation
import SwiftUI

public enum RoachFontFace: Sendable, Equatable, Hashable {
    case system
    case systemRounded
    case systemSerif
    case systemMono
    case bundled(RoachBundledFace)
    case family(String)

    public init?(key: String?) {
        guard let raw = key?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let bundled = RoachBundledFace(key: raw) {
            self = .bundled(bundled)
            return
        }
        switch raw.lowercased() {
        case "system", "system-default", "sf", "sf pro": self = .system
        case "system-rounded", "rounded", "sf rounded": self = .systemRounded
        case "system-serif", "serif", "new york": self = .systemSerif
        case "system-mono", "mono", "monospaced", "sf mono": self = .systemMono
        default: self = .family(raw)
        }
    }

    public var key: String {
        switch self {
        case .system: return "system"
        case .systemRounded: return "system-rounded"
        case .systemSerif: return "system-serif"
        case .systemMono: return "system-mono"
        case .bundled(let face): return face.rawValue
        case .family(let name): return name
        }
    }

    public var label: String {
        switch self {
        case .system: return "System"
        case .systemRounded: return "System Rounded"
        case .systemSerif: return "System Serif"
        case .systemMono: return "System Mono"
        case .bundled(let face): return face.label
        case .family(let name): return name
        }
    }

    public var isMonospaced: Bool {
        switch self {
        case .systemMono: return true
        case .bundled(let face): return face.isMonospaced
        default: return false
        }
    }

    static func bundledVariation(_ face: RoachBundledFace, weight: Double, size: CGFloat) -> (
        weight: Double, width: Double?
    ) {
        guard face == .anybody else { return (weight, nil) }
        let displayWeight = weight >= 900 ? 900 : (weight >= 600 ? RoachFonts.displayWeight : weight)
        return (displayWeight, size >= RoachFonts.displayMinimumSize ? RoachFonts.displayWidth : 100)
    }

    public func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .system: return .system(size: size, weight: weight, design: .default)
        case .systemRounded: return .system(size: size, weight: weight, design: .rounded)
        case .systemSerif: return .system(size: size, weight: weight, design: .serif)
        case .systemMono: return .system(size: size, weight: weight, design: .monospaced)
        case .bundled(let face):
            let voice = Self.bundledVariation(face, weight: RoachFonts.numericWeight(weight), size: size)
            if let font = RoachFonts.ctFont(face, size: size, weight: voice.weight, width: voice.width) {
                return Font(font)
            }
            return .system(size: size, weight: weight, design: face.isMonospaced ? .monospaced : .default)
        case .family(let name): return .custom(name, fixedSize: size).weight(weight)
        }
    }

    public func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .systemRounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .systemSerif:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .systemMono:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .bundled(let face):
            let voice = Self.bundledVariation(face, weight: RoachFonts.numericWeight(weight), size: size)
            if let font = RoachFonts.ctFont(face, size: size, weight: voice.weight, width: voice.width) {
                return font as NSFont
            }
            return face.isMonospaced
                ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        case .family(let name):
            let manager = NSFontManager.shared
            return manager.font(withFamily: name, traits: [], weight: 5, size: size)
                ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    public static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    public static func isInstalled(family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains { $0.caseInsensitiveCompare(family) == .orderedSame }
    }
}

public struct RoachResolvedTypography: Sendable, Equatable {
    public var display: RoachFontFace
    public var body: RoachFontFace
    public var mono: RoachFontFace
    public var scale: Double

    public static let signal = RoachResolvedTypography(
        display: .systemRounded, body: .system, mono: .systemMono, scale: 1)
}

public struct RoachResolvedBackground: Sendable, Equatable {
    public var style: RoachBackgroundStyle
    public var intensity: Double
    public var motion: Bool
    public var speed: Double
    public var colors: [RoachRGBA]
    public var top: RoachRGBA
    public var bottom: RoachRGBA
    public var vignette: Double
    public var imageURL: URL?
    public var imageDim: Double
    public var imageBlur: Double
    public var rise: Bool
    public var field: RoachJSON?
}

public final class RoachResolvedTheme: Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let hasDarkVariant: Bool
    public let hasLightVariant: Bool
    public let palette: [RoachRGBA]
    public let colors: [Color]
    public let typography: RoachResolvedTypography
    public let radiusScale: Double
    public let borderWidth: Double
    public let glass: Double
    public let glow: Double
    public let shadow: Double
    public let background: RoachResolvedBackground
    public let problems: [String]
    public let revision: Int
    public let tempo: Double

    public init(
        id: String,
        name: String,
        isDark: Bool,
        hasDarkVariant: Bool,
        hasLightVariant: Bool,
        palette: [RoachRGBA],
        typography: RoachResolvedTypography,
        radiusScale: Double,
        borderWidth: Double,
        glass: Double,
        glow: Double,
        shadow: Double,
        background: RoachResolvedBackground,
        problems: [String],
        revision: Int,
        tempo: Double = 1
    ) {
        precondition(palette.count == RoachColorToken.allCases.count, "a resolved palette fills every token")
        self.id = id
        self.name = name
        self.isDark = isDark
        self.hasDarkVariant = hasDarkVariant
        self.hasLightVariant = hasLightVariant
        self.palette = palette
        self.colors = palette.map(\.color)
        self.typography = typography
        self.radiusScale = radiusScale
        self.borderWidth = borderWidth
        self.glass = glass
        self.glow = glow
        self.shadow = shadow
        self.background = background
        self.problems = problems
        self.revision = revision
        self.tempo = tempo
    }

    public subscript(token: RoachColorToken) -> Color { colors[token.rawValue] }
    public func rgba(_ token: RoachColorToken) -> RoachRGBA { palette[token.rawValue] }

    public var colorScheme: ColorScheme { isDark ? .dark : .light }
    public var appearanceName: NSAppearance.Name { isDark ? .darkAqua : .aqua }
    public var glowBlendMode: BlendMode { isDark ? .screen : .multiply }

    public func exportJSON(updatedAt: Date = Date()) -> Data {
        var tokens: [String: String] = [:]
        for token in RoachColorToken.allCases {
            tokens[token.key] = rgba(token).hex
        }
        let payload: [String: Any] = [
            "schema": "org.roachnet.active-theme.v1",
            "id": id,
            "name": name,
            "mode": isDark ? "dark" : "light",
            "revision": revision,
            "palette": tokens,
            "background": [
                "style": background.style.rawValue,
                "intensity": background.intensity,
                "motion": background.motion,
                "speed": background.speed,
                "colors": background.colors.map(\.hex),
                "top": background.top.hex,
                "bottom": background.bottom.hex,
                "vignette": background.vignette,
            ] as [String: Any],
            "typography": [
                "display": typography.display.key,
                "body": typography.body.key,
                "mono": typography.mono.key,
                "scale": typography.scale,
            ] as [String: Any],
            "shape": ["radiusScale": radiusScale, "borderWidth": borderWidth],
            "effects": ["glass": glass, "glow": glow, "shadow": shadow],
            "updatedAt": ISO8601DateFormatter().string(from: updatedAt),
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }
}

public enum RoachThemeResolver {
    static func fallbackBase(isDark: Bool) -> (background: RoachRGBA, text: RoachRGBA, accent: RoachRGBA) {
        isDark
            ? (RoachRGBA("#030304")!, RoachRGBA("#FFFFFFF7")!, RoachRGBA("#3DFA8A")!)
            : (RoachRGBA("#F3F4F1")!, RoachRGBA("#14171A")!, RoachRGBA("#0A7D47")!)
    }

    public static func usesDark(
        _ document: RoachThemeDocument, preference: RoachAppearancePreference, systemIsDark: Bool
    ) -> Bool {
        let wantsDark: Bool
        switch preference {
        case .dark: wantsDark = true
        case .light: wantsDark = false
        case .system: wantsDark = systemIsDark
        }
        if wantsDark { return document.dark != nil || document.light == nil }
        return document.light == nil
    }

    public static func resolve(
        document: RoachThemeDocument,
        snippets: [RoachThemeSnippetDocument] = [],
        settings: RoachThemeSettings? = nil,
        systemIsDark: Bool = true,
        baseURL: URL? = nil,
        revision: Int = 0,
        fontIsInstalled: (String) -> Bool = RoachFontFace.isInstalled(family:)
    ) -> RoachResolvedTheme {
        let preference = settings?.appearance ?? .dark
        let isDark = usesDark(document, preference: preference, systemIsDark: systemIsDark)
        var problems: [String] = []

        var mode = (isDark ? document.dark : document.light) ?? document.dark ?? document.light ?? RoachThemeModeSpec()
        var typography = document.typography ?? RoachThemeTypographySpec()
        var shape = document.shape ?? RoachThemeShapeSpec()
        var effects = document.effects ?? RoachThemeEffectsSpec()

        var layers = snippets
        if let settings { layers.append(settings.overrideSnippet) }
        for snippet in layers {
            mode = mode.overlaid(by: snippet.all).overlaid(by: isDark ? snippet.dark : snippet.light)
            typography = typography.overlaid(by: snippet.typography)
            shape = shape.overlaid(by: snippet.shape)
            effects = effects.overlaid(by: snippet.effects)
        }

        let glass = clamp(effects.glass ?? 1, 0, 2)
        let glow = clamp(effects.glow ?? 1, 0, 2)
        let shadow = clamp(effects.shadow ?? 1, 0, 2)
        let palette = resolvePalette(
            mode.palette ?? [:], isDark: isDark, glass: glass, shadow: shadow, problems: &problems)
        let background = resolveBackground(
            mode.background, palette: palette, isDark: isDark, baseURL: baseURL, problems: &problems)

        func face(_ value: String?, role: String, fallback: RoachFontFace) -> RoachFontFace {
            guard let parsed = RoachFontFace(key: value) else { return fallback }
            if case .family(let name) = parsed, !fontIsInstalled(name) {
                problems.append("The \(role) font \"\(name)\" is not installed; using \(fallback.label).")
                return fallback
            }
            if case .bundled(let bundled) = parsed, RoachFonts.descriptor(for: bundled, italic: false) == nil {
                problems.append(
                    "The \(role) font \(bundled.label) is missing from this copy of RoachNet; using \(fallback.label).")
                return fallback
            }
            return parsed
        }
        let resolvedTypography = RoachResolvedTypography(
            display: face(typography.display, role: "display", fallback: .systemRounded),
            body: face(typography.body, role: "body", fallback: .system),
            mono: face(typography.mono, role: "mono", fallback: .systemMono),
            scale: clamp(typography.scale ?? 1, 0.8, 1.4)
        )

        return RoachResolvedTheme(
            id: document.id,
            name: document.name,
            isDark: isDark,
            hasDarkVariant: document.dark != nil,
            hasLightVariant: document.light != nil,
            palette: palette,
            typography: resolvedTypography,
            radiusScale: clamp(shape.radiusScale ?? 1, 0, 2),
            borderWidth: clamp(shape.borderWidth ?? 1, 0.5, 3),
            glass: glass,
            glow: glow,
            shadow: shadow,
            background: background,
            problems: problems,
            revision: revision,
            tempo: clamp(document.motion?.tempo ?? 1, 0.5, 2)
        )
    }

    static func resolvePalette(
        _ raw: [String: String],
        isDark: Bool,
        glass: Double,
        shadow: Double,
        problems: inout [String]
    ) -> [RoachRGBA] {
        var given: [RoachColorToken: RoachRGBA] = [:]
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
            guard let token = RoachColorToken(key: key) else {
                problems.append("Unknown color token \"\(key)\".")
                continue
            }
            guard let color = RoachRGBA(value) else {
                problems.append("\"\(value)\" is not a color (\(key)).")
                continue
            }
            given[token] = color
        }

        let fallback = fallbackBase(isDark: isDark)
        let background = given[.background] ?? fallback.background
        let text = given[.text] ?? fallback.text
        let accent = given[.accent] ?? fallback.accent
        let ink = given[.ink] ?? text.opaque
        let white = RoachRGBA.white
        let black = RoachRGBA.black

        var values: [RoachRGBA] = []
        for token in RoachColorToken.allCases {
            if let explicit = given[token] {
                values.append(explicit)
                continue
            }
            let derived: RoachRGBA
            switch token {
            case .accent: derived = accent
            case .accentSecondary: derived = accent
            case .accentTertiary: derived = given[.warning] ?? (isDark ? RoachRGBA("#FABD33")! : RoachRGBA("#9A6200")!)
            case .accentInfo: derived = accent
            case .background: derived = background
            case .backgroundRaised: derived = background.mixed(with: ink, amount: isDark ? 0.018 : 0.03)
            case .panel:
                derived =
                    isDark ? background.mixed(with: ink, amount: 0.035) : background.mixed(with: white, amount: 0.6)
            case .panelRaised:
                derived =
                    isDark ? background.mixed(with: ink, amount: 0.062) : background.mixed(with: white, amount: 0.85)
            case .panelSoft:
                derived =
                    isDark ? background.mixed(with: ink, amount: 0.098) : background.mixed(with: ink, amount: 0.05)
            case .glass: derived = ink.withAlpha(isDark ? 0.045 : 0.035)
            case .specular: derived = ink.withAlpha(isDark ? 0.08 : 0.06)
            case .border: derived = ink.withAlpha(isDark ? 0.085 : 0.12)
            case .borderStrong: derived = ink.withAlpha(isDark ? 0.14 : 0.22)
            case .text: derived = text
            case .muted: derived = text.withAlpha(isDark ? 0.68 : 0.70)
            case .success: derived = isDark ? RoachRGBA("#3DFA8A")! : RoachRGBA("#13804A")!
            case .warning: derived = isDark ? RoachRGBA("#EDBA42")! : RoachRGBA("#9A6200")!
            case .danger: derived = isDark ? RoachRGBA("#FF5C6C")! : RoachRGBA("#C2283A")!
            case .shadow: derived = black.withAlpha(isDark ? 0.24 : 0.12)
            case .ink: derived = ink
            case .shade: derived = isDark ? black : background.mixed(with: black, amount: 0.10)
            case .onAccent:
                let accentOpaque = accent.composited(over: background)
                let dark = RoachRGBA("#0A0B0C")!
                derived =
                    RoachRGBA.contrast(dark, accentOpaque) >= RoachRGBA.contrast(white, accentOpaque) ? dark : white
            case .action: derived = given[.accentSecondary] ?? accent
            case .actionInk:
                let action = (given[.action] ?? given[.accentSecondary] ?? accent).composited(over: background)
                let dark = RoachRGBA("#0A0B0C")!
                derived = RoachRGBA.contrast(dark, action) >= RoachRGBA.contrast(white, action) ? dark : white
            case .signal: derived = given[.success] ?? (isDark ? RoachRGBA("#3DFA8A")! : RoachRGBA("#13804A")!)
            case .focus: derived = given[.signal] ?? given[.success] ?? accent
            case .inputLine:
                let window = background.composited(over: black)
                let well = values[RoachColorToken.backgroundRaised.rawValue].composited(over: window)
                let surface = values[RoachColorToken.panel.rawValue].composited(over: window)
                let strong = values[RoachColorToken.text.rawValue].composited(over: surface)
                var line = values[RoachColorToken.muted.rawValue].composited(over: surface).mixed(
                    with: surface, amount: 0.4)
                var steps = 0
                while steps < 30, RoachRGBA.contrast(line, well) < 3 || RoachRGBA.contrast(line, surface) < 3 {
                    line = line.mixed(with: strong, amount: 0.1)
                    steps += 1
                }
                derived = line
            }
            values.append(derived)
        }

        if glass != 1 {
            values[RoachColorToken.glass.rawValue] = values[RoachColorToken.glass.rawValue].multiplyingAlpha(by: glass)
            values[RoachColorToken.specular.rawValue] = values[RoachColorToken.specular.rawValue].multiplyingAlpha(
                by: glass)
        }
        if shadow != 1 {
            values[RoachColorToken.shadow.rawValue] = values[RoachColorToken.shadow.rawValue].multiplyingAlpha(
                by: shadow)
        }
        return values
    }

    static func resolveBackground(
        _ spec: RoachThemeBackgroundSpec?,
        palette: [RoachRGBA],
        isDark: Bool,
        baseURL: URL?,
        problems: inout [String]
    ) -> RoachResolvedBackground {
        let spec = spec ?? RoachThemeBackgroundSpec()
        func token(_ token: RoachColorToken) -> RoachRGBA { palette[token.rawValue] }
        func color(_ value: String?, _ fallback: RoachRGBA, _ label: String) -> RoachRGBA {
            guard let value else { return fallback }
            guard let parsed = RoachRGBA(value) else {
                problems.append("\"\(value)\" is not a color (background \(label)).")
                return fallback
            }
            return parsed
        }

        var style = isDark ? RoachBackgroundStyle.signal : .paper
        if let raw = spec.style {
            if let parsed = RoachBackgroundStyle(rawValue: raw.lowercased()) {
                style = parsed
            } else {
                problems.append("Unknown background style \"\(raw)\".")
            }
        }

        var colors = (spec.colors ?? []).compactMap { value -> RoachRGBA? in
            guard let parsed = RoachRGBA(value) else {
                problems.append("\"\(value)\" is not a color (background colors).")
                return nil
            }
            return parsed
        }
        if colors.isEmpty {
            colors = [token(.accent), token(.accentSecondary), token(.accentTertiary), token(.accentInfo)]
        }

        var imageURL: URL?
        if style == .image {
            if let name = spec.image, let resolved = safeChild(named: name, of: baseURL),
                FileManager.default.fileExists(atPath: resolved.path)
            {
                imageURL = resolved
            } else {
                problems.append(
                    "The image background needs a picture file next to the theme; showing a solid background.")
                style = .solid
            }
        }

        return RoachResolvedBackground(
            style: style,
            intensity: clamp(spec.intensity ?? 1, 0, 1.5),
            motion: spec.motion ?? true,
            speed: clamp(spec.speed ?? 1, 0.25, 3),
            colors: colors,
            top: color(spec.top, token(.background), "top"),
            bottom: color(spec.bottom, token(.backgroundRaised), "bottom"),
            vignette: clamp(spec.vignette ?? (isDark ? 0.48 : 0.12), 0, 1),
            imageURL: imageURL,
            imageDim: clamp(spec.imageDim ?? 0.35, 0, 0.95),
            imageBlur: clamp(spec.imageBlur ?? 0, 0, 40),
            rise: spec.rise ?? true,
            field: spec.field
        )
    }

    public static func safeChild(named name: String, of baseURL: URL?) -> URL? {
        guard let baseURL else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        guard !trimmed.isEmpty, scalars.first != "/", scalars.first != "~" else { return nil }
        guard !scalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        let components = scalars.split(separator: "/")
        guard !components.contains(where: { $0.elementsEqual("..".unicodeScalars) }) else { return nil }
        let candidate = baseURL.appendingPathComponent(trimmed).standardizedFileURL.resolvingSymlinksInPath()
        let root = baseURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.path.hasPrefix(prefix) || candidate.path.unicodeScalars.starts(with: prefix.unicodeScalars)
        else { return nil }
        let allowed = ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff"]
        guard allowed.contains(candidate.pathExtension.lowercased()) else { return nil }
        return candidate
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(upper, max(lower, value))
    }
}
