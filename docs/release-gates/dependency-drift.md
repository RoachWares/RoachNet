# Dependency Drift Gate

This gate is repo-grounded only. Current and locked versions must come from `package.json`, `package-lock.json`, and the pinned runtime metadata; do not fill target versions from memory or package-registry guesses.

## Native Shipping Scope

- Root package version: `1.0.6` (build `106`)
- Root entrypoint: `scripts/run-roachnet-native-api.mjs`
- Root local engine: Node `>=26 <27`, npm `>=10`
- Local default Node: `.nvmrc` pins `26`; bundled runtime freshness is tracked separately in `runtime-freshness.json`
- CI Node runtime: native/root setup-node workflows pin Node `26`.
- Root runtime dependencies: none
- Root dev dependencies:
  - `convex` declared `^1.39.1`, locked `1.39.1`
  - `typescript` declared `^6.0.3`, locked `6.0.3`

The public native desktop lane must stay runnable through the first-party SwiftUI app, setup app, and dependency-free native API bridge. It must not require Electron, the legacy WebUI runtime, `npm --prefix admin ci`, or staged admin `node_modules`.

## Legacy Admin Scope

The admin/WebUI tree remains historical reference material at tag `v1.0.5`; it
is not present in this public candidate or native runtime. Its high/critical
dependency findings cannot be waived into a public source tag.

## Legacy Electron Quarantine

The `desktop/` and `installer/` Electron trees are retained as feature-parity references only. Their READMEs must say they are legacy reference material and not used by the native shipping lane. Root package scripts and native packaging scripts must continue to avoid Electron, `electron-builder`, legacy WebUI boot, admin source fallback, and admin `node_modules` staging.

The public setup payload must also stay clean. `RoachNetSource` inside the `.app` bundles may include the native API, setup backend, shared first-party helpers, collections, and setup UI. It must not include admin/WebUI source, Electron source, GitHub workflow state, local memory, legacy launchers, audit scripts, smoke scripts, tests, databases, ZIM payloads, or user-machine paths.

## Required Checks

- `npm ci`
- `npm audit --json`
- `node scripts/audit-release-configuration.mjs`
- `node scripts/audit-native-release-scope.mjs`
- `node scripts/audit-native-parity.mjs`
- `node scripts/audit-runtime-freshness.mjs`

The native release-scope audit enforces manifest/lockfile alignment, Blacksmith
runner labels, Node 26 workflow pins, admin-source exclusion, native packaging
guards, loopback defaults, and absence of machine-specific release text.

The upstream project audit enforces latest stable release metadata for the major projects RoachNet borrows patterns from: ES-DE, Ascendara, Hydra, Vortex, Owncast, and Hermes Agent. Moving default-branch commits are recorded as audit context, but stable release drift blocks a public build.
