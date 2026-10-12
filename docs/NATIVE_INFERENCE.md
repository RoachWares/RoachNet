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
| Model APIs in `roachnet-runtime`: Ollama, OpenAI (chat, completions, responses, embeddings) and Anthropic messages | Done; see "Model APIs" below |
| Tool calling, structured output held while sampling (JSON and JSON Schema), thinking split and switch | Done |
| Embeddings (mean, CLS and last-token pooling, read from the GGUF) | Done |
| Made models (`/api/create`, Modelfile) sharing the base model's weights and engine | Done |
| Batched prefill on Metal (prompts in passes of up to 512 tokens, simdgroup-matrix GEMM) | Done; checked against token-by-token passes at startup and in tests |
| Memory-aware loading: idle models unloaded, then the context shortened, then a clear refusal | Done |
| Speculative decoding, f16 KV cache, more architectures (gemma, phi3, MoE), Jinja templates | Planned |

## Model APIs

The model server answers every API below from one executor (`ModelReplies.swift`). Tools, formats, thinking, made-model settings and tracing behave the same whichever API a client speaks. Plan models (`claude:…`, `codex:…`) answer on all of them too.

| Route | Notes |
| --- | --- |
| `POST /api/chat`, `/api/generate` | `tools` and `tool_calls` (arguments as objects), `format` (`"json"` or a JSON Schema), `think` with `message.thinking`, `raw`, streamed NDJSON |
| `POST /api/embed`, `/api/embeddings` | Lists of inputs, `truncate`, `dimensions`; `/api/embeddings` returns the older unnormalized form |
| `POST /api/create` | `from`, `system`, `parameters`, `messages`, or a Modelfile (`FROM`, `SYSTEM`, `PARAMETER`, `MESSAGE`). `from` may be an installed model or the path of a `.gguf` file on this Mac |
| `POST /api/copy` | Links the weights instead of copying them |
| `POST /v1/chat/completions` | `tools`, `tool_choice` (`auto`, `none`, `required`, a named function), `response_format` (`json_object`, `json_schema`), `reasoning_effort`, `stream_options.include_usage`. Thinking comes back as `reasoning_content` |
| `POST /v1/completions` | Raw prompt completion |
| `POST /v1/responses` | String or item input (`function_call`, `function_call_output`), function tools, `text.format`, `reasoning.effort`, and the full numbered event stream |
| `POST /v1/embeddings` | `dimensions`, `encoding_format: "base64"` |
| `POST /v1/messages`, `/v1/messages/count_tokens` | Anthropic's API: system blocks, `tool_use` and `tool_result`, `tool_choice` (`auto`, `any`, `tool`, `none`), `thinking`, and the content-block event stream |

How the pieces work:

- **Structured output is enforced, not requested.** `JSONConstraint` is a character-level pushdown automaton. While sampling, each candidate token's text is checked against it: the top 64, then 1,024, then the whole vocabulary. The reply is valid JSON that matches the schema: required keys, enums, integer versus number, array bounds, `$ref` into `$defs`, and `anyOf`. Generation stops as soon as the value is complete. A thinking model that is asked to think first reasons freely, and the format applies after `</think>`.
- **Forced tool calls** (`required`, a named tool, Anthropic `any` or `tool`) hold the reply to `{"name": …, "arguments": …}` with the tool's own parameter schema, so the call always parses.
- **Tool calls use each family's own format.** Qwen's `<tool_call>` blocks, Llama 3's JSON reply and Mistral's `[TOOL_CALLS]` list are rendered into the prompt and parsed back out. Streaming holds back anything that could be the start of a call, so a client never sees half a call as text.
- **Thinking** is split from content as it streams. `think: false`, `reasoning_effort: "none"` or Anthropic's `thinking.disabled` closes Qwen3's thinking block in the prompt, so the model answers straight away.
- **Long conversations** drop their oldest turns until the prompt fits and leaves room to answer. The system prompt is never dropped.
- **Errors come back in each API's shape.** A missing model is a 404 before a stream starts.
- **The Org's RoachClaw agents** send their action schema as the format, so even a small local model always replies with one well-formed action.

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

### Prompt evaluation (prefill)

A prompt runs through the model in passes of up to 512 tokens, instead of one token at a time. Each weight matrix is dequantized once per 32 tokens into threadgroup memory. The multiplications run on the GPU's simdgroup matrix units in FP32. Measured with `roachnet-infer prefill <model.gguf> --tokens 512`, warm, on the same M2 Pro:

| Model | Batched | One token at a time | Speed-up |
| --- | --- | --- | --- |
| qwen3 0.6B Q8_0 | 1,671 tok/s | 108 tok/s | 15.5× |
| qwen2.5 0.5B Q4_K_M | 2,432 tok/s | 151 tok/s | 16.1× |
| qwen2.5-coder 1.5B Q4_K_M | 795 tok/s | 76 tok/s | 10.5× |
| llama3.2 3B Q4_K_M | 375 tok/s | 44 tok/s | 8.5× |

The batched pass leaves the same KV cache as token-by-token passes. On every device, the first batched pass is checked against token-by-token passes; if they differ, prompts run a token at a time. `ROACHNET_METAL_BATCH=0` turns batching off, and a number sets the batch size. `ROACHNET_METAL_MATMUL=simple` uses the plain four-token kernels instead of the simdgroup-matrix GEMM. Q2_K and Q3_K models still prefill a token at a time.

### Long contexts

Decode attention is split across chunks of 128 keys. Each threadgroup handles one KV head and a chunk, and packs the query heads that share the KV head as `float4`, so each key and value row is read once for all of them. A second kernel merges the chunks' partial softmaxes. Contexts shorter than one chunk use the single fused kernel. `ROACHNET_METAL_ATTENTION=fused` turns the split off. Measured with `roachnet-infer bench <model.gguf> --context N`:

| Model, context | Fused kernel | Split across keys |
| --- | --- | --- |
| qwen3 8B Q4_K_M, 700 tokens | 16.0 tok/s | 19.2 tok/s |
| qwen3 8B Q4_K_M, 2,000 tokens | 10.5 tok/s | 17.3 tok/s |
| qwen3 0.6B Q8_0, 2,000 tokens | 27.3 tok/s | 72.1 tok/s |

### Against Ollama

The same GGUF file (Ollama's own copy of qwen3:8b Q4_K_M, 5.2 GB), the same 665-token prompt and 128 generated tokens, on the M2 Pro (16 GB). Ollama 0.33.2 runs llama.cpp's Metal kernels.

| | Prompt | Decode |
| --- | --- | --- |
| Ollama 0.33.2 | 264 tok/s | 21.2 tok/s |
| RoachInference | 151 tok/s | 17.9 tok/s |

At a short context, decode is level with Ollama (21.4 tok/s). Prompt evaluation on large models is the gap still open. The GEMM runs in FP32 throughout, and staging the weight tiles in half precision is the next step.

### Memory

Before loading, the runtime works out what the model will hold from its GGUF metadata alone: the mapped weights, the FP32 KV cache for the requested context, and the working buffers. Loaded models may use 80% of the Mac's memory together (`ROACHNET_MODEL_MEMORY_GB` overrides this). If a model doesn't fit:

1. Idle models are unloaded, oldest first.
2. The context is halved until it fits, but never below 2,048 tokens. The log says so.
3. If it still doesn't fit, the request fails with a 507 that names the sizes, rather than the Mac paging itself to a halt.

`/api/ps` reports each model's real footprint and backend. `ROACHNET_MAX_LOADED_MODELS` sets how many models stay loaded at once (2 by default).

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
roachnet-infer prefill <model.gguf> [--tokens N]        (Metal: batched prompt evaluation against a token at a time)
```

## Plan models (Claude and ChatGPT plans)

The model server can also offer the Claude or ChatGPT plan a person already pays for, as `claude:<model>` (`claude:sonnet`, `claude:opus`, `claude:haiku`) and `codex:<model>` (the models `codex debug models` lists). They are off until the person turns them on in Settings › RoachClaw › Subscriptions, or with `PUT /api/roachclaw/subscriptions {"claude": true}`.

- **Where they show up:** `/api/tags`, `/v1/models`, RoachClaw's model list, and anywhere an Org agent names a model. Every model API above answers in its own format, streamed or not. A client's tools and formats are described to the plan model in words and read back from its reply, because the CLI runs with its own tools off.
- **How a reply is made:** RoachNet runs the person's own signed-in CLI headless in an empty scratch folder:
  - Claude Code: `-p --output-format stream-json --include-partial-messages`, no tools (`--tools ""`), no saved session, no user hooks or MCP servers, and the request's system messages as `--system-prompt`. Text streams as it arrives.
  - Codex: `exec --json --ephemeral --ignore-user-config` in the read-only sandbox. Its answer arrives in one piece.
  Earlier turns of a conversation are written out as a transcript. RoachNet never handles the plan's credentials.
- **Usage and cost:** usage comes from the CLI, with cached prompt tokens counted. Each reply is a generation priced `subscription_included` at $0, with Claude Code's API-equivalent cost in the trace metadata. An Org agent on a plan model bills its runs the same way.
- **Errors:** an error names the fix: sign in (401), plan limit reached (429), CLI too old for the model, or plan models turned off (403).
