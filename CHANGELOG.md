# Changelog

## Unreleased (1.1.1)

Not released yet. This lists what is on `dev/1.1.1` so far; nothing here ships until the 1.1.1 gate passes.

### No Node in RoachNet

- RoachNet, RoachNet Setup and `roachnet-runtime` contain and launch no Node or JavaScript. The app and Setup no longer fall back to a Node launcher (`ROACHNET_FORCE_NODE_RUNTIME` is gone) or unpack a bundled source tree; if the runtime helper is missing they say to reinstall with RoachNet Setup.
- RoachNet Setup refuses an app payload whose runtime helper is missing or isn't an executable file (a folder or a link in its place included) before it replaces the installed copy. Its verification step now fails instead of being skipped, and a helper that fails verification stops the install too, so Setup can't install an app that can't start. When an upgrade fails before the swap, Setup's saved settings go back to the installed copy's, even when the Setup app had already saved new choices, such as another install folder, before it asked for the install. After an install fails past its swap, the new copy's settings are the ones kept. An upgrade cut off between moving the old copy aside and moving the new one in is put back before Setup reads the install, so a failed retry keeps its settings too. While an upgrade runs, Setup also keeps the installed copy's settings on disk, so an upgrade that saved new ones (another storage folder, say) and was cut off before its copy was in place gives them back on the next run. Each install's `roachnet-install.json` now carries an `installId`, which tells Setup whether that copy got into place. The Setup app no longer saves the choices on screen when you continue or install: the install saves them after it has kept the installed copy's settings aside. Open still saves them, now through the setup service, which keeps the settings the Setup app doesn't show. If Setup can't keep the installed copy's settings aside, the install stops before changing anything and says why. If it can't write them back, it keeps them aside and tries again on its next run.
- The build fails if either bundle holds a `node` binary, `node_modules`, JavaScript files or RoachNet source. `ROACHNET_BUNDLE_NODE_COMPAT` and `ROACHNET_BUNDLE_OPENCLAW` are gone, and OpenClaw files older builds left in the Setup bundle are cleared.
- Removed: the JavaScript runtime and setup backend (`scripts/run-roachnet*.mjs` and the companion server), the Electron shells (`desktop/`, `installer/`, `setup-ui/`) and the Docker install lane (`install/`, `ops/`, `Dockerfile`). RoachNet Setup no longer shows a Docker option; its setup service already refused one.
- Both apps now carry the repository's Apache-2.0 `LICENSE`.
- `runtime-freshness.json` records Node as not shipped and OpenClaw as something RoachNet only probes when you run it yourself; the SBOM lists both as not bundled.
- Node 26 is still the toolchain for the build, test and release scripts in `scripts/`. None of it ships.

### RoachNet Cluster

- When a Mac in a split model drops before any of a reply is sent, the same request is planned again without it (on this Mac alone when the model fits) instead of failing with 502. A drop after part of the reply was sent still fails that request.
- **Find Macs Nearby** matches Macs by the node ID each proves at the handshake, so a Mac added by IP no longer shows as not added when Bonjour lists it by name.
- The status in Settings tries once more after a connect timeout, so a Mac that was idle on Wi-Fi isn't shown as unreachable. A refused connection still fails at once.
- Each hop counts round trips, tokens, time and bytes each way. `GET /api/cluster` shows the totals, and each trace carries that request's figures (`cluster_hops`) and marks a fallback reply (`cluster_fallback`). These traces are also tagged `cluster` or `cluster-fallback`.
- What another Mac sends is checked: stage and shard digests must be 64 hex characters, positions, counts, offsets and context lengths must be in range, and shard pieces are refused when the volume would drop below 4 GB free. Before this, a paired Mac could name a path outside the shard folder.

### RoachTrace

- `GET /api/traces` (and `/api/traces/metrics`) take `minLatencyMs`, `maxLatencyMs` and `minCostUsd` for finding slow or expensive traces. A trace still running has no latency yet, so a latency bound leaves it out. Bounds that aren't non-negative numbers are ignored.
- Credential fields are redacted by what their names mean (`access_token`, `client_secret`, `x-api-key`, `private_key`, cookies), not only a few exact names; counts such as `max_tokens` are kept.
- Two export flushes at once no longer drop a batch that was never sent, and the in-memory trace cap holds while a large day replays at startup.

### Model server

- Numbers from request bodies and CLI output (`num_predict`, `top_k`, `repeat_last_n`, `seed`, `num_ctx`, embedding dimensions, schema item counts, trace settings, usage counts) are clamped, so NaN, infinity or out-of-range values can't crash the runtime.
- A new request slot needs twice its size free normally and four times while macOS reports memory pressure, and isn't made at critical pressure. A refused slot pauses growth for a minute instead of capping the model for good, and idle extra slots hand back their memory after 30 seconds under pressure (5 minutes otherwise).
- A GGUF's counts, sizes, offsets and nesting are checked before use, and its model sizes (heads, widths, context) must be plausible, so a broken or hostile model file is refused instead of crashing the runtime.
- Llama 3.1-style RoPE scaling declared in a GGUF's metadata is applied when the file has no `rope_freqs` tensor.
- JSON Schema `anyOf` and `oneOf` keep every branch that still fits until the output decides, so a second object variant (or a second forced tool) can be generated. Alternatives that are all fixed values count as one choice. A schema that could leave more than 64 branches open at once, or whose references expand to more than 10,000 parts, gets a 400 instead of having branches dropped or filling memory. A top-level fixed value that also starts a longer one (`1` among `1` and `10`) can still end the output.
- `/v1/completions` takes one text prompt. Batched or token-array prompts get a 400 instead of being merged into one.
- A model that fits the memory budget but not beside models busy answering requests is refused with a 503 instead of being loaded past the budget.
- RoachNet runs beside an Ollama you run yourself without sharing a port. RoachInference never listens on Ollama's port, 11434: an `OLLAMA_BASE_URL` on 11434, or with no port, still gets RoachNet's own port, 36434, and RoachNet's model requests never default to 11434. RoachNet no longer starts `ollama serve` at all. With `ROACHNET_INFERENCE_ENGINE=ollama` it uses the Ollama you already run (at `ROACHNET_OLLAMA_URL` when that's set, otherwise `127.0.0.1:11434`), and RoachInference answers while that Ollama isn't running. Before, that setting started a second `ollama serve` of RoachNet's own on 36434, which kept running after RoachNet quit.
- When another program already answers on RoachNet's own model address, 127.0.0.1:36434 (an older RoachNet's `ollama serve` still running after an upgrade, say), RoachInference takes a free loopback port and RoachNet uses that, instead of quietly sending its requests to the other program. The other program is left running. Any other address set with `OLLAMA_BASE_URL`, apart from Ollama's port, is still used as configured. A local Org agent finds or starts the model server before reading its address, so its first run can't go to that other program either.
- Half-precision subnormals decode correctly on Intel builds, where they used to crash.

### Packs and themes

- A pack archive is read before it's unpacked and refused if an entry is absolute, climbs out with `..`, or is a link or special file, or if it would unpack to more than 64 GB. ZIPs are unpacked by RoachNet's own reader, so what's written is what was checked: `ditto` also walks an archive's local headers, and in testing it unpacked a file the directory didn't list, past every check and the size limit. The reader creates each file new (never through a link or over another file), writes exactly the size the directory declares, checks each file's CRC-32, and refuses an archive that could be read two ways: two end records, ZIP and ZIP64 records that disagree, bytes between files or ahead of the first, overlapping files, a local header that disagrees with the directory, two names that unpack to the same file (`a/./b` and `a/b`) or a file where a folder is, or a file name that tools could decode differently (a name past ASCII must be marked UTF-8, and an Info-ZIP Unicode path field must repeat it). A .tar.gz is measured by inflating it without writing anything, then unpacked by tar. Either way the result lands in a folder of its own, is checked again (a folder the archive made unreadable no longer passes as empty), and is merged in without replacing a file the pack already has. (macOS's own tools kept the tested archives inside the folder, but a symbolic link could still point outside it.)
- RoachNet's reader and unzip (which unpacks on Linux) write the same files. A ZIP is refused if a file entry names no file (`.`, which unzip writes as `_`) or ends in `.` (`a/.`, which unzip writes as `a/_`), if an entry inside `__MACOSX` is spelled any way but `__MACOSX/…` (only that spelling is left out, by both), or if a name holds a control character (unzip drops them). Two names count as one file when they match after Unicode case folding, the way APFS compares names (`ς.json` and `σ.json`, as well as `A.json` and `a.json`), or when they are one name in two Unicode normalization forms. A folder must be spelled one way throughout: `Σ/` beside `ς/`, `A/` beside `a/`, or one name in two normalization forms would be one folder on APFS and two on Linux, so such a ZIP is refused. Names are split at every `/`, as unpackers and the kernel split them, even where a combining mark follows it: `../` then U+0301 used to pass the `..` check, and `__MACOSX/` then one wasn't left out. A `.tar.gz` listing is refused for the same two kinds of file name (`.` and `a/.`).
- Unpacked packs get plain modes (folders 0755, files 0644, or 0755 when executable), and the tools that read archives run without `UNZIP`, `TAR_OPTIONS` and similar variables that change how they read.
- RoachSpeech packs install only from RoachNet download descriptors, and a pack the catalog lists must match the catalog's SHA-256 however the install was asked for (Pack Manager, install link or iPhone).
- A pack installs only when the packs it depends on are installed; if one of them is switched off, the new pack installs switched off, and an update that adds a dependency that's off switches the pack off. A pack whose dependency is removed while it downloads installs switched off. Pack state changes are made in one step, so two installs finishing together both stay recorded.
- An imported theme's background picture has to be a picture file inside the theme's folder, or the import is refused. A crafted name could copy a file outside the themes folder.

### Org

- Viewers can read traces but can no longer score them.
- Approvals sent at once decide only the stage they were checked against, so one reviewer can't pass a later stage meant for someone else. A one-time agent claim gives one key however many claims arrive together.
- Numbers in Org requests beyond what JSON carries exactly are refused instead of crashing the runtime, and token counts and amounts of money are held to 10^12 per event so sums stay in range. A cost a CLI reports that isn't a real amount (NaN, infinity, a negative number) counts as unpriced, so the run's trace can still be saved.

### Downloads, collections and maps

- Response size limits hold while bytes arrive, and up front when a server announces a larger body, for collections, pack catalogs, manifests and download descriptors.
- A live Wikipedia option other than "none" must have a URL.
- A map tile's gzip size field can no longer make RoachNet reserve gigabytes, and tiles rendered for a previous set of map packs are dropped.
- Kiwix catalog: Math & Problem Solving's recommended tier has a book again, four versions match their ZIM files, and "Download recommended" skips a recommended tier with nothing to download.

### Vault

- Optional encryption at rest (Settings › Vault › Encryption), off unless you turn it on. The Vault moves into an AES-256 encrypted disk image made by macOS, with a recovery key shown once, an optional Keychain copy, checked copies both ways and a move that survives being cut off. See `docs/VAULT_ENCRYPTION.md`.
- A locked Vault is reported as locked by `/api/rag/files` (`vaultLocked`), `/api/companion/vault` (`locked`) and the readiness check.

### Tokens

- Random tokens, salts and secrets (Org invites, Org API keys, the Org's run-token secret, webhook salts) come straight from the system's secure random generator at their full length. They used to be cut from a UUID, which stopped at 32 characters and fixed two of them. Existing tokens keep working.

### Release builds

- `scripts/tests/release-hardening.test.mjs` checks the packaged helper itself. It covers out-of-range numbers, RoachTail token expiry, the local API token and scopes, and salted webhook secrets.
- The apps no longer carry the build Mac's file paths: dSYMs are kept out of the bundle, executables are stripped of their debug map before signing, and `scripts/audit-release-privacy.mjs` fails the build if a built file names the build Mac's folders, host names or network addresses.
- The supply-chain audit expects a scan only for runtimes a release bundles, so a 1.1 candidate (no bundled Ollama or Node.js) can pass promotion.

## v1.1.0 - 2026-10-12

Feature release. Includes every fix in 1.0.6 and 1.0.7. Ad-hoc signed, not Apple-notarized.

### RoachClaw and local models

- RoachNet no longer bundles or installs Ollama. RoachClaw runs on RoachInference, a native GGUF engine with hand-written Metal kernels, served by `roachnet-runtime` on the loopback API. Models in an existing Ollama folder are read in place; `ROACHNET_INFERENCE_ENGINE=ollama` keeps using a runner you installed yourself.
- The model server answers the Ollama API (`/api/chat`, `/api/generate`, `/api/embed`, `/api/embeddings`, `/api/create`, `/api/show`, `/api/copy`, `/api/delete`, `/api/pull`, `/api/ps`, `/api/tags`), the OpenAI API (`/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/embeddings`, `/v1/models`) and the Anthropic API (`/v1/messages`, `/v1/messages/count_tokens`), streamed or not, with each API's own error shape.
- Tool calls, JSON mode and JSON Schema output (enforced while sampling), thinking on or off, and Modelfiles that make new models over the same weights.
- Up to four requests per model run at once (`ROACHNET_MODEL_SLOTS`), each in a slot with its own KV cache. A request goes to the slot already holding its conversation, and a new conversation that shares a long beginning with another starts from a copy of that prefix.
- Loads are planned against memory: idle models are unloaded, then the context is shortened, then the load is refused with a 507 that names the sizes. Keys and values are stored in FP16 on the GPU (`ROACHNET_KV_CACHE=f32` keeps FP32).
- Batched prompt evaluation on the simdgroup matrix units with half-precision weight tiles, decode attention split across key chunks with coalesced key reads. On an M2 Pro with Ollama's own qwen3 8B file: prompt 181 tok/s (Ollama 0.33.2: 267), decode 18.7 tok/s (22.0). Earlier, against Ollama 0.40.1, decode ran at about 91% of Ollama's speed on 1.5B and 3B models and faster on 0.5B. CPU and Metal produce identical tokens on the reference models.
- A failed GPU pass or a NaN in the logits ends the request with an error instead of a garbled reply.
- Model pulls resume where they stopped, retry on their own after a 90-second stall (up to six tries, like the download lane), restart cleanly when a server ignores the resume request, and are checked by SHA-256 before install. The model catalog adds verified Qwen2 models.
- The Ollama-compatible model server takes Ollama's own Host and Origin stance: loopback, plus app, file, tauri and vscode-webview origins.

### RoachNet Cluster

- One model split across several Macs: each runs a range of layers, paired with a code (Settings › Models › RoachNet Cluster), with links authenticated by the pairing key and encrypted, Bonjour discovery, shard transfer checked by SHA-256 and resumable, and fallback when a Mac drops out. `/api/cluster` reports and changes it.

### Agents, plans and tracing

- Bring your own agents: Claude Code, Codex, Gemini CLI, OpenCode and Cursor CLI join an Org and work with its other agents through issues, comments, @mentions and sub-issues, running your own signed-in CLI.
- Claude and ChatGPT plans as models (`claude:…`, `codex:…`) in RoachClaw chat, for Org agents and on the OpenAI and Ollama APIs, through your own Claude Code or Codex CLI. Off until turned on in Settings › RoachClaw › Subscriptions.
- RoachTrace traces every Org run, chat and model call (tokens with cache reuse, cost, latency, time to first token, speed, scores), scrubs secrets, keeps traces owner-only on disk, and can export to Langfuse or an OpenTelemetry collector. Org › Traces and Settings › RoachClaw › Tracing.

### Org

- RoachClaw Org, a native multi-agent company runtime: agents with roles and budgets propose hires and spend, and nothing happens until you approve it.
- The Org pane on the Mac: create a company, see the month's spend against its budget, pause and resume agents, answer approvals, and invite a paired phone as viewer, operator or admin with a one-use link that expires in 72 hours.
- `roachnet://` links no longer open duplicate windows.

### Feature packs

- RoachNet installs a small core and treats the rest as packs (`org.roachnet.pack.v1` manifests, a registry and a transactional installer). Panes mount only when their pack is enabled. Disabling or removing a pack unloads it; removing keeps its data unless you choose to move the data to a Retired folder.
- Settings › Packs lists what each pack is, what it touches and what an uninstall would leave behind.
- Speech models are installable resource packs instead of always-bundled payloads. The pack catalog comes live from apps.roachnet.org, and store items open with a `pack` install link.

### Themes

- A theme engine drives every color, font, radius, shadow, glass layer and background in the app and in RoachNet Setup.
- 31 built-in themes, 13 snippets, and an editor in Settings › Appearance with import, export and a watched themes folder. Every built-in theme is tested for readable text in each mode it ships. Signal dark matches the 1.0 look exactly.
- Theme packs install from RoachNet Apps. The iOS companion follows the Mac's theme (`GET /api/companion/theme`).
- Animated and dithered backgrounds stop under Reduce Motion.

### Maps, library and downloads

- The Maps pane draws the PMTiles packs you install with a dependency-free PMTiles v3 and vector-tile reader: pan, pinch, zoom, fit, GPS fix and route, labels with collision culling, OpenStreetMap and Protomaps credit. Install Base also queues the World Atlas.
- Map, Kiwix and Wikipedia collections come live from apps.roachnet.org (HTTPS only, 4 MB cap, schema-checked, owner-only cache, refreshed every 6 hours; `GET /api/collections`). The bundled lists match the 2026-10 storefront.
- Downloads resume after a stall instead of failing at ten minutes: a 90-second stall timer, up to six attempts with Range resume, and partial files kept across network failures. App updates still fail and clean up rather than resume.
- Download descriptors are only followed under the Apps downloads base.

### Security

- When `ROACHNET_API_TOKEN` is set, the loopback API needs that token or a scoped RoachClaw API token on every route except `GET /api/health` and Org requests carrying a member key. RoachNet.app sets a fresh token per launch and sends it only to its own runtime. Settings › RoachClaw lists, creates and revokes RoachClaw API tokens.
- Webhook secrets are stored as salted HMAC-SHA256 digests.
- RoachClaw state, RoachTail state and the runtime's server-info file are written readable by your account only, created that way before they are moved into place.
- RoachTail peer tokens are compared in constant time and stop working after 90 days unused (`ROACHTAIL_PEER_IDLE_DAYS`, `0` turns it off). Linked Devices can remove one phone.
- The 1.0.7 Host, Origin and body checks apply to every loopback service here too.

### Fixes

- Light themes get a proper shade token, sheets get scrims, and metric cards, button rows and filter chips no longer clip or overflow.
- Byte counts read "0 KB" instead of "Zero KB".
- The JS runner's legacy provider-secret lookup follows the Swift rules on macOS volumes.
- `smoke:macos-install-lanes` takes `ROACHNET_SMOKE_WORK_ROOT` (from 1.0.7).

## v1.0.7 - 2026-10-11

Security and content patch for 1.0.6, gated by hand on the release Mac (see `docs/release-gates/1.0.7-mac-gate-results.md`). Ad-hoc signed, not Apple-notarized.

### Security

- The runtime and setup service no longer treat any `Host` starting with `127.` as loopback: `127.<domain>` names could be rebound to 127.0.0.1 and used to read and drive the local API. Only `localhost`, `::1` and dotted-quad 127/8 addresses pass.
- Every loopback service (Swift runtime, Swift setup, and the JavaScript setup/API fallbacks) refuses a cross-site `Origin` (and `null`) and non-JSON bodies (`scripts/lib/roachnet_loopback_guard.mjs`).
- Download descriptors are only followed under `ROACHNET_APPS_DOWNLOADS_BASE_URL` (https://apps.roachnet.org/downloads).
- Non-Error throws return a generic message; the release workflow's privileged jobs use no npm cache and check out `github.sha`.

### Changes

- Bundled Kiwix and Wikipedia collections synced with apps.roachnet.org: titles re-pinned to what the library serves (124 dead downloads in 1.0.6), 20 withdrawn titles hidden from the installers, 10 new titles.
- Bundled Ollama 0.40.3 (checksum-verified; same file list as 0.40.2).
- Store items with the 1.1 `pack` install action (RoachSpeech feature packs) are declined with "needs RoachNet 1.1" by the app and the companion install route instead of "unsupported action".
- CI: the mid-upgrade setup test uses its own hosts file, and RoachNetApp/RoachNetSetup build with `-parse-as-library` on every toolchain.
- `smoke:macos-install-lanes` takes `ROACHNET_SMOKE_WORK_ROOT`, so a gate run from an external drive can install to the internal disk (a fresh ad-hoc build launched from a removable volume waits on the macOS removable-volume prompt).

## v1.0.6 - 2026-10-10

Published from the hand-gated Apple Silicon candidate (see `docs/release-gates/1.0.6-mac-gate-results.md`). Ad-hoc signed, not Apple-notarized.

### Security (pre-publication review, `docs/release-gates/1.0.6-security-review.md`)

- The update lane requires the release's `.sha256` sidecar, verifies the downloaded installer and discards a mismatch; assets must be https.
- Malformed HTTP body framing can no longer crash the runtime before authentication.
- The loopback API and setup service reject non-loopback `Host` headers and non-JSON bodies.
- RoachTail join codes pair once and retire after five wrong guesses; peer ids are server-generated; token compare is constant-time.
- Paired phones can only queue downloads from public hosts; download descriptors are capped.
- Installer config, RoachTail state and provider keys are written owner-only; the companion token stays out of the Ollama child environment; the privileged hosts-file alias validates the hostname.
- Release evidence queries OSV with a working purl, records reviewed Ollama advisories, and no longer lists a Node runtime that is not shipped. Every workflow action is SHA-pinned and docker publishing exact-matches the authorized actor.

### Changes since v1.0.5

- Replaced the bundled Node runtime with `roachnet-runtime`, a native Swift helper built only on Apple system frameworks. It serves the same loopback API and environment contract, runs the iOS companion bridge in-process, and the default packaging lane now refuses to embed Node.
- Rebuilt RoachNet Setup on the native helper. Installs check the hardware and OS first, stage beside the target, smoke-test the staged runtime before swapping it in, preserve storage across upgrades, and roll back cleanly on failure.
- Added `roachnet-runtime --install` for headless and Homebrew installs, plus `--provision-alias` for the RoachTail hostname.
- Fixed the install toggle for RoachClaw. The no-RoachClaw lane now skips the contained Ollama runner instead of installing it anyway.
- Bumped the reviewed bundled Ollama pin to 0.40.2.
- Expanded the native RoachClaw surface with local playbooks, service health, jobs, reports, memory, backups, scoped tools, provider routes, and agent-run summaries.
- Added a native RoachTail control-plane state with expiring join codes, peer-scoped tokens, approved routes, relay metadata, and stored token hashes instead of reusable plaintext peer tokens.
- Coalesced duplicate Ollama reachability and model-list probes during concurrent status refreshes and invalidated stale model state after failed or ambiguous pulls.
- Made every macOS `TimelineView` honor Reduce Motion, including changes made while affected views remain open.
- Removed the stale v1.0.5 launch-guide label and added a neutral fallback brand mark for missing packaged icon assets.
- Prepared the v1.0.6 / build 106 source candidate without moving or reusing the published v1.0.5 tag.
- Replaced semantic-release and direct asset clobbering with one protected draft-stage and exact-byte promotion path that fails closed on Apple signing/notary prerequisites.
- Removed the vulnerable legacy `admin/` WebUI from the public candidate while preserving its v1.0.5 provenance outside the candidate.
- Added [draft candidate notes](docs/releases/1.0.6.md) and the [artifact-bound publication matrix](docs/releases/1.0.6-publication-matrix.md). Apple-host product, signing, packaging, and publication gates remain unrun.

## v1.0.5 - 2026-05-18

### Native shell and installer

- Rebuilt RoachNet around the Apple Silicon native macOS shell, keeping Electron/WebUI out of the shipping lane and moving the product toward one contained desktop app instead of a stack of web windows wearing a trench coat.
- Polished the main app frame, command bar, About RoachNet panel, Settings/Updates lane, in-app guide, and long-scroll surfaces so content stops hiding behind chrome and the app behaves like a real consumer desktop product.
- Cut the native app bundle down to about `404M` and the setup app to about `540M` by keeping heavy speech/model packs optional instead of stapling every possible brick to the installer.
- Verified the setup app overwrite flow and the Homebrew lane against the rebuilt DMG on Apple Silicon. Still unsigned until RoachWares has a Developer ID, but the bits install and boot locally.

### RoachClaw, RoachSpeech, and command bar

- Added the RoachNet-owned native RoachClaw agent spine with local context budgeting, RoachBrain memory/wiki support, and Hermes-inspired planning without shipping Hermes as an upstream runtime dependency.
- Added native RoachSpeech model-pack support with Core ML pack validation, local install APIs, bundled RoachWhisper/Kokoro packs, and an optional Chatterbox voice-cloning pack for users who want the heavier voice lane.
- Reworked the Raycast-style command bar around `Ctrl-Cmd-R`, in-app/global command launching, RoachClaw prompts, guide/about/settings routing, and tighter copy that says what it does without writing a novel on the button.

### Vault, RoachArcade, Dev, and Maps

- Expanded Vault with drag/drop import, reader/player/preview upgrades, book metadata search scaffolding, safer destination handling, and transcript/lyrics sidecar planning for media in the vault.
- Expanded RoachArcade with ES-DE import, ROM metadata handling, emulator/player scaffolding, mod/cheat metadata, Vortex manifest import tests, and Windows-runner readiness checks.
- Reworked Dev into a larger IDE-style workbench with explorer, editor, terminal transcript, inline RoachClaw assist, project context, and less dead copy taking up room that should belong to tools.
- Added native Maps/GPS support paths, curated pack metadata, phone GPS packet parsing, stale/live fix labeling, and offline map-source profiles.

### Public release rails

- Moved public release surfaces to the RoachWares organization lanes, updated Blacksmith-backed CI, Convex metadata wiring, Homebrew cask metadata, SideStore feed metadata, wiki/API/docs, and RoachNet.org v1.0.5/v0.1.5 install pages.
- Added first-party RoachVoice/RoachWhisper model packs and stack bundles to the RoachNet Apps catalog so optional heavy lanes can be installed into RoachNet instead of bloating the base app.
- Rebuilt the RoachNetiOS v0.1.5 unsigned IPA with refreshed Apps, Runtime, Vault, and RoachClaw surfaces plus updated SideStore/AltStore install metadata.

## v1.0 - 2026-04-04

### Contained installer and clean-machine runtime

- Reworked `RoachNet Setup` around a truly contained install lane so a fresh macOS install now stages RoachNet inside the chosen install root, smoke-tests the runtime before finalization, and removes the staged tree automatically on failure.
- Stopped the setup flow from trying to bootstrap global Homebrew/npm dependencies during the default bundled install path, keeping RoachNet from spraying files across `/opt/homebrew` or other host-managed locations.
- Canonicalized the native app target back into the RoachNet install root so stale installer state can no longer drag the install toward external app paths or other legacy locations.
- Rewrote the finalized environment files against the promoted install root so the installed runtime no longer points back at deleted staging paths for SQLite, OpenClaw, storage, or the local tools lane.

### Runtime stability

- Enabled the containerless SQLite / in-memory queue boot path in the backend config and job lane so clean installs can boot without a live MySQL or Redis dependency.
- Rebuilt the compiled admin runtime against the contained database changes so the packaged app now reaches health from the installed tree instead of falling into the stale MySQL path from older build output.
- Verified a clean temp install can finish setup, boot the installed runtime, answer `/api/health`, and bring RoachClaw online after the brief OpenClaw gateway warm-up.

### Website refresh

- Refined the public site polish pass with the updated support links, darker screenshot framing, and the current `v1.0` download/version language across `roachnet.org` and `apps.roachnet.org`.
- Kept the RoachNet support path intact while updating the RoachNet support CTA to the direct PayPal payment link.

## v1.4 - 2026-04-03

### Dev Studio and command bar

- Expanded the native `Dev` lane with richer project bootstraps, grouped secret templates, inline code suggestions, contextual shell commands, and one-tap insertion of RoachClaw responses back into the active document.
- Added a detached global command bar on `Ctrl-Cmd-R` so RoachNet can surface a compact launcher panel over the desktop without pulling the full shell forward when the app is not active.

### Apps catalog and install handoff

- Rebuilt the public Apps catalog around install-ready map regions, per-course education downloads, Wikipedia bundles, and RoachClaw model packs backed by the same manifest lane the native app can consume.
- Wired the website install actions to the packaged `roachnet://install-content` handoff path so clicking `Install to RoachNet` can open the native shell and queue the selected content in the correct module instead of dropping the user into a raw download list.

### Website polish

- Refined the `roachnet.org` copy around the local-first command-center story, aligned `apps.roachnet.org` to the same tone, and updated the download surfaces to the `v1.4` release.
- Added a consistent white matte behind every website screen capture so the native screenshots read as one cohesive gallery instead of a mixed set of transparent and dark-edge assets.

### Release plumbing

- Updated package and installer versioning to the `1.4.x` line while keeping the existing native build and GitHub Actions packaging flow intact.
- Kept the Apple signing/notarization bootstrap script in place so the repository can still be wired for a future Gatekeeper-safe notarized release once those secrets are present in GitHub Actions.

## v1.30.8 - 2026-04-02

### Setup app hotfix

- Bundled an official self-contained Node.js 22 runtime into both native macOS app bundles so `RoachNet Setup.app` and the main `RoachNet.app` no longer rely on a preinstalled host Node runtime to boot on a clean Apple Silicon Mac.
- Reworked packaged repository lookup so installed app bundles prefer their own embedded `RoachNetSource` tree instead of accidentally binding to whatever local checkout happened to match the current shell environment.
- Trimmed duplicate setup-time container runtime probing and added short command timeouts so the first installer state checks come back faster and stop feeling hung on launch.
- Updated the setup shell to unlock the flow as soon as the local setup service is live instead of forcing the user to wait for a full machine scan before the app becomes responsive.
- Fixed a native setup-app startup deadlock in packaged builds by replacing the broad process-table scan that could block the main thread before the bundled installer backend ever launched.
- Disabled saved-window restoration for `RoachNet Setup.app` so stale AppKit restore state can no longer beachball the installer on reopen instead of starting a fresh setup session.
- Finished the clean-machine packaged install path by teaching the bundled admin image to reuse the embedded prebuilt runtime, switching container startup to `node bin/console.js`, and verifying the packaged setup app can install RoachNet end to end on an Apple Silicon Mac with no prior RoachNet prerequisites.

## v1.30.7 - 2026-04-02

### Installer and first-launch hardening

- Fixed the native setup app so the primary action responds reliably, the default action is keyboard-wired, and stale embedded backend helpers are torn down before a new setup pass starts.
- Reworked the bundled `RoachNet Fix.command` helper so quarantine stripping no longer sprays `xattr` errors across missing unpacked dependency paths on macOS.
- Tightened the setup copy so the installer now explicitly explains that RoachNet stages its own runtime prerequisites instead of presuming the machine was already prepared.
- Added bundled-repository resolution to the managed native runtime so packaged installs can boot from the embedded source tree instead of timing out against the wrong root.

### Runtime stability and contained services

- Hardened contained runtime startup around per-install compose project names so one RoachNet bundle no longer collides with another machine-local runtime state path.
- Split managed-service startup into blocking core lanes and non-blocking secondary AI lanes so MySQL and Redis can gate first boot without making Ollama or Qdrant hold the whole app hostage.
- Added competing-project shutdown and listener cleanup for the managed runtime so quitting or stopping the app is more likely to clear the ports it claimed on the host.
- Extended the setup backend to mark required dependencies against the active install mode so RoachNet can pull what the local install still needs instead of relying on a lucky preinstalled toolchain.

### Brand polish and website screens

- Removed the square-backed RoachNet mark treatment in favor of the transparent logo itself, with a stronger glow treatment across the native shell, admin web surfaces, and the public site.
- Added the new RoachClaw logo asset, kept it monochrome and size-matched in inactive navigation states, and surfaced the full-color mark when the RoachClaw pane is active.
- Replaced the website’s native screen gallery with new compact captures from the real 1.30.7 packaged shell and setup app.

## v1.30.6 - 2026-04-02

### Native developer surfaces

- Added a native `Dev` workspace to the macOS shell with a contained project browser, in-app code editor, Ghostty-style shell lane, RoachClaw assist, and workspace-aware project creation inside the RoachNet vault.
- Added Keychain-backed secret records for developer and cloud-lane credentials so RoachNet can keep metadata in the vault while keeping actual secret values off disk.
- Extended the shared native design system and shell polish so the `Home`, `Dev`, and `RoachClaw` panes feel like one product instead of separate utility views.

### Runtime and first-boot stability

- Moved the contained runtime away from hardcoded compose credentials by generating local-only managed runtime secrets at launch and interpolating them into the runtime environment.
- Added compatibility and repair logic for existing managed MySQL state so upgraded installs can keep booting instead of getting stuck on stale database credentials.
- Verified the contained RoachClaw path still comes up on the local endpoints, keeps the default local model aligned to the contained lane, and leaves cloud fallback available for fast first boot.
- Expanded the native and fallback settings surfaces for `AI Control` and `Model Store` so the revived local-model and cloud-lane story stays visible even when the old web shell is not present.

### Website and app-store surfaces

- Refreshed `roachnet.org` to tell the 1.30.6 story: contained dev surfaces, native coding workspace, and the updated App Store/catalog direction.
- Replaced the website’s screen gallery with fresh captures from the real 1.30.6 native shell, including the new `Dev` pane.
- Updated the website-backed App Store catalog to reflect mirror-backed maps, archives, RoachClaw model packs, and future developer toolchain downloads served from the same backend.

## v1.30.5 - 2026-04-01

### Native macOS shell, setup, and onboarding

- Reworked the shared macOS design system with calmer graphite surfaces, stronger visual hierarchy, better button treatments, and more polished dashboard cards so the native shell reads like a consumer-ready app instead of a loose internal tool.
- Redesigned the setup app into a two-column onboarding shell with a persistent install rail on the left and focused step content on the right.
- Upgraded the main RoachNet shell chrome with a stronger brand card, clearer workspace navigation, richer home hero tags, and cleaner command-grid cards.
- Restored the native panes for `Suite`, `Maps`, `Education`, `Archives`, `Vault`, and `Runtime` so the macOS app is once again the primary product surface instead of a reduced summary shell.
- Moved more of the shared AI setup path into the native runtime controls so RoachClaw, Ollama, OpenClaw, and workspace configuration stay aligned during first boot.

### Launch and installer flow

- Removed the crash-prone embedded AVKit startup guide path and moved guided video playback into a dedicated AppKit window so first launch no longer dies inside SwiftUI AVKit metadata setup.
- Added a bundled `RoachNet Fix.command` helper to the setup DMG that copies `RoachNet Setup.app` into `/Applications`, clears quarantine on the copied app, and opens it without disabling Gatekeeper globally.
- Cleared quarantine metadata during the setup install flow itself so copied app bundles are less likely to get blocked again when the setup app stages the main RoachNet desktop app.
- Raised the native runtime startup window so cold boots of the local backend do not get treated as failed launches while the managed services are still coming online.

### Runtime, RoachClaw, and contained services

- Hardened the contained native runtime so first boot now prefers RoachNet-managed Ollama and OpenClaw endpoints, keeps the local model lane aligned to the contained stack, and surfaces real RoachClaw readiness instead of timing out through onboarding.
- Moved the RoachClaw onboarding flow away from blocking OpenClaw CLI reconciliation so the first local prompt can succeed as soon as the contained runtime is actually ready.
- Improved native quit and stop behavior so the helper services RoachNet starts for the managed runtime can be torn down cleanly instead of leaving listeners behind on the host.
- Fixed the local AI lane so RoachNet no longer forces `think` mode on every Ollama request, keeps default local model selection biased toward the RoachClaw path, and preserves cloud-backed fallback for the fastest first-boot path.
- Verified fresh content downloads can be queued, written to disk, and cleaned up successfully through the managed download APIs.

### Website, mirrors, and app store backend

- Replaced the public website’s mock SVG screens with real native RoachNet captures from the current macOS shell and setup flow.
- Added client-side local-time status to `roachnet.org` plus an honest browser-storage estimate in place of fake disk telemetry.
- Added the first RoachNet App Store/catalog surface on `roachnet.org`, published mirrored collection manifests under `/collections`, and wired the native runtime toward the website-backed manifest base URL so the app and site can share one catalog backend.

### Packaging, CI, and release plumbing

- Fixed the native macOS packager so it includes the first-launch guide video in `RoachNet.app`, stages the setup assets correctly, and avoids hanging on slow recursive deletes while rebuilding large bundles on APFS volumes.
- Reworked the `Native Packages` workflow around the real macOS build path, removed the stale Linux/Windows matrix, and documented the Apple signing/notarization secrets needed for Gatekeeper-safe release artifacts.
- Added a repo-native Apple release secret bootstrapper at `scripts/configure-apple-release-secrets.sh` plus an `npm run release:apple-secrets` wrapper so signing credentials can be loaded into GitHub in one repeatable step.

## v1.30.3 - 2026-03-25

- Prior release. See GitHub Releases for earlier release notes.
