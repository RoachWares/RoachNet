# Changelog

## v1.30.6 - 2026-03-30

### Native macOS and onboarding

- Fixed the native macOS packager so it always produces validly signed app bundles, includes the first-launch guide video in `RoachNet.app`, and rebuilds the setup DMG without hanging on unused runtime staging work.
- Extended the guided setup flow from basic service install into shared AI provider onboarding, including Ollama and OpenClaw endpoint staging, workspace control, and a clearer review step for RoachClaw defaults.
- Kept the guided tour assets aligned between the website and the native app so the shipped onboarding flow now has a real packaged video resource to play on first launch.

### Shared AI runtime control

- Moved more of the OpenClaw/Ollama setup path into the shared AI runtime surface instead of provider-specific assumptions.
- Fixed offline provider reporting so configured-but-unreachable runtimes still show the configured source and URL rather than collapsing into a generic `none` state.
- Kept RoachClaw status, workspace control, and ClawHub skill management aligned with the shared runtime layer and the updated `/easy-setup` flow.

### CI, packaging, and website

- Fixed the `Validate Collection URLs` workflow so large-file URLs no longer fail the job due to curl exit handling on ranged requests.
- Reworked the `Native Packages` workflow around the real macOS build path, removed the stale Linux/Windows matrix, and documented the Apple signing/notarization secrets needed for Gatekeeper-safe release artifacts.
- Refreshed the `roachnet.org` screen section to use current RoachNet views and kept the Netlify footer badge/contact footer in place for the public site.

## v1.30.5 - 2026-03-30

### Native macOS and setup

- Raised the native runtime startup window so the macOS app no longer gives up during legitimate cold boots of the local backend.
- Verified the bundled setup backend boots correctly from the packaged `RoachNet Setup.app` outside the development repository.
- Rebuilt the native macOS app and setup installer so the shipped bundle matches the latest runtime and command-grid surfaces.

### Runtime and downloads

- Raised the compiled-runtime startup timeout in `run-roachnet.mjs` so packaged launches no longer fall back prematurely.
- Kept the packaged admin runtime aligned with the now-working compiled backend path and current frontend assets.
- Verified a fresh ZIM content download can be queued, written to disk, and cleaned up successfully through the RoachNet download API.

### Website and release

- Refreshed the public installer payload served from `roachnet.org/downloads/RoachNet-Setup-macOS.dmg`.
- Kept the footer updates in place, including the Netlify hosting badge and contact email.
- Prepared the repository for a new GitHub release with matching version metadata and release notes.

## v1.30.4 - 2026-03-29

### Native macOS

- Reworked the native macOS app shell so the product surfaces are back in the app instead of hidden behind the reduced summary shell.
- Restored native panes for `Suite`, `Maps`, `Education`, `Archives`, `Vault`, and `Runtime`.
- Rebuilt the native macOS app and installer bundles with the current RoachNet icon and refreshed UI copy.

### RoachClaw and local AI

- Fixed the local AI lane so RoachNet no longer forces `think` mode on every Ollama chat request.
- Improved RoachClaw status so it can report a valid local-ready path even when the OpenClaw agent runtime is not yet reachable.
- Added explicit local-model prioritization so RoachNet prefers `qwen2.5-coder:7b`, then `qwen2.5-coder:14b`, before heavier or less suitable defaults.
- Filtered `:cloud` models out of the local default-model lane.
- Updated the native app bridge to send local prompts with `think: false` and a longer request timeout.
- Kept local Ollama chat usable even when OpenClaw is still catching up.

### Installer and setup

- Updated setup defaults so RoachClaw now prefers `qwen2.5-coder:7b` as the default local model.
- Improved setup and shell copy so the product voice is calmer and more human.
- Kept runtime orchestration and installer config aligned between the setup flow and the native app.

### Website and branding

- Refined the feature structure around `Command Deck`, `RoachClaw`, `Offline Maps & Vault`, and contained installs.
- Kept the public macOS installer download live from `roachnet.org`.

### GitHub and release prep

- Rewrote the repository README to match the product voice and structure used on `roachnet.org`.
- Added this changelog so GitHub releases can point to a detailed summary of what actually changed.

## v1.30.3 - 2026-03-25

- Prior release. See GitHub Releases for earlier release notes.
