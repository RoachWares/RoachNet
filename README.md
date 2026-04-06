# RoachNet

Local-first desktop command center.

RoachNet keeps maps, models, dev tools, and notes in one contained workspace instead of smearing them across the machine or leaving them in a stack of tabs.

[roachnet.org](https://roachnet.org)  
[RoachNet Apps](https://apps.roachnet.org)  
[API Docs](https://roachnet.org/api/)  
[GitHub Releases](https://github.com/AHGRoach/RoachNet/releases)  
[RoachNet iOS](https://roachnet.org/iOS/)  
[Public Website Source](https://github.com/AHGRoach/roachnet-org)

## What It Ships With

- `Home`
  Command bar, launch tiles, runtime health, and the first surface you land in after setup.
- `RoachClaw`
  Local AI wired through Ollama and OpenClaw, with contained model lanes and an upgrade path that stays visible.
- `Dev`
  Native project lane with shell access, inline assist, secrets plumbing, and RoachClaw close by.
- `Maps & Vault`
  Routes, references, saved notes, and offline material grouped into one shelf.
- `RoachTail`
  Secure device pairing between the desktop lane and RoachNetiOS.
- `Contained install`
  App, runtime, models, workspace, and support services stay grouped near the RoachNet root.

## Install

Start with `RoachNet Setup`.

The setup app checks the machine, stages the contained runtime, gives Docker as an explicit opt-in, and hands off into the native shell.

The packaged setup lane now ships its own portable embedded Node runtime, so Apple Silicon installs do not assume Homebrew or host-level dylib dependencies just to boot the installer.

- Website: [roachnet.org](https://roachnet.org)
- macOS installer: [RoachNet-Setup-macOS.dmg](https://github.com/AHGRoach/RoachNet/releases/latest/download/RoachNet-Setup-macOS.dmg)
- Windows 11 beta: [RoachNet-Setup-windows-x64-beta.exe](https://github.com/AHGRoach/RoachNet/releases/latest/download/RoachNet-Setup-windows-x64-beta.exe)
- Release feed: [github.com/AHGRoach/RoachNet/releases](https://github.com/AHGRoach/RoachNet/releases)

## Support

GitHub does not host the PayPal button script used on the public site, so the repo keeps direct support links here.

- [Donate to AHG Records LLC](https://www.paypal.com/cgi-bin/webscr?business=lesherist%40gmail.com&cmd=_donations&currency_code=USD&item_name=Donation+to+AHG+Records&return=https%3A%2F%2Fahgrecords.com%2Fhome)
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
  Architecture, upstream notes, and rewrite planning.

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

## Upstream Attribution

RoachNet started from an imported upstream base from [Crosstalk Solutions project-nomad](https://github.com/Crosstalk-Solutions/project-nomad) and is being rewritten into a contained local-first desktop product.

- [`docs/UPSTREAM.md`](./docs/UPSTREAM.md)
- [`docs/NATIVE_REWRITE_PLAN.md`](./docs/NATIVE_REWRITE_PLAN.md)
- [`CHANGELOG.md`](./CHANGELOG.md)

## License

This repository still carries the upstream Apache 2.0 license. Review [`LICENSE`](./LICENSE) and [`docs/UPSTREAM.md`](./docs/UPSTREAM.md) before changing attribution or licensing details.
