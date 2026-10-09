// Hand-written Metal Shading Language kernels for RoachInference. Compiled at
// runtime from this source with MTLDevice.makeLibrary(source:); no Metal
// Performance Shaders, Accelerate, Core ML or third-party kernels are used.
// Each kernel mirrors a CPU reference in Quantization.swift / InferenceSession.swift.
enum MetalKernelSource {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// GGUF tensors are 32-byte aligned and every block size is even, so 16-bit
// loads inside a block are always aligned.
inline float f16_at(device const uchar* p) {
    return float(as_type<half>(*(device const ushort*)p));
}
inline int lo_s8(ushort w) { return int(short(ushort(w << 8))) >> 8; }
inline int hi_s8(ushort w) { return int(short(w)) >> 8; }
inline uint u32_at(device const uchar* p) {
    return uint(p[0]) | (uint(p[1]) << 8) | (uint(p[2]) << 16) | (uint(p[3]) << 24);
}
inline void scale_min_k4(int j, device const uchar* q, thread float& d, thread float& m) {
    if (j < 4) { d = float(q[j] & 63); m = float(q[j + 4] & 63); }
    else {
        d = float((q[j + 4] & 0x0F) | ((q[j - 4] >> 6) << 4));
        m = float((q[j + 4] >> 4) | ((q[j] >> 6) << 4));
    }
}

// ---- block dot products: one quantized block against floats ----

template <typename X> inline float dot_f32_32(device const uchar* b, X x) {
    device const float* w = (device const float*)b;
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += w[j] * x[j];
    return acc;
}
template <typename X> inline float dot_f16_32(device const uchar* b, X x) {
    device const half* w = (device const half*)b;
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += float(w[j]) * x[j];
    return acc;
}
template <typename X> inline float dot_bf16_32(device const uchar* b, X x) {
    device const ushort* w = (device const ushort*)b;
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += as_type<float>(uint(w[j]) << 16) * x[j];
    return acc;
}
template <typename X> inline float dot_q4_0(device const uchar* b, X x) {
    float d = f16_at(b);
    device const ushort* q = (device const ushort*)(b + 2);
    float acc = 0;
    for (int m = 0; m < 8; ++m) {
        uint w = q[m];
        acc += float(int(w & 0x0F) - 8) * x[2 * m] + float(int((w >> 8) & 0x0F) - 8) * x[2 * m + 1]
             + float(int((w >> 4) & 0x0F) - 8) * x[2 * m + 16] + float(int((w >> 12) & 0x0F) - 8) * x[2 * m + 17];
    }
    return d * acc;
}
template <typename X> inline float dot_q4_1(device const uchar* b, X x) {
    float d = f16_at(b), m = f16_at(b + 2);
    float acc = 0, sum = 0;
    for (int j = 0; j < 16; ++j) {
        uchar q = b[4 + j];
        acc += float(q & 0x0F) * x[j] + float(q >> 4) * x[j + 16];
        sum += x[j] + x[j + 16];
    }
    return d * acc + m * sum;
}
template <typename X> inline float dot_q5_0(device const uchar* b, X x) {
    float d = f16_at(b);
    device const ushort* h = (device const ushort*)(b + 2);
    uint qh = uint(h[0]) | (uint(h[1]) << 16);
    device const ushort* q = (device const ushort*)(b + 6);
    float acc = 0;
    for (int m = 0; m < 8; ++m) {
        uint w = q[m];
        uint j0 = uint(2 * m), j1 = j0 + 1;
        acc += float(int((w & 0x0F) | (((qh >> j0) << 4) & 0x10)) - 16) * x[j0]
             + float(int(((w >> 8) & 0x0F) | (((qh >> j1) << 4) & 0x10)) - 16) * x[j1]
             + float(int(((w >> 4) & 0x0F) | ((qh >> (j0 + 12)) & 0x10)) - 16) * x[j0 + 16]
             + float(int(((w >> 12) & 0x0F) | ((qh >> (j1 + 12)) & 0x10)) - 16) * x[j1 + 16];
    }
    return d * acc;
}
template <typename X> inline float dot_q5_1(device const uchar* b, X x) {
    float d = f16_at(b), m = f16_at(b + 2);
    uint qh = u32_at(b + 4);
    float acc = 0, sum = 0;
    for (int j = 0; j < 16; ++j) {
        uchar q = b[8 + j];
        uint h0 = ((qh >> uint(j)) << 4) & 0x10;
        uint h1 = (qh >> uint(j + 12)) & 0x10;
        acc += float((q & 0x0F) | h0) * x[j] + float((q >> 4) | h1) * x[j + 16];
        sum += x[j] + x[j + 16];
    }
    return d * acc + m * sum;
}
template <typename X> inline float dot_q8_0(device const uchar* b, X x) {
    float d = f16_at(b);
    device const ushort* q = (device const ushort*)(b + 2);
    float acc = 0;
    for (int m = 0; m < 16; ++m) {
        ushort w = q[m];
        acc += float(lo_s8(w)) * x[2 * m] + float(hi_s8(w)) * x[2 * m + 1];
    }
    return d * acc;
}
inline float dot_q2_K(device const uchar* b, device const float* x) {
    device const uchar* scales = b;
    device const uchar* q = b + 16;
    float d = f16_at(b + 80), dmin = f16_at(b + 82);
    float acc = 0;
    int index = 0, out = 0;
    for (int n = 0; n < 2; ++n) {
        int shift = 0;
        for (int j = 0; j < 4; ++j) {
            uchar sc = scales[index++];
            float dl = d * float(sc & 0x0F), ml = dmin * float(sc >> 4);
            for (int l = 0; l < 16; ++l) acc += (dl * float((q[l] >> shift) & 3) - ml) * x[out + l];
            out += 16;
            sc = scales[index++];
            dl = d * float(sc & 0x0F); ml = dmin * float(sc >> 4);
            for (int l = 0; l < 16; ++l) acc += (dl * float((q[l + 16] >> shift) & 3) - ml) * x[out + l];
            out += 16;
            shift += 2;
        }
        q += 32;
    }
    return acc;
}
inline float dot_q3_K(device const uchar* b, device const float* x) {
    device const uchar* hm = b;
    device const uchar* q = b + 32;
    float d = f16_at(b + 108);
    uint aux[4] = { u32_at(b + 96), u32_at(b + 100), u32_at(b + 104), 0 };
    const uint kmask1 = 0x03030303, kmask2 = 0x0f0f0f0f;
    uint tmp = aux[2];
    aux[2] = ((aux[0] >> 4) & kmask2) | (((tmp >> 4) & kmask1) << 4);
    aux[3] = ((aux[1] >> 4) & kmask2) | (((tmp >> 6) & kmask1) << 4);
    aux[0] = (aux[0] & kmask2) | (((tmp >> 0) & kmask1) << 4);
    aux[1] = (aux[1] & kmask2) | (((tmp >> 2) & kmask1) << 4);
    float acc = 0;
    int index = 0, out = 0;
    uchar m = 1;
    for (int n = 0; n < 2; ++n) {
        int shift = 0;
        for (int j = 0; j < 4; ++j) {
            int s0 = int(char((aux[index / 4] >> (uint(index % 4) * 8)) & 0xFF)); index++;
            float dl = d * float(s0 - 32);
            for (int l = 0; l < 16; ++l) acc += dl * float(int((q[l] >> shift) & 3) - ((hm[l] & m) ? 0 : 4)) * x[out + l];
            out += 16;
            int s1 = int(char((aux[index / 4] >> (uint(index % 4) * 8)) & 0xFF)); index++;
            dl = d * float(s1 - 32);
            for (int l = 0; l < 16; ++l) acc += dl * float(int((q[l + 16] >> shift) & 3) - ((hm[l + 16] & m) ? 0 : 4)) * x[out + l];
            out += 16;
            shift += 2;
            m <<= 1;
        }
        q += 32;
    }
    return acc;
}
inline float dot_q4_K(device const uchar* b, device const float* x) {
    float d = f16_at(b), dmin = f16_at(b + 2);
    device const uchar* scales = b + 4;
    device const uchar* q = b + 16;
    float acc = 0;
    for (int i = 0; i < 4; ++i) {
        float sc1, m1, sc2, m2;
        scale_min_k4(2 * i, scales, sc1, m1);
        scale_min_k4(2 * i + 1, scales, sc2, m2);
        float d1 = d * sc1, mm1 = dmin * m1, d2 = d * sc2, mm2 = dmin * m2;
        device const float* xs = x + i * 64;
        float a1 = 0, s1 = 0, a2 = 0, s2 = 0;
        for (int l = 0; l < 32; ++l) {
            a1 += float(q[l] & 0x0F) * xs[l];
            s1 += xs[l];
            a2 += float(q[l] >> 4) * xs[l + 32];
            s2 += xs[l + 32];
        }
        acc += d1 * a1 - mm1 * s1 + d2 * a2 - mm2 * s2;
        q += 32;
    }
    return acc;
}
inline float dot_q5_K(device const uchar* b, device const float* x) {
    float d = f16_at(b), dmin = f16_at(b + 2);
    device const uchar* scales = b + 4;
    device const uchar* qh = b + 16;
    device const uchar* ql = b + 48;
    float acc = 0;
    uchar u1 = 1, u2 = 2;
    for (int i = 0; i < 4; ++i) {
        float sc1, m1, sc2, m2;
        scale_min_k4(2 * i, scales, sc1, m1);
        scale_min_k4(2 * i + 1, scales, sc2, m2);
        float d1 = d * sc1, mm1 = dmin * m1, d2 = d * sc2, mm2 = dmin * m2;
        device const float* xs = x + i * 64;
        for (int l = 0; l < 32; ++l) {
            acc += (d1 * float(int(ql[l] & 0x0F) + ((qh[l] & u1) ? 16 : 0)) - mm1) * xs[l];
            acc += (d2 * float(int(ql[l] >> 4) + ((qh[l] & u2) ? 16 : 0)) - mm2) * xs[l + 32];
        }
        ql += 32;
        u1 <<= 2;
        u2 <<= 2;
    }
    return acc;
}
inline float dot_q6_K(device const uchar* b, device const float* x) {
    device const uchar* ql = b;
    device const uchar* qh = b + 128;
    device const char* sc = (device const char*)(b + 192);
    float d = f16_at(b + 208);
    float acc = 0;
    for (int n = 0; n < 2; ++n) {
        device const float* xs = x + n * 128;
        for (int l = 0; l < 32; ++l) {
            int is = l / 16;
            int q1 = int((ql[l] & 0x0F) | (((qh[l] >> 0) & 3) << 4)) - 32;
            int q2 = int((ql[l + 32] & 0x0F) | (((qh[l] >> 2) & 3) << 4)) - 32;
            int q3 = int((ql[l] >> 4) | (((qh[l] >> 4) & 3) << 4)) - 32;
            int q4 = int((ql[l + 32] >> 4) | (((qh[l] >> 6) & 3) << 4)) - 32;
            acc += float(sc[is]) * float(q1) * xs[l]
                 + float(sc[is + 2]) * float(q2) * xs[l + 32]
                 + float(sc[is + 4]) * float(q3) * xs[l + 64]
                 + float(sc[is + 6]) * float(q4) * xs[l + 96];
        }
        ql += 64;
        qh += 32;
        sc += 8;
    }
    return d * acc;
}
inline float dot_q8_K(device const uchar* b, device const float* x) {
    float d = *(device const float*)b;
    device const char* q = (device const char*)(b + 4);
    float acc = 0;
    for (int j = 0; j < 256; ++j) acc += float(q[j]) * x[j];
    return d * acc;
}

// K-quant partial dots over one 32-element chunk j (0..7) of a 256-element
// superblock, so a simdgroup can spread a short row's few superblocks over
// all 32 lanes instead of leaving most of them idle.
// `xs` points at the 32 floats of chunk j.
template <typename X> inline float pdot_q4_K(device const uchar* b, X xs, uint j) {
    float d = f16_at(b), dmin = f16_at(b + 2);
    float sc, mn;
    scale_min_k4(int(j), b + 4, sc, mn);
    // Q4_K blocks are 144 bytes and the quants start at byte 16: 16-byte aligned.
    device const uint4* q = (device const uint4*)(b + 16 + (j >> 1) * 32);
    uint shift = (j & 1) ? 4 : 0;
    float a = 0, s = 0;
    for (int h = 0; h < 2; ++h) {
        uint4 v = q[h];
        uint words[4] = { v.x, v.y, v.z, v.w };
        for (int k = 0; k < 4; ++k) {
            uint w = words[k] >> shift;
            int e = 16 * h + 4 * k;
            a += float(w & 0x0F) * xs[e] + float((w >> 8) & 0x0F) * xs[e + 1]
               + float((w >> 16) & 0x0F) * xs[e + 2] + float((w >> 24) & 0x0F) * xs[e + 3];
            s += xs[e] + xs[e + 1] + xs[e + 2] + xs[e + 3];
        }
    }
    return d * sc * a - dmin * mn * s;
}
// `xs` points at the 32 floats of chunk j.
template <typename X> inline float pdot_q5_K(device const uchar* b, X xs, uint j) {
    float d = f16_at(b), dmin = f16_at(b + 2);
    float sc, mn;
    scale_min_k4(int(j), b + 4, sc, mn);
    device const uchar* qh = b + 16;
    device const uchar* ql = b + 48 + (j >> 1) * 32;
    uint shift = (j & 1) ? 4 : 0;
    float a = 0, s = 0;
    for (int l = 0; l < 32; ++l) {
        a += float(int((ql[l] >> shift) & 0x0F) + (((qh[l] >> j) & 1) ? 16 : 0)) * xs[l];
        s += xs[l];
    }
    return d * sc * a - dmin * mn * s;
}
// `xs` points at the 32 floats of chunk j.
template <typename X> inline float pdot_q6_K(device const uchar* b, X xs, uint j) {
    uint n = j >> 2, k = j & 3;
    device const ushort* ql = (device const ushort*)(b + n * 64 + ((k & 1) ? 32 : 0));
    device const ushort* qh = (device const ushort*)(b + 128 + n * 32);
    device const char* sc = (device const char*)(b + 192 + n * 8);
    float d = f16_at(b + 208);
    uint lowShift = (k & 2) ? 4 : 0, highShift = 2 * k;
    float a0 = 0, a1 = 0;
    for (int m = 0; m < 16; ++m) {
        uint lw = ql[m], hw = qh[m];
        float v0 = float(int(((lw >> lowShift) & 0x0F) | (((hw >> highShift) & 3) << 4)) - 32) * xs[2 * m];
        float v1 = float(int(((lw >> (8 + lowShift)) & 0x0F) | (((hw >> (8 + highShift)) & 3) << 4)) - 32) * xs[2 * m + 1];
        if (m < 8) a0 += v0 + v1; else a1 += v0 + v1;
    }
    return d * (float(sc[2 * k]) * a0 + float(sc[2 * k + 1]) * a1);
}
// `xs` points at the 32 floats of chunk j.
template <typename X> inline float pdot_q8_K(device const uchar* b, X xs, uint j) {
    float d = *(device const float*)b;
    device const char* q = (device const char*)(b + 4) + j * 32;
    float a = 0;
    for (int l = 0; l < 32; ++l) a += float(q[l]) * xs[l];
    return d * a;
}

struct MatvecArgs { uint cols; uint rowBytes; uint rows; uint flags; };

// flags bit 0: accumulate into y (residual add); bit 1: add bias[row].
inline float matvec_out(float v, uint row, device float* y, device const float* bias, constant MatvecArgs& a) {
    if (a.flags & 2u) v += bias[row];
    if (a.flags & 1u) v += y[row];
    return v;
}

// y[row] = W[row] · x. Four rows per threadgroup, one simdgroup (32 lanes)
// per row; lanes stride over the row's blocks and reduce with simd_sum.
#define MATVEC(NAME, BLOCK, BYTES, DOT) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 device const float* bias [[buffer(4)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint row = tg * 4 + sg; \
    if (row >= a.rows) return; \
    device const uchar* r = W + ulong(row) * a.rowBytes; \
    uint blocks = a.cols / BLOCK; \
    float acc = 0; \
    for (uint b = lane; b < blocks; b += 32) acc += DOT(r + ulong(b) * BYTES, x + b * BLOCK); \
    acc = simd_sum(acc); \
    if (lane == 0) y[row] = matvec_out(acc, row, y, bias, a); \
}
// K-quant variant: lanes stride over (superblock, 32-element chunk) pairs.
#define MATVEC_K(NAME, BYTES, PDOT) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 device const float* bias [[buffer(4)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint row = tg * 4 + sg; \
    if (row >= a.rows) return; \
    device const uchar* r = W + ulong(row) * a.rowBytes; \
    uint items = (a.cols / 256) * 8; \
    float acc = 0; \
    for (uint i = lane; i < items; i += 32) { \
        uint blk = i >> 3; \
        acc += PDOT(r + ulong(blk) * BYTES, x + blk * 256 + (i & 7) * 32, i & 7); \
    } \
    acc = simd_sum(acc); \
    if (lane == 0) y[row] = matvec_out(acc, row, y, bias, a); \
}
// Multi-row variants: each simdgroup computes R rows. A lane loads its 32 x
// values into registers once and reuses them for all R rows, which keeps
// R independent weight streams in flight per lane.
#define LOAD_X32(XR, SRC) \
    { device const float4* x4 = (device const float4*)(SRC); \
      for (int q = 0; q < 8; ++q) { float4 v = x4[q]; XR[4*q] = v.x; XR[4*q+1] = v.y; XR[4*q+2] = v.z; XR[4*q+3] = v.w; } }
#define MATVEC_R(NAME, BYTES, DOT, R) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 device const float* bias [[buffer(4)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint row0 = (tg * 4 + sg) * R; \
    if (row0 >= a.rows) return; \
    uint blocks = a.cols / 32; \
    float acc[R]; \
    for (uint r = 0; r < R; ++r) acc[r] = 0; \
    for (uint b = lane; b < blocks; b += 32) { \
        float xr[32]; \
        LOAD_X32(xr, x + b * 32) \
        for (uint r = 0; r < R; ++r) { \
            if (row0 + r < a.rows) acc[r] += DOT(W + ulong(row0 + r) * a.rowBytes + ulong(b) * BYTES, (thread const float*)xr); \
        } \
    } \
    for (uint r = 0; r < R; ++r) { \
        float total = simd_sum(acc[r]); \
        if (lane == 0 && row0 + r < a.rows) y[row0 + r] = matvec_out(total, row0 + r, y, bias, a); \
    } \
}
#define MATVEC_KR(NAME, BYTES, PDOT, R) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 device const float* bias [[buffer(4)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint row0 = (tg * 4 + sg) * R; \
    if (row0 >= a.rows) return; \
    uint items = (a.cols / 256) * 8; \
    float acc[R]; \
    for (uint r = 0; r < R; ++r) acc[r] = 0; \
    for (uint i = lane; i < items; i += 32) { \
        uint blk = i >> 3, j = i & 7; \
        float xr[32]; \
        LOAD_X32(xr, x + blk * 256 + j * 32) \
        for (uint r = 0; r < R; ++r) { \
            if (row0 + r < a.rows) acc[r] += PDOT(W + ulong(row0 + r) * a.rowBytes + ulong(blk) * BYTES, (thread const float*)xr, j); \
        } \
    } \
    for (uint r = 0; r < R; ++r) { \
        float total = simd_sum(acc[r]); \
        if (lane == 0 && row0 + r < a.rows) y[row0 + r] = matvec_out(total, row0 + r, y, bias, a); \
    } \
}
// ---- vectorized register-x dots (x held as float4[8]) ----
inline uint u32_from16(device const ushort* q, int k) { return uint(q[2 * k]) | (uint(q[2 * k + 1]) << 16); }
inline float dotv_q8_0(device const uchar* b, thread const float4* xv) {
    float d = f16_at(b);
    device const ushort* q = (device const ushort*)(b + 2);
    float acc = 0;
    for (int k = 0; k < 8; ++k) acc += dot(float4(as_type<char4>(u32_from16(q, k))), xv[k]);
    return d * acc;
}
inline float dotv_q4_0(device const uchar* b, thread const float4* xv) {
    float d = f16_at(b);
    device const ushort* q = (device const ushort*)(b + 2);
    float acc = 0;
    for (int k = 0; k < 4; ++k) {
        uint w = u32_from16(q, k);
        acc += dot(float4(as_type<uchar4>(w & 0x0F0F0F0Fu)) - 8.0f, xv[k])
             + dot(float4(as_type<uchar4>((w >> 4) & 0x0F0F0F0Fu)) - 8.0f, xv[k + 4]);
    }
    return d * acc;
}
// Chunk j (0..7) of a Q4_K superblock; xsum is the sum of the chunk's x.
inline float pdotv_q4_K(device const uchar* b, thread const float4* xv, uint j, float xsum) {
    float d = f16_at(b), dmin = f16_at(b + 2);
    float sc, mn;
    scale_min_k4(int(j), b + 4, sc, mn);
    device const uint4* q = (device const uint4*)(b + 16 + (j >> 1) * 32);
    uint shift = (j & 1) ? 4 : 0;
    uint4 v0 = q[0], v1 = q[1];
    uint w[8] = { v0.x, v0.y, v0.z, v0.w, v1.x, v1.y, v1.z, v1.w };
    float a = 0;
    for (int k = 0; k < 8; ++k) a += dot(float4(as_type<uchar4>((w[k] >> shift) & 0x0F0F0F0Fu)), xv[k]);
    return d * sc * a - dmin * mn * xsum;
}
inline float pdotv_q6_K(device const uchar* b, thread const float4* xv, uint j, float xsum) {
    uint n = j >> 2, k = j & 3;
    device const ushort* ql = (device const ushort*)(b + n * 64 + ((k & 1) ? 32 : 0));
    device const ushort* qh = (device const ushort*)(b + 128 + n * 32);
    device const char* sc = (device const char*)(b + 192 + n * 8);
    float d = f16_at(b + 208);
    uint lowShift = (k & 2) ? 4 : 0, highShift = 2 * k;
    float a0 = 0, a1 = 0;
    for (int m = 0; m < 8; ++m) {
        uint q = ((u32_from16(ql, m) >> lowShift) & 0x0F0F0F0Fu) | (((u32_from16(qh, m) >> highShift) & 0x03030303u) << 4);
        float t = dot(float4(as_type<uchar4>(q)) - 32.0f, xv[m]);
        if (m < 4) a0 += t; else a1 += t;
    }
    return d * (float(sc[2 * k]) * a0 + float(sc[2 * k + 1]) * a1);
}

#define LOAD_XV(XV, SRC) \
    { device const float4* x4 = (device const float4*)(SRC); for (int q = 0; q < 8; ++q) XV[q] = x4[q]; }
// LANES = 32: a simdgroup covers R rows. LANES = 16: each half-simdgroup
// covers its own R rows, which keeps all lanes busy on short rows (< 2048 columns).
inline float lanes_sum(float v, uint lanes) {
    if (lanes == 32) return simd_sum(v);
    v += simd_shuffle_xor(v, 8);
    v += simd_shuffle_xor(v, 4);
    v += simd_shuffle_xor(v, 2);
    v += simd_shuffle_xor(v, 1);
    return v;
}
#define MATVEC_RV(NAME, BYTES, DOTV, R, LANES) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 device const float* bias [[buffer(4)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint l = lane % LANES; \
    uint row0 = ((tg * 4 + sg) * (32 / LANES) + lane / LANES) * R; \
    uint blocks = row0 < a.rows ? a.cols / 32 : 0; \
    float acc[R]; \
    for (uint r = 0; r < R; ++r) acc[r] = 0; \
    for (uint b = l; b < blocks; b += LANES) { \
        float4 xv[8]; \
        LOAD_XV(xv, x + b * 32) \
        for (uint r = 0; r < R; ++r) { \
            if (row0 + r < a.rows) acc[r] += DOTV(W + ulong(row0 + r) * a.rowBytes + ulong(b) * BYTES, (thread const float4*)xv); \
        } \
    } \
    for (uint r = 0; r < R; ++r) { \
        float total = lanes_sum(acc[r], LANES); \
        if (l == 0 && row0 + r < a.rows) y[row0 + r] = matvec_out(total, row0 + r, y, bias, a); \
    } \
}
#define MATVEC_KRV(NAME, BYTES, PDOTV, R, LANES) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 device const float* bias [[buffer(4)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint l = lane % LANES; \
    uint row0 = ((tg * 4 + sg) * (32 / LANES) + lane / LANES) * R; \
    uint items = row0 < a.rows ? (a.cols / 256) * 8 : 0; \
    float acc[R]; \
    for (uint r = 0; r < R; ++r) acc[r] = 0; \
    for (uint i = l; i < items; i += LANES) { \
        uint blk = i >> 3, j = i & 7; \
        float4 xv[8]; \
        LOAD_XV(xv, x + blk * 256 + j * 32) \
        float4 s4 = xv[0] + xv[1] + xv[2] + xv[3] + xv[4] + xv[5] + xv[6] + xv[7]; \
        float xsum = s4.x + s4.y + s4.z + s4.w; \
        for (uint r = 0; r < R; ++r) { \
            if (row0 + r < a.rows) acc[r] += PDOTV(W + ulong(row0 + r) * a.rowBytes + ulong(blk) * BYTES, (thread const float4*)xv, j, xsum); \
        } \
    } \
    for (uint r = 0; r < R; ++r) { \
        float total = lanes_sum(acc[r], LANES); \
        if (l == 0 && row0 + r < a.rows) y[row0 + r] = matvec_out(total, row0 + r, y, bias, a); \
    } \
}

MATVEC(matvec_f32, 32, 128, dot_f32_32)
MATVEC(matvec_f16, 32, 64, dot_f16_32)
MATVEC(matvec_bf16, 32, 64, dot_bf16_32)
MATVEC(matvec_q4_0, 32, 18, dot_q4_0)
MATVEC(matvec_q4_1, 32, 20, dot_q4_1)
MATVEC(matvec_q5_0, 32, 22, dot_q5_0)
MATVEC(matvec_q5_1, 32, 24, dot_q5_1)
MATVEC(matvec_q8_0, 32, 34, dot_q8_0)
MATVEC(matvec_q2_K, 256, 84, dot_q2_K)
MATVEC(matvec_q3_K, 256, 110, dot_q3_K)
MATVEC_K(matvec_q4_K, 144, pdot_q4_K)
MATVEC_K(matvec_q5_K, 176, pdot_q5_K)
MATVEC_K(matvec_q6_K, 210, pdot_q6_K)
MATVEC_K(matvec_q8_K, 292, pdot_q8_K)
MATVEC_R(matvec_f32_r2, 128, dot_f32_32, 2)
MATVEC_R(matvec_f16_r2, 64, dot_f16_32, 2)
MATVEC_R(matvec_bf16_r2, 64, dot_bf16_32, 2)
MATVEC_RV(matvec_q4_0_r2, 18, dotv_q4_0, 2, 32)
MATVEC_RV(matvec_q4_0_h2, 18, dotv_q4_0, 2, 16)
MATVEC_R(matvec_q4_1_r2, 20, dot_q4_1, 2)
MATVEC_R(matvec_q5_0_r2, 22, dot_q5_0, 2)
MATVEC_R(matvec_q5_1_r2, 24, dot_q5_1, 2)
MATVEC_RV(matvec_q8_0_r2, 34, dotv_q8_0, 2, 32)
MATVEC_RV(matvec_q8_0_h2, 34, dotv_q8_0, 2, 16)
MATVEC_KRV(matvec_q4_K_r2, 144, pdotv_q4_K, 2, 32)
MATVEC_KRV(matvec_q4_K_h2, 144, pdotv_q4_K, 2, 16)
MATVEC_KR(matvec_q5_K_r2, 176, pdot_q5_K, 2)
MATVEC_KRV(matvec_q6_K_r2, 210, pdotv_q6_K, 2, 32)
MATVEC_KRV(matvec_q6_K_h2, 210, pdotv_q6_K, 2, 16)
MATVEC_KR(matvec_q8_K_r2, 292, pdot_q8_K, 2)
MATVEC_R(matvec_f32_r4, 128, dot_f32_32, 4)
MATVEC_R(matvec_f16_r4, 64, dot_f16_32, 4)
MATVEC_R(matvec_bf16_r4, 64, dot_bf16_32, 4)
MATVEC_RV(matvec_q4_0_r4, 18, dotv_q4_0, 4, 32)
MATVEC_RV(matvec_q4_0_h4, 18, dotv_q4_0, 4, 16)
MATVEC_R(matvec_q4_1_r4, 20, dot_q4_1, 4)
MATVEC_R(matvec_q5_0_r4, 22, dot_q5_0, 4)
MATVEC_R(matvec_q5_1_r4, 24, dot_q5_1, 4)
MATVEC_RV(matvec_q8_0_r4, 34, dotv_q8_0, 4, 32)
MATVEC_RV(matvec_q8_0_h4, 34, dotv_q8_0, 4, 16)
MATVEC_KRV(matvec_q4_K_r4, 144, pdotv_q4_K, 4, 32)
MATVEC_KRV(matvec_q4_K_h4, 144, pdotv_q4_K, 4, 16)
MATVEC_KR(matvec_q5_K_r4, 176, pdot_q5_K, 4)
MATVEC_KRV(matvec_q6_K_r4, 210, pdotv_q6_K, 4, 32)
MATVEC_KRV(matvec_q6_K_h4, 210, pdotv_q6_K, 4, 16)
MATVEC_KR(matvec_q8_K_r4, 292, pdot_q8_K, 4)

// ---- elementwise and reductions ----

struct NormArgs { uint n; float eps; };

// One threadgroup per row of length n; weight is shared across rows.
kernel void rms_norm(device const float* x [[buffer(0)]], device const float* w [[buffer(1)]],
                     device float* y [[buffer(2)]], constant NormArgs& a [[buffer(3)]],
                     uint row [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]],
                     uint threads [[threads_per_threadgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                     uint lane [[thread_index_in_simdgroup]]) {
    threadgroup float partial[32];
    device const float* xr = x + ulong(row) * a.n;
    device float* yr = y + ulong(row) * a.n;
    float sum = 0;
    for (uint i = tid; i < a.n; i += threads) sum += xr[i] * xr[i];
    sum = simd_sum(sum);
    if (lane == 0) partial[sg] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sg == 0) {
        uint groups = (threads + 31) / 32;
        float v = lane < groups ? partial[lane] : 0;
        v = simd_sum(v);
        if (lane == 0) partial[0] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float scale = rsqrt(partial[0] / float(a.n) + a.eps);
    for (uint i = tid; i < a.n; i += threads) yr[i] = xr[i] * scale * w[i];
}

kernel void add_inplace(device float* y [[buffer(0)]], device const float* x [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    y[i] += x[i];
}

kernel void silu_mul(device float* g [[buffer(0)]], device const float* u [[buffer(1)]],
                     uint i [[thread_position_in_grid]]) {
    float v = g[i];
    g[i] = v / (1.0f + exp(-v)) * u[i];
}

struct RopeArgs { uint headDim; uint pairs; uint position; uint neox; };

kernel void rope(device float* v [[buffer(0)]], device const float* inv [[buffer(1)]],
                 constant RopeArgs& a [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
    uint i = gid.x, h = gid.y;
    if (i >= a.pairs) return;
    device float* head = v + ulong(h) * a.headDim;
    float theta = float(a.position) * inv[i];
    float c = cos(theta), s = sin(theta);
    uint p = a.neox ? i : 2 * i;
    uint q = a.neox ? i + a.pairs : 2 * i + 1;
    float x0 = head[p], x1 = head[q];
    head[p] = x0 * c - x1 * s;
    head[q] = x0 * s + x1 * c;
}

kernel void get_row_f32(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    dst[i] = src[i];
}

struct AttnArgs { uint headDim; uint valueDim; uint keyWidth; uint valueWidth; uint group; uint context; uint span; float scale; };

// scores[h][t] = q_h · K[t][kvh] * scale
kernel void attn_scores(device const float* q [[buffer(0)]], device const float* K [[buffer(1)]],
                        device float* s [[buffer(2)]], constant AttnArgs& a [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint t = gid.x, h = gid.y;
    if (t >= a.span) return;
    uint kvh = h / a.group;
    device const float* qh = q + ulong(h) * a.headDim;
    device const float* kt = K + ulong(t) * a.keyWidth + ulong(kvh) * a.headDim;
    float acc = 0;
    for (uint d = 0; d < a.headDim; ++d) acc += qh[d] * kt[d];
    s[ulong(h) * a.context + t] = acc * a.scale;
}

// Row-wise softmax over the first `span` scores of each head (one threadgroup per head).
kernel void attn_softmax(device float* s [[buffer(0)]], constant AttnArgs& a [[buffer(1)]],
                         uint h [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]],
                         uint threads [[threads_per_threadgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                         uint lane [[thread_index_in_simdgroup]]) {
    threadgroup float partial[32];
    device float* row = s + ulong(h) * a.context;
    uint groups = (threads + 31) / 32;
    float m = -INFINITY;
    for (uint t = tid; t < a.span; t += threads) m = max(m, row[t]);
    m = simd_max(m);
    if (lane == 0) partial[sg] = m;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sg == 0) {
        float v = lane < groups ? partial[lane] : -INFINITY;
        v = simd_max(v);
        if (lane == 0) partial[0] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float maximum = partial[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float sum = 0;
    for (uint t = tid; t < a.span; t += threads) {
        float e = exp(row[t] - maximum);
        row[t] = e;
        sum += e;
    }
    sum = simd_sum(sum);
    if (lane == 0) partial[sg] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sg == 0) {
        float v = lane < groups ? partial[lane] : 0;
        v = simd_sum(v);
        if (lane == 0) partial[0] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inverse = 1.0f / partial[0];
    for (uint t = tid; t < a.span; t += threads) row[t] *= inverse;
}

// Fused decode attention, one threadgroup per head: scores, softmax and the
// weighted value sum in a single dispatch. Same arithmetic as attn_scores,
// attn_softmax and attn_values.
kernel void attn_fused(device const float* q [[buffer(0)]], device const float* K [[buffer(1)]],
                       device const float* V [[buffer(2)]], device float* s [[buffer(3)]],
                       device float* out [[buffer(4)]], constant AttnArgs& a [[buffer(5)]],
                       uint h [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]],
                       uint threads [[threads_per_threadgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                       uint lane [[thread_index_in_simdgroup]]) {
    threadgroup float partial[32];
    uint kvh = h / a.group;
    uint groups = (threads + 31) / 32;
    device const float* qh = q + ulong(h) * a.headDim;
    device float* row = s + ulong(h) * a.context;
    float m = -INFINITY;
    for (uint t = tid; t < a.span; t += threads) {
        device const float* kt = K + ulong(t) * a.keyWidth + ulong(kvh) * a.headDim;
        float acc = 0;
        for (uint d = 0; d < a.headDim; ++d) acc += qh[d] * kt[d];
        float score = acc * a.scale;
        row[t] = score;
        m = max(m, score);
    }
    m = simd_max(m);
    if (lane == 0) partial[sg] = m;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sg == 0) {
        float v = lane < groups ? partial[lane] : -INFINITY;
        v = simd_max(v);
        if (lane == 0) partial[0] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float maximum = partial[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float sum = 0;
    for (uint t = tid; t < a.span; t += threads) {
        float e = exp(row[t] - maximum);
        row[t] = e;
        sum += e;
    }
    sum = simd_sum(sum);
    if (lane == 0) partial[sg] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sg == 0) {
        float v = lane < groups ? partial[lane] : 0;
        v = simd_sum(v);
        if (lane == 0) partial[0] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
    float inverse = 1.0f / partial[0];
    for (uint t = tid; t < a.span; t += threads) row[t] *= inverse;
    threadgroup_barrier(mem_flags::mem_device);
    for (uint d = tid; d < a.valueDim; d += threads) {
        float acc = 0;
        for (uint t = 0; t < a.span; ++t) acc += row[t] * V[ulong(t) * a.valueWidth + ulong(kvh) * a.valueDim + d];
        out[ulong(h) * a.valueDim + d] = acc;
    }
}

// out[h][d] = Σ_t p[h][t] · V[t][kvh][d]
kernel void attn_values(device const float* s [[buffer(0)]], device const float* V [[buffer(1)]],
                        device float* out [[buffer(2)]], constant AttnArgs& a [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint d = gid.x, h = gid.y;
    if (d >= a.valueDim) return;
    uint kvh = h / a.group;
    device const float* p = s + ulong(h) * a.context;
    float acc = 0;
    for (uint t = 0; t < a.span; ++t) acc += p[t] * V[ulong(t) * a.valueWidth + ulong(kvh) * a.valueDim + d];
    out[ulong(h) * a.valueDim + d] = acc;
}
"""#
}
