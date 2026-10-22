import Foundation

public struct RoachThemeIssue: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var message: String
    public var id: String { severity.rawValue + ":" + message }

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct RoachContrastCheck: Sendable, Equatable, Identifiable {
    public var foreground: RoachColorToken
    public var background: RoachColorToken
    public var ratio: Double
    public var minimum: Double

    public var passes: Bool { ratio + 0.0001 >= minimum }
    public var id: String { foreground.key + "/" + background.key }
    public var label: String { "\(foreground.label) on \(background.label.lowercased())" }
}

public enum RoachThemeValidator {
    public static let contrastRequirements: [(RoachColorToken, RoachColorToken, Double)] = [
        (.text, .background, 7),
        (.text, .panel, 7),
        (.muted, .panel, 4.5),
        (.muted, .panelRaised, 4.5),
        (.accent, .panel, 4.5),
        (.accentSecondary, .panel, 3),
        (.accentTertiary, .panel, 3),
        (.accentInfo, .panel, 3),
        (.success, .panel, 3),
        (.warning, .panel, 3),
        (.danger, .panel, 3),
        (.onAccent, .accent, 4.5),
        (.borderStrong, .panel, 1.3),
        (.actionInk, .action, 4.5),
        (.signal, .panel, 3),
        (.focus, .background, 3),
        (.inputLine, .backgroundRaised, 3),
        (.inputLine, .panel, 3),
    ]

    public static func isValidID(_ id: String) -> Bool {
        guard (2...64).contains(id.count), let first = id.unicodeScalars.first else { return false }
        let lowerDigits = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let allowed = lowerDigits.union(CharacterSet(charactersIn: "._-"))
        return lowerDigits.contains(first) && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func contrastChecks(for theme: RoachResolvedTheme) -> [RoachContrastCheck] {
        let window = theme.rgba(.background).composited(over: .black)
        return contrastRequirements.map { foreground, background, minimum in
            let under = theme.rgba(background).composited(over: window)
            let over = theme.rgba(foreground).composited(over: under)
            return RoachContrastCheck(
                foreground: foreground,
                background: background,
                ratio: RoachRGBA.contrast(over, under),
                minimum: minimum
            )
        }
    }

    public static func validate(
        _ document: RoachThemeDocument,
        baseURL: URL? = nil,
        fontIsInstalled: (String) -> Bool = RoachFontFace.isInstalled(family:)
    ) -> [RoachThemeIssue] {
        var issues: [RoachThemeIssue] = []
        if document.schema != RoachThemeDocument.schemaID {
            issues.append(.init(.error, "The schema must be \(RoachThemeDocument.schemaID), not \(document.schema)."))
        }
        if !isValidID(document.id) {
            issues.append(
                .init(
                    .error,
                    "The id \"\(document.id)\" must be 2 to 64 lowercase letters, digits, dots, dashes or underscores, starting with a letter or digit."
                ))
        }
        if document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.error, "The theme needs a name."))
        }
        if document.dark == nil && document.light == nil {
            issues.append(.init(.error, "The theme needs a dark mode, a light mode, or both."))
        }

        for (isDark, mode) in [(true, document.dark), (false, document.light)] {
            guard let mode else { continue }
            let label = isDark ? "Dark" : "Light"
            for required in ["background", "text", "accent"] where mode.palette?[required] == nil {
                issues.append(.init(.warning, "\(label) mode does not set \(required); RoachNet will fill it in."))
            }
            let settings = RoachThemeSettings(themeID: document.id, appearance: isDark ? .dark : .light)
            let resolved = RoachThemeResolver.resolve(
                document: document,
                settings: settings,
                systemIsDark: isDark,
                baseURL: baseURL,
                fontIsInstalled: fontIsInstalled
            )
            for problem in resolved.problems {
                let severity: RoachThemeIssue.Severity =
                    problem.contains("not installed") || problem.contains("showing a solid") ? .warning : .error
                issues.append(.init(severity, "\(label) mode: \(problem)"))
            }
            for check in contrastChecks(for: resolved) where !check.passes {
                issues.append(
                    .init(
                        .warning,
                        String(
                            format: "%@ mode: %@ is %.1f:1; aim for %.1f:1.", label, check.label, check.ratio,
                            check.minimum)))
            }
        }
        return issues
    }

    public static func validate(_ snippet: RoachThemeSnippetDocument) -> [RoachThemeIssue] {
        var issues: [RoachThemeIssue] = []
        if snippet.schema != RoachThemeSnippetDocument.schemaID {
            issues.append(
                .init(.error, "The schema must be \(RoachThemeSnippetDocument.schemaID), not \(snippet.schema)."))
        }
        if !isValidID(snippet.id) {
            issues.append(
                .init(
                    .error,
                    "The id \"\(snippet.id)\" must be 2 to 64 lowercase letters, digits, dots, dashes or underscores."))
        }
        if snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.error, "The snippet needs a name."))
        }
        for mode in [snippet.all, snippet.dark, snippet.light].compactMap({ $0 }) {
            for (key, value) in mode.palette ?? [:] {
                if RoachColorToken(key: key) == nil {
                    issues.append(.init(.error, "Unknown color token \"\(key)\"."))
                } else if RoachRGBA(value) == nil {
                    issues.append(.init(.error, "\"\(value)\" is not a color (\(key))."))
                }
            }
            if let style = mode.background?.style, RoachBackgroundStyle(rawValue: style.lowercased()) == nil {
                issues.append(.init(.error, "Unknown background style \"\(style)\"."))
            }
        }
        return issues
    }
}
