import RoachNetDesign
import XCTest
@testable import RoachNetApp

final class RoachThemeTests: XCTestCase {
    // MARK: Built-in themes

    func testBuiltInThemesAndSnippetsAllDecode() {
        XCTAssertEqual(RoachBuiltInThemes.undecodableSourceCount, 0)
        XCTAssertGreaterThanOrEqual(RoachBuiltInThemes.themes.count, 30, "1.1 ships plenty of themes")
        XCTAssertGreaterThanOrEqual(RoachBuiltInThemes.snippets.count, 10)
        XCTAssertEqual(RoachBuiltInThemes.themes.first?.id, "roachnet.signal")
        XCTAssertEqual(Set(RoachBuiltInThemes.themes.map(\.id)).count, RoachBuiltInThemes.themes.count)
        XCTAssertEqual(Set(RoachBuiltInThemes.snippets.map(\.id)).count, RoachBuiltInThemes.snippets.count)
        let lightThemes = RoachBuiltInThemes.themes.filter { $0.light != nil }
        XCTAssertGreaterThanOrEqual(lightThemes.count, 10, "light mode is a real choice, not an afterthought")
    }

    func testEveryBuiltInThemeIsValidAndReadableInEveryMode() {
        for theme in RoachBuiltInThemes.themes {
            let issues = RoachThemeValidator.validate(theme, fontIsInstalled: { _ in true })
            XCTAssertEqual(issues.map(\.message), [], theme.id)
            for (isDark, mode) in [(true, theme.dark), (false, theme.light)] where mode != nil {
                let resolved = RoachThemeResolver.resolve(
                    document: theme,
                    settings: RoachThemeSettings(themeID: theme.id, appearance: isDark ? .dark : .light),
                    systemIsDark: isDark
                )
                XCTAssertEqual(resolved.isDark, isDark, theme.id)
                XCTAssertEqual(resolved.problems, [], theme.id)
                for check in RoachThemeValidator.contrastChecks(for: resolved) {
                    XCTAssertTrue(check.passes, "\(theme.id) \(isDark ? "dark" : "light"): \(check.label) is \(check.ratio)")
                }
            }
        }
    }

    func testEveryBuiltInSnippetIsValid() {
        for snippet in RoachBuiltInThemes.snippets {
            XCTAssertEqual(RoachThemeValidator.validate(snippet).map(\.message), [], snippet.id)
        }
    }

    func testBuiltInThemeNamesAvoidWellKnownThirdPartyThemes() {
        let taken = ["dracula", "nord", "solarized", "monokai", "gruvbox", "one dark", "tokyo night", "catppuccin",
                     "rosé pine", "rose pine", "everforest", "ayu", "material", "synthwave", "abyss", "cobalt", "solar flare"]
        for theme in RoachBuiltInThemes.themes {
            let name = theme.name.lowercased()
            XCTAssertFalse(taken.contains { name.contains($0) }, theme.name)
        }
    }

    /// Signal is the RoachNet look from 1.0; theming must not change it.
    func testSignalDarkMatchesThePre11Palette() {
        let signal = RoachThemeResolver.resolve(document: RoachBuiltInThemes.defaultTheme, settings: RoachThemeSettings(), systemIsDark: true)
        XCTAssertTrue(signal.isDark)
        func assertColor(_ token: RoachColorToken, _ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1, line: UInt = #line) {
            let value = signal.rgba(token)
            XCTAssertEqual(value.red, red, accuracy: 0.6 / 255, "\(token) red", line: line)
            XCTAssertEqual(value.green, green, accuracy: 0.6 / 255, "\(token) green", line: line)
            XCTAssertEqual(value.blue, blue, accuracy: 0.6 / 255, "\(token) blue", line: line)
            XCTAssertEqual(value.alpha, alpha, accuracy: 0.0001, "\(token) alpha", line: line)
        }
        assertColor(.accent, 0.24, 0.98, 0.54)
        assertColor(.accentSecondary, 0.5686, 0.2196, 0.8471)
        assertColor(.accentTertiary, 0.98, 0.74, 0.20)
        assertColor(.accentInfo, 0.40, 0.84, 1.0)
        assertColor(.background, 0.010, 0.012, 0.015)
        assertColor(.backgroundRaised, 0.026, 0.029, 0.034)
        assertColor(.panel, 0.043, 0.047, 0.055)
        assertColor(.panelRaised, 0.068, 0.073, 0.084)
        assertColor(.panelSoft, 0.104, 0.110, 0.126)
        assertColor(.glass, 1, 1, 1, 0.045)
        assertColor(.specular, 1, 1, 1, 0.08)
        assertColor(.border, 1, 1, 1, 0.085)
        assertColor(.borderStrong, 1, 1, 1, 0.14)
        assertColor(.text, 1, 1, 1, 0.97)
        assertColor(.muted, 1, 1, 1, 0.68)
        assertColor(.success, 0.24, 0.98, 0.54)
        assertColor(.warning, 0.93, 0.73, 0.26)
        assertColor(.shadow, 0, 0, 0, 0.24)
        assertColor(.ink, 1, 1, 1)
        assertColor(.shade, 0, 0, 0)
        XCTAssertEqual(signal.typography, .signal)
        XCTAssertEqual(signal.radiusScale, 1)
        XCTAssertEqual(signal.background.style, .signal)
        XCTAssertEqual(signal.background.vignette, 0.48, accuracy: 0.0001)
    }

    // MARK: Resolution

    func testAMinimalThemeGetsEveryTokenAndReadableTextOnItsAccent() {
        let minimal = RoachThemeDocument(
            id: "test.minimal",
            name: "Minimal",
            dark: RoachThemeModeSpec(palette: ["background": "#101014", "text": "#F0F0F0", "accent": "#FFB000"])
        )
        let theme = RoachThemeResolver.resolve(document: minimal)
        XCTAssertEqual(theme.palette.count, RoachColorToken.allCases.count)
        XCTAssertEqual(theme.rgba(.accent).hex, "#FFB000")
        XCTAssertEqual(theme.rgba(.ink).hex, "#F0F0F0")
        let accent = theme.rgba(.accent).composited(over: theme.rgba(.background))
        XCTAssertGreaterThanOrEqual(RoachRGBA.contrast(theme.rgba(.onAccent), accent), 4.5)
        XCTAssertEqual(theme.background.style, .signal)
        XCTAssertEqual(theme.background.colors.first, theme.rgba(.accent))
    }

    func testModeChoiceFallsBackToTheVariantATHemeHas() {
        let darkOnly = RoachThemeDocument(id: "test.dark", name: "Dark", dark: RoachThemeModeSpec())
        let lightOnly = RoachThemeDocument(id: "test.light", name: "Light", light: RoachThemeModeSpec())
        let both = RoachThemeDocument(id: "test.both", name: "Both", dark: RoachThemeModeSpec(), light: RoachThemeModeSpec())
        XCTAssertTrue(RoachThemeResolver.usesDark(darkOnly, preference: .light, systemIsDark: false))
        XCTAssertFalse(RoachThemeResolver.usesDark(lightOnly, preference: .dark, systemIsDark: true))
        XCTAssertTrue(RoachThemeResolver.usesDark(both, preference: .system, systemIsDark: true))
        XCTAssertFalse(RoachThemeResolver.usesDark(both, preference: .system, systemIsDark: false))
        XCTAssertFalse(RoachThemeResolver.usesDark(both, preference: .light, systemIsDark: true))
    }

    func testSnippetsAndSettingsLayerInOrder() throws {
        let signal = RoachBuiltInThemes.defaultTheme
        let square = try XCTUnwrap(RoachBuiltInThemes.snippet(id: "roachnet.snippet.square-corners"))
        let round = try XCTUnwrap(RoachBuiltInThemes.snippet(id: "roachnet.snippet.extra-round"))
        let mono = try XCTUnwrap(RoachBuiltInThemes.snippet(id: "roachnet.snippet.mono-everything"))

        XCTAssertEqual(RoachThemeResolver.resolve(document: signal, snippets: [square]).radiusScale, 0)
        XCTAssertEqual(RoachThemeResolver.resolve(document: signal, snippets: [square, round]).radiusScale, 1.6, accuracy: 0.0001)
        XCTAssertEqual(RoachThemeResolver.resolve(document: signal, snippets: [round, square]).radiusScale, 0)

        let monoTheme = RoachThemeResolver.resolve(document: signal, snippets: [mono])
        XCTAssertEqual(monoTheme.typography.body, .systemMono)
        XCTAssertEqual(monoTheme.typography.display, .systemMono)

        var settings = RoachThemeSettings()
        settings.accent = "#FF0000"
        settings.radiusScale = 0.5
        settings.textScale = 9 // clamped
        let tuned = RoachThemeResolver.resolve(document: signal, snippets: [square], settings: settings)
        XCTAssertEqual(tuned.rgba(.accent).hex, "#FF0000")
        XCTAssertEqual(tuned.radiusScale, 0.5, accuracy: 0.0001, "settings win over snippets")
        XCTAssertEqual(tuned.typography.scale, 1.4, accuracy: 0.0001)
    }

    func testEffectsScaleGlassAndShadowTokens() {
        var document = RoachBuiltInThemes.defaultTheme
        document.effects = RoachThemeEffectsSpec(glass: 0, glow: 0.5, shadow: 2)
        let theme = RoachThemeResolver.resolve(document: document)
        XCTAssertEqual(theme.rgba(.glass).alpha, 0)
        XCTAssertEqual(theme.rgba(.specular).alpha, 0)
        XCTAssertEqual(theme.rgba(.shadow).alpha, 0.48, accuracy: 0.0001)
        XCTAssertEqual(theme.glow, 0.5)
    }

    func testProblemsAreReportedNotFatal() {
        let broken = RoachThemeDocument(
            id: "test.broken",
            name: "Broken",
            dark: RoachThemeModeSpec(
                palette: ["background": "#000", "text": "#fff", "accent": "green-ish", "sparkle": "#fff"],
                background: RoachThemeBackgroundSpec(style: "lava-lamp")
            ),
            typography: RoachThemeTypographySpec(display: "Definitely Not A Font 12345")
        )
        let theme = RoachThemeResolver.resolve(document: broken, fontIsInstalled: { _ in false })
        XCTAssertTrue(theme.problems.contains { $0.contains("green-ish") })
        XCTAssertTrue(theme.problems.contains { $0.contains("sparkle") })
        XCTAssertTrue(theme.problems.contains { $0.contains("lava-lamp") })
        XCTAssertTrue(theme.problems.contains { $0.contains("not installed") })
        XCTAssertEqual(theme.typography.display, .systemRounded)
        let issues = RoachThemeValidator.validate(broken, fontIsInstalled: { _ in false })
        XCTAssertTrue(issues.contains { $0.severity == .error })
    }

    // MARK: Colors and files

    func testColorParsing() {
        XCTAssertEqual(RoachRGBA("#abc")?.hex, "#AABBCC")
        XCTAssertEqual(RoachRGBA("#AABBCC80")?.hex, "#AABBCC80")
        XCTAssertEqual(RoachRGBA("rgba(255, 0, 0, 0.5)")?.hex, "#FF000080")
        XCTAssertEqual(RoachRGBA("rgb(0,128,255)")?.hex, "#0080FF")
        XCTAssertNil(RoachRGBA("rgb(300,0,0)"))
        XCTAssertNil(RoachRGBA("nope"))
        XCTAssertNil(RoachRGBA("#12345"))
        XCTAssertEqual(RoachRGBA.contrast(.white, .black), 21, accuracy: 0.01)
    }

    func testThemeImagesMustStayInsideTheThemeFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roach-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNotNil(RoachThemeResolver.safeChild(named: "backdrop.png", of: folder))
        XCTAssertNotNil(RoachThemeResolver.safeChild(named: "art/backdrop.jpg", of: folder))
        XCTAssertNil(RoachThemeResolver.safeChild(named: "../backdrop.png", of: folder))
        XCTAssertNil(RoachThemeResolver.safeChild(named: "/etc/backdrop.png", of: folder))
        XCTAssertNil(RoachThemeResolver.safeChild(named: "~/backdrop.png", of: folder))
        XCTAssertNil(RoachThemeResolver.safeChild(named: "backdrop.svg", of: folder))
        XCTAssertNil(RoachThemeResolver.safeChild(named: "backdrop.png", of: nil))
    }

    func testExportJSONCarriesEveryToken() throws {
        let theme = RoachThemeResolver.resolve(document: RoachBuiltInThemes.defaultTheme, revision: 7)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: theme.exportJSON()) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "org.roachnet.active-theme.v1")
        XCTAssertEqual(object["id"] as? String, "roachnet.signal")
        XCTAssertEqual(object["mode"] as? String, "dark")
        XCTAssertEqual(object["revision"] as? Int, 7)
        let palette = try XCTUnwrap(object["palette"] as? [String: String])
        XCTAssertEqual(Set(palette.keys), Set(RoachColorToken.allCases.map(\.key)))
        XCTAssertEqual(palette["accent"], "#3DFA8A")
    }
}

@MainActor
final class RoachThemeStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("roach-theme-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        RoachThemeRuntime.shared.apply(RoachThemeRuntime.defaultTheme())
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)
    }

    private func themeJSON(id: String, name: String, accent: String) -> [String: Any] {
        [
            "schema": "org.roachnet.theme.v1",
            "id": id,
            "name": name,
            "dark": ["palette": ["background": "#0A0A0A", "panel": "#141414", "panelRaised": "#1C1C1C", "text": "#F2F2F2", "accent": accent]],
        ]
    }

    func testStoreFindsUserAndPackThemesAppliesThemAndWritesTheActiveTheme() throws {
        let themes = root.appendingPathComponent("themes", isDirectory: true)
        try writeJSON(themeJSON(id: "user.test", name: "Test", accent: "#FF4545"), to: themes.appendingPathComponent("user.test/user.test.roachtheme.json"))
        let packRoot = root.appendingPathComponent("packs/installed/halloween/1.0.0", isDirectory: true)
        try writeJSON(["name": "Halloween Collection"], to: packRoot.appendingPathComponent("manifest.json"))
        try writeJSON(themeJSON(id: "halloween.hollow-moon", name: "Hollow Moon", accent: "#FFB000"), to: packRoot.appendingPathComponent("themes/hollow-moon.roachtheme.json"))
        let statePath = root.appendingPathComponent("packs/state.json")
        try writeJSON(["schema": "org.roachnet.pack-state.v1", "packs": ["halloween": ["enabled": true, "installedVersion": "1.0.0"]]], to: statePath)

        let store = RoachThemeStore(storageRoot: root)
        store.scan()
        let user = try XCTUnwrap(store.themes.first { $0.id == "user.test" })
        XCTAssertTrue(user.isUserTheme)
        XCTAssertEqual(user.issues.filter { $0.severity == .error }, [])
        let packTheme = try XCTUnwrap(store.themes.first { $0.id == "halloween.hollow-moon" })
        XCTAssertEqual(packTheme.source, .pack(id: "halloween", name: "Halloween Collection"))
        XCTAssertEqual(store.themes.filter { $0.source == .builtIn }.count, RoachBuiltInThemes.themes.count)

        store.select(user)
        XCTAssertEqual(RoachThemeRuntime.shared.untrackedTheme.id, "user.test")
        XCTAssertEqual(RoachThemeRuntime.shared.untrackedTheme.rgba(.accent).hex, "#FF4545")
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.exportURL)) as? [String: Any])
        XCTAssertEqual(exported["id"] as? String, "user.test")
        XCTAssertEqual((exported["palette"] as? [String: String])?["accent"], "#FF4545")

        // Switching the pack off hides its themes.
        try writeJSON(["schema": "org.roachnet.pack-state.v1", "packs": ["halloween": ["enabled": false, "installedVersion": "1.0.0"]]], to: statePath)
        store.scan()
        XCTAssertNil(store.themes.first { $0.id == "halloween.hollow-moon" })
    }

    func testImportRefusesBrokenFilesAndRenamesCollisions() throws {
        let store = RoachThemeStore(storageRoot: root)
        store.scan()

        let broken = root.appendingPathComponent("broken.roachtheme.json")
        try writeJSON(["schema": "org.roachnet.theme.v1", "id": "x", "name": "", "dark": ["palette": ["accent": "nope"]]], to: broken)
        XCTAssertThrowsError(try store.importFile(at: broken))

        let encoder = JSONEncoder()
        let copy = root.appendingPathComponent("signal-copy.roachtheme.json")
        try encoder.encode(RoachBuiltInThemes.defaultTheme).write(to: copy)
        let importedID = try store.importFile(at: copy)
        XCTAssertEqual(importedID, "user.roachnet.signal")
        XCTAssertTrue(store.themes.contains { $0.id == importedID && $0.isUserTheme })

        let snippet = root.appendingPathComponent("tight.roachsnippet.json")
        try writeJSON(["schema": "org.roachnet.theme-snippet.v1", "id": "user.tight", "name": "Tight", "shape": ["radiusScale": 0.2]], to: snippet)
        XCTAssertEqual(try store.importFile(at: snippet), "user.tight")
        XCTAssertTrue(store.snippets.contains { $0.id == "user.tight" && $0.source == .user })
    }

    func testDuplicateMakesAnEditableCopyAndSettingsPersist() throws {
        let store = RoachThemeStore(storageRoot: root)
        store.scan()
        let signal = try XCTUnwrap(store.themes.first { $0.id == "roachnet.signal" })
        let copy = try store.duplicate(signal, name: "My Signal")
        XCTAssertTrue(copy.id.hasPrefix("user."))
        XCTAssertTrue(copy.isUserTheme)
        XCTAssertEqual(copy.document.name, "My Signal")

        store.update { settings in
            settings.themeID = copy.id
            settings.textScale = 1.2
            settings.snippets = ["roachnet.snippet.square-corners"]
        }
        store.saveSettings()
        let reloaded = RoachThemeStore(storageRoot: root).loadSettings()
        XCTAssertEqual(reloaded.themeID, copy.id)
        XCTAssertEqual(reloaded.textScale, 1.2)
        XCTAssertEqual(reloaded.snippets, ["roachnet.snippet.square-corners"])
        XCTAssertEqual(RoachThemeRuntime.shared.untrackedTheme.radiusScale, 0)

        try store.trash(copy)
        XCTAssertNil(store.themes.first { $0.id == copy.id })
        XCTAssertEqual(store.settings.themeID, RoachThemeSettings.defaultThemeID)
    }
}
