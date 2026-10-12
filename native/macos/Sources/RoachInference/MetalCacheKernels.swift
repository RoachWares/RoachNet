// The kernels that read or write the KV cache, generated once for each cache
// element type: `float` (names as written) and `half` (names ending in `_h`).
// A half cache holds twice the context in the same memory and halves what
// attention reads per token; arithmetic stays in float either way.
extension MetalKernelSource {
    static func cacheKernels(_ T: String, _ suffix: String) -> String {
        """
        // Writes one token's key and value rows into the cache.
        kernel void kv_store\(suffix)(device const float* key [[buffer(0)]], device const float* value [[buffer(1)]],
                              device \(T)* keys [[buffer(2)]], device \(T)* values [[buffer(3)]],
                              constant uint2& w [[buffer(4)]], uint i [[thread_position_in_grid]]) {
            if (i < w.x) keys[i] = \(T)(key[i]);
            if (i < w.y) values[i] = \(T)(value[i]);
        }

        // Fused decode attention, one threadgroup per head: scores, softmax and
        // the weighted value sum in a single dispatch.
        kernel void attn_fused\(suffix)(device const float* q [[buffer(0)]], device const \(T)* K [[buffer(1)]],
                               device const \(T)* V [[buffer(2)]], device float* s [[buffer(3)]],
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
                device const \(T)* kt = K + ulong(t) * a.keyWidth + ulong(kvh) * a.headDim;
                float acc = 0;
                for (uint d = 0; d < a.headDim; ++d) acc += qh[d] * float(kt[d]);
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
                for (uint t = 0; t < a.span; ++t) acc += row[t] * float(V[ulong(t) * a.valueWidth + ulong(kvh) * a.valueDim + d]);
                out[ulong(h) * a.valueDim + d] = acc;
            }
        }

        // Unpacks four tokens' keys or values into consecutive cache rows.
        kernel void kv_store4\(suffix)(device const float4* src [[buffer(0)]], device \(T)* cache [[buffer(1)]],
                              constant KVStoreArgs& a [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
            uint i = gid.x, g = gid.y;
            if (i >= a.width) return;
            float4 v = src[ulong(g) * a.width + i];
            for (uint c = 0; c < 4; ++c) {
                uint t = 4 * g + c;
                if (t < a.count) cache[ulong(t) * a.width + i] = \(T)(v[c]);
            }
        }

        """ + attention4(T, suffix) + attentionSplit(T, suffix)
    }
}

extension MetalKernelSource {
    /// Causal attention for four tokens and one head per threadgroup (128
    /// threads): keys in chunks of 128 with a running maximum and sum (online
    /// softmax), so no score buffer is needed. Token 4g + c sees keys up to its
    /// own position. Head and value widths are at most 256.
    static func attention4(_ T: String, _ suffix: String) -> String {
        """
        kernel void attn4\(suffix)(device const float4* q [[buffer(0)]], device const \(T)* K [[buffer(1)]],
                          device const \(T)* V [[buffer(2)]], device float4* out [[buffer(3)]],
                          constant Attn4Args& a [[buffer(4)]],
                          uint2 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                          uint sg [[simdgroup_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]]) {
            threadgroup float4 qs[256];
            threadgroup float4 ps[128];
            threadgroup float4 partial[4];
            uint h = tg.x, g = tg.y;
            uint kvh = h / a.group;
            for (uint d = tid; d < a.headDim; d += 128) qs[d] = q[(ulong(g) * a.heads + h) * a.headDim + d];
            uint first = a.start + 4 * g;
            float4 limit = float4(float(first), float(first + 1), float(first + 2), float(first + 3));
            uint span = min(first + 4, a.start + a.count);
            float4 m = float4(-INFINITY), l = float4(0), o0 = float4(0), o1 = float4(0);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint base = 0; base < span; base += 128) {
                // Simdgroup sg scores keys base + sg, base + sg + 4, …: its 32
                // lanes read one key row together and sum across lanes.
                for (uint k = sg; k < 128; k += 4) {
                    uint t = base + k;
                    float4 acc = float4(0);
                    if (t < span) {
                        device const \(T)* kt = K + ulong(t) * a.keyWidth + ulong(kvh) * a.headDim;
                        for (uint d = lane; d < a.headDim; d += 32) acc += qs[d] * float(kt[d]);
                    }
                    acc = simd_sum(acc);
                    if (lane == 0) ps[k] = t < span ? select(acc * a.scale, float4(-INFINITY), float4(float(t)) > limit) : float4(-INFINITY);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                float4 score = ps[tid];
                float4 chunk = simd_max(score);
                if (lane == 0) partial[sg] = chunk;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                float4 top = max(m, max(max(partial[0], partial[1]), max(partial[2], partial[3])));
                ps[tid] = exp(score - top);
                float4 factor = exp(m - top);
                m = top;
                l *= factor;
                o0 *= factor;
                o1 *= factor;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                uint keys = min(128u, span - base);
                for (uint k = 0; k < keys; ++k) {
                    float4 p = ps[k];
                    l += p;
                    device const \(T)* vt = V + ulong(base + k) * a.valueWidth + ulong(kvh) * a.valueDim;
                    if (tid < a.valueDim) o0 += p * float(vt[tid]);
                    if (tid + 128 < a.valueDim) o1 += p * float(vt[tid + 128]);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            device float4* o = out + (ulong(g) * a.heads + h) * a.valueDim;
            if (tid < a.valueDim) o[tid] = o0 / l;
            if (tid + 128 < a.valueDim) o[tid + 128] = o1 / l;
        }

        """
    }

    /// Decode attention split across keys: one threadgroup per (KV head, quad
    /// of its query heads, chunk of keys). The four query heads that share a KV
    /// head are packed as float4, so each key and value row is read once for
    /// all of them; `attn_merge` combines the chunks' partial softmaxes.
    static func attentionSplit(_ T: String, _ suffix: String) -> String {
        """
        kernel void attn_split\(suffix)(device const float* q [[buffer(0)]], device const \(T)* K [[buffer(1)]],
                               device const \(T)* V [[buffer(2)]], device float* part [[buffer(3)]],
                               constant AttnSplitArgs& a [[buffer(4)]],
                               uint3 tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                               uint sg [[simdgroup_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]]) {
            threadgroup float4 qs[256];
            threadgroup float4 ps[128];
            threadgroup float4 partial[4];
            uint kvh = tg.x, quad = tg.y, c = tg.z;
            uint h0 = kvh * a.group + quad * 4;
            uint nh = min(4u, a.group - quad * 4);
            for (uint d = tid; d < a.headDim; d += 128) {
                float4 v = float4(0);
                for (uint i = 0; i < nh; ++i) v[i] = q[ulong(h0 + i) * a.headDim + d];
                qs[d] = v;
            }
            uint start = c * a.chunk, end = min(start + a.chunk, a.span);
            float4 m = float4(-INFINITY), l = float4(0), o0 = float4(0), o1 = float4(0);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint base = start; base < end; base += 128) {
                // Simdgroup sg scores keys base + sg, base + sg + 4, …: its 32
                // lanes read one key row together and sum across lanes.
                for (uint k = sg; k < 128; k += 4) {
                    uint t = base + k;
                    float4 acc = float4(0);
                    if (t < end) {
                        device const \(T)* kt = K + ulong(t) * a.keyWidth + ulong(kvh) * a.headDim;
                        for (uint d = lane; d < a.headDim; d += 32) acc += qs[d] * float(kt[d]);
                    }
                    acc = simd_sum(acc);
                    if (lane == 0) ps[k] = t < end ? acc * a.scale : float4(-INFINITY);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                float4 score = ps[tid];
                float4 chunkMax = simd_max(score);
                if (lane == 0) partial[sg] = chunkMax;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                float4 top = max(m, max(max(partial[0], partial[1]), max(partial[2], partial[3])));
                ps[tid] = exp(score - top);
                float4 factor = exp(m - top);
                m = top;
                l *= factor;
                o0 *= factor;
                o1 *= factor;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                uint keys = min(128u, end - base);
                for (uint k = 0; k < keys; ++k) {
                    float4 p = ps[k];
                    l += p;
                    device const \(T)* vt = V + ulong(base + k) * a.valueWidth + ulong(kvh) * a.valueDim;
                    if (tid < a.valueDim) o0 += p * float(vt[tid]);
                    if (tid + 128 < a.valueDim) o1 += p * float(vt[tid + 128]);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            uint chunks = (a.span + a.chunk - 1) / a.chunk;
            uint stride = 2 + a.valueDim;
            for (uint i = 0; i < nh; ++i) {
                device float* p = part + (ulong(h0 + i) * chunks + c) * stride;
                if (tid == 0) { p[0] = m[i]; p[1] = l[i]; }
                if (tid < a.valueDim) p[2 + tid] = o0[i];
                if (tid + 128 < a.valueDim) p[2 + tid + 128] = o1[i];
            }
        }

        """
    }
}
