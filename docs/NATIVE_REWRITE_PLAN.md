# RoachNet Native Rewrite Plan

RoachNet should ship to end users through a separate setup application first.

Product flow:

1. User downloads `RoachNet Setup`.
2. `RoachNet Setup` detects hardware, architecture, and prerequisite state.
3. `RoachNet Setup` installs Docker/Desktop or the platform runtime path that RoachNet needs, installs the RoachNet application, prepares RoachClaw, and performs the first-run handoff.
4. The main `RoachNet` application becomes the only app the user uses after setup is complete.

The current Electron shells are a transition layer. The target product is a native application per platform.

## Platform Targets

### macOS Apple Silicon

- UI shell: SwiftUI with AppKit where needed for window, menu-bar, drag-region, and system integration work.
- AI acceleration: MLX-first path for Apple Silicon, with Ollama still available as a compatibility/runtime option.
- Packaging: signed `.app` bundle and `.dmg`.
- Distribution target: direct download from the RoachNet site, with `RoachNet Setup.app` as the only initial download.

Reference:

- [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [MLX documentation](https://ml-explore.github.io/mlx/build/html/index.html)

### Windows 11 x64

- UI shell: WinUI 3 on the Windows App SDK.
- Runtime orchestration: native Windows service/process management instead of relying on the app shell to host setup.
- Packaging: signed installer or MSIX plus a standalone `RoachNet Setup.exe`.
- Target hardware: non-ARM 64-bit Windows 11 systems.

Reference:

- [WinUI 3 / Windows App SDK](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/)

### Linux

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

- `installer/`
  Standalone setup application and onboarding flow.
- `native/macos/`
  SwiftUI/AppKit shell for macOS.
- `native/windows/`
  WinUI 3 shell for Windows 11 x64.
- `native/linux/`
  GTK4/libadwaita shell for Linux.
- shared runtime core
  Service/process/container orchestration, RoachClaw bootstrap, updater state, health probes, model routing, and knowledge/indexing APIs.

## RoachClaw Direction

RoachClaw remains the bundled local-AI path:

- install Ollama and OpenClaw together
- prefer local Ollama models by default
- present one guided onboarding path
- expose advanced model/runtime tuning inside RoachNet after setup, not during initial install unless the user opens advanced options

## Current Transitional Rule

Until the native platform shells replace Electron:

- `RoachNet Setup` is the only setup/onboarding entry point
- the packaged main app should stay locked until setup is complete
- the packaged main app should hand the user back to the separate setup app or release downloads instead of hosting setup internally
