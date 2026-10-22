import Foundation

enum RoachFieldShader {
    static let vertexFunction = "roach_field_vertex"
    static let fragmentFunction = "roach_field_fragment"

    static let source = #"""
        #include <metal_stdlib>
        using namespace metal;

        #define PI 3.14159265

        struct FieldUniforms {
            float4 res;
            float4 view;
            float4 scroll;
            float4 ptr;
            float4 tilt;
            float4 rip[6];
            float4 sweep;
            float4 q[8];
            float4 spot[4];
            float4 ground;
        };

        struct FieldVertexOut {
            float4 position [[position]];
        };

        vertex FieldVertexOut roach_field_vertex(uint vid [[vertex_id]]) {
            float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            FieldVertexOut out;
            out.position = float4(corners[vid], 0.0, 1.0);
            return out;
        }

        static inline float sq(float x) { return x * x; }
        static inline float glmod(float x, float y) { return x - y * floor(x / y); }
        static inline float hash12(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
        static inline float2 hash22(float2 p) {
            float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.xx + p3.yz) * p3.zy);
        }
        static inline float vnoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash12(i), hash12(i + float2(1.0, 0.0)), u.x), mix(hash12(i + float2(0.0, 1.0)), hash12(i + float2(1.0, 1.0)), u.x), u.y);
        }
        static inline float3 vnoised(float2 p) {
            float2 i = floor(p), f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f), du = 6.0 * f * (1.0 - f);
            float a = hash12(i), b = hash12(i + float2(1.0, 0.0)), c = hash12(i + float2(0.0, 1.0)), d = hash12(i + float2(1.0, 1.0));
            float k = a - b - c + d;
            return float3(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y, du * (float2(b - a, c - a) + k * u.yx));
        }
        constant float2x2 M2 = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
        constant float2x2 M2T = float2x2(float2(1.6, -1.2), float2(1.2, 1.6));
        static float fbm(float2 p, float oct) {
            float v = 0.0, a = 0.5;
            for (int i = 0; i < 5; i++) { if (float(i) >= oct) break; v += a * vnoise(p); p = M2 * p; a *= 0.5; }
            return v;
        }
        static float3 fbmd(float2 p, float oct) {
            float v = 0.0, a = 0.5; float2 d = float2(0.0);
            float2x2 J = float2x2(float2(1.0, 0.0), float2(0.0, 1.0));
            for (int i = 0; i < 5; i++) {
                if (float(i) >= oct) break;
                float3 n = vnoised(p);
                v += a * n.x; d += a * (J * n.yz);
                p = M2 * p; J = M2T * J; a *= 0.5;
            }
            return float3(v, d);
        }
        static inline float bayer2(float2 a) { a = floor(a); return fract(dot(a, float2(0.5, a.y * 0.75))); }
        static inline float bayer4(float2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
        static inline float bayer8(float2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

        constexpr sampler blueSampler(coord::normalized, address::repeat, filter::nearest);

        static float dth(float2 wp, float4 w, float sw, float4 dp, texture2d<float> blue) {
            float th = 0.0, tot = 0.0;
            if (w.x > 0.0) { th += w.x * (bayer4(wp) + 0.03125); tot += w.x; }
            if (w.y > 0.0) { th += w.y * (bayer8(wp) + 0.0078125); tot += w.y; }
            if (w.z > 0.0) { th += w.z * blue.sample(blueSampler, (wp + 0.5) / 64.0).r; tot += w.z; }
            if (w.w > 0.0) {
                float2 r = wp + 0.5; float ca = cos(dp.y), sa = sin(dp.y);
                float2 c = fract(float2(ca * r.x - sa * r.y, sa * r.x + ca * r.y) / dp.x) - 0.5;
                th += w.w * min(PI * dot(c, c) * 1.12, 1.0); tot += w.w;
            }
            if (sw > 0.0) { float row = glmod(wp.y, dp.z); th += sw * clamp((row + bayer4(float2(wp.x, 0.0)) * 0.9 + 0.05) / dp.z, 0.0, 1.0); tot += sw; }
            return tot > 0.0 ? th / tot : bayer4(wp) + 0.03125;
        }
        static inline void over(thread float4 &acc, float3 c, float a) { acc = float4(c * a, a) + acc * (1.0 - a); }

        #define P(i) mix(A[i], B[i], sel)

        fragment float4 roach_field_fragment(
            FieldVertexOut in [[stage_in]],
            constant FieldUniforms &u [[buffer(0)]],
            constant float4 *A [[buffer(1)]],
            constant float4 *B [[buffer(2)]],
            texture2d<float> blue [[texture(0)]]
        ) {
            float2 px = floor(in.position.xy);
            float cell = u.view.z;
            float2 view = u.view.xy;
            float2 css = (px + 0.5) * cell;
            float detail = u.scroll.z;
            float oct = detail > 0.75 ? 4.0 : 3.0;
            float sel = 0.0;
            if (u.sweep.w > 0.0) {
                float m = clamp((u.sweep.z - length(css - u.sweep.xy)) / u.sweep.w, 0.0, 1.0);
                sel = step(blue.sample(blueSampler, (px + 0.5) / 64.0).r * 0.98 + 0.01, m);
            }
            float4 g0 = P(0), g1 = P(1), g2 = P(2), g3 = P(3), g4 = P(4), g5 = P(5), g6 = P(6);
            float4 dp = P(13), ds = P(12);
            float t = u.view.w * g1.x;

            float quiet = 0.0;
            for (int i = 0; i < 4; i++) {
                float4 qa = u.q[i * 2], qb = u.q[i * 2 + 1];
                if (qb.x > 0.0) {
                    float sd;
                    if (qb.z > 0.5) { float2 qq = abs(css - qa.xy) - qa.zw + qb.w; sd = length(max(qq, 0.0)) + min(max(qq.x, qq.y), 0.0) - qb.w; }
                    else { sd = (length((css - qa.xy) / qa.zw) - 1.0) * min(qa.z, qa.w); }
                    quiet = max(quiet, qb.x * (1.0 - smoothstep(0.0, max(qb.y, 1.0), sd)));
                }
            }
            quiet = max(quiet, g6.w);
            float calm = 1.0 - quiet * (1.0 - g0.w);

            float pulse = 1.0 + g6.x * sin(t * 6.2832 / max(g6.y, 0.1));
            float breath = 1.0 + g6.z * sin(t * 6.2832 / max(g1.y, 0.1) + 1.7);
            float4 x1 = P(49);
            float roll = 0.0;
            if (x1.x > 0.0) { float yc = fract(t * x1.y); float dy = abs(css.y / view.y - yc); dy = min(dy, 1.0 - dy); roll = x1.x * exp(-sq(dy / 0.07)); }
            float I = g0.x * pulse * (1.0 + roll);

            float2 toP = css - u.ptr.xy;
            float pr = max(g2.w, 1.0);
            float near = u.ptr.z * g3.x * exp(-dot(toP, toP) / (pr * pr)) * mix(1.0, 0.3, quiet);
            float2 disp = toP * near * g2.y + float2(-toP.y, toP.x) * near * g2.z * 0.7;
            float rip = 0.0; float2 push = float2(0.0);
            for (int i = 0; i < 6; i++) {
                float4 r = u.rip[i];
                if (r.w > 0.0) {
                    float2 dv = css - r.xy; float d = length(dv) + 0.001;
                    float ring = exp(-sq((d - r.z * g1.w) / max(g3.y, 1.0))) * r.w * (1.0 - smoothstep(0.15, 1.7, r.z));
                    rip += ring; push += dv / d * ring * 24.0;
                }
            }
            rip *= g1.z * mix(1.0, 0.45, quiet);
            float spot = 0.0; float3 spotC = float3(1.0);
            for (int i = 0; i < 2; i++) {
                float4 s = u.spot[i * 2];
                if (s.w > 0.0) { float k = s.w * exp(-sq(max(length(css - s.xy) - s.z, 0.0) / 120.0)); if (k > spot) { spot = k; spotC = u.spot[i * 2 + 1].rgb; } }
            }
            float front = 0.0;
            if (u.sweep.w > 0.0) { front = exp(-sq((length(css - u.sweep.xy) - u.sweep.z) / (u.sweep.w * 0.45))); }

            float2 tilt = u.tilt.xy * g4.w;
            float2 oF = floor((float2(0.0, u.scroll.x * g4.x) + tilt * g5.x) / cell + 0.5);
            float2 oM = floor((float2(0.0, u.scroll.x * g4.y) + tilt * g5.y) / cell + 0.5);
            float2 oN = floor((float2(0.0, u.scroll.x * g4.z) + tilt * g5.z) / cell + 0.5);
            float2 wF = px + oF, wM = px + oM, wN = px + oN;
            float2 uv = css / view;
            float vig = mix(1.0, 1.0 - smoothstep(0.42, 1.12, length((uv - 0.5) * float2(view.x / view.y, 1.0)) * 1.08), g0.z);

            float4 acc = float4(0.0);

            float lit = 0.0; float3 lightC = float3(0.0); float bloom = 0.0; float2 ldir = float2(0.0, 1.0);
            float4 l0 = P(39);
            if (l0.x > 0.001) {
                float4 l1 = P(40), l2 = P(41), l3 = P(42);
                float2 lp = l0.yz * view + u.tilt.xy * g5.x * g4.w * 0.6;
                float2 dl = css - lp; float dlen = length(dl * float2(1.0, max(P(50).y, 0.2)));
                ldir = dl / max(dlen, 1.0);
                float R = l0.w * max(view.x, view.y);
                float fall = exp(-sq(dlen / R)) * breath;
                float shafts = 0.0;
                if (l2.x > 0.0) {
                    float ang = atan2(dl.y, dl.x);
                    float n = fbm(float2(ang * 3.0 + t * 0.02, dlen / R - t * 0.05), 3.0);
                    shafts = l2.x * pow(max(0.0, sin(ang * l2.y + n * 5.0 + t * l2.z)), 4.0) * exp(-dlen / (R * 1.7)) * smoothstep(0.0, R * 0.25, dlen);
                }
                lit = (fall + shafts) * l0.x;
                lightC = l1.rgb; bloom = l2.w;
                float v = lit * I * vig * mix(1.0, calm, 0.7) + front * 0.25;
                if (ds.w > 0.5) { over(acc, l1.rgb, clamp(v, 0.0, 1.0) * l1.a); }
                else if (v > dth(wF, P(10), ds.z, dp, blue)) {
                    float th2 = dth(wF + float2(1.0, 3.0), P(10), ds.z, dp, blue);
                    if (v > P(50).x * (0.75 + 0.5 * th2)) over(acc, l3.rgb, l3.a); else over(acc, l1.rgb, l1.a);
                }
            }

            float4 f0 = P(34);
            if (f0.x > 0.001) {
                float4 f1 = P(35), fc0 = P(36), fc1 = P(37), f4 = P(38);
                float4 dwf = P(9);
                for (int i = 0; i < 3; i++) {
                    float fi = float(i);
                    if (fi >= f0.w || (detail < 0.5 && i == 1)) continue;
                    float2 o = floor((float2(0.0, u.scroll.x * (g4.x + (g4.z - g4.x) * fi * 0.5)) + tilt * (g5.x + (g5.z - g5.x) * fi * 0.5)) / cell + 0.5);
                    float2 wp = px + o;
                    float sc = f0.y * (1.0 - fi * f1.z);
                    float2 q = (wp * cell - disp * (0.2 + fi * 0.2) - push * 0.6) / sc + float2(t * f0.z * (0.010 + fi * 0.006), -t * f0.z * (0.004 + fi * 0.003)) + fi * 7.3;
                    float f = fbm(q + 0.6 * float2(fbm(q * 0.5 + fi, 3.0), fbm(q * 0.5 + 3.1, 3.0)), oct);
                    float lo = f1.x + fi * 0.035;
                    float v = smoothstep(lo, f1.y + fi * 0.02, f) * f0.x * I * calm * vig * breath * (0.75 + 0.25 * fi) + lit * bloom * (0.35 + 0.25 * fi) * smoothstep(lo - 0.15, f1.y, f) * calm + rip * 0.3 + near * g2.x * 0.18;
                    float th = dth(wp + fi * float2(17.0, 31.0), dwf, ds.y, dp, blue);
                    if (v > th) {
                        float4 c = mix(fc0, fc1, fi * 0.5);
                        float3 col = mix(c.rgb, lightC, clamp(lit * bloom * 1.5, 0.0, 0.7));
                        over(acc, col, c.a * mix(1.0, f4.x, fi * 0.5));
                    }
                }
            }

            float4 w0 = P(14);
            if (w0.x > 0.001) {
                float4 w1 = P(15), w5 = P(19);
                float2 q = (wF * cell - disp * 0.3 - push) / w0.y;
                float tw = t * w0.w;
                float2 dir = float2(cos(w1.w), sin(w1.w));
                float2 wv = float2(fbm(q + dir * tw * 0.016, oct), fbm(q + float2(5.2, 1.3) - dir.yx * tw * 0.012, oct));
                float2 qq = q * 1.15 + w0.z * wv + float2(0.0, u.scroll.y * 0.00005 * g3.w);
                float f; float rim = 0.0;
                if (w5.a > 0.0) {
                    float3 fd = fbmd(qq, oct); f = fd.x;
                    float gpx = length(fd.yz) * 1.15 / w0.y;
                    float edge = abs(f - (w1.x + 0.05)) / max(gpx, 1e-5);
                    rim = w5.a * smoothstep(0.05, 0.6, dot(normalize(fd.yz + 1e-5), ldir)) * (1.0 - smoothstep(1.0, 3.2, edge)) * clamp(lit * 2.2, 0.0, 1.2);
                } else {
                    f = fbm(qq, oct);
                }
                float v = smoothstep(w1.x, w1.y, f) * w0.x * I * calm * vig * breath;
                v += near * g2.x * 0.24 + rip * 0.55 + spot * 0.45 + front * 0.6 + lit * bloom * 0.6 * calm;
                if (v > dth(wF, P(8), ds.x, dp, blue)) {
                    float4 x0 = P(48);
                    float th2 = dth(wF + float2(3.0, 1.0), P(8), ds.x, dp, blue);
                    float4 c = P(16);
                    if (w1.z >= 2.0 && v > x0.x * (0.75 + 0.5 * th2)) c = P(17);
                    if (w1.z >= 3.0 && v > x0.y * (0.75 + 0.5 * th2)) c = P(18);
                    over(acc, mix(c.rgb, lightC, clamp(lit * bloom, 0.0, 0.65)), c.a);
                }
                if (rim * calm > dth(wF + 3.0, P(8), 0.0, dp, blue)) over(acc, w5.rgb, 0.85);
            }

            float4 t0 = P(43);
            if (t0.x > 0.001) {
                float4 t1 = P(44), tc = P(45), tp = P(46), x3t = P(51);
                float hy = t0.y + u.tilt.z;
                float sy = css.y / view.y;
                if (sy > hy + 0.002) {
                    float H = t0.z * (1.0 + u.tilt.w);
                    float dz = sy - hy;
                    float z = H / dz;
                    float aspect = view.x / view.y;
                    float sx = css.x / view.x - 0.5 - u.tilt.x * g4.w * 0.012;
                    float x = sx * z * aspect;
                    float travel = t * t0.w + u.scroll.x * 0.0025 * g4.y;
                    float fq = x3t.z > 0.0 ? x3t.z : 0.35;
                    float3 h = fbmd(float2(x, z + travel) * fq, 3.0);
                    float b = h.x * t1.x;
                    float dzdy = -H / (dz * dz) / view.y;
                    float dxdx = z * aspect / view.x, dxdy = sx * aspect * dzdy;
                    float2 gb = t1.x * fq * float2(h.y * dxdx, h.y * dxdy + h.z * dzdy);
                    float dist = abs(fract(b + 0.5) - 0.5) / max(length(gb), 1e-5);
                    float fade = exp(-z * t1.y) * smoothstep(0.0, 0.05, dz);
                    float line = (1.0 - smoothstep(t1.z * 0.5, t1.z, dist));
                    float v = line * fade * t0.x * I * calm * vig * 1.2 + rip * line * 0.6;
                    if (v > dth(wM, P(8), 0.0, dp, blue) * 0.92 + 0.04) over(acc, tc.rgb, tc.a * mix(0.55, 1.0, fade));
                    if (t1.w > 0.0) {
                        float sp = 0.75;
                        float k = floor(x / sp + 0.5);
                        float zz = z + travel;
                        float seg = step(0.34, hash12(float2(k, floor(zz * 0.3))));
                        float lane = step(0.4, hash12(float2(k, 11.0))) * seg;
                        float dxp = abs(x - k * sp) / max(dxdx, 1e-5);
                        float trace = lane * (1.0 - smoothstep(0.45, 1.25, dxp)) * fade;
                        float tpulse = smoothstep(0.9, 1.0, fract(zz * 0.16 + t * (0.25 + hash12(float2(k, 4.0)) * 0.35)));
                        float tv = trace * t1.w * (0.85 + tpulse * 1.6) * I * calm * vig;
                        if (tv > dth(wM + 7.0, P(8), 0.0, dp, blue) * 0.9) over(acc, mix(tc.rgb, tp.rgb, tpulse), mix(tc.a * 0.5, tp.a, tpulse));
                    }
                }
            }

            float4 c0 = P(20);
            if (c0.x > 0.001) {
                float4 c1 = P(21), c2 = P(22);
                float2 cc = floor(wM / c1.x); float2 lpc = wM - cc * c1.x;
                if (lpc.x < c1.y && lpc.y < c1.y) {
                    float2 cp = (cc * c1.x + c1.y * 0.5) * cell;
                    float2 q = (cp - disp * 0.55 - push * 1.5) / c0.y;
                    float2 dr = float2(-t * 0.026, t * 0.019 + u.scroll.y * 0.00008 * g3.w) * c0.w;
                    if (x1.z > 0.0) q += x1.z * float2(fbm(q * 0.6 + float2(t * 0.011, 0.0), 3.0), fbm(q * 0.6 + float2(4.7, -t * 0.009), 3.0));
                    float3 g = fbmd(q + dr, oct);
                    float b = g.x * c0.z + t * 0.04 * c1.w;
                    float gpx = length(g.yz) * c0.z / c0.y;
                    float major = step(glmod(floor(b + 0.5), max(c1.z, 1.0)), 0.5);
                    float dist = abs(fract(b + 0.5) - 0.5) / max(gpx, 0.0004);
                    float line = 1.0 - smoothstep(c2.x + major * c2.y, c2.x * 2.2 + major * c2.y * 1.3, dist);
                    float v = line * 0.92 + spot * 0.9 * line + spot * 0.25 + rip * 0.85 + near * line * g2.x * 0.5 + front * line * 0.8;
                    float fade = clamp(c0.x / 0.92, 0.0, 1.4) * I * mix(calm, 1.0, clamp(spot + rip + near * 0.5, 0.0, 1.0)) * vig;
                    float4 x3m = P(51);
                    if (x3m.w > 0.0) fade *= mix(1.0, smoothstep(0.36, 0.6, fbm(q * 0.32 + float2(t * 0.012, -t * 0.008) + 9.1, 3.0)), x3m.w);
                    float cth = bayer4(cc) * 0.92 + 0.04;
                    float halo = c2.w > 0.0 ? c2.w * 0.5 * (1.0 - smoothstep(0.0, (c2.x + major * c2.y) * 5.0, dist)) : 0.0;
                    bool onLine = v > cth;
                    if ((onLine || halo > cth) && fade > 0.02) {
                        float4 cm = P(23), cj = P(24), x3 = P(51);
                        float shim = x3.x > 0.0 ? x3.x * major * smoothstep(0.8, 1.0, sin(dot(cp, float2(0.0034, 0.0023)) * 6.2832 - t * x3.y)) : 0.0;
                        float3 col = mix(cm.rgb, cj.rgb, major);
                        col = mix(col, spotC, clamp(spot * 1.2, 0.0, 1.0));
                        col = mix(col, float3(1.0), shim * 0.3);
                        over(acc, col, min(1.0, mix(cm.a, cj.a, major) * fade * (onLine ? 1.0 : 0.42) * mix(1.0, 1.3, clamp(spot + near * c2.z, 0.0, 1.0)) * (1.0 + shim * 0.7)));
                    }
                }
            }

            float4 r0 = P(25);
            if (r0.x > 0.001) {
                float4 r1 = P(26), rd = P(27), rl = P(28);
                float G = r0.y;
                float2 gc = floor(wN / G); float2 lpg = wN - gc * G - floor(G * 0.5);
                float2 cc = (gc * G + floor(G * 0.5) + 0.5 - oN) * cell;
                float h = hash12(gc + 7.0), h2 = hash12(gc + 31.0);
                float wake = u.ptr.z * exp(-sq(length(cc - u.ptr.xy) / max(r1.y, 1.0))) * mix(1.0, 0.3, quiet) * g3.x;
                float blink = step(1.0 - r1.x, h) * step(0.55, 0.5 + 0.5 * sin(t * (0.6 + h * 1.7) + h * 31.0));
                float lit2 = max(max(blink * calm, step(h2 * 0.8 + 0.12, wake)), max(spot * step(0.4, h), rip));
                float on = 0.0;
                float style = r0.w;
                if (style < 0.5) {
                    float arm = r0.z + floor(wake * 3.4 * step(h2 * 0.8 + 0.12, wake) + 0.5);
                    float streak = floor(min(abs(u.scroll.y) * 0.0035 * g3.z, 9.0));
                    bool onX = abs(lpg.y) < 0.5 && abs(lpg.x) <= arm;
                    bool onY = abs(lpg.x) < 0.5 && abs(lpg.y) <= arm + streak;
                    if (onX || onY) on = 1.0;
                } else if (style < 1.5) {
                    if (abs(lpg.x) < 0.5 || abs(lpg.y) < 0.5) on = step(0.5, fract((wN.x + wN.y) * 0.5)) * 0.85 + 0.15 * step(abs(lpg.x) + abs(lpg.y), r0.z + 0.5);
                } else if (style < 2.5) {
                    if (abs(lpg.x) < 0.5 + r0.z * 0.5 && abs(lpg.y) < 0.5 + r0.z * 0.5) on = 1.0;
                } else {
                    float hx = hash12(gc + 2.0);
                    bool east = hx > 0.5;
                    float run = east ? (lpg.x + G * 0.5) / G : (lpg.y + G * 0.5) / G;
                    bool onT = east ? (abs(lpg.y) < 0.5 && lpg.x >= 0.0) : (abs(lpg.x) < 0.5 && lpg.y >= 0.0);
                    bool pad = abs(lpg.x) <= 1.0 && abs(lpg.y) <= 1.0;
                    if ((onT && h > 0.35) || (pad && h > 0.35)) on = 1.0;
                    float gpulse = smoothstep(0.8, 1.0, fract(run * 0.5 - t * r1.w * (0.4 + h2) + h * 9.0));
                    lit2 = max(lit2, gpulse * step(0.6, h2) * on);
                }
                if (on > 0.0) {
                    if (lit2 > 0.35) over(acc, mix(rl.rgb, spotC, clamp(spot, 0.0, 1.0)), rl.a);
                    else if (rd.a * calm * on > 0.002) over(acc, rd.rgb, rd.a * calm * on * vig);
                }
                if (r1.z > 0.0) {
                    float hy = 0.62 + u.tilt.z;
                    float sy = css.y / view.y;
                    if (sy > hy + 0.004) {
                        float dz = sy - hy, H = 0.12 * (1.0 + u.tilt.w);
                        float z = H / dz; float aspect = view.x / view.y;
                        float sx = css.x / view.x - 0.5 - u.tilt.x * g4.w * 0.015;
                        float x = sx * z * aspect;
                        float zz = z + t * 0.02 + u.scroll.x * 0.0012;
                        float dzdy = H / (dz * dz) / view.y, dxdx = z * aspect / view.x;
                        float lx = abs(fract(x * 2.0 + 0.5) - 0.5) / (2.0 * dxdx);
                        float lz = abs(fract(zz * 2.0 + 0.5) - 0.5) / (2.0 * dzdy);
                        float fl = (1.0 - smoothstep(0.4, 1.2, min(lx, lz))) * exp(-z * 0.55) * smoothstep(0.0, 0.05, dz) * r1.z;
                        if (fl * calm > dth(wN, P(8), 0.0, dp, blue)) over(acc, rd.rgb, min(1.0, rd.a * 2.6 + 0.08));
                    }
                }
            }

            float4 p0 = P(29);
            if (p0.x > 0.001) {
                float4 p1 = P(30), p2 = P(31), pa = P(32), pb = P(33);
                float C = p0.y;
                float2 pos = wN * cell;
                float rise = p2.z * t * p1.x * 30.0;
                float coreR = max(p1.y, cell);
                float trailL = p2.z > 0.0 ? coreR * 7.0 * p2.z : 0.0;
                float best = 0.0, hot = 0.0; float4 bc = pa;
                float2 ci = floor(pos / C);
                int span = detail > 0.5 ? 1 : 0;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        if (span == 0 && (dx != 0 || dy != 0)) continue;
                        float cx = ci.x + float(dx);
                        float spd = 0.55 + 0.9 * hash12(float2(cx, 17.0));
                        float yo = rise * spd;
                        float cy = floor((pos.y + yo) / C) + float(dy);
                        float2 id = float2(cx, cy);
                        float h = hash12(id + 3.1);
                        if (h < p0.z) {
                            float2 j = hash22(id);
                            float2 pp = (id + 0.2 + j * 0.6) * C - float2(0.0, yo);
                            pp += p2.w * C * 0.32 * float2(sin(t * (0.5 + j.x) + h * 40.0), cos(t * (0.4 + j.y) + h * 23.0));
                            if (p2.z > 0.0) pp.x += sin(t * 2.1 + h * 31.0 + pp.y * 0.02) * C * 0.06;
                            float2 sp = pp - oN * cell;
                            float2 tpp = u.ptr.xy - sp; float dd = dot(tpp, tpp);
                            float gth = u.ptr.z * p2.x * g3.x * exp(-dd / (pr * pr * 1.6)) * mix(1.0, 0.4, quiet);
                            pp += tpp * gth * 0.42;
                            float2 dv = pos - pp;
                            float d = length(dv);
                            float life = p2.z > 0.0 ? sin(clamp(fract(h * 13.7 + (pos.y + yo) / C * 0.031 + t * 0.07 * spd), 0.0, 1.0) * PI) : 1.0;
                            float tw = 1.0 - p1.w * (0.5 + 0.5 * sin(t * (1.3 + h * 4.0) + h * 50.0));
                            float gr = p1.z * (1.0 + p2.y * gth * 3.0);
                            float core = 1.0 - smoothstep(coreR, coreR + cell, d);
                            float trail = 0.0;
                            if (trailL > 0.0 && dv.y > 0.0 && dv.y < trailL) trail = (1.0 - dv.y / trailL) * (1.0 - smoothstep(coreR * 0.5, coreR * 0.5 + cell, abs(dv.x)));
                            float glow = gr > 0.0 ? exp(-d * d / (gr * gr)) : 0.0;
                            float k = max(core * 1.25, max(trail * 0.9, glow * 0.62)) * life * tw;
                            if (k > best) { best = k; hot = core * life * tw; bc = fract(h * 91.7) < 0.5 ? pa : pb; }
                        }
                    }
                }
                float v = best * p0.x * I * mix(1.0, 0.25, quiet) * vig;
                if (v > dth(wN, P(11), 0.0, dp, blue)) over(acc, mix(bc.rgb, float3(1.0), hot * 0.35), bc.a * (v > 1.0 ? 1.0 : 0.72));
            }

            if (front > 0.0) { float4 sw = P(47); if (front * sw.a > dth(px, float4(0.0, 1.0, 0.0, 0.0), 0.0, dp, blue)) over(acc, sw.rgb, 0.9); }
            if (rip > 0.25) { float4 rc = P(7); if (rip * rc.a > dth(px + 5.0, float4(1.0, 0.0, 0.0, 0.0), 0.0, dp, blue)) over(acc, rc.rgb, 0.85); }

            float4 field = acc * g0.y;
            return float4(u.ground.rgb * (1.0 - field.a) + field.rgb, 1.0);
        }
        """#
}
