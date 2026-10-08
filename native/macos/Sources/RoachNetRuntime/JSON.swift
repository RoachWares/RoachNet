import Foundation

/// Insertion-ordered JSON value with JavaScript-compatible semantics.
///
/// The RoachNet runtime contract was originally defined by a JavaScript
/// implementation, so values keep key order, `undefined` vs `null`, and the
/// truthiness/number coercion rules the desktop app and iOS companion rely on.
public enum JSON: Equatable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// Ordered string-keyed map used for JSON objects.
public struct JSONObject: Equatable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON {
        get { storage[key] ?? .undefined }
        set {
            if storage[key] == nil { keys.append(key) }
            storage[key] = newValue
        }
    }

    public func has(_ key: String) -> Bool { storage[key] != nil }

    public mutating func remove(_ key: String) {
        guard storage.removeValue(forKey: key) != nil else { return }
        keys.removeAll { $0 == key }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [JSON] { keys.map { storage[$0]! } }

    public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, storage[key]!)
        }
    }

    /// `{ ...self, ...other }`
    public func merging(_ other: JSONObject) -> JSONObject {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.storage == rhs.storage
    }
}

// MARK: - Literals

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByStringInterpolation
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Conversions

extension JSON {
    public init(_ value: String) { self = .string(value) }
    public init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
    public init(_ value: Int64) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: Double?) { self = value.map { .number($0) } ?? .null }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: [JSON]) { self = .array(value) }
    public init(_ value: [String]) { self = .array(value.map { .string($0) }) }
    public init(_ value: JSONObject) { self = .object(value) }

    public var isUndefined: Bool { if case .undefined = self { return true }; return false }
    public var isNull: Bool { if case .null = self { return true }; return false }
    /// `value === null || value === undefined`
    public var isNullish: Bool {
        switch self {
        case .undefined, .null: return true
        default: return false
        }
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var arrayValue: [JSON]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: JSONObject? { if case .object(let value) = self { return value }; return nil }
    public var isArray: Bool { arrayValue != nil }
    public var isObject: Bool { objectValue != nil }

    /// `Array.isArray(v) ? v : []`
    public var array: [JSON] { arrayValue ?? [] }
    /// Object view, or an empty object for non-objects.
    public var object: JSONObject { objectValue ?? JSONObject() }

    /// JavaScript truthiness.
    public var truthy: Bool {
        switch self {
        case .undefined, .null: return false
        case .bool(let value): return value
        case .number(let value): return value != 0 && !value.isNaN
        case .string(let value): return !value.isEmpty
        case .array, .object: return true
        }
    }

    /// Property access that mirrors `value?.key` (undefined when absent).
    public subscript(key: String) -> JSON {
        get {
            if case .object(let object) = self { return object[key] }
            return .undefined
        }
        set {
            if case .object(var object) = self {
                object[key] = newValue
                self = .object(object)
            } else if case .undefined = self {
                var object = JSONObject()
                object[key] = newValue
                self = .object(object)
            }
        }
    }

    public subscript(index: Int) -> JSON {
        if case .array(let values) = self, index >= 0, index < values.count { return values[index] }
        return .undefined
    }

    /// `{ ...self, ...other }` for objects.
    public func merging(_ other: JSON) -> JSON {
        .object(object.merging(other.object))
    }
}

// MARK: - JavaScript operators

/// `lhs || rhs` with JavaScript truthiness.
public func || (lhs: JSON, rhs: @autoclosure () -> JSON) -> JSON {
    lhs.truthy ? lhs : rhs()
}

/// `lhs ?? rhs` with JavaScript nullish semantics.
public func ?? (lhs: JSON, rhs: @autoclosure () -> JSON) -> JSON {
    lhs.isNullish ? rhs() : lhs
}

// MARK: - JavaScript coercion

extension JSON {
    /// `Number(value)`
    public var jsNumber: Double {
        switch self {
        case .undefined: return .nan
        case .null: return 0
        case .bool(let value): return value ? 1 : 0
        case .number(let value): return value
        case .string(let value): return JSCoercion.number(fromString: value)
        case .array(let values):
            if values.isEmpty { return 0 }
            if values.count == 1 { return JSCoercion.number(fromString: values[0].jsString) }
            return .nan
        case .object: return .nan
        }
    }

    /// `String(value)`
    public var jsString: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return JSCoercion.format(number: value)
        case .string(let value): return value
        case .array(let values):
            return values.map { $0.isNullish ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// `Boolean(value)`
    public var jsBool: Bool { truthy }
}

public enum JSCoercion {
    public static func number(fromString raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("0x"), let value = UInt64(trimmed.dropFirst(2), radix: 16) { return Double(value) }
        if lower.hasPrefix("0o"), let value = UInt64(trimmed.dropFirst(2), radix: 8) { return Double(value) }
        if lower.hasPrefix("0b"), let value = UInt64(trimmed.dropFirst(2), radix: 2) { return Double(value) }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        // Reject forms Swift accepts but JS does not (nan, inf, hex floats).
        let allowed = CharacterSet(charactersIn: "0123456789+-.eE")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) { return .nan }
        return Double(trimmed) ?? .nan
    }

    /// `Number.prototype.toString()` formatting.
    public static func format(number value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e21 {
            if abs(value) < 9.007_199_254_740_992e15 { return String(Int64(value)) }
            return String(format: "%.0f", value)
        }
        // Use Swift's shortest round-trip digits, then lay them out like JS.
        let negative = value < 0
        let description = String(abs(value))
        var digits = ""
        var exponent = 0
        var mantissa = description
        if let eIndex = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(description[..<eIndex])
            exponent = Int(description[description.index(after: eIndex)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = String(parts[0])
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        digits = integerPart + fractionPart
        var pointPosition = integerPart.count + exponent
        // Strip leading zeros.
        while digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
            pointPosition -= 1
        }
        while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let n = pointPosition
        var result: String
        if k <= n && n <= 21 {
            result = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let index = digits.index(digits.startIndex, offsetBy: n)
            result = String(digits[..<index]) + "." + String(digits[index...])
        } else if -6 < n && n <= 0 {
            result = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e >= 0 ? "+" : "-"
            if k == 1 {
                result = "\(digits)e\(sign)\(abs(e))"
            } else {
                let first = digits.prefix(1)
                let rest = digits.dropFirst()
                result = "\(first).\(rest)e\(sign)\(abs(e))"
            }
        }
        return negative ? "-" + result : result
    }

    public static func isSafeInteger(_ value: Double) -> Bool {
        value.isFinite && value == value.rounded(.towardZero) && abs(value) <= 9_007_199_254_740_991
    }
}

// MARK: - Serialization

extension JSON {
    /// `JSON.stringify(value)`
    public func serialized() -> String {
        var output = ""
        JSONWriter.write(self, into: &output, indent: nil, level: 0)
        return output
    }

    /// `JSON.stringify(value, null, 2)`
    public func prettySerialized() -> String {
        var output = ""
        JSONWriter.write(self, into: &output, indent: "  ", level: 0)
        return output
    }

    public func serializedData() -> Data { Data(serialized().utf8) }
}

enum JSONWriter {
    static func write(_ value: JSON, into output: inout String, indent: String?, level: Int) {
        switch value {
        case .undefined, .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .number(let number):
            output += number.isFinite ? JSCoercion.format(number: number) : "null"
        case .string(let string):
            writeString(string, into: &output)
        case .array(let values):
            if values.isEmpty {
                output += "[]"
                return
            }
            output += "["
            for (index, element) in values.enumerated() {
                if index > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                write(element.isUndefined ? .null : element, into: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "]"
        case .object(let object):
            let entries = object.filter { !$0.value.isUndefined }
            if entries.isEmpty {
                output += "{}"
                return
            }
            output += "{"
            for (index, entry) in entries.enumerated() {
                if index > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                writeString(entry.key, into: &output)
                output += indent == nil ? ":" : ": "
                write(entry.value, into: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "}"
        }
    }

    private static func newline(_ output: inout String, indent: String?, level: Int) {
        guard let indent else { return }
        output += "\n"
        output += String(repeating: indent, count: level)
    }

    static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

extension JSON {
    /// `JSON.parse(text)`
    public static func parse(_ text: String) throws -> JSON {
        var parser = JSONParser(Array(text.utf8))
        return try parser.parseDocument()
    }

    public static func parse(_ data: Data) throws -> JSON {
        var parser = JSONParser(Array(data))
        return try parser.parseDocument()
    }

    /// Reads and parses a JSON file, returning nil when absent or invalid.
    public static func read(contentsOf path: String) -> JSON? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? parse(data)
    }
}

struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        var bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSON {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected trailing content") }
        return value
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(message: "\(message) at offset \(index)")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func parseValue(depth: Int) throws -> JSON {
        guard depth < 512 else { throw error("JSON nesting too deep") }
        guard index < bytes.count else { throw error("Unexpected end of JSON input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)]) == literalBytes
        else { throw error("Unexpected token") }
        index += literalBytes.count
    }

    private mutating func parseObject(depth: Int) throws -> JSON {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected property name") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw error("Unexpected end of JSON input") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            throw error("Expected ',' or '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSON {
        index += 1
        var values: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("Unexpected end of JSON input") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            throw error("Expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var buffer: [UInt8] = []
        func flush() throws {
            if buffer.isEmpty { return }
            guard let decoded = String(bytes: buffer, encoding: .utf8) else { throw error("Invalid UTF-8 in string") }
            scalars.append(contentsOf: decoded.unicodeScalars)
            buffer.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                try flush()
                return String(scalars)
            }
            if byte == UInt8(ascii: "\\") {
                try flush()
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let high = try parseHex4()
                    if (0xD800...0xDBFF).contains(high) {
                        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                                scalars.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                            } else {
                                scalars.append("\u{FFFD}")
                                scalars.append(Unicode.Scalar(low) ?? "\u{FFFD}")
                            }
                        } else {
                            scalars.append("\u{FFFD}")
                        }
                    } else if (0xDC00...0xDFFF).contains(high) {
                        scalars.append("\u{FFFD}")
                    } else {
                        scalars.append(Unicode.Scalar(high) ?? "\u{FFFD}")
                    }
                default:
                    throw error("Bad escaped character")
                }
                continue
            }
            if byte < 0x20 { throw error("Bad control character in string literal") }
            buffer.append(byte)
            index += 1
        }
        throw error("Unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let text = String(bytes: bytes[index..<(index + 4)], encoding: .ascii),
              let value = UInt32(text, radix: 16)
        else { throw error("Bad Unicode escape") }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
            throw error("Unexpected token")
        }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                throw error("Unterminated fractional number")
            }
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                throw error("Exponent part is missing a number")
            }
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(text) else { throw error("Invalid number") }
        return value
    }
}
