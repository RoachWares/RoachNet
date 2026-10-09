// Hand-written Metal Shading Language kernels for RoachInference. Compiled at
// runtime from this source with MTLDevice.makeLibrary(source:); no Metal
// Performance Shaders, Accelerate, Core ML or third-party kernels are used.
// Each kernel mirrors a CPU reference in Quantization.swift / InferenceSession.swift.
enum MetalKernelSource {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

inline float f16_at(device const uchar* p) {
    ushort bits = ushort(p[0]) | (ushort(p[1]) << 8);
    return float(as_type<half>(bits));
}
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

inline float dot_f32_32(device const uchar* b, device const float* x) {
    device const float* w = (device const float*)b;
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += w[j] * x[j];
    return acc;
}
inline float dot_f16_32(device const uchar* b, device const float* x) {
    device const half* w = (device const half*)b;
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += float(w[j]) * x[j];
    return acc;
}
inline float dot_bf16_32(device const uchar* b, device const float* x) {
    device const ushort* w = (device const ushort*)b;
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += as_type<float>(uint(w[j]) << 16) * x[j];
    return acc;
}
inline float dot_q4_0(device const uchar* b, device const float* x) {
    float d = f16_at(b);
    float acc = 0;
    for (int j = 0; j < 16; ++j) {
        uchar q = b[2 + j];
        acc += float(int(q & 0x0F) - 8) * x[j] + float(int(q >> 4) - 8) * x[j + 16];
    }
    return d * acc;
}
inline float dot_q4_1(device const uchar* b, device const float* x) {
    float d = f16_at(b), m = f16_at(b + 2);
    float acc = 0, sum = 0;
    for (int j = 0; j < 16; ++j) {
        uchar q = b[4 + j];
        acc += float(q & 0x0F) * x[j] + float(q >> 4) * x[j + 16];
        sum += x[j] + x[j + 16];
    }
    return d * acc + m * sum;
}
inline float dot_q5_0(device const uchar* b, device const float* x) {
    float d = f16_at(b);
    uint qh = u32_at(b + 2);
    float acc = 0;
    for (int j = 0; j < 16; ++j) {
        uchar q = b[6 + j];
        uint h0 = ((qh >> uint(j)) << 4) & 0x10;
        uint h1 = (qh >> uint(j + 12)) & 0x10;
        acc += float(int((q & 0x0F) | h0) - 16) * x[j] + float(int((q >> 4) | h1) - 16) * x[j + 16];
    }
    return d * acc;
}
inline float dot_q5_1(device const uchar* b, device const float* x) {
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
inline float dot_q8_0(device const uchar* b, device const float* x) {
    float d = f16_at(b);
    device const char* q = (device const char*)(b + 2);
    float acc = 0;
    for (int j = 0; j < 32; ++j) acc += float(q[j]) * x[j];
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

struct MatvecArgs { uint cols; uint rowBytes; uint rows; };

// y[row] = W[row] · x. Four rows per threadgroup, one simdgroup (32 lanes)
// per row; lanes stride over the row's blocks and reduce with simd_sum.
#define MATVEC(NAME, BLOCK, BYTES, DOT) \
kernel void NAME(device const uchar* W [[buffer(0)]], device const float* x [[buffer(1)]], \
                 device float* y [[buffer(2)]], constant MatvecArgs& a [[buffer(3)]], \
                 uint tg [[threadgroup_position_in_grid]], uint sg [[simdgroup_index_in_threadgroup]], \
                 uint lane [[thread_index_in_simdgroup]]) { \
    uint row = tg * 4 + sg; \
    if (row >= a.rows) return; \
    device const uchar* r = W + ulong(row) * a.rowBytes; \
    uint blocks = a.cols / BLOCK; \
    float acc = 0; \
    for (uint b = lane; b < blocks; b += 32) acc += DOT(r + ulong(b) * BYTES, x + b * BLOCK); \
    acc = simd_sum(acc); \
    if (lane == 0) y[row] = acc; \
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
MATVEC(matvec_q4_K, 256, 144, dot_q4_K)
MATVEC(matvec_q5_K, 256, 176, dot_q5_K)
MATVEC(matvec_q6_K, 256, 210, dot_q6_K)
MATVEC(matvec_q8_K, 256, 292, dot_q8_K)

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
