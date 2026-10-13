# Dependency Drift Gate

This gate is repo-grounded only. Current and locked versions must come from `package.json`, `package-lock.json`, and the pinned runtime metadata; do not fill target versions from memory or package-registry guesses.

## Native Shipping Scope

- Root package version: read it from `package.json`; it has no JavaScript entry point.
- Shipping runtime: `roachnet-runtime` (Swift, no third-party packages). RoachNet ships no Node (ROA-78).
- Script toolchain: Node `>=26 <27`, npm `>=10`; `.nvmrc` pins `26`.
- CI Node runtime: native/root setup-node workflows pin Node `26` for the scripts.
- Root runtime dependencies: none
- Root dev dependencies:
  - `convex` declared `^1.39.1`, locked `1.39.1`
  - `typescript` declared `^6.0.3`, locked `6.0.3`

The public native desktop lane must stay runnable through the first-party SwiftUI app, setup app, and `roachnet-runtime`. It must not require Node, Electron, the legacy WebUI runtime, `npm --prefix admin ci`, or staged admin `node_modules`.

## Legacy Admin Scope

The admin/WebUI tree remains historical reference material at tag `v1.0.5`; it
is not present in this public candidate or native runtime. Its high/critical
dependency findings cannot be waived into a public source tag.

## Retired JavaScript and Electron Lanes

The `desktop/` and `installer/` Electron trees, `setup-ui/`, the JavaScript runtime and setup backend, and the Docker install lane were removed in 1.1.1 (tag `v1.1.0` keeps them). Root package scripts and native packaging scripts must not bring back Electron, `electron-builder`, legacy WebUI boot, admin source fallback, or admin `node_modules` staging.

The `.app` bundles carry no `RoachNetSource` tree and no JavaScript at all; the builder and the release-scope audit fail a bundle that does.

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
