# RoachNet Development Guide

Last verified: 2026-10-13

This is the contributor guide for the native RoachNet desktop and runtime lane.

RoachNet ships Swift only. RoachNet.app, RoachNet Setup.app and
`roachnet-runtime` contain and launch no Node or JavaScript, and the builder
refuses a bundle that carries any. Node is the toolchain for the build, test
and release scripts in `scripts/`; none of it ships.

## Source of truth

Repository:

```text
https://github.com/RoachWares/RoachNet
```

Current shipping lane:

- `native/macos/` — Swift 6 package for macOS 14 and later.
- `native/macos/Sources/RoachNetApp/` — desktop application.
- `native/macos/Sources/RoachNetSetup/` — native setup application.
- `native/macos/Sources/RoachNetCore/` — shared runtime and domain behavior.
- `native/macos/Sources/RoachNetDesign/` — shared native design system.
- `native/macos/Sources/RoachNetRuntime/` and `RoachNetRuntimeHost/` —
  `roachnet-runtime`, the dependency-free, loopback-only runtime both apps run:
  the API, the setup service (`--setup`) and the RoachInference model server.
- `native/macos/Sources/RoachInference/` — the native GGUF inference engine.
- `scripts/build-native-macos-apps.mjs` — app, setup, archive, signing, and DMG
  packaging automation.
- `scripts/tests/` — contract tests that run against a built `roachnet-runtime`,
  plus packaging and release-audit tests.
- `docs/release-gates/` — release-state records and dependency drift inputs.

Reference-only lanes:

- Legacy `admin/` — excluded from the post-v1.0.5 public candidate because its
  retained lock had high/critical vulnerabilities. Tag `v1.0.5` preserves the
  last tracked public tree for migration research.
- The Electron desktop and setup shells (`desktop/`, `installer/`, `setup-ui/`),
  the JavaScript runtime (`scripts/run-roachnet*.mjs`, the companion server) and
  the Docker install lane (`install/`, `ops/`, `Dockerfile`) were removed in
  1.1.1 (ROA-78). Tag `v1.1.0` keeps them for reference.

Do not add shipping entrypoints, package scripts, installer payloads, or release
gates that boot a reference-only lane unless the native ownership decision is
explicitly reversed.

The public website and Apps storefront are maintained separately in the
[roachnet-org](https://github.com/RoachWares/roachnet-org) repository.

## Requirements

### Native source and API work

- macOS 14 or later for native application execution.
- Apple Silicon for release packaging.
- Xcode with Swift 6 support and command-line tools.
- Node.js `>=26 <27` and npm `>=10` for the scripts; `.nvmrc` contains `26`.
- Network access for dependency installation and release audits.
- Sufficient free disk space for model packs, caches, apps, archives, and the
  DMG.

Use native arm64 Node on Apple Silicon. The release builder rejects a non-arm64
host by default; `ROACHNET_REQUIRE_APPLE_SILICON_NATIVE=0` is for local
Intel/Rosetta diagnostics, not public release artifacts.

### Linux or non-macOS verification

Script tests, TypeScript checks, dependency audit, upstream drift checks, and
several native-source audits run without Xcode.

On Linux with Swift 6.4 (and `unzip`), the runtime targets build and their
XCTests run: RoachInference, RoachNetRuntime and `roachnet-runtime`.

```bash
swift build --package-path native/macos --build-tests
swift test --package-path native/macos --skip-build
```

The `Linux runtime` workflow runs the same two commands on every change to
those targets, in the official Swift image. RoachInference uses its CPU
backend there. The Cluster and RoachSpeech are compiled out. The workflow
then runs the runtime contract tests against the Linux build, with Node as
the test harness only:

```bash
ROACHNET_NATIVE_API_BINARY="$PWD/native/macos/.build/debug/roachnet-runtime" \
  node --test scripts/tests/*.test.mjs
```

`docs/LINUX_PARITY.md` has the current numbers and what each area still needs.

Linux cannot validate the macOS app targets, Core ML, `ditto` archive
behavior, signing, app launch, iOS compatibility, or DMG/notarization gates.
RoachNet for Linux ships only once the Linux app matches the Mac app (ROA-80).

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
cd RoachNet
nvm use
node --version
npm --version
npm ci
```

Expected Node major: `26`.

`npm ci` installs the development tools the scripts use (TypeScript and the
Convex CLI). RoachNet itself has no dependencies to install.

Do not create or commit production secrets. Root `.env`, `admin/.env`, runtime
storage, and local caches are ignored. If a feature requires credentials, use
the existing secret/configuration lane rather than adding a checked-in value.

## Run the runtime

Build `roachnet-runtime` and start it on a predictable local URL:

```bash
npm run runtime:build
PORT=8080 npm run runtime:start
```

Verify from another terminal:

```bash
curl --fail --silent http://127.0.0.1:8080/api/health
```

Without `PORT`, the runtime takes a free ephemeral port and records its
runtime information under the configured storage root. The API refuses
non-loopback `HOST` values. Do not weaken that boundary for convenience.

Defaults:

- storage: `~/RoachNet/storage`
- runtime state: `~/RoachNet/storage/.runtime`
- logs: `~/RoachNet/storage/logs`
- RoachTail state: `~/RoachNet/storage/vault/roachtail/state.json`
- RoachInference model server: `http://127.0.0.1:36434`
- OpenClaw compatibility probe: `http://127.0.0.1:13001` (an OpenClaw you run
  yourself; RoachNet never installs or starts one)

Override storage for isolated development or tests:

```bash
ROACHNET_STORAGE_PATH="$(mktemp -d)" \
PORT=8080 \
npm run runtime:start
```

Stop with `Ctrl-C`, or from another terminal (same storage root):

```bash
native/macos/.build/release/roachnet-runtime --stop
```

`roachnet-runtime --setup` serves the setup backend RoachNet Setup uses, and
`roachnet-runtime --help` lists the rest.

Never treat a preserved legacy `admin/storage/` directory outside this candidate
as disposable fixture data.

## Build and test matrix

### Fast cross-platform gate

Run after runtime or script changes:

```bash
npm run runtime:build
npm run test:native-runtime
npm run convex:typecheck
npm run audit:upstreams
node scripts/audit-native-parity.mjs
node scripts/smoke-test-command-bar-lane.mjs
npm audit --audit-level=high
```

What these cover:

- runtime contract behavior and regressions, against the built
  `roachnet-runtime` (plain `npm test` skips those without a build).
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

The build compiles both apps and `roachnet-runtime`, packs the RoachSpeech
archives, signs code, and builds the DMG. It downloads no runtime payloads and
fails if either bundle carries Node, JavaScript or RoachNet source. It can be
large and slow. Do not delete a prior release artifact until its
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
it holds the RoachSpeech packs to their recorded digests, but uses only the
existing ad-hoc
local signing behavior and never produces notarization evidence. It is not a
public-release switch. `ROACHNET_RELEASE_BUILD=1` remains the staging-only
fail-closed mode and requires Developer ID signing, notarization, and DMG
creation.

Never put signing credentials, notary secrets, or keychain data in Git.

### Aggregate release gate

After a native distribution build and with an approved local speech fixture, a clean
tracked iOS companion checkout, and its exact commit SHA:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export ROACHNET_WHISPER_PARITY_AUDIO=/absolute/path/to/local-whisper-fixture.wav
export ROACHNET_IOS_REPO=/absolute/path/to/RoachNet-iOS
export ROACHNET_IOS_EXPECTED_SHA=$(git -C "$ROACHNET_IOS_REPO" rev-parse HEAD)
npm run smoke:release-gates
```

`ROACHNET_IOS_REPO` defaults to the sibling `../RoachNet-iOS` checkout. In
`ROACHNET_CANDIDATE_BUILD=1` or `ROACHNET_RELEASE_BUILD=1`, the companion smoke
requires `ROACHNET_IOS_EXPECTED_SHA` to be the exact full 40-character SHA,
requires the tracked `RoachNetCompanion.xcodeproj/project.pbxproj`, and rejects
any dirty or mismatched companion checkout. A normal developer invocation without
that variable remains a diagnostic and may skip an absent sibling checkout; it is
not release evidence. The smoke never regenerates the Xcode project by default.
For intentional project-file maintenance only, run it explicitly with
`ROACHNET_REGENERATE_XCODEPROJ=1`; Ruby and the `xcodeproj` gem must already be
installed—the smoke does not install tooling or mutate project files implicitly.

The aggregate runs, in order:

1. public release-surface audit;
2. native release-scope audit;
3. RoachSpeech Core ML smoke;
4. native parity audit;
5. runtime freshness audit (no Node, Ollama runner or OpenClaw in the apps);
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
5. Verify bundle architecture, that `roachnet-runtime` links only system
   libraries, and checksums.
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

If this checkout shares a workspace folder with other repositories or has
work in progress, check its state before changing it:

```bash
git status --short --branch
git worktree list
git remote -v
```

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

The scripts require Node 26.

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
PORT=8081 npm run runtime:start
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
