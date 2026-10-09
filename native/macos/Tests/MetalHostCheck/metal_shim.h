// Syntax/type shim so Metal kernels can be checked with a host C++ compiler.
#pragma once
#include <cmath>
#include <cstring>
#include <cstdint>
#include <algorithm>
#define kernel extern "C"
#define device
#define constant const
#define threadgroup
#define thread
typedef unsigned char uchar; typedef unsigned short ushort; typedef unsigned int uint; typedef unsigned long ulong;
inline float h2f(unsigned short h) {
    unsigned sign = (h & 0x8000u) << 16, exp = (h >> 10) & 0x1F, man = h & 0x3FF, bits;
    if (exp == 0) { if (man == 0) bits = sign; else { exp = 1; while (!(man & 0x400)) { man <<= 1; exp--; } man &= 0x3FF; bits = sign | ((exp + 112) << 23) | (man << 13); } }
    else if (exp == 31) bits = sign | 0x7F800000u | (man << 13);
    else bits = sign | ((exp + 112) << 23) | (man << 13);
    float f; std::memcpy(&f, &bits, 4); return f;
}
struct uint4 { uint x, y, z, w; };
struct uchar4 { uchar x, y, z, w; }; struct char4 { signed char x, y, z, w; };
struct float4 {
    float x, y, z, w;
    float4() = default;
    float4(float a, float b, float c, float d) : x(a), y(b), z(c), w(d) {}
    explicit float4(uchar4 v) : x(v.x), y(v.y), z(v.z), w(v.w) {}
    explicit float4(char4 v) : x(v.x), y(v.y), z(v.z), w(v.w) {}
    float4 operator-(float s) const { return float4(x - s, y - s, z - s, w - s); }
    float4 operator+(float4 o) const { return float4(x + o.x, y + o.y, z + o.z, w + o.w); }
};
inline float dot(float4 a, float4 b) { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }
struct half { unsigned short v; operator float() const { return h2f(v); } };
struct uint2 { uint x, y; };
template<class T, class U> T as_type(U u) { static_assert(sizeof(T)==sizeof(U), "as_type size"); T t; std::memcpy(&t, &u, sizeof(T)); return t; }
inline float simd_sum(float v) { return v; } inline float simd_shuffle_xor(float, uint) { return 0; } inline float simd_max(float v) { return v; }
inline float rsqrt(float v) { return 1.0f / std::sqrt(v); }
using std::exp; using std::cos; using std::sin; using std::max;
enum class mem_flags { mem_threadgroup = 1, mem_device = 2 };
inline mem_flags operator|(mem_flags a, mem_flags b) { return mem_flags(int(a) | int(b)); }
inline void threadgroup_barrier(mem_flags) {}
namespace metal {}
