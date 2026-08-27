# RoachNet Public Release Checklist

Last verified: 2026-08-23
Owner: release coordinator
Shipping lane: native Apple Silicon macOS application and setup DMG

This is the authoritative go/no-go contract for a RoachNet public release. The
older `v1.0.5-launch-readiness.md` records a historical release train; it is not
proof that a new candidate passed.

## Release decision

Use the staged decision sequence below:

- `GO-TO-STAGE` — every pre-publication P0/P1 gate is `PASS`. The immutable
  candidate may be uploaded to a draft/quarantined release that is not reachable
  through stable download, update, Homebrew, website, or feed routes.
- `GO-LIVE` — the staged bytes were downloaded and verified, every P0/P1 gate is
  `PASS`, and the release coordinator authorizes serialized stable-channel
  promotion without changing bytes.
- `GO` — the staged artifact was promoted without changing bytes, stable routes
  were switched as one controlled operation, and immediate public smoke checks
  passed.
- `NO-GO` — any P0 or P1 gate is failed, skipped, stale, unverified, or lacks
  evidence.
- `PRE-RELEASE ONLY` — engineering checks pass but a deliberately labeled beta,
  RC, or unsigned diagnostic build still has a public-stable blocker. It must not
  replace the stable channel or be described as public release-ready.

The only valid evidence states are `PASS`, `FAIL`, `NOT RUN`, and `N/A`. `N/A`
requires a frozen-scope reason and release-owner approval before testing begins;
`NOT RUN` is never a pass. No verbal waiver turns a missing P0/P1 result into
`PASS`. A waiver can only move
an item to P2/P3 after the release owner documents the user impact, mitigation,
expiry, and follow-up issue before candidate testing begins.

Any code, dependency, signing, package, installer, or bundled-asset change after
a gate passes invalidates the affected evidence. Rebuild the artifact and rerun
all downstream gates. The candidate identity is its commit SHA plus artifact
SHA-256, not its filename.

## Current readiness snapshot

This snapshot is informational. Re-run every candidate gate for the final commit.

| Area | Current state | Evidence or blocker |
| --- | --- | --- |
| Workspace | PARTIAL | The 28-entry workspace manifest is complete, but no physical cleanup/migration has occurred because dirty repositories, persistent data, and hardcoded paths are protected. |
| Repository hygiene | READY FOR SOURCE FREEZE | The v1.0.6 candidate is isolated on `release/v1.0.6-candidate` from current `origin/main`; included/excluded local work and the untouched dirty shared tree are recorded in `v1.0.6-source-candidate-preservation.md`. |
| Lint/static checks | PARTIAL | Convex typecheck and native/public-surface audits pass. There is no single explicit project-wide lint gate for the native lane. |
| Build | FAIL | No fresh Apple Silicon release build has been produced from the current changes. |
| Tests | PARTIAL | On Linux: 56 tests, 53 passed, 0 failed, 3 explicit macOS-only skips. Swift, archive, Core ML, signing, install, and iOS gates remain unrun for this candidate. |
| Prior unfinished work | RECONCILED FOR SOURCE CANDIDATE | Intended local work is on the isolated candidate; excluded admin and machine-local work remains preserved with hashes. The dirty shared tree remains untouched. |
| Architecture | READY WITH VALIDATION | Native ownership, loopback API, local storage, and reference-lane quarantine audits pass; the built app still needs on-device validation. |
| Core functionality | NEEDS WORK | Automated Node behavior is green; fresh-install, upgrade, app-launch, offline, failure, and primary workflow outcomes are not current. |
| UI | NEEDS WORK | Latest SwiftUI changes have not been built or visually inspected on macOS. |
| Design system | NEEDS WORK | Source changes exist in shared hotspot files and require integrated native visual verification. |
| UX | NEEDS WORK | No current clean-account end-to-end walkthrough exists. |
| Copy | NEEDS WORK | The release notes have no current `Unreleased` section for the new work and public metadata is inconsistent. |
| Performance | NEEDS WORK | Probe coalescing tests pass, but launch, responsiveness, memory, and long-run behavior are not measured on target hardware. |
| Privacy/local-first | READY WITH VALIDATION | Loopback and source-surface audits pass; the final bundle and network behavior still require inspection. |
| Security | PARTIAL | Root `npm audit --audit-level=high` reports zero vulnerabilities and vulnerable `admin/` is removed from the public candidate. Apple signing/notarization and final mounted-artifact supply-chain evidence remain unresolved. |
| Persistence | NEEDS WORK | Upgrade, overwrite-install, rollback, and user-data preservation need current artifact testing. |
| Distribution | BLOCKED ON APPLE GATES | Candidate source metadata is `1.0.6` / build `106`; no tag is reused. No signed/notarized exact public artifact or synchronized channel metadata exists yet. |
| Overall | NOT READY | Apple-host gates, signed/notarized packaging, E2E validation, finalized release notes, and channel publication remain blocking. |

Linux verification run on 2026-08-23:

- Node `v26.5.1`; npm `11.17.0`.
- `npm test`: 53 passed, 0 failed, 3 macOS-only skips.
- `npm run convex:typecheck`: passed.
- `npm audit --audit-level=high`: zero vulnerabilities.
- `npm run audit:upstreams`: passed for 8 stable references.
- public release-surface, native release-scope, native parity, command-bar,
  and `git diff --check` gates: passed.

These checks do not substitute for the macOS gates.

## Required fixes before a public stable release

| Priority | Required outcome | Pass criterion | Current state |
| --- | --- | --- | --- |
| P0 | Create a clean, intentional candidate commit. | A fresh clone or isolated clean worktree at the candidate SHA has `git status --porcelain` empty; every intended dirty-tree change is committed or deliberately excluded with preservation evidence; the candidate includes or consciously supersedes the upstream commits. | PASS at source handoff; rerun clean-clone proof from handed-off SHA |
| P0 | Use a new version and tag. | `package.json`, package lock, app/setup `CFBundleShortVersionString`, build number, release notes, tag, DMG metadata, and update feeds agree on a version greater than the already-published `v1.0.5`. The tag resolves to the tested SHA. | PARTIAL: source is 1.0.6/build 106; tag and artifact proof remain NOT RUN |
| P0 | Close every release-path bypass. | Inventory `release.yml`, `native-packages.yml`, semantic-release, and every tag/asset uploader. Exact actor authorization, protected environment approval, a concurrency lock, candidate-tag-to-tested-SHA proof, and all engineering/native/package/signing gates are mandatory. No alternate workflow can create/promote/clobber a stable release around them. | PASS in source/static audit; hosted environment policy still requires verification |
| P0 | Make public-release CI fail closed. | A release-tag run fails when Developer ID or notary credentials are absent; it cannot upload an unsigned stable asset. Native tests, the aggregate post-build gate, signature checks, notarization, stapling, checksum verification, and release-copy finalization run before draft staging. | PASS in source/static audit; Apple-host execution remains NOT RUN |
| P0 | Produce the candidate on native Apple Silicon. | The build runs on supported Apple Silicon macOS with Xcode/Swift 6, Node 26, npm 10+, and the public RoachSpeech fixture. The complete command log is attached to the candidate record with no unexplained skip. | NOT RUN |
| P0 | Sign, harden, notarize, and staple the public artifact. | All nested code and both app bundles validate with Developer ID; hardened runtime and timestamp are present; Apple notarization is accepted; stapler validation and Gatekeeper assessment pass for the DMG/install result. | BLOCKED/NOT RUN |
| P0 | Prove fresh-install and upgrade safety. | Fresh install and overwrite/upgrade from the latest stable release succeed on clean macOS accounts; user storage survives; no duplicate app/API process remains; `/api/health` becomes healthy; uninstall/rollback instructions are tested. | NOT RUN |
| P0 | Reconcile public checksums. | The downloaded asset digest, `.sha256` sidecar, GitHub release body, Homebrew cask, website/API metadata, and any update feed all contain the same hash and byte size. The published v1.0.5 body must also be corrected: it currently names `587b…`, while the live DMG and checksum sidecar report `332057…`. | FAIL |
| P0 | Verify the exact staged artifact. | After draft/quarantined upload, download the stored asset through the release platform, recompute SHA-256, re-run signature/notary checks, mount/install it, and complete the launch smoke. The bytes must match the candidate; local pre-upload files alone do not pass. Unauthenticated public-route verification occurs immediately after `GO-LIVE` promotion. | NOT RUN |
| P0 | Make publication staged and reversible. | Candidate assets are first uploaded immutably to a draft/quarantined release, verified there, then promoted without `--clobber` or byte replacement. Stable channels switch under a serialized release transaction with a recorded rollback plan, owner, trigger, and target recovery time. | FAIL |
| P1 | Finish current release notes and support copy. | Notes describe user-visible changes, security/privacy changes, system requirements, install/upgrade/rollback, known limitations, and support/reporting links in direct RoachNet voice. No stale checksum or already-published version is reused. | FAIL |
| P1 | Resolve retained legacy-admin source risk. | If `admin/` remains in the public tag, its Node 24 lockfile audit has zero high/critical findings and its non-shipping status is unmistakable. Otherwise remove it from the public source surface without losing private preservation/provenance. | PASS in v1.0.6 candidate: removed with v1.0.5 tree and dirty local-work hashes preserved |
| P1 | Prove final-artifact supply-chain health. | Generate an SBOM and binary/license inventory from the mounted/installed artifact, covering bundled OpenClaw packages, Node, Ollama, model/runtime assets, and native dependencies. Every binary/package is versioned, source-pinned, licensed for distribution, checksum-verified, and scanned for candidate-bound vulnerabilities. | NOT RUN |
| P1 | Complete target-device product-quality review. | Keyboard, VoiceOver, focus, contrast, Reduce Motion, narrow/wide window layouts, long content, first launch, errors, and offline behavior pass on the built candidate. | NOT RUN |
| P1 | Measure performance on target hardware. | Candidate hardware and measurements are recorded for cold launch, time-to-healthy, workflow responsiveness, memory, and a 30-minute soak. No unexplained regression versus the approved baseline and no unbounded growth/hang occurs. | NOT RUN |
| P1 | Validate public routing and discovery. | Product, install, release, checksum, Homebrew, SideStore/iOS (if included), privacy, support, and API URLs return the intended public content; redirects, canonical metadata, version text, screenshots, and download links all point to the candidate. | NOT RUN |
| P1 | Close independent hostile review. | A reviewer independent from the implementation checks security, accessibility, responsive behavior, routing/SEO, performance, dependency health, packaging, and outcome-based tests. Every release-blocking finding is fixed and re-reviewed. | PARTIAL; prior focused reviews do not cover the final artifact |

## Candidate identity and evidence record

Create one candidate record under `docs/release-gates/candidates/` before voting
`GO`. Use a filename such as `<version>-<short-sha>.md`. It must contain:

```text
Version:
Build number:
Tag:
Commit SHA:
Frozen scope manifest SHA-256:
Shipping components/channels:
Approved N/A items and reasons:
Release-capable workflows inventoried:
Source tree clean: PASS/FAIL
macOS version and hardware:
Xcode and Swift versions:
Node and npm versions:
Build workflow/run URL:
Release-test workflow/run URL:
DMG filename:
DMG byte size:
DMG SHA-256:
Checksum sidecar asserted DMG SHA-256:
Checksum sidecar file SHA-256:
SBOM/binary/license inventory:
Developer ID team/identity label (no secrets):
Notarization submission ID and Accepted result:
Stapler validation: PASS/FAIL
Gatekeeper assessment: PASS/FAIL
Fresh-install test: PASS/FAIL
Upgrade/overwrite test: PASS/FAIL
Rollback test: PASS/FAIL
Accessibility/visual review: PASS/FAIL
Performance/soak review: PASS/FAIL
Public-link post-publish check: PASS/FAIL
Known limitations:
Open P2/P3 issues:
Independent reviewer:
Release coordinator:
Pre-publication decision: GO-TO-STAGE/NO-GO/PRE-RELEASE ONLY
Quarantined exact-asset verification: PASS/FAIL
Promotion decision: GO-LIVE/NO-GO
Final decision: GO/NO-GO
```

Attach or link complete logs. Redact credentials, tokens, usernames, private paths,
and user content. A summary saying “green” is not evidence.

Before running gates, freeze a scope manifest in the candidate record. It must
name every shipping app, helper, runtime, model/asset class, public source lane,
distribution channel, website/feed, companion target, release workflow, supported
OS/hardware configuration, accessibility configuration/window dimension, numeric
performance budget, rollback target time, and approved exclusion. Changing scope
invalidates the affected evidence and requires a new manifest digest.

Copy every checklist item into an evidence matrix and give it a stable ID in
section order (`A-01`, `A-02`, …, `I-01`). Each row must contain:

```text
Gate ID:
Requirement:
Applicability: REQUIRED/N/A
Result: PASS/FAIL/NOT RUN/N/A
Candidate commit SHA:
Artifact SHA-256 (when applicable):
Executor/reviewer:
UTC timestamp:
Environment/device:
Command or test case:
Immutable log, screenshot, AX snapshot, recording, or workflow URL:
Notes/approved N/A reason:
```

## Gate A — source freeze and provenance

- [ ] `PASS` Candidate version is greater than the current stable tag.
- [ ] `PASS` Candidate tag and release branch policy are explicit; no tag is moved
      or reused.
- [ ] `PASS` Candidate SHA includes every intended change and no accidental local
      artifact.
- [ ] `PASS` `git status --porcelain` is empty in the release checkout.
- [ ] `PASS` `git diff --check` passes before commit and on the candidate SHA.
- [ ] `PASS` `package-lock.json` was generated from the committed manifest and
      `npm ci` succeeds in a clean checkout.
- [ ] `PASS` public release-surface and native release-scope audits pass on the
      committed tree.
- [ ] `PASS` imported-source license, attribution, and `docs/UPSTREAM.md` are
      present and accurate.
- [ ] `PASS` generated assets are reproducible or their exact source/provenance is
      recorded.
- [ ] `PASS` every release-capable workflow and script is listed in the frozen
      scope; only one protected, serialized promotion path can create a stable tag
      or expose assets.
- [ ] `PASS` release actor authorization uses exact identity membership and a
      protected environment approval, never substring matching.
- [ ] `PASS` the workflow checkout SHA, candidate commit, tag target, release
      notes, package manifest, package lock, and uploaded artifact provenance all
      resolve to the same candidate before promotion.
- [ ] `PASS` third-party GitHub Actions used by release workflows are pinned to
      reviewed immutable commit SHAs; release tokens and workflow permissions are
      least-privilege.
- [ ] `PASS` no `.env`, private key, credentials, runtime storage, indexed user
      content, local database, private path, or machine-specific secret is tracked
      or bundled.

Fail this gate for a dirty checkout, reused tag/version, unexplained generated
asset, source/lock drift, secret exposure, or missing provenance.

## Gate B — cross-platform engineering checks

Run from the clean candidate checkout with Node 26:

```bash
npm ci
npm test
npm run convex:typecheck
npm run audit:upstreams
node scripts/audit-public-release-surface.mjs
node scripts/audit-native-release-scope.mjs
node scripts/audit-native-parity.mjs
node scripts/smoke-test-command-bar-lane.mjs
npm audit --audit-level=high
git diff --check
```

Pass only if every command exits zero. The three archive-install tests may skip on
non-macOS hosts, but they must run and pass in Gate C. A live upstream audit drift
requires review of the upstream release; never refresh the record blindly.

If `admin/` ships in the public source tag, also run its dependency audit with its
documented Node 24 toolchain. A missing or irreproducible legacy toolchain is not
a pass.

## Gate C — native Apple build and aggregate validation

Run on supported native Apple Silicon with Xcode selected:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
npm ci
node scripts/prepare-roachspeech-release-packs.mjs
npm run native:build
npm run native:test
ROACHNET_CANDIDATE_BUILD=1 npm run native:dist
export ROACHNET_IOS_REPO=/absolute/path/to/RoachNet-iOS
export ROACHNET_IOS_EXPECTED_SHA=$(git -C "$ROACHNET_IOS_REPO" rev-parse HEAD)
export ROACHNET_WHISPER_PARITY_AUDIO=/absolute/path/to/approved-local-fixture.wav
ROACHNET_CANDIDATE_BUILD=1 npm run smoke:release-gates
```

`ROACHNET_CANDIDATE_BUILD=1` is the credential-independent Gate C path. It
uses the candidate's reviewed Node and Ollama URLs and SHA-256 pins, retains
the Apple-Silicon host requirement, and may only ad-hoc sign locally. It does
not submit, staple, or claim notarization/Gate D evidence. Public staging must
continue to use `ROACHNET_RELEASE_BUILD=1`, which requires Developer ID,
notarization, and DMG creation.

Pass only if:

- [ ] Swift release build and all native unit tests pass.
- [ ] All Node tests discovered by the candidate run on macOS with zero
      release-relevant skip. The candidate count must not fall below the current
      53-test baseline unless a reviewed change explains every removed test.
- [ ] Public surface and native scope audits pass against built payloads.
- [ ] Core ML speech smoke and approved local parity fixture pass.
- [ ] Native parity and bundled runtime freshness pass.
- [ ] All 8 pinned upstream stable references pass.
- [ ] Setup and Homebrew install-lane smokes pass.
- [ ] Command-bar smoke passes.
- [ ] Desktop/iOS companion compatibility passes when the companion is in scope.
- [ ] Built app and setup bundle versions, identifiers, minimum OS, architecture,
      privacy descriptions, icon, runtime payloads, and checksums match the
      candidate record.

A missing Apple tool, fixture, credential, model pack, or compatible host is
`NOT RUN`, not `PASS`.

## Gate D — signing, notarization, integrity, and package contents

Public stable policy: unsigned or ad-hoc-signed artifacts are not `GO`.

Required checks against the final DMG and installed app include:

```bash
codesign --verify --deep --strict --verbose=2 "RoachNet.app"
codesign -dv --verbose=4 "RoachNet.app"
codesign -d --entitlements :- "RoachNet.app"
codesign --verify --deep --strict --verbose=2 "RoachNet Setup.app"
codesign -dv --verbose=4 "RoachNet Setup.app"
codesign -d --entitlements :- "RoachNet Setup.app"
xcrun stapler validate "RoachNet-Setup-macOS.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "RoachNet-Setup-macOS.dmg"
shasum -a 256 "RoachNet-Setup-macOS.dmg"
```

- [ ] Developer ID Application identity and expected Team ID are present.
- [ ] Hardened runtime and secure timestamp are present.
- [ ] Entitlements match an approved allowlist, and the App Sandbox policy is
      explicit. If RoachNet ships outside the sandbox because it manages local
      files/processes, the release record explains that boundary and verifies
      least-privilege behavior; no unexpected entitlement is present.
- [ ] Notarization result is `Accepted`; submission ID is recorded.
- [ ] Stapler validation and Gatekeeper assessment pass offline after download.
- [ ] DMG mounts read-only and contains only intended setup/install material.
- [ ] App, setup app, nested executables, embedded Node/Ollama payloads, model
      packs, source archive, and archive manifests are signed or covered as
      intended and contain no local data.
- [ ] SHA-256 and byte size are recorded before publication and independently
      reproduced after public download.

## Gate E — outcome-based installation and product tests

Test the artifact, not a developer checkout.

Fresh-install matrix:

- [ ] Clean supported macOS account, no Homebrew dependency.
- [ ] Default install path.
- [ ] Low/free-disk preflight and understandable failure.
- [ ] Denied/missing permissions and recovery.
- [ ] Offline first launch with local-only surfaces usable.
- [ ] Network-enabled setup and optional model hydration.

Upgrade/overwrite matrix:

- [ ] Latest stable release to candidate.
- [ ] Existing models, Vault content, settings, RoachTail state, and logs remain
      owned by the user and are not silently deleted.
- [ ] Failed/cancelled upgrade leaves a launchable prior install or a documented
      recovery path.
- [ ] Reinstall does not duplicate services or corrupt runtime state.

Primary workflow matrix:

- [ ] First launch and guide.
- [ ] Home and navigation.
- [ ] Command bar and keyboard commands.
- [ ] RoachClaw local model status, model pull success/failure, and stale-cache
      recovery.
- [ ] RoachSpeech input/output and missing-pack recovery.
- [ ] Dev, RoachArcade, Maps/GPS, Vault, Runtime, Settings, and About.
- [ ] Search/import/download cancellation and corrupt/oversized input handling.
- [ ] Update check, unavailable update service, and rollback path.
- [ ] One desktop app process and one API process after launch/relaunch.
- [ ] `/api/health` becomes healthy and the listener remains loopback-only.
- [ ] Quit stops owned processes without killing unrelated user processes.

Fail for data loss, duplicate persistent processes, non-loopback exposure, broken
core navigation, unrecoverable first launch, installer dead-end, or a crash/hang.

## Gate F — accessibility, responsive layout, visual quality, and performance

Accessibility and responsive behavior:

The frozen scope must state exact minimum/default/maximum window dimensions,
macOS text/contrast settings, VoiceOver and Reduce Motion states, and the primary
keyboard workflows. Evidence must identify each case and include an automated UI
result, AX snapshot, screenshot, or recording tied to the candidate. Normal text
must meet at least 4.5:1 contrast and large text/UI graphics at least 3:1 unless a
documented native-platform exception applies.

Unless the candidate intentionally changes its declared window contract before
scope freeze, test the main app at `760x580`, `1360x860`, and `1600x1000`; setup
at `760x580`, `980x740`, and `1440x900`; and Settings at `760x560`, `900x680`,
and `1040x800`. Run each primary workflow with VoiceOver on, Reduce Motion on,
Increase Contrast on, Differentiate Without Color on, and increased text size as
separate named cases; test the default state as the control.

- [ ] Complete primary workflows by keyboard only; focus is visible and ordered.
- [ ] VoiceOver names, roles, values, errors, progress, and reading order are
      meaningful on every primary screen and setup step.
- [ ] Reduce Motion changes take effect while views remain mounted; no timeline or
      decorative animation continues when disabled.
- [ ] Text and controls remain legible with increased text size and required
      contrast.
- [ ] Narrowest supported, default, and wide windows show no clipped controls,
      hidden content, overlapping bars, or inaccessible scrolling.
- [ ] Long labels, errors, model names, paths, and localization-like expansion do
      not break layout.

Performance record:

Before the first candidate run, freeze numeric pass budgets for cold-launch
median/worst time, API time-to-healthy, each named interaction, warm/soak RSS,
idle/active CPU, network retry count, log growth, DMG/installed size, required
free disk, and fresh/upgrade install duration. Each budget must name the test Mac
and comparison baseline. A missing budget, exceeded budget, or threshold chosen
after seeing candidate results is `FAIL`.

Default budgets, measured against the latest stable artifact on the same Mac,
are: candidate medians no worse than 110% of stable for cold launch,
time-to-healthy, and named interactions; candidate worst runs no worse than 125%
of stable; warm RSS growth no more than 10% during the 30-minute soak; constant
owned-process count; median idle CPU no more than 5% of one core; candidate log
growth no more than 10 MiB during the soak; and DMG/installed footprint no more
than 115% of stable. Any different budget must be justified and approved in the
frozen scope before candidate measurements begin.

- [ ] Record target Mac model, RAM, storage state, OS, and power mode.
- [ ] Record cold launch to interactive and API time-to-healthy over at least five
      clean runs; report median and worst run.
- [ ] Record responsiveness for Home, command bar, model status, Vault search, and
      settings transitions.
- [ ] Run a 30-minute representative soak and record memory at start/end, CPU,
      network retries, log growth, and process count.
- [ ] Eight concurrent status refreshes still produce one Ollama version probe and
      one model-list probe.
- [ ] No unexplained regression versus the approved baseline, unbounded resource
      growth, retry storm, beachball, or user-visible stall.

The release owner must approve the baseline before the final run. Missing
measurements or an after-the-fact threshold is `NO-GO`.

## Gate G — security, privacy, and failure boundaries

- [ ] API binds only to loopback and rejects non-loopback `HOST` values.
- [ ] No listener, peer token, join code, credential, private path, or imported
      user content leaks into logs or diagnostics.
- [ ] Tokens are stored through the intended secret/hash lane; no plaintext token
      persists where only a hash is required.
- [ ] Downloads have HTTPS/source policy, timeout, redirect, byte limit, checksum,
      partial-file cleanup, and atomic install behavior.
- [ ] Imports and archives reject traversal, malformed manifests, oversize data,
      unsafe destinations, and unexpected executable payloads.
- [ ] Subprocesses do not use shell interpolation; executable and argument
      validation remains intact.
- [ ] External AI/cloud providers are explicit opt-ins and offline/local behavior
      remains understandable.
- [ ] Root and every shipped runtime dependency have zero known high/critical
      vulnerabilities, with dependency scan evidence tied to the candidate.
- [ ] An SBOM and mounted-artifact binary/license inventory cover Swift packages,
      root and bundled OpenClaw packages, Node, Ollama, model/runtime assets, and
      every redistributed binary. Sources, exact versions, licenses, checksums,
      and candidate-bound scan results are recorded; unlocked `npm install`
      output or an unverified latest-download binary is not releasable.
- [ ] GitHub security alerts, workflow permissions, release-token scope, artifact
      provenance, and dependency action versions receive independent review.
- [ ] Privacy descriptions match actual microphone, speech, Bluetooth, network,
      filesystem, and companion behavior.

## Gate H — release notes, packaging, and public channels

Release notes must include:

- version, date, supported hardware, minimum macOS, and installer format;
- concise user-visible changes and fixed defects;
- security/privacy changes without exposing exploit detail unnecessarily;
- install, upgrade, backup, rollback, and uninstall expectations;
- local-first/offline behavior and every external service that may be contacted;
- known limitations, affected users, workarounds, and follow-up links;
- checksum, signature/notarization status, support, issue-reporting, license, and
  attribution links;
- migration or data-format changes and whether downgrade is safe.

Packaging/channel consistency:

- [ ] The candidate is first uploaded to a draft/quarantined release whose assets
      are immutable and absent from stable download/update routes.
- [ ] Draft asset bytes pass download, checksum, signature, notarization, mount,
      install, and launch verification before any stable-channel promotion.
- [ ] Promotion never uses `--clobber`, tag mutation, or asset replacement; a
      byte change creates a new candidate and invalidates downstream evidence.
- [ ] GitHub release tag points to the tested SHA and is not mutable/reused.
- [ ] GitHub assets include the final DMG and matching checksum sidecar.
- [ ] Release body hash and size match the downloaded asset.
- [ ] Homebrew cask URL, version, SHA-256, architecture, and install path match.
- [ ] `roachnet.org`, Apps storefront/API, README, wiki, screenshots, update feed,
      and support pages use the same version and final artifact URLs.
- [ ] SideStore/iOS version, IPA, size, hash, screenshots, and desktop contract are
      updated and tested if included in this release.
- [ ] Optional RoachSpeech packs remain on the approved descriptor lane; each
      descriptor/part/final archive hash is verified and GitHub is not used for
      unintended large model assets.
- [ ] Product/install/release/checksum/privacy/support/API URLs return intended
      unauthenticated content with correct redirects, canonical metadata, titles,
      descriptions, social previews, and no stale version claims.
- [ ] `robots.txt`, sitemap, canonical URLs, and index/noindex directives expose
      the intended public pages without indexing staging, duplicate, or private
      routes; an internal-link crawl finds no broken release/install path.
- [ ] Public screenshots come from the final candidate.

## Gate I — launch, observation, and rollback

Before publish:

- [ ] Preserve the previous stable artifact, checksum, cask/feed metadata, and
      rollback instructions.
- [ ] Define release owner, stop authority, support channel, rollback trigger, and
      numeric rollback-time objective.
- [ ] Obtain `GO-TO-STAGE`, verify the quarantined candidate bytes, then obtain a
      separate `GO-LIVE` vote for serialized stable-channel promotion.
- [ ] Confirm no step can expose an unverified artifact and no concurrent release
      can interleave channel updates.

After publish, before announcing:

- [ ] Download and verify the unauthenticated public artifact.
- [ ] Install and launch that exact download on a clean account.
- [ ] Verify latest-release, direct-asset, Homebrew, website, API, and update-feed
      routes.
- [ ] Confirm version, checksum, signature, notarization, screenshots, and notes.
- [ ] Monitor download failures, installer/support reports, crash diagnostics,
      update failures, and broken links during the launch window.

Rollback if the public artifact has a checksum/signature mismatch, data loss,
non-loopback exposure, widespread install/launch failure, crash loop, broken
update path, or materially misleading release metadata. Restore the last known
good channel metadata, preserve the failed artifact/evidence privately for
forensics, and publish a direct status note.

## Allowed known limitations

These may remain only when release notes state the impact and workaround and the
release owner accepts them as P2/P3:

- macOS 14+ Apple Silicon is the only desktop target for this release; Windows
  and Linux desktop installers are not shipped.
- Legacy `admin/`, Electron desktop, and Electron installer lanes are reference
  material, not runtime dependencies of the native public product.
- Optional remote AI providers, cloud metadata, model downloads, maps, and public
  catalogs need network access; core local surfaces must fail clearly offline.
- iOS companion distribution may be a separately versioned companion release,
  but desktop/companion contract claims must match what was actually tested.
- Workspace migration and archive-candidate cleanup may remain deferred because
  they are not part of the installed app, provided no release path depends on
  stale absolute paths and all persistent data is protected.

## Blocking limitations

The following are never acceptable as public-stable “known limitations”:

- unsigned, ad-hoc-signed, unnotarized, or unstapled stable DMG;
- stale/reused version or tag;
- dirty/unreproducible candidate source;
- missing target-macOS build/test/install evidence;
- checksum disagreement across any public surface;
- known high/critical shipped dependency vulnerability;
- data loss, secret leakage, path traversal, non-loopback API exposure, or unsafe
  archive/download behavior;
- inaccessible primary workflows or layouts that hide required controls;
- release notes or public pages that materially misstate artifact identity,
  platform support, privacy, signing, or limitations.

## Final go/no-go sign-off

```text
Candidate version:
Candidate commit:
Candidate DMG SHA-256:
Frozen scope manifest: PASS / FAIL
Evidence matrix complete: PASS / FAIL
P0 gates: PASS / FAIL
P1 gates: PASS / FAIL
Independent hostile review: PASS / FAIL
Known limitations accepted and documented: YES / NO
Rollback tested: PASS / FAIL
Pre-publication decision: GO-TO-STAGE / NO-GO / PRE-RELEASE ONLY
Quarantined exact-asset verification: PASS / FAIL
Promotion decision: GO-LIVE / NO-GO
Public post-promotion verification: PASS / FAIL
Final decision: GO / NO-GO
Release coordinator:
Date:
```

A blank field is a failure. `GO` is valid only when every line above supports it.
