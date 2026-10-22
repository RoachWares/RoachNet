import Foundation

public enum RoachBuiltInThemes {
    public static let themes: [RoachThemeDocument] = decode(RoachBuiltInThemeSources.themes)
    public static let snippets: [RoachThemeSnippetDocument] = decode(RoachBuiltInThemeSources.snippets)

    public static var defaultTheme: RoachThemeDocument {
        theme(id: RoachThemeSettings.defaultThemeID)
            ?? themes.first
            ?? RoachThemeDocument(
                id: RoachThemeSettings.defaultThemeID, name: "Kernel Night", dark: RoachThemeModeSpec())
    }

    public static func theme(id: String) -> RoachThemeDocument? {
        let current = aliases[id] ?? id
        return themes.first { $0.id == current }
    }

    public static let aliases: [String: String] = [
        "roachnet.green-phosphor": "roachnet.phosphor"
    ]

    public static func defaultThemeID(on date: Date = Date(), dark: Bool, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let halloween = (month == 10 && day >= 24) || (month == 11 && day <= 1)
        if halloween { return dark ? "roachnet.spectral" : "roachnet.bone" }
        return dark ? RoachThemeSettings.defaultThemeID : "roachnet.daylight"
    }

    public static func snippet(id: String) -> RoachThemeSnippetDocument? {
        snippets.first { $0.id == id }
    }

    public static var undecodableSourceCount: Int {
        (RoachBuiltInThemeSources.themes.count - themes.count)
            + (RoachBuiltInThemeSources.snippets.count - snippets.count)
    }

    private static func decode<Document: Decodable>(_ sources: [String]) -> [Document] {
        let decoder = JSONDecoder()
        return sources.compactMap { try? decoder.decode(Document.self, from: Data($0.utf8)) }
    }
}
