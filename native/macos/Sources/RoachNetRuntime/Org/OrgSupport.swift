import Foundation

enum HMACSHA256 {
    static func mac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let blockSize = 64
        var keyBlock = key
        if keyBlock.count > blockSize {
            var digest = SHA256Digest()
            digest.update(keyBlock)
            keyBlock = digest.finalizeBytes()
        }
        keyBlock += [UInt8](repeating: 0, count: blockSize - keyBlock.count)
        var inner = SHA256Digest()
        inner.update(keyBlock.map { $0 ^ 0x36 })
        inner.update(message)
        var outer = SHA256Digest()
        outer.update(keyBlock.map { $0 ^ 0x5c })
        outer.update(inner.finalizeBytes())
        return outer.finalizeBytes()
    }

    static func hex(key: String, message: String) -> String {
        Encoding.hex(mac(key: Array(key.utf8), message: Array(message.utf8)))
    }
}

func orgConstantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for index in 0..<a.count { diff |= a[index] ^ b[index] }
    return diff == 0
}

struct OrgActor {
    enum Kind: String { case owner, user, agent, system }
    var kind: Kind
    var userId: String?
    var agentId: String?
    var companyId: String?
    var runId: String?
    var source: String

    static let system = OrgActor(kind: .system, userId: nil, agentId: nil, companyId: nil, runId: nil, source: "system")

    var isOwner: Bool { kind == .owner || kind == .system }
    var actorType: String {
        switch kind {
        case .owner, .user: return "user"
        case .agent: return "agent"
        case .system: return "system"
        }
    }
    var actorId: String? { kind == .agent ? agentId : userId }
    var json: JSON {
        [
            "kind": JSON(kind.rawValue), "userId": JSON(userId), "agentId": JSON(agentId),
            "companyId": JSON(companyId), "runId": JSON(runId), "source": JSON(source),
        ]
    }
}

enum OrgIDs {
    static func make(_ prefix: String) -> String { "\(prefix)_\(JS.randomHex(20))" }
    static func slug(_ value: String, fallback: String = "item") -> String {
        var output = ""
        var lastDash = false
        for scalar in value.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !output.isEmpty {
                output += "-"
                lastDash = true
            }
        }
        while output.hasSuffix("-") { output.removeLast() }
        let trimmed = String(output.prefix(48))
        return trimmed.isEmpty ? fallback : trimmed
    }
    static func issuePrefix(_ name: String) -> String {
        let letters = name.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) }
        let prefix = String(String.UnicodeScalarView(letters.prefix(4)))
        return prefix.isEmpty ? "ORG" : prefix
    }
}

enum OrgLimits {
    static let maxExactInteger = 9_007_199_254_740_992.0
    static let maxAmount = 1_000_000_000_000
}

extension Int {
    func orgAdding(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    func orgMultiplied(by other: Int) -> Int {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) == (other < 0) ? .max : .min) : product
    }
}

struct OrgBody {
    let raw: JSON
    init(_ raw: JSON) { self.raw = raw }

    func has(_ key: String) -> Bool { !raw[key].isUndefined }
    func string(_ key: String, max: Int = 512) -> String? {
        guard let value = raw[key].stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(max))
    }
    func text(_ key: String, max: Int = 200_000) -> String? {
        guard let value = raw[key].stringValue else { return nil }
        return String(value.prefix(max))
    }
    func required(_ key: String, max: Int = 512) throws -> String {
        guard let value = string(key, max: max) else { throw requestError("\(key) is required.") }
        return value
    }
    func nullable(_ key: String, max: Int = 512) -> String?? {
        let value = raw[key]
        if value.isUndefined { return nil }
        if value.isNull { return .some(nil) }
        return .some(string(key, max: max))
    }
    func int(_ key: String) -> Int? {
        guard let number = raw[key].numberValue, number.isFinite, abs(number) <= OrgLimits.maxExactInteger else {
            return nil
        }
        return Int(number.rounded(.towardZero))
    }
    func amount(_ key: String) -> Int? {
        int(key).map { min(max(0, $0), OrgLimits.maxAmount) }
    }
    func bool(_ key: String) -> Bool? { raw[key].boolValue }
    func strings(_ key: String, maxItems: Int = 64) -> [String]? {
        guard let array = raw[key].arrayValue else { return nil }
        return Array(
            array.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .prefix(maxItems))
    }
    func oneOf(_ key: String, _ allowed: Set<String>) throws -> String? {
        guard let value = string(key) else { return nil }
        guard allowed.contains(value) else {
            throw requestError("\(key) must be one of: \(allowed.sorted().joined(separator: ", ")).", 422)
        }
        return value
    }
}

func orgQuery(_ raw: String?) -> [String: String] {
    guard let raw, !raw.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for pair in raw.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
        let value =
            parts.count > 1
            ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1]))
            : ""
        result[key] = value
    }
    return result
}

func orgNotFound(_ what: String) -> RuntimeError { requestError("\(what) not found.", 404) }
func orgForbidden(_ why: String = "You do not have permission to do that.") -> RuntimeError { requestError(why, 403) }
func orgConflict(_ why: String) -> RuntimeError { requestError(why, 409) }
func orgInvalid(_ why: String) -> RuntimeError { requestError(why, 422) }
func orgUnavailable(_ why: String) -> RuntimeError { requestError(why, 503) }

extension Array {
    mutating func orgCap(_ limit: Int) {
        if count > limit { removeFirst(count - limit) }
    }
}

func orgMonthStart(_ date: Date = Date()) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month], from: date)
    return JS.iso(calendar.date(from: parts) ?? date)
}
