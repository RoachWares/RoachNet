# Changelog

## Unreleased

- Added a repo-native Apple release secret bootstrapper at `scripts/configure-apple-release-secrets.sh` plus an `npm run release:apple-secrets` wrapper so Developer ID and notarization credentials can be loaded into GitHub with one repeatable command.
- Expanded the native macOS README with the exact environment variables and command sequence needed to wire the `Native Packages` workflow for a real Gatekeeper-safe notarized build.

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
