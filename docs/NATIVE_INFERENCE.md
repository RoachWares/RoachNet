# RoachInference: RoachNet's native LLM engine

RoachInference (`native/macos/Sources/RoachInference`) runs GGUF language models with RoachNet's own code. It contains:

- a model-file reader;
- dequantization;
- tokenizers;
- a transformer forward pass;
- a sampler;
- chat templates;
- hand-written Metal kernels.

No Ollama, llama.cpp, MLX, Core ML, Metal Performance Shaders, Accelerate or third-party code is used. The release-scope audit allows only Foundation, the system C library, Dispatch and Metal. Model weights are data: GGUF files downloaded from their publishers and checked against the published SHA-256.

## What is implemented

| Area | Status |
| --- | --- |
| GGUF v2/v3 reader (memory-mapped) | Done |
| Tensor types F32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q2_K, Q3_K, Q4_K, Q5_K, Q6_K, Q8_K | Done |
| Tokenizers: SentencePiece-style (`llama`) and byte-level BPE (`gpt2`), with these pre-tokenizer rules: llama3, qwen2, qwen35, smollm/starcoder, gpt-2, tekken, gpt-4o, deepseek-coder, default | Done |
| Architectures: llama (includes Mistral and SmolLM), qwen2, qwen3 | Done |
| Sampling: temperature, top-k, top-p, min-p, repeat/presence/frequency penalties, seed | Done |
| Chat templates detected from GGUF: ChatML, Llama 3, Mistral, Gemma, Phi-3 | Done |
| KV-cache prefix reuse, stop sequences, streamed UTF-8 output | Done |
| CPU backend: Swift SIMD, multithreaded | Done |
| Metal backend: hand-written MSL, weights read in place from the mapped file | Done; verified on Apple Silicon (M2 Pro) |
| Ollama-compatible API in `roachnet-runtime` | Done; see `NativeModelServer.swift` |
| Embeddings, batched prefill, more architectures (gemma, phi3, MoE), Jinja templates | Planned |

## Metal performance

Measured on an Apple M2 Pro (16 GB) running macOS 26.6. The figures are greedy decode of 128 tokens, warm, with the model on the internal SSD. Ollama is the 0.40.1 build that 1.0.6 bundles, running the same model through its own registry.

| Model | RoachInference (Metal) | Ollama 0.40.1 |
| --- | --- | --- |
| qwen2.5 0.5B Q4_K_M | 185 tok/s | ~140 tok/s |
| qwen3 0.6B Q8_0 | 136 tok/s | – |
| qwen2.5-coder 1.5B Q4_K_M | 93 tok/s | 102 tok/s |
| llama3.2 3B Q4_K_M | 51 tok/s | 56 tok/s |

For every model above, the Metal backend produces the same tokens as the CPU backend.

The decode path works like this:

- **Matrix-vector products.** Each simdgroup computes 4 rows. A lane holds its 32 input values in registers and reuses them across those rows.
  - Q4_0, Q8_0, Q4_K and Q6_K use vectorized 16-bit and 128-bit loads with `float4` dot products.
  - K-quant superblocks are split into 32-value chunks, so a row's few superblocks still spread across all lanes.
  - Rows shorter than 2,048 columns use half-simdgroups.
- **Fewer, overlapping dispatches.** Each token is one command buffer on a concurrent encoder, with barriers only between dependent steps. Bias adds and residual adds are folded into the matrix-vector kernels. Attention (scores, softmax and values) is one kernel per head.
- **Model loading.** Loading a model calls `madvise(WILLNEED)`, so a model on an external drive pages in ahead of use.

`roachnet-infer bench <model.gguf>` prints the per-token wall and GPU time and the bandwidth of each matrix kind. These environment variables are for A/B checks:

- `ROACHNET_METAL_ROWS=1|2|4` sets the rows per simdgroup.
- `ROACHNET_METAL_FULL_ROWS=1` turns off half-simdgroups.
- `ROACHNET_METAL_SERIAL=1` turns off concurrent dispatch.

On a Metal device the session uses the GPU backend. Before using it, the session checks one forward pass against the CPU reference and falls back to the CPU if the results differ. Use `ROACHNET_INFERENCE_BACKEND=cpu|metal` to choose a backend, and `ROACHNET_METAL_VERIFY=0` to skip the startup check.

## How correctness is verified

Download the reference models into a folder, set `ROACHNET_TEST_MODELS` to it, and run:

```
cd native/macos
swift build -c release -Xswiftc -enable-testing --build-tests
ROACHNET_TEST_MODELS=~/models swift test --skip-build -c release -Xswiftc -enable-testing --filter RoachInferenceTests
ROACHNET_INFERENCE_TOOL=.build/release/roachnet-infer ROACHNET_TEST_MODELS=~/models \
  node --test ../../scripts/tests/roachinference-metal-kernels.test.mjs
```

Reference models (file names the tests expect):

| File | Source |
| --- | --- |
| `stories15M-q4_0.gguf` | `ggml-org/models` → `tinyllamas/stories15M-q4_0.gguf` |
| `smollm2-135m-q8_0.gguf` | `bartowski/SmolLM2-135M-Instruct-GGUF` → Q8_0 |
| `qwen2.5-0.5b-q4_k_m.gguf` | `Qwen/Qwen2.5-0.5B-Instruct-GGUF` → q4_k_m |
| `qwen3-0.6b-q8_0.gguf` | `Qwen/Qwen3-0.6B-GGUF` → Q8_0 |

The tests check:

- **Tokenization:** token ids match a reference runtime exactly on a 15-string corpus (Unicode, code, whitespace, special tokens).
- **Logits:** prompt logits match a float64 NumPy forward pass over the dequantized weights to within 0.002 (observed agreement is 1e-5).
- **Greedy decoding:** continuations agree with a reference runtime on their leading tokens. That runtime quantizes activations, so long continuations can legitimately part ways where two candidate tokens are nearly tied.
- **Metal kernels:** each quantized block dot product in the MSL source is compiled on the host and compared with Swift on synthetic blocks of every type and on real rows from the models.
- **On a Mac:** `MetalParityTests` runs the full GPU forward pass token by token against the CPU path.

The reference runtime and the NumPy script are test oracles only. They are never shipped or linked.

## Developer CLI

```
roachnet-infer info <model.gguf>
roachnet-infer tokenize <model.gguf> "text"
roachnet-infer logits <model.gguf> "prompt"
roachnet-infer generate <model.gguf> "prompt" [--chat] [--tokens N] [--temp T] [--seed S] [--ctx N]
roachnet-infer bench <model.gguf> [--tokens N]          (Metal: per-token time and per-matrix bandwidth)
```
