import Foundation

/// ggml tensor element types that RoachInference understands.
public enum GGMLType: UInt32, CaseIterable {
    case f32 = 0
    case f16 = 1
    case q4_0 = 2
    case q4_1 = 3
    case q5_0 = 6
    case q5_1 = 7
    case q8_0 = 8
    case q2_K = 10
    case q3_K = 11
    case q4_K = 12
    case q5_K = 13
    case q6_K = 14
    case q8_K = 15
    case bf16 = 30

    /// Elements per quantization block.
    public var blockSize: Int {
        switch self {
        case .f32, .f16, .bf16: return 1
        case .q4_0, .q4_1, .q5_0, .q5_1, .q8_0: return 32
        case .q2_K, .q3_K, .q4_K, .q5_K, .q6_K, .q8_K: return 256
        }
    }

    /// Bytes per block.
    public var blockBytes: Int {
        switch self {
        case .f32: return 4
        case .f16, .bf16: return 2
        case .q4_0: return 18
        case .q4_1: return 20
        case .q5_0: return 22
        case .q5_1: return 24
        case .q8_0: return 34
        case .q2_K: return 84
        case .q3_K: return 110
        case .q4_K: return 144
        case .q5_K: return 176
        case .q6_K: return 210
        case .q8_K: return 292
        }
    }

    public func rowBytes(_ elements: Int) -> Int { elements / blockSize * blockBytes }

    public var name: String {
        switch self {
        case .f32: return "F32"
        case .f16: return "F16"
        case .bf16: return "BF16"
        case .q4_0: return "Q4_0"
        case .q4_1: return "Q4_1"
        case .q5_0: return "Q5_0"
        case .q5_1: return "Q5_1"
        case .q8_0: return "Q8_0"
        case .q2_K: return "Q2_K"
        case .q3_K: return "Q3_K"
        case .q4_K: return "Q4_K"
        case .q5_K: return "Q5_K"
        case .q6_K: return "Q6_K"
        case .q8_K: return "Q8_K"
        }
    }
}

@inline(__always)
func halfToFloat(_ bits: UInt16) -> Float {
    #if arch(arm64)
    return Float(Float16(bitPattern: bits))
    #else
    let sign = UInt32(bits & 0x8000) << 16
    var exponent = UInt32(bits >> 10) & 0x1F
    var mantissa = UInt32(bits & 0x3FF)
    if exponent == 0 {
        if mantissa == 0 { return Float(bitPattern: sign) }
        // Subnormal: normalise.
        exponent = 1
        while mantissa & 0x400 == 0 {
            mantissa <<= 1
            exponent -= 1
        }
        mantissa &= 0x3FF
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }
    if exponent == 0x1F {
        return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
    }
    return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    #endif
}

@inline(__always)
func floatToHalf(_ value: Float) -> UInt16 {
    #if arch(arm64)
    return Float16(value).bitPattern
    #else
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
    let mantissa = bits & 0x7F_FFFF
    if exponent <= 0 { return sign }
    if exponent >= 0x1F { return sign | 0x7C00 }
    return sign | UInt16(exponent << 10) | UInt16(mantissa >> 13)
    #endif
}

@inline(__always)
private func f16(_ pointer: UnsafeRawPointer, _ offset: Int) -> Float {
    halfToFloat(pointer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
}

@inline(__always)
private func scaleMinK4(_ index: Int, _ q: UnsafePointer<UInt8>) -> (Float, Float) {
    if index < 4 {
        return (Float(q[index] & 63), Float(q[index + 4] & 63))
    }
    let d = (q[index + 4] & 0x0F) | ((q[index - 4] >> 6) << 4)
    let m = (q[index + 4] >> 4) | ((q[index] >> 6) << 4)
    return (Float(d), Float(m))
}

/// Dequantization and quantized dot products for ggml block formats.
/// Layouts follow the GGUF file format specification.
public enum Quantization {
    /// Dequantizes one block of `type` at `src` into `dst` (`type.blockSize` floats).
    @inline(__always)
    public static func dequantizeBlock(_ type: GGMLType, _ src: UnsafeRawPointer, _ dst: UnsafeMutablePointer<Float>) {
        let bytes = src.assumingMemoryBound(to: UInt8.self)
        switch type {
        case .f32:
            dst[0] = src.loadUnaligned(as: Float.self)
        case .f16:
            dst[0] = f16(src, 0)
        case .bf16:
            dst[0] = Float(bitPattern: UInt32(src.loadUnaligned(as: UInt16.self)) << 16)
        case .q4_0:
            let d = f16(src, 0)
            let qs = bytes + 2
            for j in 0..<16 {
                dst[j] = Float(Int(qs[j] & 0x0F) - 8) * d
                dst[j + 16] = Float(Int(qs[j] >> 4) - 8) * d
            }
        case .q4_1:
            let d = f16(src, 0)
            let m = f16(src, 2)
            let qs = bytes + 4
            for j in 0..<16 {
                dst[j] = Float(qs[j] & 0x0F) * d + m
                dst[j + 16] = Float(qs[j] >> 4) * d + m
            }
        case .q5_0:
            let d = f16(src, 0)
            let qh = src.loadUnaligned(fromByteOffset: 2, as: UInt32.self).littleEndian
            let qs = bytes + 6
            for j in 0..<16 {
                let h0 = UInt8(((qh >> UInt32(j)) << 4) & 0x10)
                let h1 = UInt8((qh >> UInt32(j + 12)) & 0x10)
                dst[j] = Float(Int((qs[j] & 0x0F) | h0) - 16) * d
                dst[j + 16] = Float(Int((qs[j] >> 4) | h1) - 16) * d
            }
        case .q5_1:
            let d = f16(src, 0)
            let m = f16(src, 2)
            let qh = src.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            let qs = bytes + 8
            for j in 0..<16 {
                let h0 = UInt8(((qh >> UInt32(j)) << 4) & 0x10)
                let h1 = UInt8((qh >> UInt32(j + 12)) & 0x10)
                dst[j] = Float((qs[j] & 0x0F) | h0) * d + m
                dst[j + 16] = Float((qs[j] >> 4) | h1) * d + m
            }
        case .q8_0:
            let d = f16(src, 0)
            let qs = UnsafeRawPointer(bytes + 2).assumingMemoryBound(to: Int8.self)
            for j in 0..<32 { dst[j] = Float(qs[j]) * d }
        case .q2_K:
            // scales[16], qs[64], d, dmin
            let scales = bytes
            var q = bytes + 16
            let d = f16(src, 80)
            let dmin = f16(src, 82)
            var out = dst
            var index = 0
            for _ in 0..<2 {
                var shift: UInt8 = 0
                for _ in 0..<4 {
                    var sc = scales[index]; index += 1
                    var dl = d * Float(sc & 0x0F), ml = dmin * Float(sc >> 4)
                    for l in 0..<16 { out[l] = dl * Float((q[l] >> shift) & 3) - ml }
                    out += 16
                    sc = scales[index]; index += 1
                    dl = d * Float(sc & 0x0F); ml = dmin * Float(sc >> 4)
                    for l in 0..<16 { out[l] = dl * Float((q[l + 16] >> shift) & 3) - ml }
                    out += 16
                    shift += 2
                }
                q += 32
            }
        case .q3_K:
            // hmask[32], qs[64], scales[12], d
            let hm = bytes
            var q = bytes + 32
            let d = f16(src, 108)
            var aux = [UInt32](repeating: 0, count: 4)
            for i in 0..<3 { aux[i] = src.loadUnaligned(fromByteOffset: 96 + i * 4, as: UInt32.self).littleEndian }
            let kmask1: UInt32 = 0x0303_0303, kmask2: UInt32 = 0x0F0F_0F0F
            let tmp = aux[2]
            aux[2] = ((aux[0] >> 4) & kmask2) | (((tmp >> 4) & kmask1) << 4)
            aux[3] = ((aux[1] >> 4) & kmask2) | (((tmp >> 6) & kmask1) << 4)
            aux[0] = (aux[0] & kmask2) | (((tmp >> 0) & kmask1) << 4)
            aux[1] = (aux[1] & kmask2) | (((tmp >> 2) & kmask1) << 4)
            var scales = [Int8](repeating: 0, count: 16)
            for i in 0..<16 { scales[i] = Int8(bitPattern: UInt8((aux[i / 4] >> UInt32((i % 4) * 8)) & 0xFF)) }
            var out = dst
            var index = 0
            var m: UInt8 = 1
            for _ in 0..<2 {
                var shift: UInt8 = 0
                for _ in 0..<4 {
                    var dl = d * Float(Int(scales[index]) - 32); index += 1
                    for l in 0..<16 {
                        out[l] = dl * Float(Int((q[l] >> shift) & 3) - (hm[l] & m != 0 ? 0 : 4))
                    }
                    out += 16
                    dl = d * Float(Int(scales[index]) - 32); index += 1
                    for l in 0..<16 {
                        out[l] = dl * Float(Int((q[l + 16] >> shift) & 3) - (hm[l + 16] & m != 0 ? 0 : 4))
                    }
                    out += 16
                    shift += 2
                    m <<= 1
                }
                q += 32
            }
        case .q4_K:
            // d, dmin, scales[12], qs[128]
            let d = f16(src, 0)
            let dmin = f16(src, 2)
            let scales = bytes + 4
            var q = bytes + 16
            var out = dst
            var index = 0
            for _ in 0..<4 {
                let (sc1, m1) = scaleMinK4(index, scales)
                let (sc2, m2) = scaleMinK4(index + 1, scales)
                let d1 = d * sc1, mm1 = dmin * m1, d2 = d * sc2, mm2 = dmin * m2
                for l in 0..<32 { out[l] = d1 * Float(q[l] & 0x0F) - mm1 }
                for l in 0..<32 { out[l + 32] = d2 * Float(q[l] >> 4) - mm2 }
                out += 64
                q += 32
                index += 2
            }
        case .q5_K:
            // d, dmin, scales[12], qh[32], qs[128]
            let d = f16(src, 0)
            let dmin = f16(src, 2)
            let scales = bytes + 4
            let qh = bytes + 16
            var ql = bytes + 48
            var out = dst
            var index = 0
            var u1: UInt8 = 1, u2: UInt8 = 2
            for _ in 0..<4 {
                let (sc1, m1) = scaleMinK4(index, scales)
                let (sc2, m2) = scaleMinK4(index + 1, scales)
                let d1 = d * sc1, mm1 = dmin * m1, d2 = d * sc2, mm2 = dmin * m2
                for l in 0..<32 { out[l] = d1 * Float(Int(ql[l] & 0x0F) + (qh[l] & u1 != 0 ? 16 : 0)) - mm1 }
                for l in 0..<32 { out[l + 32] = d2 * Float(Int(ql[l] >> 4) + (qh[l] & u2 != 0 ? 16 : 0)) - mm2 }
                out += 64
                ql += 32
                index += 2
                u1 <<= 2
                u2 <<= 2
            }
        case .q6_K:
            // ql[128], qh[64], scales[16] (int8), d
            var ql = bytes
            var qh = bytes + 128
            var sc = UnsafeRawPointer(bytes + 192).assumingMemoryBound(to: Int8.self)
            let d = f16(src, 208)
            var out = dst
            for _ in 0..<2 {
                for l in 0..<32 {
                    let isc = l / 16
                    let q1 = Int((ql[l] & 0x0F) | (((qh[l] >> 0) & 3) << 4)) - 32
                    let q2 = Int((ql[l + 32] & 0x0F) | (((qh[l] >> 2) & 3) << 4)) - 32
                    let q3 = Int((ql[l] >> 4) | (((qh[l] >> 4) & 3) << 4)) - 32
                    let q4 = Int((ql[l + 32] >> 4) | (((qh[l] >> 6) & 3) << 4)) - 32
                    out[l] = d * Float(sc[isc]) * Float(q1)
                    out[l + 32] = d * Float(sc[isc + 2]) * Float(q2)
                    out[l + 64] = d * Float(sc[isc + 4]) * Float(q3)
                    out[l + 96] = d * Float(sc[isc + 6]) * Float(q4)
                }
                out += 128
                ql += 64
                qh += 32
                sc += 8
            }
        case .q8_K:
            let d = src.loadUnaligned(as: Float.self)
            let qs = UnsafeRawPointer(bytes + 4).assumingMemoryBound(to: Int8.self)
            for j in 0..<256 { dst[j] = Float(qs[j]) * d }
        }
    }

    /// Dequantizes `count` elements (a multiple of the block size) into `dst`.
    public static func dequantize(_ type: GGMLType, _ src: UnsafeRawPointer, count: Int, into dst: UnsafeMutablePointer<Float>) {
        switch type {
        case .f32:
            dst.update(from: src.assumingMemoryBound(to: Float.self), count: count)
        case .f16:
            for i in 0..<count { dst[i] = f16(src, i * 2) }
        case .bf16:
            for i in 0..<count { dst[i] = Float(bitPattern: UInt32(src.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) << 16) }
        default:
            let blocks = count / type.blockSize
            for b in 0..<blocks {
                dequantizeBlock(type, src + b * type.blockBytes, dst + b * type.blockSize)
            }
        }
    }

    /// Dot product of one quantized row of `count` elements with `x`.
    @inline(__always)
    public static func dot(_ type: GGMLType, _ row: UnsafeRawPointer, _ x: UnsafePointer<Float>, count: Int) -> Float {
        switch type {
        case .f32:
            return dotF32(row.assumingMemoryBound(to: Float.self), x, count)
        case .q8_0:
            return dotQ8_0(row, x, count)
        case .q4_0:
            return dotQ4_0(row, x, count)
        case .f16, .bf16:
            var sum: Float = 0
            let block = 64
            return withUnsafeTemporaryAllocation(of: Float.self, capacity: block) { buffer in
                var i = 0
                while i < count {
                    let n = min(block, count - i)
                    dequantize(type, row + i * 2, count: n, into: buffer.baseAddress!)
                    sum += dotF32(buffer.baseAddress!, x + i, n)
                    i += n
                }
                return sum
            }
        default:
            let blockSize = type.blockSize
            let blockBytes = type.blockBytes
            let blocks = count / blockSize
            return withUnsafeTemporaryAllocation(of: Float.self, capacity: blockSize) { buffer in
                var sum: Float = 0
                for b in 0..<blocks {
                    dequantizeBlock(type, row + b * blockBytes, buffer.baseAddress!)
                    sum += dotF32(buffer.baseAddress!, x + b * blockSize, blockSize)
                }
                return sum
            }
        }
    }

    @inline(__always)
    static func dotF32(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ count: Int) -> Float {
        var acc0 = SIMD8<Float>(), acc1 = SIMD8<Float>()
        var i = 0
        let ra = UnsafeRawPointer(a), rb = UnsafeRawPointer(b)
        while i + 16 <= count {
            acc0 += ra.loadUnaligned(fromByteOffset: i * 4, as: SIMD8<Float>.self) * rb.loadUnaligned(fromByteOffset: i * 4, as: SIMD8<Float>.self)
            acc1 += ra.loadUnaligned(fromByteOffset: (i + 8) * 4, as: SIMD8<Float>.self) * rb.loadUnaligned(fromByteOffset: (i + 8) * 4, as: SIMD8<Float>.self)
            i += 16
        }
        var sum = (acc0 + acc1).sum()
        while i < count {
            sum += a[i] * b[i]
            i += 1
        }
        return sum
    }

    @inline(__always)
    static func dotQ8_0(_ row: UnsafeRawPointer, _ x: UnsafePointer<Float>, _ count: Int) -> Float {
        var sum: Float = 0
        let blocks = count / 32
        let rx = UnsafeRawPointer(x)
        for b in 0..<blocks {
            let block = row + b * 34
            let d = f16(block, 0)
            let qs = block + 2
            var acc = SIMD8<Float>()
            for k in 0..<4 {
                let q = qs.loadUnaligned(fromByteOffset: k * 8, as: SIMD8<Int8>.self)
                acc += SIMD8<Float>(q) * rx.loadUnaligned(fromByteOffset: (b * 32 + k * 8) * 4, as: SIMD8<Float>.self)
            }
            sum += d * acc.sum()
        }
        return sum
    }

    @inline(__always)
    static func dotQ4_0(_ row: UnsafeRawPointer, _ x: UnsafePointer<Float>, _ count: Int) -> Float {
        var sum: Float = 0
        let blocks = count / 32
        let rx = UnsafeRawPointer(x)
        let eight = SIMD8<Int16>(repeating: 8)
        for b in 0..<blocks {
            let block = row + b * 18
            let d = f16(block, 0)
            var acc = SIMD8<Float>()
            for k in 0..<2 {
                let packed = block.loadUnaligned(fromByteOffset: 2 + k * 8, as: SIMD8<UInt8>.self)
                let low = SIMD8<Int16>(truncatingIfNeeded: packed & 0x0F) &- eight
                let high = SIMD8<Int16>(truncatingIfNeeded: packed &>> 4) &- eight
                acc += SIMD8<Float>(low) * rx.loadUnaligned(fromByteOffset: (b * 32 + k * 8) * 4, as: SIMD8<Float>.self)
                acc += SIMD8<Float>(high) * rx.loadUnaligned(fromByteOffset: (b * 32 + 16 + k * 8) * 4, as: SIMD8<Float>.self)
            }
            sum += d * acc.sum()
        }
        return sum
    }
}
