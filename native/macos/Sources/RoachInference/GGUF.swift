import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum InferenceError: Error, CustomStringConvertible, Equatable {
    case cannotOpen(String)
    case notGGUF
    case unsupportedVersion(UInt32)
    case truncated
    case unsupportedTensorType(UInt32, String)
    case missingKey(String)
    case missingTensor(String)
    case unsupportedArchitecture(String)
    case invalid(String)
    case cancelled

    public var description: String {
        switch self {
        case .cannotOpen(let path): return "Could not open model file \(path)."
        case .notGGUF: return "The file is not a GGUF model."
        case .unsupportedVersion(let version): return "GGUF version \(version) is not supported."
        case .truncated: return "The model file is truncated."
        case .unsupportedTensorType(let type, let name): return "Tensor \(name) uses unsupported type \(type)."
        case .missingKey(let key): return "The model is missing metadata \(key)."
        case .missingTensor(let name): return "The model is missing tensor \(name)."
        case .unsupportedArchitecture(let arch): return "Model architecture \(arch) is not supported yet."
        case .invalid(let message): return message
        case .cancelled: return "Generation was cancelled."
        }
    }
}

/// A GGUF metadata value.
public enum GGUFValue: Equatable {
    case uint(UInt64)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case array([GGUFValue])

    public var intValue: Int? {
        switch self {
        case .uint(let value): return Int(exactly: value)
        case .int(let value): return Int(exactly: value)
        case .float(let value): return Int(exactly: value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .uint(let value): return Double(value)
        case .int(let value): return Double(value)
        case .float(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .uint(let value): return value != 0
        case .int(let value): return value != 0
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [GGUFValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

public struct GGUFTensorInfo {
    public let name: String
    /// Dimensions with the fastest-varying first (ggml `ne` order).
    public let shape: [Int]
    public let type: GGMLType
    /// Byte offset relative to the start of the tensor data section.
    public let offset: Int

    public var elementCount: Int { shape.reduce(1, *) }
    /// Elements in one contiguous row (`ne0`).
    public var rowLength: Int { shape.first ?? 0 }
    public var rowCount: Int { elementCount / max(rowLength, 1) }
    public var rowBytes: Int { type.rowBytes(rowLength) }
    public var byteCount: Int { rowBytes * rowCount }
}

/// Read-only, memory-mapped GGUF model file (versions 2 and 3).
public final class GGUFFile {
    public let path: String
    public let version: UInt32
    public let metadata: [String: GGUFValue]
    public let tensors: [String: GGUFTensorInfo]
    public let tensorNames: [String]
    public let alignment: Int
    public let fileSize: Int
    let base: UnsafeRawPointer
    let dataOffset: Int

    public init(path: String) throws {
        self.path = path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw InferenceError.cannotOpen(path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 24 else { throw InferenceError.cannotOpen(path) }
        let size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else {
            throw InferenceError.cannotOpen(path)
        }
        self.fileSize = size
        self.base = UnsafeRawPointer(mapped)

        var reader = GGUFReader(base: UnsafeRawPointer(mapped), length: size)
        do {
            guard try reader.u32() == 0x4655_4747 else { throw InferenceError.notGGUF }
            let version = try reader.u32()
            guard version == 2 || version == 3 else { throw InferenceError.unsupportedVersion(version) }
            self.version = version
            let tensorCount = Int(try reader.u64())
            let kvCount = Int(try reader.u64())
            guard tensorCount < 1_000_000, kvCount < 1_000_000 else { throw InferenceError.invalid("Implausible GGUF header counts.") }

            var metadata: [String: GGUFValue] = [:]
            for _ in 0..<kvCount {
                let key = try reader.string()
                let type = try reader.u32()
                metadata[key] = try reader.value(type: type)
            }
            self.metadata = metadata
            let alignment = metadata["general.alignment"]?.intValue ?? 32
            guard alignment > 0, alignment & (alignment - 1) == 0 else { throw InferenceError.invalid("Invalid GGUF alignment.") }
            self.alignment = alignment

            var tensors: [String: GGUFTensorInfo] = [:]
            var names: [String] = []
            names.reserveCapacity(tensorCount)
            for _ in 0..<tensorCount {
                let name = try reader.string()
                let dims = Int(try reader.u32())
                guard dims >= 1, dims <= 4 else { throw InferenceError.invalid("Tensor \(name) has \(dims) dimensions.") }
                var shape: [Int] = []
                for _ in 0..<dims { shape.append(Int(try reader.u64())) }
                let rawType = try reader.u32()
                guard let type = GGMLType(rawValue: rawType) else { throw InferenceError.unsupportedTensorType(rawType, name) }
                let offset = Int(try reader.u64())
                guard shape[0] % type.blockSize == 0 else {
                    throw InferenceError.invalid("Tensor \(name) row length \(shape[0]) is not a multiple of its block size.")
                }
                tensors[name] = GGUFTensorInfo(name: name, shape: shape, type: type, offset: offset)
                names.append(name)
            }
            self.tensors = tensors
            self.tensorNames = names
            let dataOffset = (reader.offset + alignment - 1) / alignment * alignment
            self.dataOffset = dataOffset
            for tensor in tensors.values where dataOffset + tensor.offset + tensor.byteCount > size {
                throw InferenceError.truncated
            }
        } catch {
            munmap(mapped, size)
            throw error
        }
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), fileSize)
    }

    public func pointer(to tensor: GGUFTensorInfo) -> UnsafeRawPointer {
        base + dataOffset + tensor.offset
    }

    public func tensor(_ name: String) throws -> GGUFTensorInfo {
        guard let tensor = tensors[name] else { throw InferenceError.missingTensor(name) }
        return tensor
    }

    public subscript(key: String) -> GGUFValue? { metadata[key] }

    public var architecture: String { metadata["general.architecture"]?.stringValue ?? "unknown" }
    public var modelName: String? { metadata["general.name"]?.stringValue }
}

struct GGUFReader {
    let base: UnsafeRawPointer
    let length: Int
    var offset = 0

    init(base: UnsafeRawPointer, length: Int) {
        self.base = base
        self.length = length
    }

    @inline(__always)
    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= length else { throw InferenceError.truncated }
        let value = base.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += size
        return T(littleEndian: value)
    }

    mutating func u32() throws -> UInt32 { try read(UInt32.self) }
    mutating func u64() throws -> UInt64 { try read(UInt64.self) }

    mutating func string() throws -> String {
        let count = Int(try u64())
        guard count >= 0, offset + count <= length else { throw InferenceError.truncated }
        let buffer = UnsafeRawBufferPointer(start: base + offset, count: count)
        offset += count
        return String(decoding: buffer, as: UTF8.self)
    }

    mutating func value(type: UInt32) throws -> GGUFValue {
        switch type {
        case 0: return .uint(UInt64(try read(UInt8.self)))
        case 1: return .int(Int64(try read(Int8.self)))
        case 2: return .uint(UInt64(try read(UInt16.self)))
        case 3: return .int(Int64(try read(Int16.self)))
        case 4: return .uint(UInt64(try read(UInt32.self)))
        case 5: return .int(Int64(try read(Int32.self)))
        case 6: return .float(Double(Float(bitPattern: try read(UInt32.self))))
        case 7: return .bool(try read(UInt8.self) != 0)
        case 8: return .string(try string())
        case 9:
            let elementType = try u32()
            let count = Int(try u64())
            guard count >= 0, count <= length else { throw InferenceError.truncated }
            var values: [GGUFValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try value(type: elementType)) }
            return .array(values)
        case 10: return .uint(try u64())
        case 11: return .int(Int64(bitPattern: try u64()))
        case 12: return .float(Double(bitPattern: try u64()))
        default: throw InferenceError.invalid("Unknown GGUF metadata type \(type).")
        }
    }
}
