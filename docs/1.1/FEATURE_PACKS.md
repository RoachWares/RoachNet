# RoachNet 1.1 — Feature packs and the minimal core

"Install only what you need. Expand whenever you want. Own everything."

This is the architecture the 1.1 modularization work implements. Everything in
the **Implemented** sections exists in the tree with tests; everything under
**Designed** is specified but not yet built. Nothing here is reported as done
until its tests run on macOS.

## 1. Where the bytes are (baseline, published 1.0.6)

Measured from the published `RoachNet-Setup-macOS.dmg` (v1.0.6, 394,438,768
bytes = 376 MiB):

| Component | Size | Share |
| --- | ---: | ---: |
| `RoachNetApp` binary | 22.8 MB | 6.1% |
| `roachnet-runtime` helper | 1.7 MB | 0.5% |
| Design bundle, icon, launch guide video | 2.5 MB | 0.7% |
| RoachSpeech Core ML packs inside the app (Whisper base.en 143.7 MB + Kokoro 86.4 MB) | 230.1 MB | 61% |
| Bundled Ollama (`bundled-ollama.tar.gz`, 161 MB compressed; ~480 MB unpacked, of which 327 MB are MLX metallibs) | 161 MB | 43% (compressed) |

The core — shell, runtime, design system — is about 27 MB. Everything else
is resources. 1.1 already retires the bundled Ollama (ROA-30); making the
speech packs optional takes the app archive from 257 MB to roughly 27 MB.

Launch-time and idle-memory baselines are measured with
`/tmp/rn-gate/measure-launch.sh` on the release Mac and recorded in
`docs/1.1/BASELINES.md` once the machine is quiet enough for the numbers to
mean something (the first attempt ran during a video call; load average 38).

## 2. Model

A **pack** is the unit RoachNet installs, enables, updates and removes. Two
kinds matter for 1.1:

- **Capability packs** are code. On macOS and iOS they are compiled into the
  app; the registry decides which of them *mount* (sidebar entry, panes,
  commands, runtime lanes, background work). Disabling one unloads its UI and
  stops its runtime lanes; it never deletes data. Separately downloadable code
  is deliberately **not** promised: on macOS it would need Developer
  ID-signed bundles with library validation (ROA-40 is the prerequisite), and
  on iOS downloadable executable code is not permitted. The manifest format
  already carries what a signed `.roachpack` bundle would need, so that lane
  can open later without a format change.
- **Resource packs** are files: inference models, speech packs, map
  collections, knowledge (ZIM) bundles, themes, animation and background
  packs. They are downloaded or installed from a local package, verified by
  SHA-256 and byte size, and swapped into place transactionally.

Capability packs shipped in 1.1 (`PackCatalog.bundledCapabilityPacks`):
`roachclaw`, `org` (needs roachclaw), `dev` (needs roachclaw), `vault`,
`arcade`, `maps`, `education`, `speech` (needs roachclaw), `companion`. Each
declares the capabilities it uses (`network.public`, `process.spawn`,
`microphone`, `bluetooth`, …) and the **data roots** it owns under the
storage root, so the Pack Manager can show what a pack touches and what an
uninstall would leave behind.

## 3. Manifest (`org.roachnet.pack.v1`) — implemented

```json
{
  "schema": "org.roachnet.pack.v1",
  "id": "roachvoice-kokoro-82m-int8-coreml",
  "version": "1.2.0",
  "kind": "resource",
  "name": "Kokoro voice (82M, int8)",
  "summary": "On-device text to speech.",
  "publisher": "RoachWares LLC",
  "requires": { "roachnet": "1.1.0", "platforms": ["macos"] },
  "dependencies": [{ "id": "speech", "minimumVersion": "1.1.0" }],
  "capabilities": ["speaker"],
  "resources": [
    { "path": "RoachVoice.zip", "url": "https://apps.roachnet.org/downloads/roachvoice-kokoro-82m-int8-coreml.zip",
      "sha256": "…64 hex…", "bytes": 80330811, "archive": "zip" }
  ],
  "dataRoots": [{ "path": "RoachSpeech/voices/kokoro", "description": "Voice settings and samples" }],
  "signature": { "algorithm": "ed25519", "publicKeyId": "roachwares-2026", "value": "…" }
}
```

Validation (`PackManifest.validate`) rejects: unknown schema, ids outside
`[a-z0-9][a-z0-9.-]{1,63}`, non-semantic versions, self or duplicate
dependencies, resource paths that escape the pack folder, missing or
malformed digests, zero byte sizes, non-https download URLs (loopback http is
allowed only for the contract tests), data roots that escape the storage root,
and resources on a capability pack. `signature` is carried but not yet
enforced (Designed: trusted-key list in the app, ed25519 over the canonical
manifest bytes; unsigned manifests are accepted only from the bundled catalog
and local packages the person chose).

## 4. Registry and lifecycle — implemented (runtime side)

`PackRegistry` (`native/macos/Sources/RoachNetRuntime/Packs/`):

- State lives in `<storage>/packs/state.json` (owner-only). A fresh install
  and an upgrade from 1.0.x both start with every bundled capability pack on,
  so nobody loses a feature they used.
- `enable(id)` checks compatibility (minimum RoachNet version, platform),
  resolves dependencies in order, turns dependencies on, then the pack.
  `disable(id)` refuses while an enabled pack depends on it and names the
  dependents. `resolveDependencies` reports missing packs, too-old versions
  and cycles.
- `uninstall(id, retainData:)` removes the pack's files, refuses while
  dependents are enabled, and **keeps the person's data roots by default**. With
  `retainData: false` the data roots are moved under `<storage>/packs/retired/`
  with a timestamp instead of being deleted, so a mistaken removal is
  recoverable until the person empties that folder. Capability packs cannot be
  uninstalled, only disabled.
- `PackInstaller` is transactional: every resource lands in
  `<storage>/packs/.staging/<id>-<version>-<rand>/`, is verified against size
  and SHA-256 (archives are extracted only after verification and checked for
  escaping paths), a receipt with per-file digests is written, and the folder
  is renamed into `installed/<id>/<version>/`. Only then is the state updated
  and the previous version removed. Any failure deletes the staging folder and
  leaves the previous version live. A process that dies mid-install leaves a
  staging folder that `sweepStaleStaging()` removes on the next runtime start.
- Offline install: `installLocalPackage(at:)` takes a folder with
  `manifest.json` and the resources; nothing is downloaded. Downloads use the
  same path with a fetch step and a progress job (`/api/packs` → `jobs`).

Routes (loopback API, owner only — the companion proxy does not forward them):
`GET /api/packs`, `GET /api/packs/<id>`, `POST /api/packs/install`
(`packagePath` | `manifestUrl` | `manifest`), `POST /api/packs/<id>/enable`,
`…/disable`, `…/uninstall` (`{"retainData": true|false}`).

Tests: `PackTests` (15 XCTests: manifest validation, semver, catalog
acyclicity, state persistence, dependency enable/disable rules, compatibility
gate, local install with receipt, tampered package rollback, atomic upgrade,
stale staging sweep, data retention and retirement, dependents block) and the
`feature packs` contract test in `scripts/tests/roachnet-native-api.test.mjs`
(HTTP catalog, refused disable, offline install, tampered refusal, uninstall
keeps data). Verified on macOS (M2 Pro, Xcode 27 / Swift 6.4, 2026-10-10):
`swift build` clean, `PackTests` 15/15, contract test passes against the
macOS-built `roachnet-runtime`; the same on Linux (Swift 6.1). The contract
test skips on the dependency-free Node reference lane (`npm test`) with the
repo's `needsBinary` convention — packs exist only in the Swift runtime.

## 5. App side — implemented (Mac)

`native/macos/Sources/RoachNetApp/FeaturePacks.swift`:

- `FeaturePackStore` reads `/api/packs` with every runtime refresh (the cheap
  form; `?sizes=1` only when the Pack Manager is open, because sizing walks
  every data root). `WorkspacePane.packID` maps panes to capability packs
  (Dev → `dev`, RoachClaw → `roachclaw`, Org → `org`, RoachArcade → `arcade`,
  Maps → `maps`, Vault → `vault`); Home and Runtime are core and always mount.
- The sidebar's `visiblePanes` is now "panes whose pack is on". Until the first
  read completes the store uses the set it remembered from the last launch
  (`roachnet.packs.disabled` in UserDefaults), so a switched-off pack never
  flashes into the sidebar at launch. A pane whose pack the runtime does not
  list is never hidden; a runtime without the registry (404) mounts everything.
- **Settings › Packs** (`FeaturePacksSettingsView`): counts and sizes, install
  jobs with progress, Features with toggles (disabled while an enabled pack
  depends on them, with the blocker named), capability tags in plain words
  ("Internet", "Runs programs", "Microphone"…), data roots with sizes, Resource
  packs with Remove → a confirmation that spells out the choice: keep the data
  (with its size) or move it to Retired; "Open Package…" installs a local pack
  folder offline through `/api/packs/install`.
- Tests: `FeaturePackTests` (5) cover mount-before-load, remembered disabled
  set across launches, unknown-pack safety, dependents blocking disable, size
  retention across cheap refreshes, schema rejection, capability labels.

Not yet done on the app side: runtime lanes (Org engine, companion bridge,
speech model loading) still start regardless of the pack state; pane stores
are still created in `WorkspaceModel.init`. Both wait for the launch/idle
baselines so the change can be measured rather than assumed.

## 6. Designed, not yet built

- **Lazy lanes and stores.** Runtime lanes start only when their pack is
  enabled; `RoachArcadeLibraryStore`, `RoachArchiveStore`, the speech
  controller, maps and dev stores are created on first mount instead of in
  `WorkspaceModel.init`. Measured against `BASELINES.md`.
- **Minimal core packaging.** `ROACHNET_ROACHSPEECH_BUNDLE_PROFILE=none` plus
  catalog manifests for the two speech packs on `apps.roachnet.org` so the
  speech pack installs on first use through the Pack Manager; the launch guide
  video stays (0.5 MB). Target: app archive ≈ 27 MB, DMG ≈ 35 MB, measured.
- **Catalog.** `collections/packs.json` lists the optional packs RoachWares
  publishes with their manifest URLs; the Pack Manager merges it with the
  bundled capability packs and installed resource packs, and shows download
  sizes before anything is fetched.
- **Signatures and trusted sources.** Trusted public keys ship in the app;
  catalog manifests must verify; local packages prompt.
- **Onboarding.** First run offers the pack list with sizes instead of
  installing everything.
- **iOS.** The companion reads the Mac's `/api/packs` to show what the Mac
  has; the phone itself installs only resource/config packs (themes, voice
  packs) under the same manifest rules — never code.
