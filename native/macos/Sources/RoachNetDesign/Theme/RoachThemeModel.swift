import AppKit
import Foundation
import SwiftUI

public enum RoachColorToken: Int, CaseIterable, Sendable, Codable, Identifiable {
    case accent
    case accentSecondary
    case accentTertiary
    case accentInfo
    case background
    case backgroundRaised
    case panel
    case panelRaised
    case panelSoft
    case glass
    case specular
    case border
    case borderStrong
    case text
    case muted
    case success
    case warning
    case danger
    case shadow
    case ink
    case shade
    case onAccent
    case action
    case actionInk
    case signal
    case focus
    case inputLine

    public var id: Int { rawValue }

    public var key: String { "\(self)" }

    public init?(key: String) {
        guard let token = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = token
    }

    public var label: String {
        switch self {
        case .accent: return "Accent"
        case .accentSecondary: return "Second accent"
        case .accentTertiary: return "Third accent"
        case .accentInfo: return "Info accent"
        case .background: return "Background"
        case .backgroundRaised: return "Raised background"
        case .panel: return "Panel"
        case .panelRaised: return "Raised panel"
        case .panelSoft: return "Soft panel"
        case .glass: return "Glass"
        case .specular: return "Specular"
        case .border: return "Border"
        case .borderStrong: return "Strong border"
        case .text: return "Text"
        case .muted: return "Muted text"
        case .success: return "Success"
        case .warning: return "Warning"
        case .danger: return "Danger"
        case .shadow: return "Shadow"
        case .ink: return "Ink"
        case .shade: return "Shade"
        case .onAccent: return "Text on accent"
        case .action: return "Action"
        case .actionInk: return "Text on action"
        case .signal: return "Signal"
        case .focus: return "Focus ring"
        case .inputLine: return "Input line"
        }
    }

    public var help: String {
        switch self {
        case .accent: return "Primary highlight: selection, links, live status, focus rings."
        case .accentSecondary: return "Buttons, spotlights and the second chart series."
        case .accentTertiary: return "Badges, ratings and the third chart series."
        case .accentInfo: return "Informational tags, maps and the fourth chart series."
        case .background: return "Window background."
        case .backgroundRaised: return "The far end of the background gradient."
        case .panel: return "Cards and panels."
        case .panelRaised: return "Panels above panels: popovers, hovered tiles."
        case .panelSoft: return "The lightest panel step: wells and selected rows."
        case .glass: return "Translucent wash over glass panels."
        case .specular: return "The highlight edge on glass panels."
        case .border: return "Hairline borders."
        case .borderStrong: return "Borders that need to read at a glance."
        case .text: return "Body text."
        case .muted: return "Secondary text and captions."
        case .success: return "Healthy, done, connected."
        case .warning: return "Needs attention."
        case .danger: return "Errors and destructive actions."
        case .shadow: return "Drop shadows."
        case .ink: return "Neutral tint for strokes and washes (white on dark themes, near-black on light)."
        case .shade:
            return "Neutral tint for recessed wells and vignettes (black on dark themes, a light gray on light ones)."
        case .onAccent: return "Text drawn on an accent fill."
        case .action: return "The main action on a screen: primary buttons and the selected tab."
        case .actionInk: return "Text and icons drawn on the action color."
        case .signal: return "Live and current: the online dot, the active row's bar, LED details."
        case .focus: return "The keyboard focus ring."
        case .inputLine:
            return "Text-field and menu borders; 3:1 against what's behind them so a field reads as a field."
        }
    }

    public var group: RoachColorTokenGroup {
        switch self {
        case .accent, .accentSecondary, .accentTertiary, .accentInfo, .action, .signal: return .accents
        case .background, .backgroundRaised, .panel, .panelRaised, .panelSoft: return .surfaces
        case .text, .muted, .onAccent, .actionInk: return .text
        case .success, .warning, .danger: return .status
        case .glass, .specular, .border, .borderStrong, .shadow, .ink, .shade, .focus, .inputLine: return .effects
        }
    }
}

public enum RoachColorTokenGroup: String, CaseIterable, Sendable, Identifiable {
    case accents = "Accents"
    case surfaces = "Surfaces"
    case text = "Text"
    case status = "Status"
    case effects = "Lines and effects"

    public var id: String { rawValue }
    public var tokens: [RoachColorToken] { RoachColorToken.allCases.filter { $0.group == self } }
}

public struct RoachRGBA: Sendable, Equatable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("rgb") {
            guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            var values: [Double] = []
            for (index, part) in parts.enumerated() {
                if index < 3 {
                    guard let value = Double(part), value >= 0, value <= 255 else { return nil }
                    values.append(value / 255)
                } else if part.hasSuffix("%") {
                    guard let value = Double(part.dropLast()), value >= 0, value <= 100 else { return nil }
                    values.append(value / 100)
                } else {
                    guard let value = Double(part), value >= 0, value <= 1 else { return nil }
                    values.append(value)
                }
            }
            self.init(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
            return
        }

        var hex = trimmed
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit), let value = UInt64(hex, radix: 16) else {
            return nil
        }
        switch hex.count {
        case 3:
            self.init(
                red: Double((value >> 8) & 0xF) / 15, green: Double((value >> 4) & 0xF) / 15,
                blue: Double(value & 0xF) / 15)
        case 4:
            self.init(
                red: Double((value >> 12) & 0xF) / 15,
                green: Double((value >> 8) & 0xF) / 15,
                blue: Double((value >> 4) & 0xF) / 15,
                alpha: Double(value & 0xF) / 15
            )
        case 6:
            self.init(
                red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255)
        default:
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = RoachRGBA(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a color: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public static let white = RoachRGBA(red: 1, green: 1, blue: 1)
    public static let black = RoachRGBA(red: 0, green: 0, blue: 0)

    public var hex: String {
        func byte(_ value: Double) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        let base = "#" + byte(red) + byte(green) + byte(blue)
        return alpha >= 0.998 ? base : base + byte(alpha)
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var opaque: RoachRGBA { withAlpha(1) }

    public func withAlpha(_ value: Double) -> RoachRGBA {
        RoachRGBA(red: red, green: green, blue: blue, alpha: value)
    }

    public func multiplyingAlpha(by factor: Double) -> RoachRGBA {
        RoachRGBA(red: red, green: green, blue: blue, alpha: alpha * factor)
    }

    public func mixed(with other: RoachRGBA, amount: Double) -> RoachRGBA {
        let t = Self.clamp(amount)
        return RoachRGBA(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    public func composited(over base: RoachRGBA) -> RoachRGBA {
        let under = base.alpha >= 0.998 ? base : base.composited(over: .black)
        return RoachRGBA(
            red: red * alpha + under.red * (1 - alpha),
            green: green * alpha + under.green * (1 - alpha),
            blue: blue * alpha + under.blue * (1 - alpha)
        )
    }

    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public static func contrast(_ first: RoachRGBA, _ second: RoachRGBA) -> Double {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public enum RoachBackgroundStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case field
    case signal
    case grid
    case circuit
    case aurora
    case starfield
    case scanlines
    case particles
    case paper
    case solid
    case image

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .field: return "Field"
        case .signal: return "Signal"
        case .grid: return "Floor grid"
        case .circuit: return "Circuit"
        case .aurora: return "Aurora"
        case .starfield: return "Starfield"
        case .scanlines: return "Scanlines"
        case .particles: return "Drift"
        case .paper: return "Paper"
        case .solid: return "Solid"
        case .image: return "Image"
        }
    }

    public var summary: String {
        switch self {
        case .field:
            return
                "The RoachWares field: dithered weather, LED contours and a dot lattice, with each theme's own light, fog, particles or scanlines."
        case .signal: return "The RoachNet dither field, floor grid, traces and signal packets."
        case .grid: return "A perspective floor grid that slowly scrolls."
        case .circuit: return "Board traces with packets running along them."
        case .aurora: return "Soft color bands that drift and breathe."
        case .starfield: return "Points of light drifting past."
        case .scanlines: return "A CRT glass: scanlines, phosphor bloom and a little flicker."
        case .particles: return "Embers rising or ash and snow falling."
        case .paper: return "A still, lightly grained sheet. Made for light themes."
        case .solid: return "Only the background gradient."
        case .image: return "A picture from the theme folder, dimmed and blurred to taste."
        }
    }

    public var animates: Bool {
        switch self {
        case .paper, .solid, .image: return false
        default: return true
        }
    }
}

public struct RoachThemeBackgroundSpec: Codable, Sendable, Equatable {
    public var style: String?
    public var intensity: Double?
    public var motion: Bool?
    public var speed: Double?
    public var colors: [String]?
    public var top: String?
    public var bottom: String?
    public var vignette: Double?
    public var image: String?
    public var imageDim: Double?
    public var imageBlur: Double?
    public var rise: Bool?
    public var field: RoachJSON?

    public init(
        style: String? = nil,
        intensity: Double? = nil,
        motion: Bool? = nil,
        speed: Double? = nil,
        colors: [String]? = nil,
        top: String? = nil,
        bottom: String? = nil,
        vignette: Double? = nil,
        image: String? = nil,
        imageDim: Double? = nil,
        imageBlur: Double? = nil,
        rise: Bool? = nil,
        field: RoachJSON? = nil
    ) {
        self.style = style
        self.intensity = intensity
        self.motion = motion
        self.speed = speed
        self.colors = colors
        self.top = top
        self.bottom = bottom
        self.vignette = vignette
        self.image = image
        self.imageDim = imageDim
        self.imageBlur = imageBlur
        self.rise = rise
        self.field = field
    }

    public func overlaid(by patch: RoachThemeBackgroundSpec?) -> RoachThemeBackgroundSpec {
        guard let patch else { return self }
        return RoachThemeBackgroundSpec(
            style: patch.style ?? style,
            intensity: patch.intensity ?? intensity,
            motion: patch.motion ?? motion,
            speed: patch.speed ?? speed,
            colors: patch.colors ?? colors,
            top: patch.top ?? top,
            bottom: patch.bottom ?? bottom,
            vignette: patch.vignette ?? vignette,
            image: patch.image ?? image,
            imageDim: patch.imageDim ?? imageDim,
            imageBlur: patch.imageBlur ?? imageBlur,
            rise: patch.rise ?? rise,
            field: field.map { $0.merged(with: patch.field) } ?? patch.field
        )
    }
}

public struct RoachThemeModeSpec: Codable, Sendable, Equatable {
    public var palette: [String: String]?
    public var background: RoachThemeBackgroundSpec?

    public init(palette: [String: String]? = nil, background: RoachThemeBackgroundSpec? = nil) {
        self.palette = palette
        self.background = background
    }

    public func overlaid(by patch: RoachThemeModeSpec?) -> RoachThemeModeSpec {
        guard let patch else { return self }
        var mergedPalette = palette ?? [:]
        for (key, value) in patch.palette ?? [:] {
            mergedPalette[key] = value
        }
        let mergedBackground: RoachThemeBackgroundSpec?
        if let base = background {
            mergedBackground = base.overlaid(by: patch.background)
        } else {
            mergedBackground = patch.background
        }
        return RoachThemeModeSpec(palette: mergedPalette.isEmpty ? nil : mergedPalette, background: mergedBackground)
    }
}

public struct RoachThemeTypographySpec: Codable, Sendable, Equatable {
    public var display: String?
    public var body: String?
    public var mono: String?
    public var scale: Double?

    public init(display: String? = nil, body: String? = nil, mono: String? = nil, scale: Double? = nil) {
        self.display = display
        self.body = body
        self.mono = mono
        self.scale = scale
    }

    public func overlaid(by patch: RoachThemeTypographySpec?) -> RoachThemeTypographySpec {
        guard let patch else { return self }
        return RoachThemeTypographySpec(
            display: patch.display ?? display,
            body: patch.body ?? body,
            mono: patch.mono ?? mono,
            scale: patch.scale ?? scale
        )
    }
}

public struct RoachThemeShapeSpec: Codable, Sendable, Equatable {
    public var radiusScale: Double?
    public var borderWidth: Double?

    public init(radiusScale: Double? = nil, borderWidth: Double? = nil) {
        self.radiusScale = radiusScale
        self.borderWidth = borderWidth
    }

    public func overlaid(by patch: RoachThemeShapeSpec?) -> RoachThemeShapeSpec {
        guard let patch else { return self }
        return RoachThemeShapeSpec(
            radiusScale: patch.radiusScale ?? radiusScale, borderWidth: patch.borderWidth ?? borderWidth)
    }
}

public struct RoachThemeEffectsSpec: Codable, Sendable, Equatable {
    public var glass: Double?
    public var glow: Double?
    public var shadow: Double?

    public init(glass: Double? = nil, glow: Double? = nil, shadow: Double? = nil) {
        self.glass = glass
        self.glow = glow
        self.shadow = shadow
    }

    public func overlaid(by patch: RoachThemeEffectsSpec?) -> RoachThemeEffectsSpec {
        guard let patch else { return self }
        return RoachThemeEffectsSpec(
            glass: patch.glass ?? glass, glow: patch.glow ?? glow, shadow: patch.shadow ?? shadow)
    }
}

public struct RoachThemeMotionSpec: Codable, Sendable, Equatable {
    public var tempo: Double?

    public init(tempo: Double? = nil) {
        self.tempo = tempo
    }
}

public struct RoachThemeDocument: Codable, Sendable, Equatable, Identifiable {
    public static let schemaID = "org.roachnet.theme.v1"
    public static let fileSuffix = ".roachtheme.json"

    public var schema: String
    public var id: String
    public var name: String
    public var author: String?
    public var version: String?
    public var description: String?
    public var tags: [String]?
    public var dark: RoachThemeModeSpec?
    public var light: RoachThemeModeSpec?
    public var typography: RoachThemeTypographySpec?
    public var shape: RoachThemeShapeSpec?
    public var effects: RoachThemeEffectsSpec?
    public var motion: RoachThemeMotionSpec?

    public init(
        schema: String = RoachThemeDocument.schemaID,
        id: String,
        name: String,
        author: String? = nil,
        version: String? = nil,
        description: String? = nil,
        tags: [String]? = nil,
        dark: RoachThemeModeSpec? = nil,
        light: RoachThemeModeSpec? = nil,
        typography: RoachThemeTypographySpec? = nil,
        shape: RoachThemeShapeSpec? = nil,
        effects: RoachThemeEffectsSpec? = nil,
        motion: RoachThemeMotionSpec? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.tags = tags
        self.dark = dark
        self.light = light
        self.typography = typography
        self.shape = shape
        self.effects = effects
        self.motion = motion
    }

    public var hasDark: Bool { dark != nil }
    public var hasLight: Bool { light != nil }
}

public struct RoachThemeSnippetDocument: Codable, Sendable, Equatable, Identifiable {
    public static let schemaID = "org.roachnet.theme-snippet.v1"
    public static let fileSuffix = ".roachsnippet.json"

    public var schema: String
    public var id: String
    public var name: String
    public var author: String?
    public var description: String?
    public var all: RoachThemeModeSpec?
    public var dark: RoachThemeModeSpec?
    public var light: RoachThemeModeSpec?
    public var typography: RoachThemeTypographySpec?
    public var shape: RoachThemeShapeSpec?
    public var effects: RoachThemeEffectsSpec?

    public init(
        schema: String = RoachThemeSnippetDocument.schemaID,
        id: String,
        name: String,
        author: String? = nil,
        description: String? = nil,
        all: RoachThemeModeSpec? = nil,
        dark: RoachThemeModeSpec? = nil,
        light: RoachThemeModeSpec? = nil,
        typography: RoachThemeTypographySpec? = nil,
        shape: RoachThemeShapeSpec? = nil,
        effects: RoachThemeEffectsSpec? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.author = author
        self.description = description
        self.all = all
        self.dark = dark
        self.light = light
        self.typography = typography
        self.shape = shape
        self.effects = effects
    }
}

public enum RoachAppearancePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case dark
    case light
    case system

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match macOS"
        }
    }
}

public struct RoachThemeSettings: Codable, Sendable, Equatable {
    public static let defaultThemeID = "roachnet.kernel-night"
    public static let currentDesignGeneration = 8

    public var themeID: String
    public var appearance: RoachAppearancePreference
    public var accent: String?
    public var displayFont: String?
    public var bodyFont: String?
    public var monoFont: String?
    public var textScale: Double?
    public var radiusScale: Double?
    public var backgroundStyle: String?
    public var backgroundIntensity: Double?
    public var backgroundMotion: Bool?
    public var glass: Double?
    public var snippets: [String]
    public var followsDefault: Bool?
    public var designGeneration: Int?

    public init(themeID: String = RoachThemeSettings.defaultThemeID, appearance: RoachAppearancePreference = .dark) {
        self.themeID = themeID
        self.appearance = appearance
        self.snippets = []
        self.designGeneration = Self.currentDesignGeneration
    }

    public static var fresh: RoachThemeSettings {
        var settings = RoachThemeSettings()
        settings.followsDefault = true
        return settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themeID = try container.decodeIfPresent(String.self, forKey: .themeID) ?? Self.defaultThemeID
        appearance = (try? container.decodeIfPresent(RoachAppearancePreference.self, forKey: .appearance)) ?? .dark
        accent = try container.decodeIfPresent(String.self, forKey: .accent)
        displayFont = try container.decodeIfPresent(String.self, forKey: .displayFont)
        bodyFont = try container.decodeIfPresent(String.self, forKey: .bodyFont)
        monoFont = try container.decodeIfPresent(String.self, forKey: .monoFont)
        textScale = try container.decodeIfPresent(Double.self, forKey: .textScale)
        radiusScale = try container.decodeIfPresent(Double.self, forKey: .radiusScale)
        backgroundStyle = try container.decodeIfPresent(String.self, forKey: .backgroundStyle)
        backgroundIntensity = try container.decodeIfPresent(Double.self, forKey: .backgroundIntensity)
        backgroundMotion = try container.decodeIfPresent(Bool.self, forKey: .backgroundMotion)
        glass = try container.decodeIfPresent(Double.self, forKey: .glass)
        snippets = try container.decodeIfPresent([String].self, forKey: .snippets) ?? []
        followsDefault = try container.decodeIfPresent(Bool.self, forKey: .followsDefault)
        designGeneration = try container.decodeIfPresent(Int.self, forKey: .designGeneration)
    }

    public func migrated() -> RoachThemeSettings {
        var next = self
        if designGeneration == nil {
            if themeID == "roachnet.signal" {
                next.themeID = Self.defaultThemeID
                next.followsDefault = true
            } else {
                next.followsDefault = false
            }
            next.designGeneration = Self.currentDesignGeneration
        }
        if let current = RoachBuiltInThemes.aliases[next.themeID] { next.themeID = current }
        return next
    }

    public var hasOverrides: Bool {
        accent != nil || displayFont != nil || bodyFont != nil || monoFont != nil || textScale != nil
            || radiusScale != nil || backgroundStyle != nil || backgroundIntensity != nil || backgroundMotion != nil
            || glass != nil
    }

    public var overrideSnippet: RoachThemeSnippetDocument {
        let background = RoachThemeBackgroundSpec(
            style: backgroundStyle, intensity: backgroundIntensity, motion: backgroundMotion)
        let hasBackground = backgroundStyle != nil || backgroundIntensity != nil || backgroundMotion != nil
        return RoachThemeSnippetDocument(
            id: "settings",
            name: "Your settings",
            all: RoachThemeModeSpec(
                palette: accent.map { ["accent": $0] },
                background: hasBackground ? background : nil
            ),
            typography: RoachThemeTypographySpec(
                display: displayFont, body: bodyFont, mono: monoFont, scale: textScale),
            shape: RoachThemeShapeSpec(radiusScale: radiusScale),
            effects: RoachThemeEffectsSpec(glass: glass)
        )
    }
}
