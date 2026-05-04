# RoachNet

Offline spine for the stuff that matters.

RoachNet keeps AI, archive, media, games, notes, and dev tools on hardware you own instead of leaving them scattered across rented dashboards and dead logins.

[roachnet.org](https://roachnet.org)  
[RoachNet Apps](https://apps.roachnet.org)  
[API Docs](https://roachnet.org/api/)  
[GitHub Releases](https://github.com/AHGRoach/RoachNet/releases)  
[RoachNet iOS](https://roachnet.org/iOS/)  
[RoachNet SideStore Source](https://github.com/AHGRoach/RoachNet-SideStore)  
[Public Website Source](https://github.com/AHGRoach/roachnet-org)

## What It Ships With

- `Home`
  Command bar, launch tiles, runtime health, and the first surface you land in after setup.
- `RoachClaw`
  Local AI wired through Ollama first, with LM Studio-ready local endpoints and remote providers kept as explicit opt-in trips outside the bunker.
- `Dev`
  Native project lane with shell access, inline assist, secrets plumbing, Raycast-style guidebook references, and RoachClaw close by.
- `RoachArcade`
  ROMs, macOS games, mods, cheats, collection notes, and play counts in one local shelf. Every backlog has fossils.
- `Maps & Vault`
  Routes, references, saved notes, Roach's Archive bulk-metadata search, and offline material grouped into one shelf.
- `RoachTail`
  Secure device pairing between the desktop lane and RoachNetiOS.
- `Contained install`
  App, runtime, models, workspace, and support services stay grouped near the RoachNet root.

## Install

Start with `RoachNet Setup`.

The setup app checks the machine, stages the contained runtime, gives Docker as an explicit opt-in, and hands off into the native shell.

The packaged setup lane now ships its own portable embedded Node runtime, so Apple Silicon installs do not assume Homebrew or host-level dylib dependencies just to boot the installer.

There is also a direct Homebrew lane for Apple Silicon Macs:

```bash
brew update
brew tap --force AHGRoach/roachnet
brew install --cask roachnet
open ~/RoachNet/app/RoachNet.app
```

That path skips `RoachNet Setup.app` and writes the contained RoachNet config automatically so the native app lands straight in `~/RoachNet/app`.

The direct Homebrew lane stages its compiled runtime under `~/RoachNet/storage/state/runtime-cache`, writes launcher and server logs under `~/RoachNet/storage/logs`, uses a contained handshake file instead of `/tmp`, re-signs native runtime artifacts on macOS, and keeps the runtime/API surface aligned with the main native app once boot completes.

On first boot, the Homebrew profile marks the contained runtime as pending bootstrap, does one contained self-heal pass if the first runtime handoff fails, and then records the last healthy launch timestamp once `/api/health` is up.
- Website: [roachnet.org](https://roachnet.org)
- macOS installer: [RoachNet-Setup-macOS.dmg](https://github.com/AHGRoach/RoachNet/releases/latest/download/RoachNet-Setup-macOS.dmg)
- Windows 11 beta: [RoachNet-Setup-windows-x64-beta.exe](https://github.com/AHGRoach/RoachNet/releases/latest/download/RoachNet-Setup-windows-x64-beta.exe)
- Release feed: [github.com/AHGRoach/RoachNet/releases](https://github.com/AHGRoach/RoachNet/releases)

## Support

GitHub does not host the support widgets used on the public site, so the repo keeps public support links here.

- [Support RoachNet development](https://www.paypal.com/ncp/payment/ZV8RL9DWQXHGE)

## Platform Status

- `macOS Apple Silicon`
  Current native release lane with the contained setup flow.
- `Windows 11 x64`
  Native beta lane with setup and shell scaffolding.
- `Linux`
  Runtime and packaging work still moving toward a native desktop lane.

## Repo Layout

- [`admin/`](./admin)
  Local API, runtime services, maps, archives, content installs, and RoachClaw plumbing.
- [`native/macos/`](./native/macos)
  SwiftUI/AppKit shell, setup app, and desktop runtime bridge.
- [`native/windows/`](./native/windows)
  Windows beta shell and setup surfaces.
- [`scripts/`](./scripts)
  Setup, runtime, packaging, companion, and release automation.
- [`docs/`](./docs)
  Architecture, brand voice, upstream notes, and rewrite planning.

The public site and Apps storefront live in [`AHGRoach/roachnet-org`](https://github.com/AHGRoach/roachnet-org) so this repo can stay focused on the desktop product and runtime.

## Local Development

Start the source runtime:

```bash
npm start
```

No-browser boot:

```bash
npm run start:no-browser
```

Build the native macOS packages:

```bash
node scripts/build-native-macos-apps.mjs
```

Run the setup backend:

```bash
npm run setup:no-browser
```

## Public Source Boundary

RoachNet is now a native local-first desktop product. The old imported base is no longer a public source lane.

- [`docs/NATIVE_REWRITE_PLAN.md`](./docs/NATIVE_REWRITE_PLAN.md)
- [`CHANGELOG.md`](./CHANGELOG.md)

## License

This repository still carries the upstream Apache 2.0 license. Review [`LICENSE`](./LICENSE) and [`docs/UPSTREAM.md`](./docs/UPSTREAM.md) before changing attribution or licensing details.
