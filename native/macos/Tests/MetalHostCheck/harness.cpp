// Standard headers first: the Metal shim redefines `thread`, `device` and friends.
#include <cstdio>
#include <vector>
#include "kernels.cpp"
typedef float (*DotFn)(const uchar*, const float*);
typedef float (*PartialFn)(const uchar*, const float*, uint);
int main(int argc, char** argv) {
    int failures = 0, checked = 0;
    for (int f = 1; f < argc; ++f) {
        FILE* fp = fopen(argv[f], "rb"); if (!fp) return 2;
        while (true) {
            uint type, cols, rowBytes; float expected;
            if (fread(&type, 4, 1, fp) != 1) break;
            fread(&cols, 4, 1, fp); fread(&rowBytes, 4, 1, fp); fread(&expected, 4, 1, fp);
            std::vector<uchar> row(rowBytes); fread(row.data(), 1, rowBytes, fp);
            std::vector<float> x(cols); fread(x.data(), 4, cols, fp);
            DotFn fn = nullptr; PartialFn pfn = nullptr; int block = 32, bytes = 0;
            switch (type) {
                case 0: fn = dot_f32_32<const float*>; bytes = 128; break; case 1: fn = dot_f16_32<const float*>; bytes = 64; break;
                case 30: fn = dot_bf16_32<const float*>; bytes = 64; break; case 2: fn = dot_q4_0<const float*>; bytes = 18; break;
                case 3: fn = dot_q4_1<const float*>; bytes = 20; break; case 6: fn = dot_q5_0<const float*>; bytes = 22; break;
                case 7: fn = dot_q5_1<const float*>; bytes = 24; break; case 8: fn = dot_q8_0<const float*>; bytes = 34; break;
                case 10: fn = dot_q2_K; block = 256; bytes = 84; break; case 11: fn = dot_q3_K; block = 256; bytes = 110; break;
                case 12: fn = dot_q4_K; pfn = pdot_q4_K<const float*>; block = 256; bytes = 144; break; case 13: fn = dot_q5_K; pfn = pdot_q5_K<const float*>; block = 256; bytes = 176; break;
                case 14: fn = dot_q6_K; pfn = pdot_q6_K<const float*>; block = 256; bytes = 210; break; case 15: fn = dot_q8_K; pfn = pdot_q8_K<const float*>; block = 256; bytes = 292; break;
            }
            if (!fn) { printf("type %u: no kernel\n", type); failures++; continue; }
            double acc = 0; for (uint b = 0; b < cols / block; ++b) acc += fn(row.data() + b * bytes, x.data() + b * block);
            double tol = 1e-4 * fabs(expected) + 1e-3; bool ok = fabs(acc - expected) <= tol;
            if (pfn) {
                // The chunked K-quant path used by the MATVEC_K kernels must agree too.
                double pacc = 0;
                for (uint b = 0; b < cols / block; ++b) for (uint j = 0; j < 8; ++j) pacc += pfn(row.data() + b * bytes, x.data() + b * block + j * 32, j);
                if (fabs(pacc - expected) > tol) { printf("FAIL chunked type %2u cols %4u  msl %.6f  swift %.6f\n", type, cols, pacc, expected); ok = false; }
            }
            if (type == 2 || type == 8 || type == 12 || type == 14) {
                // The vectorized register-x dots used by the multi-row kernels must agree too.
                double vacc = 0;
                for (uint b = 0; b < cols / block; ++b) {
                    const uchar* blockPtr = row.data() + b * bytes;
                    for (uint j = 0; j < (block == 256 ? 8u : 1u); ++j) {
                        const float* xs = x.data() + b * block + j * 32;
                        float4 xv[8]; float xsum = 0;
                        for (int q = 0; q < 8; ++q) { xv[q] = float4(xs[4*q], xs[4*q+1], xs[4*q+2], xs[4*q+3]); }
                        for (int e = 0; e < 32; ++e) xsum += xs[e];
                        if (type == 2) vacc += dotv_q4_0(blockPtr, xv);
                        else if (type == 8) vacc += dotv_q8_0(blockPtr, xv);
                        else if (type == 12) vacc += pdotv_q4_K(blockPtr, xv, j, xsum);
                        else vacc += pdotv_q6_K(blockPtr, xv, j, xsum);
                    }
                }
                if (fabs(vacc - expected) > tol) { printf("FAIL vector type %2u cols %4u  msl %.6f  swift %.6f\n", type, cols, vacc, expected); ok = false; }
            }
            printf("%s type %2u cols %4u  msl %.6f  swift %.6f\n", ok ? "ok  " : "FAIL", type, cols, acc, expected);
            failures += !ok; checked++;
        }
        fclose(fp);
    }
    printf("%d checked, %d failures\n", checked, failures);
    return failures ? 1 : 0;
}
