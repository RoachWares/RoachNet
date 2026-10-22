import Foundation

public enum RoachJSON: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RoachJSON])
    case object([String: RoachJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RoachJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RoachJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> RoachJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> RoachJSON? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var number: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [RoachJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: RoachJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public func merged(with patch: RoachJSON?) -> RoachJSON {
        guard let patch else { return self }
        guard case .object(var base) = self, case .object(let over) = patch else { return patch }
        for (key, value) in over {
            base[key] = base[key].map { $0.merged(with: value) } ?? value
        }
        return .object(base)
    }

    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }
}
