import Foundation

public enum PromptPath {
    public static func named(_ path: String, storagePath: String, home: String = NSHomeDirectory()) -> String {
        let target = standardized(path)
        if let rest = remainder(of: target, under: standardized(home)) {
            return rest.isEmpty ? "~" : "~/" + rest
        }
        if let rest = remainder(of: target, under: standardized(storagePath)) {
            return rest.isEmpty ? "RoachNet storage" : "RoachNet storage/" + rest
        }
        return URL(fileURLWithPath: target).lastPathComponent
    }

    private static func standardized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let resolved = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    private static func remainder(of path: String, under root: String) -> String? {
        guard !root.isEmpty, root != "/" else { return nil }
        let scalars = Array(path.unicodeScalars)
        let base = Array(root.unicodeScalars)
        if scalars == base { return "" }
        guard scalars.count > base.count, scalars.starts(with: base), scalars[base.count] == "/" else { return nil }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[(base.count + 1)...])
        return String(rest)
    }
}
