# RoachNet

Offline spine for the stuff that matters.

RoachNet keeps AI, archive, media, games, notes, and dev tools on hardware you own instead of leaving them scattered across rented dashboards and dead logins.

[roachnet.org](https://roachnet.org)<br>
[RoachNet Apps](https://apps.roachnet.org)<br>
[API Docs](https://roachnet.org/api/)<br>
[GitHub Releases](https://github.com/RoachWares/RoachNet/releases)<br>
[RoachNet iOS](https://roachnet.org/iOS/)<br>
[RoachNet SideStore Source](https://github.com/RoachWares/RoachNet-SideStore)<br>
[Public Website Source](https://github.com/RoachWares/roachnet-org)

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
  Native device lane for RoachNetiOS and nearby machines: expiring join keys, private peer tokens, approved local routes, and a relay map shaped after Headscale without handing your work to a hosted control plane.
- `Contained install`
  App, runtime, models, workspace, and support services stay grouped near the RoachNet root.

## Install

Start with `RoachNet Setup`.

The setup app checks the machine, stages the contained runtime, gives Docker as an explicit opt-in, and hands off into the native shell.

The packaged setup lane now ships its own portable embedded Node runtime, so Apple Silicon installs do not assume Homebrew or host-level dylib dependencies just to boot the installer.

There is also a direct Homebrew lane for Apple Silicon Macs:

```bash
brew update
brew tap --force RoachWares/roachnet
brew install --cask roachnet
open ~/RoachNet/app/RoachNet.app
```

That path skips `RoachNet Setup.app` and writes the contained RoachNet config automatically so the native app lands straight in `~/RoachNet/app`.

The direct Homebrew lane stages its compiled runtime under `~/RoachNet/storage/state/runtime-cache`, writes launcher and server logs under `~/RoachNet/storage/logs`, uses a contained handshake file instead of `/tmp`, re-signs native runtime artifacts on macOS, and keeps the runtime/API surface aligned with the main native app once boot completes.

On first boot, the Homebrew profile marks the contained runtime as pending bootstrap, does one contained self-heal pass if the first runtime handoff fails, and then records the last healthy launch timestamp once `/api/health` is up.
- Website: [roachnet.org](https://roachnet.org)
- macOS installer: [RoachNet-Setup-macOS.dmg](https://github.com/RoachWares/RoachNet/releases/latest/download/RoachNet-Setup-macOS.dmg)
- Release feed: [github.com/RoachWares/RoachNet/releases](https://github.com/RoachWares/RoachNet/releases)

## Support

GitHub does not host the support widgets used on the public site, so the repo keeps public support links here.

- [Support RoachNet development](https://www.paypal.com/ncp/payment/ZV8RL9DWQXHGE)

## Platform Status

- `macOS Apple Silicon`
  v1.0.5 remains the current stable release. The [v1.0.6 candidate notes](./docs/releases/1.0.6.md) and [publication matrix](./docs/releases/1.0.6-publication-matrix.md) are draft-only until Developer ID, notarization, install, accessibility, performance, and exact-public-byte gates pass.
- `Windows 11 x64`
  No public installer lane in this candidate. RoachArcade keeps Windows-game runner planning inside the macOS app instead of shipping another half-built desktop target.
- `Linux`
  Runtime and packaging work still moving toward a native desktop lane.

## Repo Layout

- [`native/macos/`](./native/macos)
  SwiftUI/AppKit shell, setup app, and desktop runtime bridge.
- [`scripts/`](./scripts)
  Setup, runtime, packaging, companion, and release automation.
- [`docs/`](./docs)
  Architecture, brand voice, upstream notes, and rewrite planning.

The public site and Apps storefront live in [`RoachWares/roachnet-org`](https://github.com/RoachWares/roachnet-org) so this repo can stay focused on the desktop product and runtime.

## Local Development

Start the dependency-free native API bridge:

```bash
npm start
```

RoachTail is served from the same native bridge. The desktop owns the local control-plane state, the join key is one-use/expiring, and paired devices only receive peer-scoped tokens. The API surface is intentionally small:

- `GET /api/companion/roachtail`
  Returns the current RoachTail status, join payload, route map, relay map, and paired peer list.
- `POST /api/companion/roachtail/pair`
  Exchanges a fresh join code for a peer token. The token is returned once and only its hash is stored.
- `POST /api/companion/roachtail/affect`
  Enables, disables, refreshes the join code, clears peers, sets a relay host, or removes a peer.

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

The vulnerable legacy `admin/` WebUI was removed from the post-v1.0.5 public candidate. Its last tracked public provenance remains available from tag `v1.0.5`; uncommitted local reference work was preserved outside this candidate rather than discarded.

- [`docs/NATIVE_REWRITE_PLAN.md`](./docs/NATIVE_REWRITE_PLAN.md)
- [`CHANGELOG.md`](./CHANGELOG.md)

## License

This repository still carries the upstream Apache 2.0 license. Review [`LICENSE`](./LICENSE) and [`docs/UPSTREAM.md`](./docs/UPSTREAM.md) before changing attribution or licensing details.
