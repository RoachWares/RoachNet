# RoachNet Development Guide

Last verified: 2026-08-23

This is the contributor guide for the native RoachNet desktop and runtime lane.
It separates the public native product from the retained legacy admin/WebUI so
contributors do not accidentally build or release the wrong application.

## Source of truth

Repository root:

```text
/Volumes/MediaSSD/DEVPROJECTS/RoachNet
```

Current shipping lane:

- `native/macos/` — Swift 6 package for macOS 14 and later.
- `native/macos/Sources/RoachNetApp/` — desktop application.
- `native/macos/Sources/RoachNetSetup/` — native setup application.
- `native/macos/Sources/RoachNetCore/` — shared runtime and domain behavior.
- `native/macos/Sources/RoachNetDesign/` — shared native design system.
- `scripts/run-roachnet-native-api.mjs` — dependency-free, loopback-only API
  bridge used by the native app.
- `scripts/run-roachnet-setup.mjs` — setup backend.
- `scripts/build-native-macos-apps.mjs` — app, setup, archive, signing, and DMG
  packaging automation.
- `scripts/tests/` — Node API/runtime and packaging regression tests.
- `docs/release-gates/` — release-state records and dependency drift inputs.

Reference-only lanes:

- Legacy `admin/` — excluded from the post-v1.0.5 public candidate because its
  retained lock had high/critical vulnerabilities. Tag `v1.0.5` preserves the
  last tracked public tree for migration research.
- `desktop/` — legacy Electron desktop reference.
- `installer/` — legacy Electron setup reference.

Do not add shipping entrypoints, package scripts, installer payloads, or release
gates that boot a reference-only lane unless the native ownership decision is
explicitly reversed.

The public website and Apps storefront are maintained separately in
`/Volumes/MediaSSD/DEVPROJECTS/roachnet-org`.

## Requirements

### Native source and API work

- macOS 14 or later for native application execution.
- Apple Silicon for release packaging.
- Xcode with Swift 6 support and command-line tools.
- Node.js `>=26 <27`; `.nvmrc` contains `26`.
- npm `>=10`.
- Network access for dependency installation and release audits.
- Sufficient free disk space for embedded runtimes, model packs, caches, apps,
  archives, and the DMG.

Use native arm64 Node on Apple Silicon. The release builder rejects a non-arm64
host by default; `ROACHNET_REQUIRE_APPLE_SILICON_NATIVE=0` is for local
Intel/Rosetta diagnostics, not public release artifacts.

### Linux or non-macOS verification

Node tests, TypeScript checks, dependency audit, upstream drift checks, and
several native-source audits run without Xcode. Linux cannot validate the Swift
build, Core ML, `ditto` archive behavior, signing, app launch, iOS compatibility,
or DMG/notarization gates.

### Historical legacy admin/WebUI work only

The removed `admin/` lane had a separate toolchain:

- Node.js `>=24 <25`
- MySQL
- Redis
- an uncommitted `admin/.env`

Use `docs/LOCAL_BOOT.md` with tag `v1.0.5` only when migration research requires
that historical lane. Do not restore it to the public candidate.

## First setup

From a clean clone:

```bash
cd /Volumes/MediaSSD/DEVPROJECTS/RoachNet
nvm use
node --version
npm --version
npm ci
```

Expected Node major: `26`.

`npm ci` installs only the root development dependencies. The native API itself
uses Node built-ins and starts without the legacy `admin/node_modules` tree.

Do not create or commit production secrets. Root `.env`, `admin/.env`, runtime
storage, and local caches are ignored. If a feature requires credentials, use
the existing secret/configuration lane rather than adding a checked-in value.

## Run the native API bridge

For a predictable local URL and no browser launch:

```bash
PORT=8080 ROACHNET_NO_BROWSER=1 npm start
```

Verify from another terminal:

```bash
curl --fail --silent http://127.0.0.1:8080/api/health
```

Without `PORT`, the bridge requests an available ephemeral port and records its
runtime information under the configured storage root. The API refuses
non-loopback `HOST` values. Do not weaken that boundary for convenience.

Defaults:

- storage: `~/RoachNet/storage`
- runtime state: `~/RoachNet/storage/.runtime`
- logs: `~/RoachNet/storage/logs`
- RoachTail state: `~/RoachNet/storage/vault/roachtail/state.json`
- managed Ollama endpoint: `http://127.0.0.1:36434`
- managed OpenClaw endpoint: `http://127.0.0.1:13001`

Override storage for isolated development or tests:

```bash
ROACHNET_STORAGE_PATH="$(mktemp -d)" \
PORT=8080 \
ROACHNET_NO_BROWSER=1 \
npm start
```

Stop with `Ctrl-C`. The launcher also accepts a direct stop command:

```bash
node scripts/run-roachnet-native-api.mjs --stop
```

Never treat a preserved legacy `admin/storage/` directory outside this candidate
as disposable fixture data.

## Build and test matrix

### Fast cross-platform gate

Run after Node/API/script changes:

```bash
npm test
npm run convex:typecheck
npm run audit:upstreams
node scripts/audit-native-parity.mjs
node scripts/smoke-test-command-bar-lane.mjs
npm audit --audit-level=high
```

What these cover:

- Node API/runtime behavior and regressions.
- Convex TypeScript validity.
- pinned upstream release drift.
- native-versus-reference surface ownership.
- command-bar integration.
- known high-severity dependency vulnerabilities.

The upstream audit is intentionally live and may fail when a pinned dependency
has moved. Review the upstream release; do not refresh the record blindly.

### Native macOS build and unit tests

On a Mac with Xcode selected:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
npm run native:build
npm run native:test
```

Equivalent direct commands are:

```bash
xcrun swift build --package-path native/macos
xcrun swift test --package-path native/macos
```

### Native distribution build

On native Apple Silicon:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROACHNET_CANDIDATE_BUILD=1 npm run native:dist
```

Primary output directory:

```text
native/macos/dist/
```

The build can download and cache embedded Node/Ollama payloads, build native
apps, create source/runtime archives, sign code, and build the DMG. It can be
large and network-dependent. Do not delete a prior release artifact until its
version, checksum, and publication provenance are recorded.

Useful controlled build flags:

- `ROACHNET_SKIP_DMG=1` — skip DMG creation for a local diagnostic build.
- `ROACHNET_SKIP_ROACHSPEECH_PACK_ARCHIVES=1` — skip optional speech archive
  production.
- `ROACHNET_ROACHSPEECH_BUNDLE_PROFILE=baseline` — default public bundle
  profile.
- `ROACHNET_CODESIGN_IDENTITY` — Developer ID identity when available.
- `ROACHNET_NOTARY_PROFILE` and `ROACHNET_NOTARY_KEYCHAIN` — notarization
  configuration.

`ROACHNET_CANDIDATE_BUILD=1` is the credential-independent Gate C build path:
it requires the reviewed Node/Ollama runtime URLs and SHA-256 values in
`docs/release-gates/runtime-freshness.json`, but uses only the existing ad-hoc
local signing behavior and never produces notarization evidence. It is not a
public-release switch. `ROACHNET_RELEASE_BUILD=1` remains the staging-only
fail-closed mode and requires Developer ID signing, notarization, and DMG
creation.

Never put signing credentials, notary secrets, or keychain data in Git.

### Aggregate release gate

After a native distribution build and with an approved local speech fixture:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export ROACHNET_WHISPER_PARITY_AUDIO=/absolute/path/to/local-whisper-fixture.wav
npm run smoke:release-gates
```

The aggregate runs, in order:

1. public release-surface audit;
2. native release-scope audit;
3. RoachSpeech Core ML smoke;
4. native parity audit;
5. bundled runtime freshness audit;
6. upstream stable-release audit;
7. macOS setup and Homebrew install-lane smoke;
8. command-bar smoke;
9. desktop/iOS companion compatibility smoke.

A Linux failure at a missing Apple tool is an environment limitation, not a
pass. Re-run the complete gate on the target Mac before release.

## Release verification

A release candidate needs more than a successful build:

1. Confirm a clean, intentional Git diff; preserve unrelated dirty work.
2. Run the cross-platform gate and `git diff --check`.
3. Run Swift build/tests and the aggregate release gate on Apple Silicon.
4. Verify app/setup bundle versions match `package.json`.
5. Verify bundle architecture, embedded runtime portability, and checksums.
6. Verify code signatures with `codesign --verify --deep --strict`.
7. If credentials exist, verify hardened runtime and notarization/stapling.
8. Perform fresh-install and overwrite-install walkthroughs.
9. Launch the installed app and verify one desktop process, one API process,
   expected companion behavior, and `/api/health`.
10. Exercise first launch, Home, command bar, RoachClaw, Dev, Arcade, Maps,
    Vault, Runtime, Settings, update flow, errors, and offline behavior.
11. Rebuild and verify the iOS companion after contract changes.
12. Update release notes, Homebrew cask, SideStore feed, website, API docs,
    screenshots, wiki, and public checksums only from final artifacts.

`docs/release-gates/v1.0.5-launch-readiness.md` is a historical working board,
not proof that a newly built artifact passed today. Record current command
output and artifact checksums for every candidate.

## Git and workspace safety

The shared DEVPROJECTS root contains multiple repositories and non-repository
projects. Before changing this repository:

```bash
git status --short --branch
git worktree list
git remote -v
```

Current known constraints at this guide's verification date:

- `main` has preserved uncommitted and untracked work.
- local `main` is two commits behind `origin/main`.
- a detached prunable worktree exists outside DEVPROJECTS.
- the shared pre-candidate tree retains private legacy admin/runtime work that is
  deliberately excluded from the public candidate.

Do not use reset, clean, broad stash, rebase, merge, or worktree pruning as a
setup shortcut. First classify and preserve the existing work. A fresh clone or
isolated worktree is safer for clean-release reproduction after the current
state has been reconciled.

## Data, privacy, and security boundaries

- The native API must remain loopback-only.
- User storage defaults to `~/RoachNet/storage`; it must not be bundled into
  release artifacts.
- legacy admin/runtime storage remains outside this candidate and is excluded
  from public source archives.
- Peer tokens and join codes are sensitive; RoachTail stores token hashes, not
  reusable plaintext tokens.
- External AI providers and cloud services must remain explicit opt-ins.
- Logs must not contain tokens, secrets, private paths beyond what diagnostics
  require, or imported user content.
- Imports, downloads, subprocesses, URL handling, and archive extraction are
  trust boundaries. Keep size, timeout, path, and checksum validation intact.
- Keep credentials in the configured secret store or environment, never source.

## Change conventions

- Keep changes focused; do not combine formatting, dependency upgrades,
  architecture changes, and feature work without a real dependency.
- Add a behavior-level regression test for bug fixes when feasible.
- Preserve native ownership. Reference code may inform parity but should not
  become a second shipping architecture.
- Prefer local-first behavior and user-controlled storage.
- Avoid new dependencies unless the platform or repository cannot do the job.
- Use Conventional Commits: `<type>(<scope>): <description>`.
- For user-facing changes, update the `Unreleased` section in `CHANGELOG.md` and
  note why the behavior changed.
- Report exact verification commands, platform, skips, and failures. Never call
  an unrun macOS gate passed from Linux output.

## Troubleshooting

### Wrong Node major

```bash
nvm install 26
nvm use 26
npm ci
```

The root lane requires Node 26. The legacy admin lane requires Node 24; do not
reuse one `node_modules` tree across them.

### Native commands cannot find Xcode

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift --version
```

If `xcrun`, Swift, `ditto`, `codesign`, or Xcode are unavailable, move the native
verification to a target macOS worker rather than weakening the gate.

### Port is already in use

Choose another explicit loopback port:

```bash
PORT=8081 ROACHNET_NO_BROWSER=1 npm start
```

### Runtime uses unexpected data

Set an isolated `ROACHNET_STORAGE_PATH` before launch. Do not delete the default
storage until its ownership and backup are known.

### Upstream audit fails

Read `docs/release-gates/dependency-drift.md`, inspect the actual upstream
release, then update the stable-reference record only if the change is reviewed
and accepted.

## Related documentation

- `README.md` — product overview and install lanes.
- `docs/LOCAL_BOOT.md` — legacy admin/WebUI environment.
- `docs/SURFACE_MAP.md` — product surface and integration seams.
- `docs/NATIVE_REWRITE_PLAN.md` — native ownership plan.
- `docs/ROACHSPEECH_RUNTIME.md` — native speech architecture.
- `docs/roachnet-secrets-architecture.md` — secrets boundary.
- `docs/release-gates/dependency-drift.md` — upstream drift procedure.
- `docs/release-gates/public-release-checklist.md` — authoritative public-release
  go/no-go contract, evidence requirements, and candidate sign-off template.
- `docs/release-gates/v1.0.5-launch-readiness.md` — historical v1.0.5 launch
  board and known signing limitation.
- `../WORKSPACE.md` and `../DEVPROJECTS.yml` — estate map and move rules.
