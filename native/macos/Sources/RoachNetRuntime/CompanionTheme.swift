import Foundation

extension NativeRuntime {
    func companionTheme() -> JSON {
        let path = Path.join(storageRoot, "themes", "active-theme.json")
        if Files.exists(path), let theme = JSON.read(contentsOf: path),
            theme["schema"].jsString == "org.roachnet.active-theme.v1", theme["palette"].isObject
        {
            return theme
        }
        return Self.defaultCompanionTheme
    }

    static let defaultCompanionTheme: JSON = [
        "schema": "org.roachnet.active-theme.v1",
        "id": "roachnet.kernel-night",
        "name": "Kernel Night",
        "mode": "dark",
        "revision": 0,
        "palette": [
            "accent": "#B97EDE", "accentSecondary": "#36FF84", "accentTertiary": "#FFD166", "accentInfo": "#D1A4EF",
            "background": "#06060B", "backgroundRaised": "#09080F", "panel": "#0E0D16", "panelRaised": "#15141F",
            "panelSoft": "#1F1D2C", "glass": "#0E0D16BD", "specular": "#E4C7F914", "border": "#CDC6FF1A",
            "borderStrong": "#CDC6FF33", "text": "#F3F2F8", "muted": "#ADA6BB", "success": "#36FF84",
            "warning": "#FFD166", "danger": "#FF7A6B", "shadow": "#00000080", "ink": "#FFFFFF",
            "shade": "#000000", "onAccent": "#0A0B0C", "action": "#703093", "actionInk": "#F7EEFF",
            "signal": "#36FF84", "focus": "#36FF84", "inputLine": "#716C88",
        ],
        "background": [
            "style": "field", "intensity": 1, "motion": true, "speed": 1,
            "colors": ["#B97EDE", "#36FF84", "#FFD166", "#D1A4EF"], "top": "#06060B", "bottom": "#09080F",
            "vignette": 0.34,
        ],
        "typography": ["display": "anybody", "body": "schibsted-grotesk", "mono": "jetbrains-mono", "scale": 1],
        "shape": ["radiusScale": 1, "borderWidth": 1],
        "effects": ["glass": 1, "glow": 1, "shadow": 1],
    ]
}
