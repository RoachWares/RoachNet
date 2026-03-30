# Changelog

## v1.30.4 - 2026-03-29

### Native macOS

- Reworked the native macOS app shell so the product surfaces are back in the app instead of hidden behind the reduced summary shell.
- Restored native panes for `Suite`, `Maps`, `Education`, `Archives`, `Vault`, and `Runtime`.
- Tightened the native macOS copy and hierarchy so the app and setup flow read more like the website and less like internal tooling.
- Rebuilt the native macOS app and installer bundles with the current RoachNet icon and refreshed UI copy.

### RoachClaw and local AI

- Fixed the local AI lane so RoachNet no longer forces `think` mode on every Ollama chat request.
- Improved RoachClaw status so it can report a valid local-ready path even when the OpenClaw agent runtime is not yet reachable.
- Added explicit local-model prioritization so RoachNet prefers `qwen2.5-coder:7b`, then `qwen2.5-coder:14b`, before heavier or less suitable defaults.
- Filtered `:cloud` models out of the local default-model lane.
- Updated the native app bridge to send local prompts with `think: false` and a longer request timeout.
- Kept local Ollama chat usable even when OpenClaw is still catching up.

### Installer and setup

- Continued the shift to a separate installer-first product flow where setup happens before the main app opens.
- Updated setup defaults so RoachClaw now prefers `qwen2.5-coder:7b` as the default local model.
- Improved setup and shell copy so the product voice is calmer and more human.
- Kept runtime orchestration and installer config aligned between the setup flow and the native app.

### Website and branding

- Restructured `roachnet.org` to sell the product first and push setup details lower on the page.
- Rewrote the landing-page copy in a friendlier, more human voice centered on local-first use rather than infrastructure.
- Refined the feature structure around `Command Deck`, `RoachClaw`, `Offline Maps & Vault`, and contained installs.
- Kept the public macOS installer download live from `roachnet.org`.

### GitHub and release prep

- Rewrote the repository README to match the product voice and structure used on `roachnet.org`.
- Added this changelog so GitHub releases can point to a detailed summary of what actually changed.

## v1.30.3 - 2026-03-25

- Prior release. See GitHub Releases for earlier release notes.
