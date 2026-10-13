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
  Local AI on RoachInference, RoachNet's own GGUF engine with hand-written Metal kernels, served on the same Ollama-compatible loopback API. Models you already pulled with Ollama are used in place. Remote providers stay an explicit opt-in.
- `Org`
  A RoachClaw agent company that runs on your Mac. Agents propose hires and spend against a monthly budget; nothing happens until you approve it, on the Mac or from a paired iPhone.
- `Dev`
  Native project lane with shell access, inline assist, secrets plumbing, Raycast-style guidebook references, and RoachClaw close by.
- `RoachArcade`
  ROMs, macOS games, mods, cheats, collection notes, and play counts in one local shelf. Every backlog has fossils.
- `Maps`
  An offline atlas that draws the PMTiles packs you install (50 states, DC, five territories, and a world overview), with pan, zoom, GPS fixes and routes. No tile server, no web view.
- `Vault`
  Notes, references, archives, Roach's Archive metadata search, and offline material on one shelf.
- `RoachTail`
  Native device lane for RoachNet iOS and nearby machines: expiring join keys, peer-scoped tokens that lapse when unused, approved local routes, and a relay map shaped after Headscale without handing your work to a hosted control plane.
- `Themes`
  31 built-in themes, 13 snippets, and a theme editor in Settings › Appearance. A theme is a JSON file you can export, share, or drop into your themes folder. More arrive as theme packs on RoachNet Apps, and the iOS companion follows the theme you pick on the Mac.
- `Feature packs`
  Install the core, then add what you use. Panes, speech packs, map collections, knowledge bundles and themes are packs you enable, disable or remove in Settings › Packs. Removing a pack keeps your data unless you choose to retire it.
- `Contained install`
  App, runtime, models, workspace, and support services stay grouped near the RoachNet root.

## Install

Start with `RoachNet Setup`.

The setup app checks the machine, stages the contained runtime beside the target, smoke-tests it before swapping it in, and hands off to the native shell. It runs on `roachnet-runtime`, a native Swift helper, so it needs no Node, Docker, Homebrew, or host libraries. RoachNet ships no Node and runs no JavaScript of its own; agent CLIs you connect to Org yourself run on whatever they were built with.

There is also a direct Homebrew lane for Apple Silicon Macs:

```bash
brew update
brew tap --force RoachWares/roachnet
brew install --cask roachnet
open ~/RoachNet/app/RoachNet.app
```

That path skips `RoachNet Setup.app`, runs `roachnet-runtime --install`, and writes the contained RoachNet config so the native app lands straight in `~/RoachNet/app`.

- Website: [roachnet.org](https://roachnet.org)
- macOS installer: [RoachNet-Setup-macOS.dmg](https://github.com/RoachWares/RoachNet/releases/latest/download/RoachNet-Setup-macOS.dmg)
- Release feed: [github.com/RoachWares/RoachNet/releases](https://github.com/RoachWares/RoachNet/releases)

Releases are ad-hoc signed and not Apple-notarized until RoachWares has a Developer ID. The first launch needs System Settings › Privacy & Security › **Open Anyway**. Check the download against the `.sha256` file published next to it first.

## Support

GitHub does not host the support widgets used on the public site, so the repo keeps public support links here.

- [Support RoachNet development](https://www.paypal.com/ncp/payment/ZV8RL9DWQXHGE)

## Platform Status

- `macOS Apple Silicon`
  macOS 14 or later. [GitHub Releases](https://github.com/RoachWares/RoachNet/releases) has the current version; [`docs/releases/`](./docs/releases) has each release's notes and gate results.
- `iOS`
  [RoachNet iOS](https://github.com/RoachWares/RoachNet-iOS) is a companion: it pairs over RoachTail and drives the Mac. Unsigned IPA through SideStore or AltStore.
- `Windows 11 x64`
  No public installer lane. RoachArcade keeps Windows-game runner planning inside the macOS app instead of shipping another half-built desktop target.
- `Linux`
  Not released. The runtime builds and is tested on Linux in CI while the Linux app is built; RoachNet for Linux ships only when it matches the Mac app. Progress is tracked in `docs/LINUX_PARITY.md`.

## Repo Layout

- [`native/macos/`](./native/macos)
  SwiftUI/AppKit shell, setup app, `roachnet-runtime`, RoachInference, and the design and theme system.
- [`scripts/`](./scripts)
  Packaging, audits, contract tests, and release automation (Node 26; none of it ships).
- [`docs/`](./docs)
  Architecture, brand voice, upstream notes, and release records.

The public site and Apps storefront live in [`RoachWares/roachnet-org`](https://github.com/RoachWares/roachnet-org) so this repo can stay focused on the desktop product and runtime.

## Local Development

RoachNet itself is Swift only. Node 26 is just the toolchain for the build, test and release scripts in `scripts/`.

Build and start `roachnet-runtime`, the loopback runtime the app runs:

```bash
npm run runtime:build
PORT=8080 npm run runtime:start
```

The loopback API refuses any request whose `Host` is not `localhost`, `::1` or a `127.x.x.x` address, any request from another website's `Origin`, and request bodies that are not JSON. When `ROACHNET_API_TOKEN` is set (RoachNet.app sets a fresh one every launch), every route except `GET /api/health` and Org requests that carry an Org member key also needs that token or a RoachClaw API token with the right scope, sent as `Authorization: Bearer …` or `X-RoachNet-API-Token`. See [roachnet.org/api](https://roachnet.org/api/).

RoachTail is served from the same runtime. The desktop owns the local control-plane state, the join key is one-use and expiring, and paired devices only receive peer-scoped tokens:

- `GET /api/companion/roachtail`
  Returns the current RoachTail status, join payload, route map, relay map, and paired peer list.
- `POST /api/companion/roachtail/pair`
  Exchanges a fresh join code for a peer token. The token is returned once and only its hash is stored.
- `POST /api/companion/roachtail/affect`
  Enables, disables, refreshes the join code, clears peers, sets a relay host, or removes a peer.

A peer token unused for 90 days stops working (`ROACHTAIL_PEER_IDLE_DAYS`; `0` turns this off).

Build and test the native macOS packages, and run the runtime contract tests against the release build of the helper:

```bash
swift test --package-path native/macos
npm run runtime:build
npm run test:native-runtime
node scripts/build-native-macos-apps.mjs
```

Run the setup backend RoachNet Setup uses:

```bash
native/macos/.build/release/roachnet-runtime --setup
```

## Public Source Boundary

RoachNet is a native local-first desktop product. The old imported base is no longer a public source lane.

The vulnerable legacy `admin/` WebUI was removed after v1.0.5. Its last tracked public provenance remains available from tag `v1.0.5`.

- [`docs/NATIVE_REWRITE_PLAN.md`](./docs/NATIVE_REWRITE_PLAN.md)
- [`docs/1.1/FEATURE_PACKS.md`](./docs/1.1/FEATURE_PACKS.md)
- [`CHANGELOG.md`](./CHANGELOG.md)

## License

This repository still carries the upstream Apache 2.0 license. Review [`LICENSE`](./LICENSE) and [`docs/UPSTREAM.md`](./docs/UPSTREAM.md) before changing attribution or licensing details.
