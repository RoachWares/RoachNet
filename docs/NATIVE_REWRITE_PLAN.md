# RoachNet Native Rewrite Plan

RoachNet ships to end users through a native setup application first.

Product flow:

1. User downloads `RoachNet Setup`.
2. `RoachNet Setup` detects hardware, architecture, and prerequisite state.
3. `RoachNet Setup` detects the local runtime lane, installs the RoachNet application, prepares RoachClaw, and performs the first-run handoff.
4. The main `RoachNet` application becomes the only app the user uses after setup is complete.

The Electron shell is no longer a shipping target. The current product target is native Apple Silicon macOS first.

## Platform Targets

### macOS Apple Silicon

- UI shell: SwiftUI with AppKit where needed for window, menu-bar, drag-region, and system integration work.
- AI acceleration: MLX-first path for Apple Silicon, with Ollama still available as a compatibility/runtime option.
- Packaging: signed `.app` bundle and `.dmg`.
- Distribution target: direct download from the RoachNet site, with `RoachNet Setup.app` as the only initial download.

Reference:

- [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [MLX documentation](https://ml-explore.github.io/mlx/build/html/index.html)

### Future Windows 11 x64

- UI shell: WinUI 3 on the Windows App SDK.
- Runtime orchestration: native Windows service/process management instead of relying on the app shell to host setup.
- Packaging: signed installer or MSIX plus a standalone `RoachNet Setup.exe`.
- Target hardware: non-ARM 64-bit Windows 11 systems.

Reference:

- [WinUI 3 / Windows App SDK](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/)

### Future Linux

- UI shell: GTK4 + libadwaita for the native Linux desktop build.
- Distribution focus: Ubuntu and Bazzite-compatible packaging.
- Packaging targets:
  - Flatpak first for Bazzite and Fedora-atomic style environments.
  - `.deb` and/or AppImage for Ubuntu and other desktop installs.

Reference:

- [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/)
- [Flatpak documentation](https://docs.flatpak.org/en/latest/)

## Shared Product Architecture

The native UI shells should not own the AI/runtime logic directly. RoachNet should move toward:

- native platform UI shell per OS
- shared RoachNet runtime supervisor
- shared RoachClaw orchestration layer
- local IPC boundary between UI and runtime

Recommended split:

- `native/macos/`
  SwiftUI/AppKit shell and setup app for Apple Silicon macOS.
- `native/windows/`
  Future WinUI 3 shell for Windows 11 x64.
- `native/linux/`
  Future GTK4/libadwaita shell for Linux.
- shared runtime core
  Service/process/container orchestration, RoachClaw bootstrap, updater state, health probes, model routing, and knowledge/indexing APIs.

Current bridge:

- `scripts/run-roachnet-native-api.mjs`
  Dependency-free native API bridge used by the SwiftUI shell and installer smoke tests.
- It owns health, system info, local AI provider status, RoachClaw model calls, companion payloads, service catalog state, map manifests, Kiwix/Wikipedia manifests, downloads, site archive summaries, update status, and benchmark state without booting the legacy WebUI.
- It can spawn the token-protected companion proxy for iOS compatibility while keeping the target runtime on loopback.

## RoachClaw Direction

RoachClaw remains the bundled local-AI path:

- install Ollama and OpenClaw together
- prefer local Ollama models by default
- present one guided onboarding path
- expose advanced model/runtime tuning inside RoachNet after setup, not during initial install unless the user opens advanced options

## Current Shipping Rule

- `RoachNet Setup.app` is the only setup/onboarding entry point.
- `RoachNet.app` is SwiftUI/AppKit, not Electron.
- The default package entrypoint is `scripts/run-roachnet-native-api.mjs`; `npm start` must not boot the legacy WebUI runtime.
- The native API and companion bridge default to loopback. LAN companion access is an explicit user/runtime setting, not the public install default.
- Runtime services may stay as local background glue while features migrate into native surfaces.
- New user-facing work should land in the native macOS app unless there is a clear runtime-only reason.

## Feature Preservation Rule

Moving away from Electron is not permission to throw features overboard.

- Legacy Electron/WebUI source may stay in the private working tree as reference material until native parity exists.
- The public shipping lane must not install Electron or package Electron artifacts.
- A feature can be removed from the legacy surface only after it exists in the native app, is intentionally retired, or is replaced by a tested runtime API.
- Release gates must prove the native app still has first-class surfaces for RoachClaw, Vault, RoachArcade, Dev, Settings, About, command bar, installer handoff, and the local runtime bridge.
- Fast tests must prove the native API exposes the app catalogs and iOS companion payloads without the legacy WebUI runtime.
- Any dependency removal must be paired with a local RoachNet replacement or a clear proof that the dependency was unused.
