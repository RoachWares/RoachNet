import Foundation

public enum OllamaCloudModel {
    public static func matches(_ name: String) -> Bool {
        guard let colon = name.lastIndex(of: ":") else { return false }
        let tag = name[name.index(after: colon)...].lowercased()
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }
}
