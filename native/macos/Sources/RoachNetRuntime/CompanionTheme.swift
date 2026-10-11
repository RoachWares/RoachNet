import Foundation

extension NativeRuntime {
    /// The Mac's active theme for the iOS companion: the resolved palette,
    /// background, type and shape the Mac app wrote to
    /// `<storage>/themes/active-theme.json` (schema org.roachnet.active-theme.v1).
    /// Before the Mac app has written one, this is Signal dark, so the phone
    /// always gets something it can draw.
    func companionTheme() -> JSON {
        let path = Path.join(storageRoot, "themes", "active-theme.json")
        if Files.exists(path), let theme = JSON.read(contentsOf: path),
           theme["schema"].jsString == "org.roachnet.active-theme.v1", theme["palette"].isObject {
            return theme
        }
        return Self.signalCompanionTheme
    }

    static let signalCompanionTheme: JSON = [
        "schema": "org.roachnet.active-theme.v1",
        "id": "roachnet.signal",
        "name": "Signal",
        "mode": "dark",
        "revision": 0,
        "palette": [
            "accent": "#3DFA8A", "accentSecondary": "#9138D8", "accentTertiary": "#FABD33", "accentInfo": "#66D6FF",
            "background": "#030304", "backgroundRaised": "#070709", "panel": "#0B0C0E", "panelRaised": "#111315",
            "panelSoft": "#1B1C20", "glass": "#FFFFFF0B", "specular": "#FFFFFF14", "border": "#FFFFFF16",
            "borderStrong": "#FFFFFF24", "text": "#FFFFFFF7", "muted": "#FFFFFFAD", "success": "#3DFA8A",
            "warning": "#EDBA42", "danger": "#FF5C6C", "shadow": "#0000003D", "ink": "#FFFFFF", "shade": "#000000",
            "onAccent": "#050607",
        ],
        "background": [
            "style": "signal", "intensity": 1, "motion": true, "speed": 1,
            "colors": ["#3DFA8A", "#9138D8", "#FABD33", "#66D6FF"], "top": "#030304", "bottom": "#070709", "vignette": 0.48,
        ],
        "typography": ["display": "system-rounded", "body": "system", "mono": "system-mono", "scale": 1],
        "shape": ["radiusScale": 1, "borderWidth": 1],
        "effects": ["glass": 1, "glow": 1, "shadow": 1],
    ]
}
