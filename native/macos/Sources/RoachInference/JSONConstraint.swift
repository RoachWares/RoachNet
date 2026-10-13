import Foundation

/// Something that decides which text may come next while sampling.
public protocol GenerationConstraint: AnyObject {
    /// Whether `piece` can follow what has been accepted so far.
    func allows(_ piece: String) -> Bool
    /// Records `piece` as generated.
    func accept(_ piece: String)
    /// True once the output is complete; generation stops there.
    var isComplete: Bool { get }
    /// Whether the end of generation may come now.
    var canEnd: Bool { get }
    /// Whether a token that ends partway through a UTF-8 character may come now
    /// (inside free text, such as a JSON string).
    var insideFreeText: Bool { get }
}

/// The part of JSON Schema structured outputs use.
public indirect enum JSONSchemaNode: Equatable {
    case any
    case object(properties: [String: JSONSchemaNode], order: [String], required: Set<String>, additional: Bool)
    case array(items: JSONSchemaNode, minItems: Int, maxItems: Int?)
    case string
    case number(integer: Bool)
    case boolean
    case null
    /// Allowed values, each serialized compactly (`"red"`, `3`, `true`).
    case literals([String])
    /// One of several types. Every branch the output so far fits stays open
    /// until a later character rules it out (two object variants both start with `{`).
    case union([JSONSchemaNode])
}

/// Holds generation to valid JSON, and to a schema when one is given. It works
/// on characters, so it fits any tokenizer: the sampler asks it about each
/// candidate token's text.
public final class JSONConstraint: GenerationConstraint {
    /// Every reading of the output so far that the schema still allows. Usually
    /// one; a union whose branches start alike keeps one per open branch.
    private var states: [State]

    /// The most readings followed at once. Requests are refused when
    /// `mostOpenReadings` of their schema is larger, so the cut in `advance`
    /// is only a last guard and never drops a branch a schema allows.
    public static let maxStates = 64

    /// The most readings `node` can keep open at once, as an upper bound: all
    /// of a union's branches can be open together, so their counts add up,
    /// while an object or array is inside one value at a time, so the largest
    /// count wins. Branches usually part ways within a character or two.
    public static func mostOpenReadings(_ node: JSONSchemaNode) -> Int {
        switch node {
        case .union(let branches):
            return branches.reduce(0) { min($0 + mostOpenReadings($1), Int(Int32.max)) }
        case .object(let properties, _, _, _):
            return properties.values.reduce(1) { max($0, mostOpenReadings($1)) }
        case .array(let items, _, _):
            return mostOpenReadings(items)
        default:
            return 1
        }
    }

    /// `requireObject` is OpenAI's `json_object` and Ollama's `format: "json"`.
    public init(schema: JSONSchemaNode? = nil, requireObject: Bool = false) {
        let root: JSONSchemaNode
        if let schema { root = schema } else if requireObject {
            root = .object(properties: [:], order: [], required: [], additional: true)
        } else { root = .any }
        states = [State(stack: [.value(root)])]
    }

    public var isComplete: Bool { states.contains { $0.complete } }

    public var insideFreeText: Bool {
        states.contains { state in
            if case .string(_, _, let options, _) = state.stack.last { return options == nil }
            return false
        }
    }

    public func allows(_ piece: String) -> Bool {
        var current = states
        for character in piece.unicodeScalars {
            current = Self.advance(current, character)
            if current.isEmpty { return false }
        }
        return true
    }

    public func accept(_ piece: String) {
        for character in piece.unicodeScalars {
            let next = Self.advance(states, character)
            if next.isEmpty { break }
            states = next
        }
    }

    /// The readings `c` leads to: each state that takes it, plus the branches a union opened.
    static func advance(_ states: [State], _ c: Unicode.Scalar) -> [State] {
        var next: [State] = []
        for var state in states {
            state.forks = []
            guard state.feed(c) else { continue }
            let opened = state.forks
            state.forks = []
            for candidate in [state] + opened where !next.contains(candidate) {
                next.append(candidate)
                if next.count == maxStates { return next }
            }
        }
        return next
    }

    // MARK: State machine

    enum ObjectPhase: Equatable { case keyOrEnd, key, colon, value, commaOrEnd }
    enum ArrayPhase: Equatable { case valueOrEnd, value, commaOrEnd }

    enum Frame: Equatable {
        /// A value is next; whitespace may come first.
        case value(JSONSchemaNode)
        case object(schema: JSONSchemaNode, used: [String], phase: ObjectPhase, pendingKey: String?)
        case array(items: JSONSchemaNode, count: Int, minItems: Int, maxItems: Int?, phase: ArrayPhase)
        /// Inside a string. `options` limits it to these contents (object keys).
        case string(text: String, escape: Int, options: [String]?, isKey: Bool)
        case number(text: String, integer: Bool)
        /// One of a fixed set of serialized values (enums, true/false/null).
        case literal(text: String, options: [String])
    }

    struct State: Equatable {
        var stack: [Frame]
        var complete = false
        var whitespace = 0
        /// Other readings a union opened while feeding the current character; `advance` collects them.
        var forks: [State] = []

        static let maxWhitespace = 48

        mutating func feed(_ c: Unicode.Scalar) -> Bool {
            if complete {
                // Only a little trailing whitespace once the value is done.
                guard isSpace(c), whitespace < 4 else { return false }
                whitespace += 1
                return true
            }
            guard let top = stack.last else { return false }
            switch top {
            case .value(let schema):
                if isSpace(c) { return space() }
                whitespace = 0
                return begin(c, schema)
            case .object(let schema, let used, let phase, let pendingKey):
                if isSpace(c) { return space() }
                whitespace = 0
                return object(c, schema, used, phase, pendingKey)
            case .array(let items, let count, let minItems, let maxItems, let phase):
                if isSpace(c) { return space() }
                whitespace = 0
                return array(c, items, count, minItems, maxItems, phase)
            case .string(let text, let escape, let options, let isKey):
                return string(c, text, escape, options, isKey)
            case .number(let text, let integer):
                return number(c, text, integer)
            case .literal(let text, let options):
                let next = text + String(c)
                if options.contains(where: { $0.hasPrefix(next) }) {
                    stack[stack.count - 1] = .literal(text: next, options: options)
                    if options.contains(next) && !options.contains(where: { $0 != next && $0.hasPrefix(next) }) { pop() }
                    return true
                }
                // A complete literal that is also a prefix of a longer one (`1` vs `10`) ends here.
                if options.contains(text) {
                    pop()
                    return feed(c)
                }
                return false
            }
        }

        private func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" }

        private mutating func space() -> Bool {
            guard whitespace < State.maxWhitespace else { return false }
            whitespace += 1
            return true
        }

        /// Ends the frame on top; the frame below takes the finished value.
        private mutating func pop() {
            stack.removeLast()
            guard let parent = stack.last else { complete = true; return }
            switch parent {
            case .value:
                // The value frame was the placeholder for what just finished.
                stack.removeLast()
                finishedValue()
            default:
                finishedValue()
            }
        }

        private mutating func finishedValue() {
            guard let parent = stack.last else { complete = true; return }
            switch parent {
            case .object(let schema, let used, .value, let pendingKey):
                stack[stack.count - 1] = .object(schema: schema, used: used + [pendingKey ?? ""], phase: .commaOrEnd, pendingKey: nil)
            case .array(let items, let count, let minItems, let maxItems, .value), .array(let items, let count, let minItems, let maxItems, .valueOrEnd):
                stack[stack.count - 1] = .array(items: items, count: count + 1, minItems: minItems, maxItems: maxItems, phase: .commaOrEnd)
            default:
                break
            }
        }

        private mutating func begin(_ c: Unicode.Scalar, _ schema: JSONSchemaNode) -> Bool {
            switch schema {
            case .union(let options):
                // Every branch that can start with `c` stays open; this state takes the
                // first that does, the rest become forks for `advance` to keep.
                var open: [State] = []
                for option in options where Self.starts(c, option) {
                    var branch = self
                    branch.forks = []
                    guard branch.begin(c, option) else { continue }
                    let nested = branch.forks
                    branch.forks = []
                    open.append(branch)
                    open.append(contentsOf: nested)
                }
                guard let first = open.first else { return false }
                let earlier = forks
                self = first
                forks = earlier + open.dropFirst()
                return true
            case .literals(let options):
                let first = String(c)
                guard options.contains(where: { $0.hasPrefix(first) }) else { return false }
                stack.append(.literal(text: first, options: options))
                if options == [first] { pop() }
                return true
            default:
                break
            }
            switch c {
            case "{":
                guard Self.starts(c, schema) else { return false }
                stack.append(.object(schema: schema, used: [], phase: .keyOrEnd, pendingKey: nil))
                return true
            case "[":
                guard Self.starts(c, schema) else { return false }
                if case .array(let items, let minItems, let maxItems) = schema {
                    stack.append(.array(items: items, count: 0, minItems: minItems, maxItems: maxItems, phase: .valueOrEnd))
                } else {
                    stack.append(.array(items: .any, count: 0, minItems: 0, maxItems: nil, phase: .valueOrEnd))
                }
                return true
            case "\"":
                guard Self.starts(c, schema) else { return false }
                stack.append(.string(text: "", escape: 0, options: nil, isKey: false))
                return true
            case "t", "f":
                guard Self.starts(c, schema) else { return false }
                stack.append(.literal(text: String(c), options: ["true", "false"].filter { $0.hasPrefix(String(c)) }))
                return true
            case "n":
                guard Self.starts(c, schema) else { return false }
                stack.append(.literal(text: "n", options: ["null"]))
                return true
            case "-", "0"..."9":
                guard Self.starts(c, schema) else { return false }
                if case .number(let integer) = schema {
                    stack.append(.number(text: String(c), integer: integer))
                } else {
                    stack.append(.number(text: String(c), integer: false))
                }
                return true
            default:
                return false
            }
        }

        /// Whether a value of `schema` can start with `c`.
        static func starts(_ c: Unicode.Scalar, _ schema: JSONSchemaNode) -> Bool {
            switch schema {
            case .any: return "{[\"tfn-0123456789".unicodeScalars.contains(c)
            case .object: return c == "{"
            case .array: return c == "["
            case .string: return c == "\""
            case .number: return c == "-" || ("0"..."9").contains(c)
            case .boolean: return c == "t" || c == "f"
            case .null: return c == "n"
            case .literals(let options): return options.contains { $0.unicodeScalars.first == c }
            case .union(let options): return options.contains { starts(c, $0) }
            }
        }

        private mutating func object(_ c: Unicode.Scalar, _ schema: JSONSchemaNode, _ used: [String], _ phase: ObjectPhase, _ pendingKey: String?) -> Bool {
            let (properties, required, additional) = Self.objectShape(schema)
            switch phase {
            case .keyOrEnd, .key:
                if c == "}" {
                    guard phase == .keyOrEnd, required.isSubset(of: Set(used)) else { return false }
                    pop()
                    return true
                }
                guard c == "\"" else { return false }
                var options: [String]? = nil
                if !additional { options = properties.filter { !used.contains($0) } }
                if let options, options.isEmpty { return false }
                stack[stack.count - 1] = .object(schema: schema, used: used, phase: .colon, pendingKey: nil)
                stack.append(.string(text: "", escape: 0, options: options, isKey: true))
                return true
            case .colon:
                guard c == ":" else { return false }
                stack[stack.count - 1] = .object(schema: schema, used: used, phase: .value, pendingKey: pendingKey)
                stack.append(.value(Self.propertySchema(schema, pendingKey ?? "")))
                return true
            case .value:
                return false
            case .commaOrEnd:
                if c == "}" {
                    guard required.isSubset(of: Set(used)) else { return false }
                    pop()
                    return true
                }
                guard c == "," else { return false }
                if !additional, properties.allSatisfy({ used.contains($0) }) { return false }
                stack[stack.count - 1] = .object(schema: schema, used: used, phase: .key, pendingKey: nil)
                return true
            }
        }

        static func objectShape(_ schema: JSONSchemaNode) -> (properties: [String], required: Set<String>, additional: Bool) {
            if case .object(let properties, let order, let required, let additional) = schema {
                let names = order.isEmpty ? properties.keys.sorted() : order
                return (names, required, additional || properties.isEmpty)
            }
            return ([], [], true)
        }

        static func propertySchema(_ schema: JSONSchemaNode, _ key: String) -> JSONSchemaNode {
            if case .object(let properties, _, _, _) = schema { return properties[key] ?? .any }
            return .any
        }

        private mutating func array(_ c: Unicode.Scalar, _ items: JSONSchemaNode, _ count: Int, _ minItems: Int, _ maxItems: Int?, _ phase: ArrayPhase) -> Bool {
            switch phase {
            case .valueOrEnd, .value:
                if c == "]" {
                    guard phase == .valueOrEnd, count >= minItems else { return false }
                    pop()
                    return true
                }
                if let maxItems, count >= maxItems { return false }
                guard Self.starts(c, items) else { return false }
                stack[stack.count - 1] = .array(items: items, count: count, minItems: minItems, maxItems: maxItems, phase: .value)
                stack.append(.value(items))
                return feed(c)
            case .commaOrEnd:
                if c == "]" {
                    guard count >= minItems else { return false }
                    pop()
                    return true
                }
                guard c == ",", maxItems.map({ count < $0 }) ?? true else { return false }
                stack[stack.count - 1] = .array(items: items, count: count, minItems: minItems, maxItems: maxItems, phase: .value)
                return true
            }
        }

        private mutating func string(_ c: Unicode.Scalar, _ text: String, _ escape: Int, _ options: [String]?, _ isKey: Bool) -> Bool {
            if escape == 1 {
                let simple: [Unicode.Scalar: Character] = ["\"": "\"", "\\": "\\", "/": "/", "b": "\u{8}", "f": "\u{c}", "n": "\n", "r": "\r", "t": "\t"]
                if c == "u" {
                    stack[stack.count - 1] = .string(text: text, escape: 2, options: options, isKey: isKey)
                    return true
                }
                guard let decoded = simple[c] else { return false }
                return extend(text + String(decoded), escape: 0, options: options, isKey: isKey)
            }
            if escape >= 2 {
                // \uXXXX: four hex digits (counted in escape 2...5).
                guard c.properties.isASCIIHexDigit else { return false }
                if escape == 5 {
                    // The code unit itself isn't decoded; enums and keys rarely need one.
                    return extend(text + "\u{FFFD}", escape: 0, options: options, isKey: isKey)
                }
                stack[stack.count - 1] = .string(text: text, escape: escape + 1, options: options, isKey: isKey)
                return true
            }
            if c == "\\" {
                stack[stack.count - 1] = .string(text: text, escape: 1, options: options, isKey: isKey)
                return true
            }
            if c == "\"" {
                if let options, !options.contains(text) { return false }
                if isKey {
                    stack.removeLast()
                    if case .object(let schema, let used, let phase, _) = stack[stack.count - 1] {
                        stack[stack.count - 1] = .object(schema: schema, used: used, phase: phase, pendingKey: text)
                    }
                    return true
                }
                pop()
                return true
            }
            guard c.value >= 0x20 else { return false }
            return extend(text + String(c), escape: 0, options: options, isKey: isKey)
        }

        private mutating func extend(_ text: String, escape: Int, options: [String]?, isKey: Bool) -> Bool {
            if let options, !options.contains(where: { $0.hasPrefix(text) }) { return false }
            stack[stack.count - 1] = .string(text: text, escape: escape, options: options, isKey: isKey)
            return true
        }

        private mutating func number(_ c: Unicode.Scalar, _ text: String, _ integer: Bool) -> Bool {
            let next = text + String(c)
            if Self.validNumberPrefix(next, integer: integer) {
                stack[stack.count - 1] = .number(text: next, integer: integer)
                return true
            }
            // The number ends at the first character that can't continue it.
            guard Self.completeNumber(text, integer: integer) else { return false }
            pop()
            return feed(c)
        }

        /// JSON number grammar, scanned by hand (this runs for every candidate token).
        /// `prefix` accepts anything that can still grow into a number.
        static func scanNumber(_ s: String, integer: Bool, prefix: Bool) -> Bool {
            var chars = Array(s.unicodeScalars)[...]
            func digit(_ c: Unicode.Scalar?) -> Bool { c.map { ("0"..."9").contains($0) } ?? false }
            if chars.first == "-" { chars = chars.dropFirst() }
            guard let first = chars.first else { return prefix }
            guard digit(first) else { return false }
            if first == "0" {
                chars = chars.dropFirst()
            } else {
                while digit(chars.first) { chars = chars.dropFirst() }
            }
            if chars.isEmpty { return true }
            if integer { return false }
            if chars.first == "." {
                chars = chars.dropFirst()
                guard digit(chars.first) else { return prefix && chars.isEmpty }
                while digit(chars.first) { chars = chars.dropFirst() }
                if chars.isEmpty { return true }
            }
            guard chars.first == "e" || chars.first == "E" else { return false }
            chars = chars.dropFirst()
            if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
            guard digit(chars.first) else { return prefix && chars.isEmpty }
            while digit(chars.first) { chars = chars.dropFirst() }
            return chars.isEmpty
        }

        static func validNumberPrefix(_ s: String, integer: Bool) -> Bool { scanNumber(s, integer: integer, prefix: true) }
        static func completeNumber(_ s: String, integer: Bool) -> Bool { scanNumber(s, integer: integer, prefix: false) }
    }

    /// For the end of generation: a number at the very end is complete if it parses.
    public var canEnd: Bool {
        states.contains { state in
            if state.complete { return true }
            // A top-level number has no closing character, so it can only end with the output.
            if state.stack.count == 2, case .number(let text, let integer) = state.stack[1] { return State.completeNumber(text, integer: integer) }
            // Nor does a top-level value that is one of several fixed values,
            // when it may also go on to a longer one (`1` among `1` and `10`).
            if state.stack.count == 2, case .literal(let text, let options) = state.stack[1] { return options.contains(text) }
            return false
        }
    }
}
