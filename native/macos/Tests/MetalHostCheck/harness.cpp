#include "kernels.cpp"
#include <cstdio>
#include <vector>
typedef float (*DotFn)(const uchar*, const float*);
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
            DotFn fn = nullptr; int block = 32, bytes = 0;
            switch (type) {
                case 0: fn = dot_f32_32; bytes = 128; break; case 1: fn = dot_f16_32; bytes = 64; break;
                case 30: fn = dot_bf16_32; bytes = 64; break; case 2: fn = dot_q4_0; bytes = 18; break;
                case 3: fn = dot_q4_1; bytes = 20; break; case 6: fn = dot_q5_0; bytes = 22; break;
                case 7: fn = dot_q5_1; bytes = 24; break; case 8: fn = dot_q8_0; bytes = 34; break;
                case 10: fn = dot_q2_K; block = 256; bytes = 84; break; case 11: fn = dot_q3_K; block = 256; bytes = 110; break;
                case 12: fn = dot_q4_K; block = 256; bytes = 144; break; case 13: fn = dot_q5_K; block = 256; bytes = 176; break;
                case 14: fn = dot_q6_K; block = 256; bytes = 210; break; case 15: fn = dot_q8_K; block = 256; bytes = 292; break;
            }
            if (!fn) { printf("type %u: no kernel\n", type); failures++; continue; }
            double acc = 0; for (uint b = 0; b < cols / block; ++b) acc += fn(row.data() + b * bytes, x.data() + b * block);
            double tol = 1e-4 * fabs(expected) + 1e-3; bool ok = fabs(acc - expected) <= tol;
            printf("%s type %2u cols %4u  msl %.6f  swift %.6f\n", ok ? "ok  " : "FAIL", type, cols, acc, expected);
            failures += !ok; checked++;
        }
        fclose(fp);
    }
    printf("%d checked, %d failures\n", checked, failures);
    return failures ? 1 : 0;
}
