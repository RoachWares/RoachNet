enum MetalKernelSource {
    static let source = base + cacheKernels("float", "") + cacheKernels("half", "_h")
    static let base = #"""
        #include <metal_stdlib>
        #include <metal_simdgroup_matrix>
        using namespace metal;

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

        template <typename X, typename A = float> inline A dot_f32_32(device const uchar* b, X x) {
            device const float* w = (device const float*)b;
            A acc = A(0);
            for (int j = 0; j < 32; ++j) acc += w[j] * x[j];
            return acc;
        }
        template <typename X, typename A = float> inline A dot_f16_32(device const uchar* b, X x) {
            device const half* w = (device const half*)b;
            A acc = A(0);
            for (int j = 0; j < 32; ++j) acc += float(w[j]) * x[j];
            return acc;
        }
        template <typename X, typename A = float> inline A dot_bf16_32(device const uchar* b, X x) {
            device const ushort* w = (device const ushort*)b;
            A acc = A(0);
            for (int j = 0; j < 32; ++j) acc += as_type<float>(uint(w[j]) << 16) * x[j];
            return acc;
        }
        template <typename X, typename A = float> inline A dot_q4_0(device const uchar* b, X x) {
            float d = f16_at(b);
            device const ushort* q = (device const ushort*)(b + 2);
            A acc = A(0);
            for (int m = 0; m < 8; ++m) {
                uint w = q[m];
                acc += float(int(w & 0x0F) - 8) * x[2 * m] + float(int((w >> 8) & 0x0F) - 8) * x[2 * m + 1]
                     + float(int((w >> 4) & 0x0F) - 8) * x[2 * m + 16] + float(int((w >> 12) & 0x0F) - 8) * x[2 * m + 17];
            }
            return d * acc;
        }
        template <typename X, typename A = float> inline A dot_q4_1(device const uchar* b, X x) {
            float d = f16_at(b), m = f16_at(b + 2);
            A acc = A(0), sum = A(0);
            for (int j = 0; j < 16; ++j) {
                uchar q = b[4 + j];
                acc += float(q & 0x0F) * x[j] + float(q >> 4) * x[j + 16];
                sum += x[j] + x[j + 16];
            }
            return d * acc + m * sum;
        }
        template <typename X, typename A = float> inline A dot_q5_0(device const uchar* b, X x) {
            float d = f16_at(b);
            device const ushort* h = (device const ushort*)(b + 2);
            uint qh = uint(h[0]) | (uint(h[1]) << 16);
            device const ushort* q = (device const ushort*)(b + 6);
            A acc = A(0);
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
        template <typename X, typename A = float> inline A dot_q5_1(device const uchar* b, X x) {
            float d = f16_at(b), m = f16_at(b + 2);
            uint qh = u32_at(b + 4);
            A acc = A(0), sum = A(0);
            for (int j = 0; j < 16; ++j) {
                uchar q = b[8 + j];
                uint h0 = ((qh >> uint(j)) << 4) & 0x10;
                uint h1 = (qh >> uint(j + 12)) & 0x10;
                acc += float((q & 0x0F) | h0) * x[j] + float((q >> 4) | h1) * x[j + 16];
                sum += x[j] + x[j + 16];
            }
            return d * acc + m * sum;
        }
        template <typename X, typename A = float> inline A dot_q8_0(device const uchar* b, X x) {
            float d = f16_at(b);
            device const ushort* q = (device const ushort*)(b + 2);
            A acc = A(0);
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

        template <typename X, typename A = float> inline A pdot_q4_K(device const uchar* b, X xs, uint j) {
            float d = f16_at(b), dmin = f16_at(b + 2);
            float sc, mn;
            scale_min_k4(int(j), b + 4, sc, mn);
            device const uint4* q = (device const uint4*)(b + 16 + (j >> 1) * 32);
            uint shift = (j & 1) ? 4 : 0;
            A a = A(0), s = A(0);
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
        template <typename X, typename A = float> inline A pdot_q5_K(device const uchar* b, X xs, uint j) {
            float d = f16_at(b), dmin = f16_at(b + 2);
            float sc, mn;
            scale_min_k4(int(j), b + 4, sc, mn);
            device const uchar* qh = b + 16;
            device const uchar* ql = b + 48 + (j >> 1) * 32;
            uint shift = (j & 1) ? 4 : 0;
            A a = A(0), s = A(0);
            for (int l = 0; l < 32; ++l) {
                a += float(int((ql[l] >> shift) & 0x0F) + (((qh[l] >> j) & 1) ? 16 : 0)) * xs[l];
                s += xs[l];
            }
            return d * sc * a - dmin * mn * s;
        }
        template <typename X, typename A = float> inline A pdot_q6_K(device const uchar* b, X xs, uint j) {
            uint n = j >> 2, k = j & 3;
            device const ushort* ql = (device const ushort*)(b + n * 64 + ((k & 1) ? 32 : 0));
            device const ushort* qh = (device const ushort*)(b + 128 + n * 32);
            device const char* sc = (device const char*)(b + 192 + n * 8);
            float d = f16_at(b + 208);
            uint lowShift = (k & 2) ? 4 : 0, highShift = 2 * k;
            A a0 = A(0), a1 = A(0);
            for (int m = 0; m < 16; ++m) {
                uint lw = ql[m], hw = qh[m];
                A v0 = float(int(((lw >> lowShift) & 0x0F) | (((hw >> highShift) & 3) << 4)) - 32) * xs[2 * m];
                A v1 = float(int(((lw >> (8 + lowShift)) & 0x0F) | (((hw >> (8 + highShift)) & 3) << 4)) - 32) * xs[2 * m + 1];
                if (m < 8) a0 += v0 + v1; else a1 += v0 + v1;
            }
            return d * (float(sc[2 * k]) * a0 + float(sc[2 * k + 1]) * a1);
        }
        template <typename X, typename A = float> inline A pdot_q8_K(device const uchar* b, X xs, uint j) {
            float d = *(device const float*)b;
            device const char* q = (device const char*)(b + 4) + j * 32;
            A a = A(0);
            for (int l = 0; l < 32; ++l) a += float(q[l]) * xs[l];
            return d * a;
        }

        struct MatvecArgs { uint cols; uint rowBytes; uint rows; uint flags; };

        inline float matvec_out(float v, uint row, device float* y, device const float* bias, constant MatvecArgs& a) {
            if (a.flags & 2u) v += bias[row];
            if (a.flags & 1u) v += y[row];
            return v;
        }

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

        struct NormArgs { uint n; float eps; };

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

        struct MatmulArgs { uint cols; uint rowBytes; uint rows; uint flags; uint groups; };

        inline void matmul_store(float4 v, uint row, uint g, device float4* y, device const float* bias, constant MatmulArgs& a) {
            if (a.flags & 2u) v += bias[row];
            ulong index = ulong(g) * a.rows + row;
            if (a.flags & 1u) v += y[index];
            y[index] = v;
        }
        #define MM_DOT32(NAME, DOT, BYTES) \
        inline float4 NAME(device const uchar* r, uint kc, threadgroup const float4* xs) { \
            return DOT<threadgroup const float4*, float4>(r + ulong(kc) * BYTES, xs); }
        #define MM_DOTK(NAME, PDOT, BYTES) \
        inline float4 NAME(device const uchar* r, uint kc, threadgroup const float4* xs) { \
            return PDOT<threadgroup const float4*, float4>(r + ulong(kc >> 3) * BYTES, xs, kc & 7); }
        #define MATMUL(NAME, CALL) \
        kernel void NAME(device const uchar* W [[buffer(0)]], device const float4* x [[buffer(1)]], \
                         device float4* y [[buffer(2)]], constant MatmulArgs& a [[buffer(3)]], \
                         device const float* bias [[buffer(4)]], \
                         uint2 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]], \
                         uint sg [[simdgroup_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]]) { \
            threadgroup float4 tile[8 * 32]; \
            uint row = tg.x * 32 + sg * 8 + (lane & 7); \
            uint g0 = tg.y * 8; \
            uint ga = lane >> 3, gb = ga + 4; \
            bool live = row < a.rows; \
            device const uchar* r = W + ulong(min(row, a.rows - 1)) * a.rowBytes; \
            float4 acc0 = float4(0), acc1 = float4(0); \
            uint chunks = a.cols / 32; \
            for (uint kc = 0; kc < chunks; ++kc) { \
                threadgroup_barrier(mem_flags::mem_threadgroup); \
                for (uint i = tid; i < 8 * 32; i += 128) { \
                    uint g = g0 + i / 32; \
                    tile[i] = g < a.groups ? x[ulong(g) * a.cols + kc * 32 + (i & 31)] : float4(0); \
                } \
                threadgroup_barrier(mem_flags::mem_threadgroup); \
                if (live) { \
                    acc0 += CALL(r, kc, (threadgroup const float4*)(tile + ga * 32)); \
                    acc1 += CALL(r, kc, (threadgroup const float4*)(tile + gb * 32)); \
                } \
            } \
            if (live) { \
                if (g0 + ga < a.groups) matmul_store(acc0, row, g0 + ga, y, bias, a); \
                if (g0 + gb < a.groups) matmul_store(acc1, row, g0 + gb, y, bias, a); \
            } \
        }

        MM_DOT32(mmd_f32, dot_f32_32, 128)
        MM_DOT32(mmd_f16, dot_f16_32, 64)
        MM_DOT32(mmd_bf16, dot_bf16_32, 64)
        MM_DOT32(mmd_q4_0, dot_q4_0, 18)
        MM_DOT32(mmd_q4_1, dot_q4_1, 20)
        MM_DOT32(mmd_q5_0, dot_q5_0, 22)
        MM_DOT32(mmd_q5_1, dot_q5_1, 24)
        MM_DOT32(mmd_q8_0, dot_q8_0, 34)
        MM_DOTK(mmd_q4_K, pdot_q4_K, 144)
        MM_DOTK(mmd_q5_K, pdot_q5_K, 176)
        MM_DOTK(mmd_q6_K, pdot_q6_K, 210)
        MM_DOTK(mmd_q8_K, pdot_q8_K, 292)
        MATMUL(matmul_f32, mmd_f32)
        MATMUL(matmul_f16, mmd_f16)
        MATMUL(matmul_bf16, mmd_bf16)
        MATMUL(matmul_q4_0, mmd_q4_0)
        MATMUL(matmul_q4_1, mmd_q4_1)
        MATMUL(matmul_q5_0, mmd_q5_0)
        MATMUL(matmul_q5_1, mmd_q5_1)
        MATMUL(matmul_q8_0, mmd_q8_0)
        MATMUL(matmul_q4_K, mmd_q4_K)
        MATMUL(matmul_q5_K, mmd_q5_K)
        MATMUL(matmul_q6_K, mmd_q6_K)
        MATMUL(matmul_q8_K, mmd_q8_K)

        kernel void rms_norm4(device const float4* x [[buffer(0)]], device const float* w [[buffer(1)]],
                              device float4* y [[buffer(2)]], constant NormArgs& a [[buffer(3)]],
                              uint row [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]],
                              uint threads [[threads_per_threadgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                              uint lane [[thread_index_in_simdgroup]]) {
            threadgroup float4 partial[32];
            device const float4* xr = x + ulong(row) * a.n;
            device float4* yr = y + ulong(row) * a.n;
            float4 sum = float4(0);
            for (uint i = tid; i < a.n; i += threads) sum += xr[i] * xr[i];
            sum = simd_sum(sum);
            if (lane == 0) partial[sg] = sum;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (sg == 0) {
                uint groups = (threads + 31) / 32;
                float4 v = lane < groups ? partial[lane] : float4(0);
                v = simd_sum(v);
                if (lane == 0) partial[0] = v;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            float4 scale = rsqrt(partial[0] / float(a.n) + a.eps);
            for (uint i = tid; i < a.n; i += threads) yr[i] = xr[i] * scale * w[i];
        }

        struct Rope4Args { uint headDim; uint pairs; uint start; uint neox; uint heads; };

        kernel void rope4(device float4* v [[buffer(0)]], device const float* inv [[buffer(1)]],
                          constant Rope4Args& a [[buffer(2)]], uint3 gid [[thread_position_in_grid]]) {
            uint i = gid.x, h = gid.y, g = gid.z;
            if (i >= a.pairs) return;
            device float4* head = v + (ulong(g) * a.heads + h) * a.headDim;
            float4 position = float4(float(a.start + 4 * g), float(a.start + 4 * g + 1), float(a.start + 4 * g + 2), float(a.start + 4 * g + 3));
            float4 theta = position * inv[i];
            float4 c = cos(theta), s = sin(theta);
            uint p = a.neox ? i : 2 * i;
            uint q = a.neox ? i + a.pairs : 2 * i + 1;
            float4 x0 = head[p], x1 = head[q];
            head[p] = x0 * c - x1 * s;
            head[q] = x0 * s + x1 * c;
        }

        struct KVStoreArgs { uint width; uint count; };

        struct Attn4Args { uint headDim; uint valueDim; uint keyWidth; uint valueWidth; uint group; uint heads; uint start; uint count; float scale; };

        kernel void take4(device const float4* src [[buffer(0)]], device float* dst [[buffer(1)]],
                          constant uint2& a [[buffer(2)]], uint i [[thread_position_in_grid]]) {
            if (i < a.x) dst[i] = src[i][a.y];
        }

        #define DQ32(NAME, BYTES) template <typename P> inline void NAME(device const uchar* r, uint kc, uint il, P dst) { \
            device const uchar* b = r + ulong(kc) * BYTES;
        #define DQK(NAME, BYTES) template <typename P> inline void NAME(device const uchar* r, uint kc, uint il, P dst) { \
            device const uchar* b = r + ulong(kc >> 3) * BYTES; uint j = kc & 7;

        DQ32(dq_f32, 128)
            device const float* w = (device const float*)b + il * 16;
            for (int i = 0; i < 16; ++i) dst[i] = w[i];
        }
        DQ32(dq_f16, 64)
            device const half* w = (device const half*)b + il * 16;
            for (int i = 0; i < 16; ++i) dst[i] = float(w[i]);
        }
        DQ32(dq_bf16, 64)
            device const ushort* w = (device const ushort*)b + il * 16;
            for (int i = 0; i < 16; ++i) dst[i] = as_type<float>(uint(w[i]) << 16);
        }
        DQ32(dq_q4_0, 18)
            float d = f16_at(b);
            device const uchar* q = b + 2;
            for (int i = 0; i < 16; ++i) dst[i] = d * float(int(il ? (q[i] >> 4) : (q[i] & 0x0F)) - 8);
        }
        DQ32(dq_q4_1, 20)
            float d = f16_at(b), m = f16_at(b + 2);
            device const uchar* q = b + 4;
            for (int i = 0; i < 16; ++i) dst[i] = d * float(il ? (q[i] >> 4) : (q[i] & 0x0F)) + m;
        }
        DQ32(dq_q5_0, 22)
            float d = f16_at(b);
            device const ushort* h = (device const ushort*)(b + 2);
            uint qh = uint(h[0]) | (uint(h[1]) << 16);
            device const uchar* q = b + 6;
            for (uint i = 0; i < 16; ++i) {
                uint v = il ? ((uint(q[i]) >> 4) | ((qh >> (i + 12)) & 0x10)) : ((uint(q[i]) & 0x0F) | (((qh >> i) << 4) & 0x10));
                dst[i] = d * float(int(v) - 16);
            }
        }
        DQ32(dq_q5_1, 24)
            float d = f16_at(b), m = f16_at(b + 2);
            uint qh = u32_at(b + 4);
            device const uchar* q = b + 8;
            for (uint i = 0; i < 16; ++i) {
                uint v = il ? ((uint(q[i]) >> 4) | ((qh >> (i + 12)) & 0x10)) : ((uint(q[i]) & 0x0F) | (((qh >> i) << 4) & 0x10));
                dst[i] = d * float(v) + m;
            }
        }
        DQ32(dq_q8_0, 34)
            float d = f16_at(b);
            device const char* q = (device const char*)(b + 2) + il * 16;
            for (int i = 0; i < 16; ++i) dst[i] = d * float(q[i]);
        }
        DQK(dq_q4_K, 144)
            float d = f16_at(b), dmin = f16_at(b + 2);
            float sc, mn;
            scale_min_k4(int(j), b + 4, sc, mn);
            float scale = d * sc, offset = dmin * mn;
            device const uchar* q = b + 16 + (j >> 1) * 32 + il * 16;
            uint shift = (j & 1) ? 4 : 0;
            for (int i = 0; i < 16; ++i) dst[i] = scale * float((q[i] >> shift) & 0x0F) - offset;
        }
        DQK(dq_q5_K, 176)
            float d = f16_at(b), dmin = f16_at(b + 2);
            float sc, mn;
            scale_min_k4(int(j), b + 4, sc, mn);
            float scale = d * sc, offset = dmin * mn;
            device const uchar* qh = b + 16 + il * 16;
            device const uchar* ql = b + 48 + (j >> 1) * 32 + il * 16;
            uint shift = (j & 1) ? 4 : 0;
            for (int i = 0; i < 16; ++i) dst[i] = scale * float(int((ql[i] >> shift) & 0x0F) + (((qh[i] >> j) & 1) ? 16 : 0)) - offset;
        }
        DQK(dq_q6_K, 210)
            uint n = j >> 2, k = j & 3;
            device const uchar* ql = b + n * 64 + ((k & 1) ? 32 : 0) + il * 16;
            device const uchar* qh = b + 128 + n * 32 + il * 16;
            device const char* sc = (device const char*)(b + 192 + n * 8);
            float scale = f16_at(b + 208) * float(sc[2 * k + il]);
            uint lowShift = (k & 2) ? 4 : 0, highShift = 2 * k;
            for (int i = 0; i < 16; ++i) {
                uint q = ((ql[i] >> lowShift) & 0x0F) | (((qh[i] >> highShift) & 3) << 4);
                dst[i] = scale * float(int(q) - 32);
            }
        }
        DQK(dq_q8_K, 292)
            float d = *(device const float*)b;
            device const char* q = (device const char*)(b + 4) + j * 32 + il * 16;
            for (int i = 0; i < 16; ++i) dst[i] = d * float(q[i]);
        }

        #define MATMUL_SG(NAME, DEQ) \
        kernel void NAME(device const uchar* W [[buffer(0)]], device const float4* x [[buffer(1)]], \
                         device float4* y [[buffer(2)]], constant MatmulArgs& a [[buffer(3)]], \
                         device const float* bias [[buffer(4)]], \
                         uint2 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]], \
                         uint sg [[simdgroup_index_in_threadgroup]]) { \
            threadgroup float sa[64 * 32]; \
            threadgroup float sb[32 * 32]; \
            uint r0 = tg.x * 64, g0 = tg.y * 8; \
            simdgroup_float8x8 acc[2][4]; \
            for (int i = 0; i < 2; ++i) for (int jj = 0; jj < 4; ++jj) acc[i][jj] = simdgroup_float8x8(0); \
            uint lrow = tid >> 1, il = tid & 1, grow = r0 + lrow; \
            device const uchar* wr = W + ulong(min(grow, a.rows - 1)) * a.rowBytes; \
            threadgroup float* wdst = sa + lrow * 32 + il * 16; \
            uint chunks = a.cols / 32; \
            for (uint kc = 0; kc < chunks; ++kc) { \
                if (grow < a.rows) { DEQ(wr, kc, il, wdst); } else { for (int i = 0; i < 16; ++i) wdst[i] = 0; } \
                for (uint i = tid; i < 256; i += 128) { \
                    uint gl = i >> 5, k = i & 31, g = g0 + gl; \
                    float4 v = g < a.groups ? x[ulong(g) * a.cols + kc * 32 + k] : float4(0); \
                    threadgroup float* t = sb + gl * 4 * 32 + k; \
                    t[0] = v.x; t[32] = v.y; t[64] = v.z; t[96] = v.w; \
                } \
                threadgroup_barrier(mem_flags::mem_threadgroup); \
                for (uint kk = 0; kk < 32; kk += 8) { \
                    simdgroup_float8x8 A0, A1, B[4]; \
                    simdgroup_load(A0, sa + (sg * 16) * 32 + kk, 32); \
                    simdgroup_load(A1, sa + (sg * 16 + 8) * 32 + kk, 32); \
                    for (int jj = 0; jj < 4; ++jj) simdgroup_load(B[jj], sb + jj * 8 * 32 + kk, 32, ulong2(0, 0), true); \
                    for (int jj = 0; jj < 4; ++jj) { \
                        simdgroup_multiply_accumulate(acc[0][jj], A0, B[jj], acc[0][jj]); \
                        simdgroup_multiply_accumulate(acc[1][jj], A1, B[jj], acc[1][jj]); \
                    } \
                } \
                threadgroup_barrier(mem_flags::mem_threadgroup); \
            } \
            for (int i = 0; i < 2; ++i) for (int jj = 0; jj < 4; ++jj) \
                simdgroup_store(acc[i][jj], sa + (sg * 16 + i * 8) * 32 + jj * 8, 32); \
            threadgroup_barrier(mem_flags::mem_threadgroup); \
            for (uint i = tid; i < 64 * 8; i += 128) { \
                uint lr = i & 63, gl = i >> 6, row = r0 + lr, g = g0 + gl; \
                if (row < a.rows && g < a.groups) { \
                    threadgroup float* o = sa + lr * 32 + gl * 4; \
                    matmul_store(float4(o[0], o[1], o[2], o[3]), row, g, y, bias, a); \
                } \
            } \
        }

        MATMUL_SG(matmul_sg_f32, dq_f32)
        MATMUL_SG(matmul_sg_f16, dq_f16)
        MATMUL_SG(matmul_sg_bf16, dq_bf16)
        MATMUL_SG(matmul_sg_q4_0, dq_q4_0)
        MATMUL_SG(matmul_sg_q4_1, dq_q4_1)
        MATMUL_SG(matmul_sg_q5_0, dq_q5_0)
        MATMUL_SG(matmul_sg_q5_1, dq_q5_1)
        MATMUL_SG(matmul_sg_q8_0, dq_q8_0)
        MATMUL_SG(matmul_sg_q4_K, dq_q4_K)
        MATMUL_SG(matmul_sg_q5_K, dq_q5_K)
        MATMUL_SG(matmul_sg_q6_K, dq_q6_K)
        MATMUL_SG(matmul_sg_q8_K, dq_q8_K)
        #define MATMUL_SGH(NAME, DEQ, BT, BMAT) \
        kernel void NAME(device const uchar* W [[buffer(0)]], device const float4* x [[buffer(1)]], \
                         device float4* y [[buffer(2)]], constant MatmulArgs& a [[buffer(3)]], \
                         device const float* bias [[buffer(4)]], \
                         uint2 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]], \
                         uint sg [[simdgroup_index_in_threadgroup]]) { \
            threadgroup float smem[64 * 32]; \
            threadgroup half* sa = (threadgroup half*)smem; \
            threadgroup BT* sb = (threadgroup BT*)(smem + 64 * 32 / 2); \
            uint r0 = tg.x * 64, g0 = tg.y * 8; \
            simdgroup_float8x8 acc[2][4]; \
            for (int i = 0; i < 2; ++i) for (int jj = 0; jj < 4; ++jj) acc[i][jj] = simdgroup_float8x8(0); \
            uint lrow = tid >> 1, il = tid & 1, grow = r0 + lrow; \
            device const uchar* wr = W + ulong(min(grow, a.rows - 1)) * a.rowBytes; \
            threadgroup half* wdst = sa + lrow * 32 + il * 16; \
            uint chunks = a.cols / 32; \
            for (uint kc = 0; kc < chunks; ++kc) { \
                if (grow < a.rows) { DEQ(wr, kc, il, wdst); } else { for (int i = 0; i < 16; ++i) wdst[i] = 0; } \
                for (uint i = tid; i < 256; i += 128) { \
                    uint gl = i >> 5, k = i & 31, g = g0 + gl; \
                    float4 v = g < a.groups ? x[ulong(g) * a.cols + kc * 32 + k] : float4(0); \
                    threadgroup BT* t = sb + gl * 4 * 32 + k; \
                    t[0] = BT(v.x); t[32] = BT(v.y); t[64] = BT(v.z); t[96] = BT(v.w); \
                } \
                threadgroup_barrier(mem_flags::mem_threadgroup); \
                for (uint kk = 0; kk < 32; kk += 8) { \
                    simdgroup_half8x8 A0, A1; \
                    BMAT B[4]; \
                    simdgroup_load(A0, sa + (sg * 16) * 32 + kk, 32); \
                    simdgroup_load(A1, sa + (sg * 16 + 8) * 32 + kk, 32); \
                    for (int jj = 0; jj < 4; ++jj) simdgroup_load(B[jj], sb + jj * 8 * 32 + kk, 32, ulong2(0, 0), true); \
                    for (int jj = 0; jj < 4; ++jj) { \
                        simdgroup_multiply_accumulate(acc[0][jj], A0, B[jj], acc[0][jj]); \
                        simdgroup_multiply_accumulate(acc[1][jj], A1, B[jj], acc[1][jj]); \
                    } \
                } \
                threadgroup_barrier(mem_flags::mem_threadgroup); \
            } \
            for (int i = 0; i < 2; ++i) for (int jj = 0; jj < 4; ++jj) \
                simdgroup_store(acc[i][jj], smem + (sg * 16 + i * 8) * 32 + jj * 8, 32); \
            threadgroup_barrier(mem_flags::mem_threadgroup); \
            for (uint i = tid; i < 64 * 8; i += 128) { \
                uint lr = i & 63, gl = i >> 6, row = r0 + lr, g = g0 + gl; \
                if (row < a.rows && g < a.groups) { \
                    threadgroup float* o = smem + lr * 32 + gl * 4; \
                    matmul_store(float4(o[0], o[1], o[2], o[3]), row, g, y, bias, a); \
                } \
            } \
        }

        MATMUL_SGH(matmul_sgh_f32, dq_f32, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_f16, dq_f16, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_bf16, dq_bf16, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q4_0, dq_q4_0, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q4_1, dq_q4_1, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q5_0, dq_q5_0, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q5_1, dq_q5_1, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q8_0, dq_q8_0, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q4_K, dq_q4_K, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q5_K, dq_q5_K, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q6_K, dq_q6_K, float, simdgroup_float8x8)
        MATMUL_SGH(matmul_sgh_q8_K, dq_q8_K, float, simdgroup_float8x8)
        struct AttnSplitArgs { uint headDim; uint valueDim; uint keyWidth; uint valueWidth; uint group; uint heads; uint span; uint chunk; float scale; };

        kernel void attn_merge(device const float* part [[buffer(0)]], device float* out [[buffer(1)]],
                               constant AttnSplitArgs& a [[buffer(2)]],
                               uint h [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]],
                               uint threads [[threads_per_threadgroup]]) {
            uint chunks = (a.span + a.chunk - 1) / a.chunk;
            uint stride = 2 + a.valueDim;
            device const float* p = part + ulong(h) * chunks * stride;
            float top = -INFINITY;
            for (uint c = 0; c < chunks; ++c) top = max(top, p[c * stride]);
            float total = 0;
            for (uint c = 0; c < chunks; ++c) total += p[c * stride + 1] * exp(p[c * stride] - top);
            float inverse = 1.0f / total;
            for (uint d = tid; d < a.valueDim; d += threads) {
                float acc = 0;
                for (uint c = 0; c < chunks; ++c) acc += p[c * stride + 2 + d] * exp(p[c * stride] - top);
                out[ulong(h) * a.valueDim + d] = acc * inverse;
            }
        }
        """#
}
