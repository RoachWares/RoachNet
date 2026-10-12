# RoachNet 1.1 — expanded scope

Brennan held 1.1 on 2026-10-11, after its first full Mac gate passed, to add five more pieces:

1. Tracing and observation for the Org and RoachClaw, at the level of Langfuse and OpenTelemetry token telemetry.
2. Bring-your-own agents: any agent people already use joins an Org and works with the others the way Paperclip agents do.
3. ChatGPT/Codex and Claude subscriptions as providers and models, through the user's own logged-in Codex CLI and Claude Code (his decision: the subscription stays inside the vendor's official client).
4. RoachInference past Ollama: more efficient, more stable, cheaper to run, more features.
5. RoachNet Cluster: multi-device inference, built natively into RoachNet.

1.1 ships once all five are in and a fresh Mac gate passes. The gated candidate from `46f97b1` (DMG `90a286c1…4c09`) is a reference build only.

**Status, 2026-10-12:** all five are in on `release/v1.1`.

| Piece | Linear | Commits |
| --- | --- | --- |
| RoachTrace | ROA-50 | `ef8d8d3`, `768c8b0`, `c6af7c5` |
| Bring-your-own agents | ROA-51 | `22d340a` |
| Subscription plans as models | ROA-52 | `22d340a` |
| RoachInference past Ollama | ROA-53 | `f0666ac`, `8e72936`, `4b83bfb`, `e08e7e5`, `b935ffc` |
| RoachNet Cluster | ROA-54 | `07100f2`, `1faf4ee`, `d39edc3` |

Two parts of §4 moved to ROA-55 (1.1.x): speculative decoding, and decode at or past Ollama on qwen3 8B. Speculative decoding needs a small-batch kernel first. Where RoachInference stands against Ollama is in `docs/NATIVE_INFERENCE.md`.

Ground rules carry over: offline first, nothing leaves the Mac unless the person turns it on, hand-written Metal only for inference (no MLX, MPS, Core ML or llama.cpp code), no new runtime dependencies.

## 1. RoachTrace: tracing and observation

**Model (Langfuse-shaped, so an export maps one to one):**

- **Trace:** one unit of work: an Org run, a RoachClaw chat turn, or a model-server request.
  - Fields: kind, name, session (issue or chat thread), actor, agent, company, tags, input and output, metadata, status, start and end.
  - Rolled-up totals: tokens (input, output, cached), cost, latency.
- **Observation:** a node in the trace tree. Types: `span`, `generation`, `event`, `agent`, `tool`, `chain`, `retriever`, `embedding`, `guardrail`, `evaluator`.
  - Generations carry the model and its parameters.
  - Usage: input, output, cached input and total tokens.
  - Cost: cents, with a status of reported, estimated or unpriced, and the billing type (`local`, `metered_api`, `subscription_included`).
  - Speed: time to first token, prompt and generation tokens per second.
- **Score:** a number, category or boolean on a trace or an observation, from a person, the API or an evaluator, with an optional comment.

**Store:** one owner-only JSONL file per day under `storage/state/traces/`. It keeps an index of recent traces, and a retention window (30 days by default) removes old files. Secret values the Org knows are redacted before they're written. Capturing prompt and response text can be switched off.

**Instrumented:**
- Org runs: the agent span, every model call, every Org action as a tool span, and CLI-agent turns parsed from their JSON streams.
- RoachClaw and companion chat.
- Every `roachnet-runtime` model-server request.

**API:** `/api/traces` (list, filter, cursor), `/api/traces/:id` (tree and scores), `/api/traces/:id/scores`, `/api/traces/metrics` (by agent, model, provider or day: count, error rate, tokens, cost, latency p50/p95, TTFT, tok/s), and `/api/traces/settings`. Org members get the same, scoped to their company, under `/api/org/companies/:cid/traces`.

**Export (off by default):**
- An OTLP/HTTP JSON exporter to the person's own collector or Langfuse (`…/api/public/otel/v1/traces`), using `gen_ai.*` and `langfuse.*` attributes.
- Batched, with a bounded on-disk queue and retry. Content is excluded unless the person includes it.

**Mac UI:**
- A Traces board on the Org desk: a filtered list and a detail waterfall with tokens, cost, latency, input and output, and scores.
- Tracing settings in Settings › RoachClaw.

## 2. Bring-your-own agents

**Adapters:**
- New: `claude_local` (Claude Code), `codex_local` (Codex CLI), `gemini_local` (Gemini CLI), `opencode_local` (OpenCode) and `cursor_local` (Cursor's `cursor-agent`).
- Existing: `roachclaw_local`, `openai_compatible`, `http` and `process`.
- Each CLI adapter:
  - finds the binary on PATH and the vendors' install folders;
  - reports version and sign-in state (Test environment);
  - builds the headless command (JSON event output, model, resume);
  - parses the event stream into run logs, generations, usage, cost and the session id;
  - resumes one session per agent and issue;
  - runs in the project workspace or the agent's home with the vendor's own sandbox flags.
- CLI agents run commands on the Mac, so only the RoachNet owner can configure them.

**Talking to each other (Paperclip semantics):**
- Agents work through the Org API with their per-run token (`ROACHNET_ORG_API_URL`, `ROACHNET_ORG_API_KEY`).
- What they do there: check out an issue, comment, change status, create subtasks for another agent, request approvals, write documents.
- The Org already wakes agents on assignment, comments, mentions, blockers resolved, children completed, review requests, changes requested and approval decisions.
- New: a RoachNet Org skill (`ROACHNET_ORG.md`) that every CLI agent receives. It holds the endpoints and curl examples for those actions.

## 3. Subscription providers

- RoachClaw gets two providers: **ChatGPT (Codex CLI)** and **Claude (Claude Code)**.
- RoachNet never handles the subscription credentials. A chat turn runs the official CLI headless, with tools off: `codex exec --json --sandbox read-only --ephemeral`, or `claude -p --output-format stream-json`. The reply streams back.
- The providers are also served on the runtime's OpenAI-compatible API under `codex:` and `claude:` model names, so the Org, Dev and chat can all use them.
- Settings shows each CLI's install and sign-in state, and **Sign in** opens the CLI's own login in Terminal.
- Usage and cost go into traces with billing type `subscription_included`.

## 4. RoachInference past Ollama

**API coverage:**
- tool and function calling (OpenAI and Ollama formats);
- structured output (`format: "json"` and JSON Schema, enforced while sampling);
- thinking (`think`);
- `/v1/completions`, `/v1/responses`, and Anthropic-compatible `/v1/messages`;
- `/api/create` for derived models (system prompt, parameters, template).

**Scheduling:**
- concurrent requests with a queue per model;
- several cached sessions per model, so a new turn reuses its conversation's prefix instead of re-reading it;
- loading and eviction that check free memory.

**Speed:** speculative decoding with a small draft model of the same family, and decode at or past the installed Ollama on the reference models.

**Stability:** an out-of-memory guard before loading, request deadlines, and a watchdog for stuck generations.

**Cost:** local generations are priced at zero, and every request's trace reports its time and tokens per second, so a local run can be compared with a metered one.

## 5. RoachNet Cluster

- **Discovery:** Bonjour `_roachnet-infer._tcp` on the local network, plus paired RoachTail peers.
- **Placement:** each node reports memory, GPU family and a short benchmark. The planner splits a model's layers in proportion to each node's free memory and measured speed, and weighs link latency too.
- **Inference:** pipeline-parallel across Macs, with hidden states over authenticated TCP.
- **What RoachNet Cluster adds:**
  - each node downloads only its own layers, with HTTP Range reads of the GGUF tensors;
  - links are encrypted and work across networks over RoachTail;
  - the plan re-forms when a node drops;
  - a one-node cluster falls back to the local engine.
- **API:** the same Ollama, OpenAI and Anthropic surface, plus `/api/cluster` for nodes, plans and health.
- **Branding and code:** RoachNet Cluster is written from scratch for RoachNet. No copy, setting or doc names another project, and no outside cluster code is copied in. The 1.0-era external cluster backend option and its labels go away.

## Order and gates

Order: 1, 2, 3, 4, 5. Each lands with contract tests and a hands-on check on the M2 Pro, and gets its own Linear issue. 1.1 is gated again from the top once all five are in.
