# RoachNet

Your stuff, still here when the internet isn't.

RoachNet is a local-first command center for offline maps, local AI, education, saved websites, and your own notes. It keeps the important parts of your workflow on your machine, so bad Wi-Fi, outages, and cloud slowdowns do not take the rest of your day down with them.

[roachnet.org](https://roachnet.org)  
[GitHub Releases](https://github.com/AHGRoach/RoachNet/releases)
[Support AHG Records LLC and RoachNet](https://roachnet.org/#support)
[Public Website Source](https://github.com/AHGRoach/roachnet-org)

## What You Get

- `Command Deck`
  One calm place for runtime health, maps, education, archives, and local AI.
- `RoachClaw`
  RoachNet's local AI path, built around Ollama and OpenClaw with a fast local default model.
- `Offline Maps`
  Curated map collections and route-aware surfaces that stay available when the network drops.
- `Education`
  Wikipedia and Khan Academy-style offline learning content, grouped in one place.
- `Archives`
  Saved websites and captured references for offline browsing.
- `Contained Install`
  App, runtime data, workspace, and support services stay grouped near the RoachNet install root instead of being smeared across the OS.

## Download

Start with `RoachNet Setup`.

The installer checks the machine, prepares the local runtime, aligns RoachClaw, and then hands off into the main RoachNet app.

- Website: [roachnet.org](https://roachnet.org)
- macOS installer: [RoachNet-Setup-macOS.dmg](https://roachnet.org/downloads/RoachNet-Setup-macOS.dmg)
- Releases: [github.com/AHGRoach/RoachNet/releases](https://github.com/AHGRoach/RoachNet/releases)

## Support

GitHub does not allow the hosted PayPal button script that powers the support section on [roachnet.org](https://roachnet.org/#support), so the repo uses direct support links instead.

- [Donate to AHG Records LLC](https://www.paypal.com/cgi-bin/webscr?business=lesherist%40gmail.com&cmd=_donations&currency_code=USD&item_name=Donation+to+AHG+Records&return=https%3A%2F%2Fahgrecords.com%2Fhome)
- [Support RoachNet development](https://www.paypal.com/ncp/payment/ZV8RL9DWQXHGE)

## Current Product Direction

RoachNet is moving toward fully native desktop apps:

- `macOS Apple Silicon`
  SwiftUI/AppKit shell and native installer flow
- `Windows 11 x64`
  WinUI 3 scaffold in progress
- `Linux`
  GTK4/libadwaita scaffold in progress

The current shipping focus is the macOS-native path, with the website and GitHub release flow centered on the native installer.

## RoachClaw

RoachClaw is the default local AI lane inside RoachNet.

It brings Ollama and OpenClaw together so the app can:

- detect local model availability
- save a machine-appropriate default model
- keep local chat working even when OpenClaw's agent runtime is not yet online
- grow into agent workflows later without forcing remote providers first

For this release, RoachNet prefers `qwen2.5-coder:7b` as the default local RoachClaw model because it is a better fit for everyday work plus coding on this setup than the heavier defaults we were previously surfacing.

## Repo Layout

- [`admin/`](./admin)
  Local API, web admin, RoachClaw services, maps, archives, and content plumbing
- [`native/macos/`](./native/macos)
  Native macOS app and installer
- [`scripts/`](./scripts)
  Setup, runtime, native bundling, and asset preparation scripts
- [`docs/`](./docs)
  Architecture notes, evaluations, and rewrite plans

The public marketing site and Apps storefront now live in the separate
[`AHGRoach/roachnet-org`](https://github.com/AHGRoach/roachnet-org) repository so the desktop app repo can stay focused on the native product and runtime.

## Local Development

From the repo root:

```bash
npm start
```

No-browser boot:

```bash
npm run start:no-browser
```

Native macOS app build:

```bash
node scripts/build-native-macos-apps.mjs
```

Setup backend:

```bash
npm run setup:no-browser
```

## Upstream Attribution

RoachNet started from an imported upstream base from [Crosstalk Solutions project-nomad](https://github.com/Crosstalk-Solutions/project-nomad) and is being reshaped into a calmer, product-grade local command center with native installers, local AI, contained runtime management, and a more cohesive desktop UX.

See:

- [`docs/UPSTREAM.md`](./docs/UPSTREAM.md)
- [`docs/NATIVE_REWRITE_PLAN.md`](./docs/NATIVE_REWRITE_PLAN.md)
- [`CHANGELOG.md`](./CHANGELOG.md)

## License

This repository currently carries the upstream Apache 2.0 license from the imported base. Review [`LICENSE`](./LICENSE) and [`docs/UPSTREAM.md`](./docs/UPSTREAM.md) before changing attribution or licensing details.
