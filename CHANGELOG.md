# Changelog

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
