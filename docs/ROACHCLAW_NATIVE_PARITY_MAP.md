# RoachClaw Native Parity Map

This file tracks the upstream self-hosted AI workspace feature surface as
RoachNet-native macOS, iOS, runtime, and site work. The product language stays
RoachNet-branded; this map exists so none of the reference surface disappears
while it is being rebuilt in Swift, SwiftUI, Core ML, and the contained
RoachNet runtime.

Reference source checked: `https://github.com/pewdiepie-archdaemon/odysseus`
at GitHub HEAD `9e74a327f86ac04474a0bf6b303eae41032db89a`.
Do not use the local Odysseus checkout as the source of truth for parity work;
fresh GitHub source is the reference moving forward.

## Native Product Structure Direction

- Command and launch work should feel closer to Raycast: fast search, clear
  action labels, scoped shortcuts, and useful previews before execution.
- Context-heavy work should feel closer to Cursor: a contextual side rail that
  explains what RoachClaw can see, what it is allowed to touch, and what changed
  after the last action.
- Autonomous work should feel closer to Claude Code: explicit task goal,
  stop condition, tool boundary, evidence bundle, and replayable run history.
- Multi-agent work should feel closer to a Monet-style dashboard: separate
  agent roles, context budgets, handoff state, and a visible outcome ledger.
- Vault navigation should stay Finder-like: real local paths, preview-first file
  browsing, drag/drop imports, and no hidden cloud custody.
- Runtime and agent health should feel like Activity Monitor: live status,
  counters, stalled work, resource pressure, and safe stop/retry actions.
- The native runtime now exposes computed shell-state summaries under
  `roachClaw.operations.commandDeck`, `contextRail`, `vaultNavigator`,
  `agentMonitor`, and `orchestrationDashboard`. These are the bridge between
  raw local stores and the polished app shell. Each lane now includes native
  route, priority, hotkey, and summary metadata so macOS and iOS can present
  the shell as a real workbench instead of a pile of counters.

## Native Feature Families

| Reference family | RoachNet-native home | Current state | Notes |
| --- | --- | --- | --- |
| Chat | RoachClaw | Native-ready, expanding | Sessions, streaming, local presets, provider routes, attachments, scoped context, detached run metadata, and replay crumbs are represented in the RoachClaw runtime and web lane. |
| Session board | RoachClaw | Native-state, expanding | Session history, detached run replay, transcript save/export, context restore, and branch resume are tracked as a first-class native lane. |
| Agent tools | RoachClaw | Native-ready, expanding | Tool execution maps to scoped shell, file, MCP, app-action, approval-gated native actions, and local tool-index records. |
| Cookbook | Runtime / Apps | Native-ready, expanding | Hardware-aware model fit, quantized/MoE sizing, model packs, download lanes, cache layout, serve plans, serve schedules, and progress-stall signals are tracked through the native runtime. |
| Workspace browser | Dev / RoachClaw | Native-state | Odysseus workspace browsing is rewritten as a local loopback route that lists directories only, skips dotfiles and symlinks, and gives Dev/RoachClaw project context without a Python WebUI bridge. |
| Deep Research | RoachClaw / Vault | Native-ready path, expanding | Research plans, source gathering, synthesis, citations, and vault briefs are tracked as a RoachClaw playbook lane. |
| Compare | RoachClaw | Native-ready path, expanding | Blind comparison, scoring, reveal, and saved winners are represented as a first-class playbook lane. |
| Model bench | Runtime / RoachClaw | Native-ready path, expanding | Model fit, blind comparison, serve plans, winner history, and model-pack routing are grouped as one native Apple Silicon bench. |
| Documents | Vault / Dev | Native-state, expanding | Markdown, PDF, ebook, export, rewrite, summarize, read-aloud, and local editor draft state belong in the Vault and Dev surfaces. |
| Memory / skills | RoachBrain | Native-state, expanding | Persistent memories, reusable skills, context compaction summaries, and local tool cards now have RoachClaw stores; embedding-backed retrieval and skill extraction UI remain the next layer. |
| Memory provider | RoachBrain | Native-state, expanding | Odysseus provider-neutral memory contracts now map to a RoachBrain native provider that is always available, with external memory providers represented as explicit opt-in records. |
| Embedding lanes | RoachBrain | Native-state, expanding | Separate custom and local embedding lanes now expose dimensions, fingerprints, reset safety, stats, and health as RoachNet-native metadata without coupling to Chroma or Python runtime state. |
| Tool policy | RoachClaw | Native-state, expanding | Guide-only/no-tools detection, disabled tools, hidden tools, MCP disable state, and enforcement metadata are exposed for macOS/iOS display and future tool gating. |
| Streaming markdown | RoachClaw / Web | Native-state, limited | Hosted RoachClaw does not stream SSE yet, but the web lane now uses safe segmented markdown rendering and pending/live-tail metadata without breaking the hosted JSON chat flow. |
| Email | RoachClaw | Native-state, expanding | Local message and draft state now backs RoachMail operations; IMAP/SMTP account sync, urgency, and provider folders remain the next protocol layer. |
| Notes / tasks | Home / RoachClaw | Native-state, expanding | Local task state is exposed through RoachClaw operations; reminders, scheduled agent tasks, and delivery channels are next. |
| Calendar | Maps / RoachClaw | Native-state, expanding | Local event state is exposed through RoachClaw operations; recurrence, ICS import/export, and optional CalDAV sync are next. |
| Search / RAG | Vault / RoachClaw | Native-state, expanding | Vault indexing, provider search, ranking, source-grounded answers, and cached query crumbs stay local-first. |
| Voice | RoachSpeech | Native-ready path, expanding | STT, TTS, voice profiles, vault transcripts, read-aloud, and model packs are RoachSpeech work. |
| Gallery / editor | Vault | Native-state, expanding | Local gallery asset state is exposed through RoachClaw operations; media import, albums, cleanup, and export are next. |
| Security / accounts | Settings / Runtime | Native-state, expanding | Token gates, scoped tools, pairing, action approval, private-by-default runtime state, and local hashed API tokens are native release gates. |
| Provider security / OAuth | Settings / Runtime | Native-state, expanding | Odysseus TLS override, centralized upload limits, OAuth, and SSRF-safety behavior is represented as native metadata and local routes; insecure TLS disable is not allowed, token material is never exported, and user-owned remote tools stay explicit. |
| Mobile / PWA | RoachNet iOS | Native-ready | Mobile parity is the iOS companion: runtime checks, vault reads, app installs, RoachTail, and phone-first controls. |
| Contacts | RoachClaw | Native-state, expanding | Local contacts now have a RoachClaw store, reply-recipient scopes, and native operations payloads. |
| Diagnostics / service health | Runtime | Native-ready | Provider probes, degraded-state reports, service-health rollups, setup warnings, and runtime evidence belong in the native diagnostics lane. The `src/service_health.py` reference is rewritten as a secret-safe native report at `/api/roachclaw/diagnostics/services`. |
| Preferences / themes | Settings | Native-state, expanding | Settings, local prompt presets, model sorting, safe scrub/export, and appearance controls stay under native settings. |
| Theme studio | Settings | Native-ready path, expanding | Palette, density, motion, contrast, and settings export are now tracked as native shell controls. |
| Uploads / personal docs | Vault | Native-ready | Vision/PDF uploads, personal document indexing, ownership isolation, and vault-safe imports stay in Vault. Chat, gallery, vault, memory, email, speech, calendar, and installer intake now report through one RoachNet-native upload-limit policy table. |
| Webhooks / integrations | Runtime | Native-state, expanding | Local hook endpoints, configured webhook records, redacted secret policy, and hashed API-token state are exposed through RoachClaw operations; inbound hook execution UI is next. |
| Optional cloud provider keys | Settings / RoachClaw | Native-state, expanding | OpenAI, Anthropic, and OpenRouter keys are user-owned optional routes. RoachNet stores key material only in local 0600 files, exposes redacted metadata, and keeps local RoachClaw as the default path. Development OpenAI keys must never be bundled into RoachNet itself. |
| User time context | Settings / RoachClaw | Native-state | User timezone, UTC offset, and prompt clock context are stored locally for schedulers, reminders, and relative-date prompts. |
| Background jobs | Home / Runtime | Native-state, expanding | Download/update jobs, local task queue state, event counters, and detached agent run records are visible; pollers, replay UI, and reminders are next. |
| Visual reports | Vault / RoachClaw | Native-state, expanding | Local report state, formats, and templates are exposed through RoachClaw operations; rendered exports and vault-save flows are next. |
| Native shell surfaces | Home / RoachClaw / Vault | Native-state, expanding | Command deck, context rail, Finder-like vault navigator, Activity Monitor-style agent monitor, and orchestration dashboard are computed from the local stores and decoded by macOS/iOS. |
| Signatures | Vault / RoachClaw | Native-state, expanding | Saved signature payloads now have local native state for documents, mail, and vault notes; drawing/import UI is next. |
| Backup / restore | Settings / Runtime | Native-state, expanding | RoachClaw export payloads and snapshot metadata now have a local native route; selective restore and migration UI are next. |
| Admin recovery | Settings | Native-ready | First-run admin setup, ownerless data claims, wipe/reset gates, and recovery flows stay explicit and local-first. |

## Upstream Module Ledger

The native runtime exposes a machine-readable `referenceModules` ledger under
`roachClaw.playbook`. That ledger maps upstream routes, services, source modules,
and web modules into RoachNet-native owners. It intentionally includes planned
work so unfinished areas are visible instead of silently omitted.

The runtime also exposes `roachClaw.playbook.referenceSource.repository`,
`commit`, `latestSeenCommit`, and `sourceKind`. Those fields must point at the
GitHub upstream commit inspected for the current parity pass.

The runtime exposes a second audit layer under
`roachClaw.playbook.referenceInventory`. This compact inventory tracks the full
functional GitHub surface for the inspected commit:

| Upstream group | Functional files | RoachNet-native owner |
| --- | ---: | --- |
| `routes/` | 51 | Native API routes, Swift views, and operation contracts |
| `core/` | 10 | Contained runtime and Settings |
| `src/` | 103 | RoachClaw, RoachBrain, Vault, Settings, and Runtime |
| `services/` | 40 | Runtime, RoachSpeech, Vault, and RoachBrain |
| `mcp_servers/` | 5 | Scoped RoachClaw native tools |
| `scripts/` | 40 | Command Deck actions, runtime jobs, and migration references |
| `companion/` | 4 | RoachNet iOS and RoachTail control plane |
| `static/js/` | 149 | SwiftUI rewrites and RoachClaw web surface behavior |

That is `402` functional files tracked out of `1047` total upstream files at the
current GitHub commit. The functional count is the sum of the coverage groups
above. Docker, Python, WebUI, test, and documentation files are
reference material only; they must not become RoachNet shipping dependencies.

Representative required entries:

- `routes/admin_wipe_routes.py` -> Settings / admin recovery.
- `routes/api_token_routes.py` -> Settings / local hashed API keys.
- `routes/assistant_routes.py` -> RoachClaw / assistant crew.
- `routes/contacts_routes.py` -> RoachClaw / contacts.
- `routes/codex_routes.py` -> RoachClaw / native scoped tool/API bridge.
- `routes/copilot_routes.py` -> Settings / optional user-owned provider device-flow reference only.
- `routes/diagnostics_routes.py` -> Runtime / diagnostics.
- `routes/editor_draft_routes.py` -> Vault / native editor drafts.
- `routes/stt_routes.py` and `routes/tts_routes.py` -> RoachSpeech.
- `routes/search_routes.py` -> Vault / source cache.
- `routes/skills_routes.py` -> RoachBrain / local skills.
- `routes/webhook_routes.py` -> Runtime / integrations.
- `routes/workspace_routes.py` -> Dev / native workspace browser. This route is now retired upstream but remains tracked because RoachNet already ships the native replacement.
- `src/action_intents.py` -> RoachClaw / native action intent detection.
- `src/agent_runs.py` -> RoachClaw / detached run metadata.
- `src/agent_tools/__init__.py`, `src/agent_tools/filesystem_tools.py`,
  `src/agent_tools/subprocess_tools.py`, and `src/agent_tools/web_tools.py` -> RoachClaw / scoped native agent tool lanes.
- `src/context_compactor.py` -> RoachBrain / compacted context records.
- `src/cookbook_serve_lifecycle.py` -> Runtime / native cookbook serve schedules and stop windows.
- `src/event_bus.py` -> Runtime / local event counters.
- `src/embedding_lanes.py` -> RoachBrain / native embedding lane metadata.
- `src/memory_provider.py` -> RoachBrain / memory provider metadata.
- `src/mcp_oauth.py` -> RoachClaw / planned native OAuth handoff for user-owned tools.
- `src/memory.py` -> RoachBrain / local memories.
- `src/pdf_runtime.py` and `src/pdf_forms.py` -> Vault / PDF reader and form tools.
- `src/settings_scrub.py` -> Settings / safe export.
- `src/service_health.py` -> Runtime / secret-safe service health rollup.
- `src/task_scheduler.py` -> Home / background jobs.
- `src/tool_policy.py` -> RoachClaw / guide-only and disabled-tool policy metadata.
- `src/tls_overrides.py` -> Settings / optional scoped CA bundle metadata for user-owned providers.
- `src/tool_index.py` -> RoachClaw / local tool index.
- `src/upload_limits.py` -> Vault / centralized RoachNet intake policy for chat, gallery, vault, memory, email, speech, calendar, downloads, and public 413 handling.
- `src/url_safety.py` -> Settings / SSRF-safe user-supplied URL checks for optional provider routes.
- `src/url_security.py` -> Settings / public URL validation for optional cloud routes.
- `src/user_time.py` -> Settings / prompt clock and scheduler time context.
- `src/visual_report.py` -> Vault / visual reports.
- `services/hwfit/fit.py` -> Runtime / Apple Silicon model fit.
- `services/hwfit/image_models.py` -> Runtime / local image model fit and pack readiness.
- `services/faces/__init__.py` -> Vault / planned native face-aware gallery and media tooling.
- `services/stt/stt_service.py` and `services/tts/tts_service.py` -> RoachSpeech.
- `static/js/compare/scoreboard.js`, `static/js/compare/stream.js`, and
  `static/js/compare/vote.js` -> RoachClaw / native compare lane behavior.
- `static/js/cookbookProgressSignal.js` and `static/js/cookbookSchedule.js` -> Runtime / native cookbook progress and scheduling behavior.
- `static/js/emailLibrary.js` -> RoachClaw / mail.
- `static/js/streamingSegmenter.js` and `static/js/streamingRenderer.js` -> RoachClaw web / segmented markdown streaming behavior.
- `static/js/workspace.js` -> Dev / native workspace browsing.

## Guardrails

- Do not bundle the Python or web app as a shipping dependency.
- Do not expose the reference product name in RoachNet UI copy.
- Rebuild each feature as a native RoachNet lane or fold it into an existing
  RoachNet surface.
- Prefer Swift/SwiftUI, Foundation, AVFoundation, Core ML, Network, and the
  contained Node runtime only where the current RoachNet bridge still owns
  release/install work.
- Treat every planned-native family as a visible backlog item until it has UI,
  API state, tests, and release documentation.
- Cookbook model sizing must unpack quantized tensor counts and MoE active
  parameters before presenting a model as Apple Silicon-ready.
- Runtime cache directories should be explicit and relocatable so search,
  model-fit, and download state do not end up as loose project files.
