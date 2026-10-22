import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum JS {
    public static func compactString(_ value: JSON, _ fallback: String = "", _ maxLength: Int = 512) -> String {
        let raw = value.isNullish ? fallback : value.jsString
        return slice(collapseWhitespace(raw).trimmingCharacters(in: .whitespacesAndNewlines), maxLength)
    }

    public static func compactString(_ value: String?, _ fallback: String = "", _ maxLength: Int = 512) -> String {
        compactString(JSON(value), fallback, maxLength)
    }

    public static func compactStringList(_ value: JSON, _ maxItems: Int = 12) -> [String] {
        let source: [JSON]
        if let array = value.arrayValue {
            source = array
        } else {
            let text = value.truthy ? value.jsString : ""
            source = text.components(separatedBy: ",").map { JSON.string($0) }
        }
        return Array(source.map { compactString($0, "", 80) }.filter { !$0.isEmpty }.prefix(maxItems))
    }

    public static func collapseWhitespace(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var inWhitespace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{FEFF}" {
                if !inWhitespace { result.unicodeScalars.append(" ") }
                inWhitespace = true
            } else {
                result.unicodeScalars.append(scalar)
                inWhitespace = false
            }
        }
        return result
    }

    public static func slice(_ value: String, _ length: Int) -> String {
        guard length >= 0 else { return "" }
        let utf16 = value.utf16
        guard utf16.count > length else { return value }
        var end = utf16.index(utf16.startIndex, offsetBy: length)
        if end > utf16.startIndex {
            let previous = utf16[utf16.index(before: end)]
            if UTF16.isLeadSurrogate(previous) { end = utf16.index(before: end) }
        }
        return String(utf16[..<end]) ?? String(value.prefix(length))
    }

    public static func sliceTail(_ value: String, _ length: Int) -> String {
        let utf16 = value.utf16
        guard utf16.count > length else { return value }
        var start = utf16.index(utf16.endIndex, offsetBy: -length)
        if UTF16.isTrailSurrogate(utf16[start]) { start = utf16.index(after: start) }
        return String(utf16[start...]) ?? String(value.suffix(length))
    }

    public static func randomUUID() -> String { UUID().uuidString.lowercased() }

    public static func randomHex(_ length: Int) -> String {
        guard length > 0 else { return "" }
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        while bytes.count < length {
            let word = generator.next() as UInt64
            for shift in stride(from: 0, to: 64, by: 4) where bytes.count < length {
                bytes.append(digits[Int((word >> UInt64(shift)) & 0xF)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let isoLock = NSLock()

    public static func isoNow() -> String { iso(Date()) }

    public static func iso(_ date: Date) -> String {
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoFormatter.string(from: date)
    }

    public static func parseDate(_ value: String) -> Double? {
        isoLock.lock()
        defer { isoLock.unlock() }
        if let date = isoFormatter.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        return nil
    }

    public static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

    public static func isSafeInteger(_ value: JSON) -> Bool { JSCoercion.isSafeInteger(value.jsNumber) }

    public static func isFinite(_ value: JSON) -> Bool { value.jsNumber.isFinite }

    public static func round(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    public static func trunc(_ value: Double) -> Double { value.rounded(.towardZero) }

    public static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        if value.isNaN { return .nan }
        return Swift.max(low, Swift.min(high, value))
    }

    public static func localeCompare(_ lhs: String, _ rhs: String, baseSensitivity: Bool = false) -> Int {
        let left = Array(lhs.unicodeScalars)
        let right = Array(rhs.unicodeScalars)
        let primaryLeft = left.map(primaryWeight)
        let primaryRight = right.map(primaryWeight)
        if primaryLeft != primaryRight {
            for (a, b) in zip(primaryLeft, primaryRight) where a != b { return a < b ? -1 : 1 }
            return primaryLeft.count < primaryRight.count ? -1 : 1
        }
        if baseSensitivity { return 0 }
        for (a, b) in zip(left, right) where a != b {
            let aLower = isLowercase(a)
            let bLower = isLowercase(b)
            if aLower != bLower { return aLower ? -1 : 1 }
            return a.value < b.value ? -1 : 1
        }
        return 0
    }

    private static let punctuationOrder: [Character] = Array("\t\n\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$")

    private static func primaryWeight(_ scalar: Unicode.Scalar) -> UInt32 {
        let character = Character(scalar)
        if let index = punctuationOrder.firstIndex(of: character) { return UInt32(index) }
        if ("0"..."9").contains(scalar) { return 100 + (scalar.value - 48) }
        if ("a"..."z").contains(scalar) { return 200 + (scalar.value - 97) }
        if ("A"..."Z").contains(scalar) { return 200 + (scalar.value - 65) }
        return 1000 + scalar.value
    }

    private static func isLowercase(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) }

    public static func sortedLocale(_ values: [String]) -> [String] {
        values.sorted { localeCompare($0, $1) < 0 }
    }

    public static func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func replace(_ pattern: String, in text: String, with template: String, caseInsensitive: Bool = false)
        -> String
    {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

public enum Encoding {
    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    public static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum Path {
    public static func hasNamePrefix(_ name: String, _ prefix: String, ignoringCase: Bool = false) -> Bool {
        #if canImport(Darwin)
        func key(_ value: String) -> String.UnicodeScalarView {
            let decomposed = value.decomposedStringWithCanonicalMapping
            guard ignoringCase else { return decomposed.unicodeScalars }
            return decomposed.folding(options: [.caseInsensitive], locale: nil).decomposedStringWithCanonicalMapping
                .unicodeScalars
        }
        return key(name).starts(with: key(prefix))
        #else
        return name.unicodeScalars.starts(with: prefix.unicodeScalars)
        #endif
    }

    public static func fileSystemComponents(_ path: String, omittingEmpty: Bool = true) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: omittingEmpty).map {
            String(String.UnicodeScalarView($0))
        }
    }

    public static func isDotComponent(_ component: String) -> Bool {
        component.unicodeScalars.elementsEqual(".".unicodeScalars) || isDotDotComponent(component)
    }

    public static func isDotDotComponent(_ component: String) -> Bool {
        component.unicodeScalars.elementsEqual("..".unicodeScalars)
    }

    public static func startsWithSlash(_ path: String) -> Bool { path.unicodeScalars.first == "/" }

    public static func endsWithSlash(_ path: String) -> Bool { path.unicodeScalars.last == "/" }

    public static func normalize(_ path: String) -> String {
        if path.isEmpty { return "." }
        let absolute = startsWithSlash(path)
        var parts: [String] = []
        for part in fileSystemComponents(path) {
            if part.unicodeScalars.elementsEqual(".".unicodeScalars) { continue }
            if isDotDotComponent(part) {
                if let last = parts.last, !isDotDotComponent(last) {
                    parts.removeLast()
                } else if !absolute {
                    parts.append(part)
                }
                continue
            }
            parts.append(part)
        }
        var result = parts.joined(separator: "/")
        if absolute { result = "/" + result }
        if result.isEmpty { result = absolute ? "/" : "." }
        if endsWithSlash(path), result != "/" { result += "/" }
        return result
    }

    public static func join(_ components: String...) -> String { join(components) }

    public static func join(_ components: [String]) -> String {
        let filtered = components.filter { !$0.isEmpty }
        if filtered.isEmpty { return "." }
        return normalize(filtered.joined(separator: "/"))
    }

    public static func resolve(_ components: String...) -> String {
        var resolved = ""
        for component in components.reversed() where !component.isEmpty {
            resolved = resolved.isEmpty ? component : component + "/" + resolved
            if startsWithSlash(component) { break }
        }
        if !startsWithSlash(resolved) {
            resolved = FileManager.default.currentDirectoryPath + (resolved.isEmpty ? "" : "/" + resolved)
        }
        var normalized = normalize(resolved)
        if normalized.unicodeScalars.count > 1, endsWithSlash(normalized) { normalized.unicodeScalars.removeLast() }
        return normalized
    }

    public static func isAbsolute(_ path: String) -> Bool { startsWithSlash(path) }

    public static func dirname(_ path: String) -> String {
        if path.isEmpty { return "." }
        var trimmed = Array(path.unicodeScalars)
        while trimmed.count > 1, trimmed.last == "/" { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        if slash == 0 { return "/" }
        var parent = Array(trimmed[..<slash])
        while parent.count > 1, parent.last == "/" { parent.removeLast() }
        return String(String.UnicodeScalarView(parent))
    }

    public static func basename(_ path: String) -> String {
        var trimmed = Array(path.unicodeScalars)
        while trimmed.count > 1, trimmed.last == "/" { trimmed.removeLast() }
        if trimmed == ["/"] { return "" }
        guard let slash = trimmed.lastIndex(of: "/") else { return String(String.UnicodeScalarView(trimmed)) }
        return String(String.UnicodeScalarView(trimmed[(slash + 1)...]))
    }

    public static func relative(from: String, to: String) -> String {
        let fromParts = fileSystemComponents(resolve(from))
        let toParts = fileSystemComponents(resolve(to))
        var common = 0
        while common < fromParts.count, common < toParts.count, fromParts[common] == toParts[common] { common += 1 }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        let downs = Array(toParts[common...])
        return (ups + downs).joined(separator: "/")
    }

    public static func normalizeUserPath(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        var expanded = trimmed
        if expanded == "~" {
            expanded = Host.homeDirectory
        } else if expanded.unicodeScalars.starts(with: "~/".unicodeScalars) {
            expanded = Host.homeDirectory + String(String.UnicodeScalarView(expanded.unicodeScalars.dropFirst()))
        }
        return resolve(expanded)
    }
}

public enum Host {
    public static var homeDirectory: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        return NSHomeDirectory()
    }

    public static var hostname: String {
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let value = String(cString: buffer)
            if !value.isEmpty { return value }
        }
        return ProcessInfo.processInfo.hostName
    }

    public static var platform: String {
        #if os(macOS)
        return "darwin"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }

    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #else
        return "unknown"
        #endif
    }

    public static var isAppleSilicon: Bool { platform == "darwin" && arch == "arm64" }

    public static var pid: Int32 { getpid() }
}

public enum IPAddress {
    public static func version(_ value: String) -> Int {
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return 4
        }
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return 6 }
        return 0
    }

    public static func bytes(_ value: String) -> [UInt8]? {
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}
