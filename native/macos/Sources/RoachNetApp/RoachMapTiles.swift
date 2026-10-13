import Compression
import CoreGraphics
import Foundation

// A dependency-free reader for the map packs RoachNet installs: PMTiles v3
// archives (https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md)
// holding gzip-compressed Mapbox Vector Tiles. Everything here is plain
// Foundation + Compression so it runs on the app's own threads with no
// renderer, web view or network behind it.

enum RoachMapTileError: LocalizedError, Equatable {
    case notPMTiles
    case unsupportedVersion(Int)
    case unsupportedCompression(Int)
    case truncated(String)
    case corruptDirectory
    case corruptTile(String)

    var errorDescription: String? {
        switch self {
        case .notPMTiles: return "Not a PMTiles archive."
        case .unsupportedVersion(let version): return "PMTiles version \(version) is not supported (needs 3)."
        case .unsupportedCompression(let code): return "Compression type \(code) is not supported."
        case .truncated(let what): return "The map file ends early (\(what))."
        case .corruptDirectory: return "The map file's tile directory is damaged."
        case .corruptTile(let why): return "A map tile could not be read: \(why)."
        }
    }
}

// MARK: - Gzip

enum RoachGzip {
    /// Inflates a gzip member (RFC 1952). Raw data passes through untouched when it is not gzip.
    static func decompress(_ data: Data, sizeHint: Int = 0) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return data }
        guard bytes[2] == 8 else { throw RoachMapTileError.corruptTile("gzip method \(bytes[2])") }
        let flags = bytes[3]
        var cursor = 10
        if flags & 0x04 != 0 {
            guard cursor + 2 <= bytes.count else { throw RoachMapTileError.truncated("gzip extra") }
            cursor += 2 + Int(bytes[cursor]) + Int(bytes[cursor + 1]) << 8
        }
        if flags & 0x08 != 0 { while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }; cursor += 1 }
        if flags & 0x10 != 0 { while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }; cursor += 1 }
        if flags & 0x02 != 0 { cursor += 2 }
        guard cursor < bytes.count - 8 else { throw RoachMapTileError.truncated("gzip header") }
        // The trailer's ISIZE is the inflated length mod 2^32.
        let trailer = bytes.count - 4
        let isize = Int(bytes[trailer]) | Int(bytes[trailer + 1]) << 8 | Int(bytes[trailer + 2]) << 16 | Int(bytes[trailer + 3]) << 24
        return try inflate(Array(bytes[cursor..<(bytes.count - 8)]), expected: max(isize, sizeHint))
    }

    /// What to reserve up front for an inflated member. The size hint is the
    /// file's own ISIZE trailer, so it is a hint, not a promise: DEFLATE can't
    /// grow past about 1032:1, and nothing past 8 MB is reserved ahead of time
    /// (a 20-byte tile claiming 4 GB used to reserve 4 GB).
    static func reservation(inputBytes: Int, hint: Int) -> Int {
        let ceiling = inputBytes > Int.max / 1032 ? Int.max : inputBytes * 1032
        return max(0, min(hint, ceiling, 8 << 20))
    }

    /// Raw DEFLATE (Compression's ZLIB algorithm is headerless deflate).
    static func inflate(_ input: [UInt8], expected: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw RoachMapTileError.corruptTile("inflate init")
        }
        defer { compression_stream_destroy(stream) }
        let plausible = reservation(inputBytes: input.count, hint: expected)
        let chunk = max(16 * 1024, min(plausible > 0 ? plausible : 64 * 1024, 1 << 20))
        var output = Data()
        output.reserveCapacity(plausible > 0 ? plausible : chunk)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return try input.withUnsafeBufferPointer { source -> Data in
            guard let base = source.baseAddress else { return Data() }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:
                    if output.count > 256 * 1024 * 1024 { throw RoachMapTileError.corruptTile("inflated past 256 MB") }
                    if stream.pointee.src_size == 0 && stream.pointee.dst_size == chunk { return output }
                default: throw RoachMapTileError.corruptTile("inflate failed")
                }
            }
        }
    }
}

// MARK: - Varints

struct RoachByteReader {
    let bytes: [UInt8]
    var cursor: Int
    let end: Int

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        cursor = start
        self.end = end ?? bytes.count
    }

    var atEnd: Bool { cursor >= end }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard cursor < end else { throw RoachMapTileError.truncated("varint") }
            let byte = bytes[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw RoachMapTileError.corruptTile("varint too long") }
        }
    }

    mutating func fixed32() throws -> UInt32 {
        guard cursor + 4 <= end else { throw RoachMapTileError.truncated("fixed32") }
        defer { cursor += 4 }
        return UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8 | UInt32(bytes[cursor + 2]) << 16 | UInt32(bytes[cursor + 3]) << 24
    }

    mutating func fixed64() throws -> UInt64 {
        let low = UInt64(try fixed32())
        let high = UInt64(try fixed32())
        return low | high << 32
    }

    /// Bounds of a length-delimited field.
    mutating func lengthDelimited() throws -> Range<Int> {
        let length = Int(try varint())
        guard length >= 0, cursor + length <= end else { throw RoachMapTileError.truncated("field") }
        defer { cursor += length }
        return cursor..<(cursor + length)
    }

    mutating func skip(wireType: UInt64) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1: guard cursor + 8 <= end else { throw RoachMapTileError.truncated("skip") }; cursor += 8
        case 2: _ = try lengthDelimited()
        case 5: guard cursor + 4 <= end else { throw RoachMapTileError.truncated("skip") }; cursor += 4
        default: throw RoachMapTileError.corruptTile("wire type \(wireType)")
        }
    }

    static func zigzag(_ value: UInt64) -> Int64 { Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1) }
}

// MARK: - PMTiles

struct RoachPMTilesHeader: Equatable {
    var rootOffset: UInt64
    var rootLength: UInt64
    var metadataOffset: UInt64
    var metadataLength: UInt64
    var leafOffset: UInt64
    var leafLength: UInt64
    var tileDataOffset: UInt64
    var tileDataLength: UInt64
    var addressedTiles: UInt64
    var internalCompression: UInt8
    var tileCompression: UInt8
    var tileType: UInt8
    var minZoom: Int
    var maxZoom: Int
    var minLon: Double
    var minLat: Double
    var maxLon: Double
    var maxLat: Double
    var centerZoom: Int
    var centerLon: Double
    var centerLat: Double

    static let size = 127

    static func parse(_ data: Data) throws -> RoachPMTilesHeader {
        guard data.count >= size else { throw RoachMapTileError.truncated("header") }
        let bytes = [UInt8](data.prefix(size))
        guard Array(bytes[0..<7]) == Array("PMTiles".utf8) else { throw RoachMapTileError.notPMTiles }
        guard bytes[7] == 3 else { throw RoachMapTileError.unsupportedVersion(Int(bytes[7])) }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) } }
        func i32(_ at: Int) -> Double {
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
            return Double(Int32(bitPattern: raw)) / 10_000_000
        }
        return RoachPMTilesHeader(
            rootOffset: u64(8), rootLength: u64(16), metadataOffset: u64(24), metadataLength: u64(32),
            leafOffset: u64(40), leafLength: u64(48), tileDataOffset: u64(56), tileDataLength: u64(64),
            addressedTiles: u64(72), internalCompression: bytes[97], tileCompression: bytes[98], tileType: bytes[99],
            minZoom: Int(bytes[100]), maxZoom: Int(bytes[101]),
            minLon: i32(102), minLat: i32(106), maxLon: i32(110), maxLat: i32(114),
            centerZoom: Int(bytes[118]), centerLon: i32(119), centerLat: i32(123)
        )
    }
}

struct RoachPMTilesEntry: Equatable {
    var tileId: UInt64
    var offset: UInt64
    var length: UInt32
    var runLength: UInt32
}

enum RoachTileID {
    /// PMTiles tile id: every tile of lower zooms first, then the Hilbert index within zoom `z`.
    static func from(z: Int, x: Int, y: Int) -> UInt64 {
        precondition(z >= 0 && z <= 26)
        let n = 1 << z
        precondition(x >= 0 && x < n && y >= 0 && y < n)
        let base = (UInt64(1) << (2 * UInt64(z)) - 1) / 3
        var x = x, y = y, d: UInt64 = 0
        var s = n / 2
        while s > 0 {
            let rx = (x & s) > 0 ? 1 : 0
            let ry = (y & s) > 0 ? 1 : 0
            d += UInt64(s) * UInt64(s) * UInt64((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 {
                    x = n - 1 - x
                    y = n - 1 - y
                }
                swap(&x, &y)
            }
            s /= 2
        }
        return base + d
    }
}

/// Reads tiles out of one `.pmtiles` file. Thread-safe: file reads are serialized.
final class RoachPMTilesArchive: @unchecked Sendable {
    let path: String
    let header: RoachPMTilesHeader
    let name: String
    private let handle: FileHandle
    private let lock = NSLock()
    private let root: [RoachPMTilesEntry]
    private var leafCache: [UInt64: [RoachPMTilesEntry]] = [:]
    private var leafOrder: [UInt64] = []

    init(path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw RoachMapTileError.truncated("open \(path)") }
        self.path = path
        self.handle = handle
        name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let headerData = try handle.read(upToCount: 16_384) ?? Data()
        let header = try RoachPMTilesHeader.parse(headerData)
        guard header.internalCompression == 1 || header.internalCompression == 2 else {
            throw RoachMapTileError.unsupportedCompression(Int(header.internalCompression))
        }
        guard header.tileCompression == 1 || header.tileCompression == 2 else {
            throw RoachMapTileError.unsupportedCompression(Int(header.tileCompression))
        }
        self.header = header
        let rootEnd = Int(header.rootOffset + header.rootLength)
        let rootData: Data
        if rootEnd <= headerData.count {
            rootData = headerData.subdata(in: Int(header.rootOffset)..<rootEnd)
        } else {
            try handle.seek(toOffset: header.rootOffset)
            rootData = try handle.read(upToCount: Int(header.rootLength)) ?? Data()
        }
        root = try RoachPMTilesArchive.parseDirectory(header.internalCompression == 2 ? RoachGzip.decompress(rootData) : rootData)
    }

    deinit { try? handle.close() }

    var isVector: Bool { header.tileType == 1 }

    static func parseDirectory(_ data: Data) throws -> [RoachPMTilesEntry] {
        var reader = RoachByteReader([UInt8](data))
        let count = Int(try reader.varint())
        guard count >= 0, count < 10_000_000 else { throw RoachMapTileError.corruptDirectory }
        var entries = [RoachPMTilesEntry](repeating: RoachPMTilesEntry(tileId: 0, offset: 0, length: 0, runLength: 0), count: count)
        var lastId: UInt64 = 0
        for index in 0..<count {
            lastId += try reader.varint()
            entries[index].tileId = lastId
        }
        for index in 0..<count { entries[index].runLength = UInt32(truncatingIfNeeded: try reader.varint()) }
        for index in 0..<count { entries[index].length = UInt32(truncatingIfNeeded: try reader.varint()) }
        for index in 0..<count {
            let value = try reader.varint()
            if value == 0 && index > 0 {
                entries[index].offset = entries[index - 1].offset + UInt64(entries[index - 1].length)
            } else {
                guard value > 0 else { throw RoachMapTileError.corruptDirectory }
                entries[index].offset = value - 1
            }
        }
        return entries
    }

    /// Binary search: the entry whose range covers `tileId`, or a leaf pointer before it.
    static func find(_ tileId: UInt64, in entries: [RoachPMTilesEntry]) -> RoachPMTilesEntry? {
        var low = 0, high = entries.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = entries[middle].tileId
            if tileId > candidate { low = middle + 1 } else if tileId < candidate { high = middle - 1 } else { return entries[middle] }
        }
        guard high >= 0 else { return nil }
        let entry = entries[high]
        if entry.runLength == 0 { return entry } // leaf directory
        return tileId - entry.tileId < UInt64(entry.runLength) ? entry : nil
    }

    private func read(offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else { throw RoachMapTileError.truncated("tile data") }
        return data
    }

    private func leaf(at offset: UInt64, length: UInt32) throws -> [RoachPMTilesEntry] {
        lock.lock()
        if let cached = leafCache[offset] { lock.unlock(); return cached }
        lock.unlock()
        let raw = try read(offset: header.leafOffset + offset, length: Int(length))
        let entries = try RoachPMTilesArchive.parseDirectory(header.internalCompression == 2 ? RoachGzip.decompress(raw) : raw)
        lock.lock()
        leafCache[offset] = entries
        leafOrder.append(offset)
        if leafOrder.count > 64 { leafCache.removeValue(forKey: leafOrder.removeFirst()) }
        lock.unlock()
        return entries
    }

    /// The decompressed tile bytes, or nil when the archive has no tile there.
    func tile(z: Int, x: Int, y: Int) throws -> Data? {
        guard z >= header.minZoom, z <= header.maxZoom, z <= 26, x >= 0, y >= 0, x < 1 << z, y < 1 << z else { return nil }
        let tileId = RoachTileID.from(z: z, x: x, y: y)
        var directory = root
        for _ in 0..<4 {
            guard let entry = RoachPMTilesArchive.find(tileId, in: directory) else { return nil }
            if entry.runLength > 0 {
                let raw = try read(offset: header.tileDataOffset + entry.offset, length: Int(entry.length))
                return header.tileCompression == 2 ? try RoachGzip.decompress(raw) : raw
            }
            directory = try leaf(at: entry.offset, length: entry.length)
        }
        throw RoachMapTileError.corruptDirectory
    }
}

// MARK: - Mapbox Vector Tiles

enum RoachMVTValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool: return nil
        }
    }
}

struct RoachMVTFeature {
    enum Kind: Int { case unknown = 0, point = 1, line = 2, polygon = 3 }
    var kind: Kind
    var properties: [String: RoachMVTValue]
    /// Points, line strings or polygon rings in tile coordinates (0...extent).
    var geometry: [[CGPoint]]
}

struct RoachMVTLayer {
    var name: String
    var extent: Double
    var features: [RoachMVTFeature]
}

enum RoachMVT {
    static func decode(_ data: Data) throws -> [RoachMVTLayer] {
        let bytes = [UInt8](data)
        var reader = RoachByteReader(bytes)
        var layers: [RoachMVTLayer] = []
        while !reader.atEnd {
            let key = try reader.varint()
            if key >> 3 == 3 && key & 7 == 2 {
                layers.append(try layer(bytes, try reader.lengthDelimited()))
            } else {
                try reader.skip(wireType: key & 7)
            }
        }
        return layers
    }

    private static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    private static func layer(_ bytes: [UInt8], _ range: Range<Int>) throws -> RoachMVTLayer {
        var reader = RoachByteReader(bytes, from: range.lowerBound, to: range.upperBound)
        var name = ""
        var extent = 4096.0
        var keys: [String] = []
        var values: [RoachMVTValue] = []
        var featureRanges: [Range<Int>] = []
        while !reader.atEnd {
            let key = try reader.varint()
            switch (key >> 3, key & 7) {
            case (1, 2): name = string(bytes, try reader.lengthDelimited())
            case (2, 2): featureRanges.append(try reader.lengthDelimited())
            case (3, 2): keys.append(string(bytes, try reader.lengthDelimited()))
            case (4, 2): values.append(try value(bytes, try reader.lengthDelimited()))
            case (5, 0): extent = Double(try reader.varint())
            default: try reader.skip(wireType: key & 7)
            }
        }
        if extent <= 0 { extent = 4096 }
        let features = try featureRanges.map { try feature(bytes, $0, keys: keys, values: values) }
        return RoachMVTLayer(name: name, extent: extent, features: features)
    }

    private static func value(_ bytes: [UInt8], _ range: Range<Int>) throws -> RoachMVTValue {
        var reader = RoachByteReader(bytes, from: range.lowerBound, to: range.upperBound)
        var result = RoachMVTValue.string("")
        while !reader.atEnd {
            let key = try reader.varint()
            switch (key >> 3, key & 7) {
            case (1, 2): result = .string(string(bytes, try reader.lengthDelimited()))
            case (2, 5): result = .number(Double(Float(bitPattern: try reader.fixed32())))
            case (3, 1): result = .number(Double(bitPattern: try reader.fixed64()))
            case (4, 0): result = .number(Double(Int64(bitPattern: try reader.varint())))
            case (5, 0): result = .number(Double(try reader.varint()))
            case (6, 0): result = .number(Double(RoachByteReader.zigzag(try reader.varint())))
            case (7, 0): result = .bool(try reader.varint() != 0)
            default: try reader.skip(wireType: key & 7)
            }
        }
        return result
    }

    private static func feature(_ bytes: [UInt8], _ range: Range<Int>, keys: [String], values: [RoachMVTValue]) throws -> RoachMVTFeature {
        var reader = RoachByteReader(bytes, from: range.lowerBound, to: range.upperBound)
        var kind = RoachMVTFeature.Kind.unknown
        var tags: [UInt64] = []
        var commands: [UInt64] = []
        while !reader.atEnd {
            let key = try reader.varint()
            switch (key >> 3, key & 7) {
            case (2, 2):
                let field = try reader.lengthDelimited()
                var packed = RoachByteReader(bytes, from: field.lowerBound, to: field.upperBound)
                while !packed.atEnd { tags.append(try packed.varint()) }
            case (3, 0): kind = RoachMVTFeature.Kind(rawValue: Int(try reader.varint())) ?? .unknown
            case (4, 2):
                let field = try reader.lengthDelimited()
                var packed = RoachByteReader(bytes, from: field.lowerBound, to: field.upperBound)
                while !packed.atEnd { commands.append(try packed.varint()) }
            default: try reader.skip(wireType: key & 7)
            }
        }
        var properties: [String: RoachMVTValue] = [:]
        var index = 0
        while index + 1 < tags.count {
            let keyIndex = Int(tags[index]), valueIndex = Int(tags[index + 1])
            if keyIndex < keys.count, valueIndex < values.count { properties[keys[keyIndex]] = values[valueIndex] }
            index += 2
        }
        return RoachMVTFeature(kind: kind, properties: properties, geometry: try geometry(commands))
    }

    /// MoveTo(1) / LineTo(2) / ClosePath(7) with zigzag-encoded deltas.
    static func geometry(_ commands: [UInt64]) throws -> [[CGPoint]] {
        var parts: [[CGPoint]] = []
        var current: [CGPoint] = []
        var x: Int64 = 0, y: Int64 = 0
        var index = 0
        while index < commands.count {
            let command = commands[index] & 0x7
            let count = Int(commands[index] >> 3)
            index += 1
            switch command {
            case 1, 2:
                guard index + count * 2 <= commands.count else { throw RoachMapTileError.corruptTile("geometry") }
                for _ in 0..<count {
                    x += RoachByteReader.zigzag(commands[index])
                    y += RoachByteReader.zigzag(commands[index + 1])
                    index += 2
                    if command == 1 {
                        if !current.isEmpty { parts.append(current) }
                        current = [CGPoint(x: Double(x), y: Double(y))]
                    } else {
                        current.append(CGPoint(x: Double(x), y: Double(y)))
                    }
                }
            case 7:
                if let first = current.first { current.append(first) }
            default:
                throw RoachMapTileError.corruptTile("command \(command)")
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Web Mercator

enum RoachMercator {
    static let maxLatitude = 85.05112878

    /// Longitude/latitude → world coordinates in 0...1 (x east, y south).
    static func project(lon: Double, lat: Double) -> CGPoint {
        let clamped = min(max(lat, -maxLatitude), maxLatitude) * .pi / 180
        let x = (lon + 180) / 360
        let y = (1 - log(tan(clamped) + 1 / cos(clamped)) / .pi) / 2
        return CGPoint(x: x, y: y)
    }

    static func unproject(_ point: CGPoint) -> (lon: Double, lat: Double) {
        let lon = point.x * 360 - 180
        let n = Double.pi - 2 * Double.pi * point.y
        let lat = 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
        return (lon, lat)
    }
}
