import Foundation

/// The themes and snippets that ship inside RoachNet.
public enum RoachBuiltInThemes {
    public static let themes: [RoachThemeDocument] = decode(RoachBuiltInThemeSources.themes)
    public static let snippets: [RoachThemeSnippetDocument] = decode(RoachBuiltInThemeSources.snippets)

    /// Signal. Falls back to a bare document if the embedded JSON ever failed
    /// to decode (the test suite makes sure it does not).
    public static var defaultTheme: RoachThemeDocument {
        theme(id: RoachThemeSettings.defaultThemeID)
            ?? themes.first
            ?? RoachThemeDocument(id: RoachThemeSettings.defaultThemeID, name: "Signal", dark: RoachThemeModeSpec())
    }

    public static func theme(id: String) -> RoachThemeDocument? {
        themes.first { $0.id == id }
    }

    public static func snippet(id: String) -> RoachThemeSnippetDocument? {
        snippets.first { $0.id == id }
    }

    /// How many embedded sources failed to decode. Zero in a healthy build.
    public static var undecodableSourceCount: Int {
        (RoachBuiltInThemeSources.themes.count - themes.count) + (RoachBuiltInThemeSources.snippets.count - snippets.count)
    }

    private static func decode<Document: Decodable>(_ sources: [String]) -> [Document] {
        let decoder = JSONDecoder()
        return sources.compactMap { try? decoder.decode(Document.self, from: Data($0.utf8)) }
    }
}
