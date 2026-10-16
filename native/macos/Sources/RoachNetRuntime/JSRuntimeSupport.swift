import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Strings

public enum JS {
    /// `compactString(value, fallback, maxLength)` from the runtime contract:
    /// `String(value ?? fallback).replace(/\s+/g, ' ').trim().slice(0, maxLength)`
    public static func compactString(_ value: JSON, _ fallback: String = "", _ maxLength: Int = 512) -> String {
        let raw = value.isNullish ? fallback : value.jsString
        return slice(collapseWhitespace(raw).trimmingCharacters(in: .whitespacesAndNewlines), maxLength)
    }

    public static func compactString(_ value: String?, _ fallback: String = "", _ maxLength: Int = 512) -> String {
        compactString(JSON(value), fallback, maxLength)
    }

    /// `compactStringList(value, maxItems)`
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

    /// `.replace(/\s+/g, ' ')`
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

    /// `String.prototype.slice(0, length)` measured in UTF-16 code units.
    public static func slice(_ value: String, _ length: Int) -> String {
        guard length >= 0 else { return "" }
        let utf16 = value.utf16
        guard utf16.count > length else { return value }
        var end = utf16.index(utf16.startIndex, offsetBy: length)
        // Avoid splitting a surrogate pair.
        if end > utf16.startIndex {
            let previous = utf16[utf16.index(before: end)]
            if UTF16.isLeadSurrogate(previous) { end = utf16.index(before: end) }
        }
        return String(utf16[..<end]) ?? String(value.prefix(length))
    }

    /// `value.slice(-length)` in UTF-16 units.
    public static func sliceTail(_ value: String, _ length: Int) -> String {
        let utf16 = value.utf16
        guard utf16.count > length else { return value }
        var start = utf16.index(utf16.endIndex, offsetBy: -length)
        if UTF16.isTrailSurrogate(utf16[start]) { start = utf16.index(after: start) }
        return String(utf16[start...]) ?? String(value.suffix(length))
    }

    public static func randomUUID() -> String { UUID().uuidString.lowercased() }

    /// `randomUUID().replaceAll('-', '').slice(0, length)`
    public static func randomHex(_ length: Int) -> String {
        String(randomUUID().replacingOccurrences(of: "-", with: "").prefix(length))
    }

    // MARK: Dates

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let isoLock = NSLock()

    /// `new Date().toISOString()`
    public static func isoNow() -> String { iso(Date()) }

    public static func iso(_ date: Date) -> String {
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoFormatter.string(from: date)
    }

    /// `Date.parse(value)` for ISO-8601 strings, in milliseconds.
    public static func parseDate(_ value: String) -> Double? {
        isoLock.lock()
        defer { isoLock.unlock() }
        if let date = isoFormatter.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        return nil
    }

    /// `Date.now()`
    public static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

    /// `Number.isSafeInteger(Number(value))`
    public static func isSafeInteger(_ value: JSON) -> Bool { JSCoercion.isSafeInteger(value.jsNumber) }

    /// `Number.isFinite(Number(value))`
    public static func isFinite(_ value: JSON) -> Bool { value.jsNumber.isFinite }

    /// `Math.round` (rounds half toward +Infinity).
    public static func round(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// `Math.trunc(Number(value))`, NaN-propagating.
    public static func trunc(_ value: Double) -> Double { value.rounded(.towardZero) }

    /// `Math.max(a, Math.min(b, x))` with NaN propagation like JS.
    public static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        if value.isNaN { return .nan }
        return Swift.max(low, Swift.min(high, value))
    }

    // MARK: Collation

    /// Deterministic approximation of `a.localeCompare(b)` under the ICU root
    /// collation for the ASCII names RoachNet sorts (tool ids, folder names).
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
            let aLower = isLowercase(a), bLower = isLowercase(b)
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

    // MARK: Regex

    public static func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func replace(_ pattern: String, in text: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

// MARK: - Encoding

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

// MARK: - Paths (POSIX semantics of node:path)

public enum Path {
    public static func hasNamePrefix(_ name: String, _ prefix: String, ignoringCase: Bool = false) -> Bool {
        #if canImport(Darwin)
        func key(_ value: String) -> String.UnicodeScalarView {
            let decomposed = value.decomposedStringWithCanonicalMapping
            guard ignoringCase else { return decomposed.unicodeScalars }
            return decomposed.folding(options: [.caseInsensitive], locale: nil).decomposedStringWithCanonicalMapping.unicodeScalars
        }
        return key(name).starts(with: key(prefix))
        #else
        return name.unicodeScalars.starts(with: prefix.unicodeScalars)
        #endif
    }

    public static func normalize(_ path: String) -> String {
        if path.isEmpty { return "." }
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." {
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
        if path.hasSuffix("/"), result != "/" { result += "/" }
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
            if component.hasPrefix("/") { break }
        }
        if !resolved.hasPrefix("/") {
            resolved = FileManager.default.currentDirectoryPath + (resolved.isEmpty ? "" : "/" + resolved)
        }
        var normalized = normalize(resolved)
        if normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    public static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

    public static func dirname(_ path: String) -> String {
        if path.isEmpty { return "." }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        if slash == trimmed.startIndex { return "/" }
        var parent = String(trimmed[..<slash])
        while parent.count > 1, parent.hasSuffix("/") { parent.removeLast() }
        return parent
    }

    public static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return "" }
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    public static func relative(from: String, to: String) -> String {
        let fromParts = resolve(from).split(separator: "/")
        let toParts = resolve(to).split(separator: "/")
        var common = 0
        while common < fromParts.count, common < toParts.count, fromParts[common] == toParts[common] { common += 1 }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        let downs = toParts[common...].map(String.init)
        return (ups + downs).joined(separator: "/")
    }

    /// `normalizePath(value, fallback)`: trims, expands `~`, and resolves.
    public static func normalizeUserPath(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        var expanded = trimmed
        if expanded == "~" {
            expanded = Host.homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = Host.homeDirectory + String(expanded.dropFirst())
        }
        return resolve(expanded)
    }
}

// MARK: - Host facts

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

// MARK: - IP helpers

public enum IPAddress {
    /// `net.isIP(value)` → 0, 4, or 6.
    public static func version(_ value: String) -> Int {
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            // inet_pton accepts only dotted quads; matches net.isIP.
            return 4
        }
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return 6 }
        return 0
    }
}
