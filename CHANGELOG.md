# Changelog

## Unreleased

- Added a repo-native Apple release secret bootstrapper at `scripts/configure-apple-release-secrets.sh` plus an `npm run release:apple-secrets` wrapper so Developer ID and notarization credentials can be loaded into GitHub with one repeatable command.
- Expanded the native macOS README with the exact environment variables and command sequence needed to wire the `Native Packages` workflow for a real Gatekeeper-safe notarized build.

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
