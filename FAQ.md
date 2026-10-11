# Frequently Asked Questions

## What is RoachNet?

A native macOS app that keeps local AI, an agent company, maps, a vault of notes and archives, games, and dev tools on your own Mac, working with the network off. An iOS companion pairs with it over RoachTail.

## What do I need to run it?

An Apple Silicon Mac on macOS 14 or later. For local AI, 16 GB of memory or more is the comfortable floor, and a fast SSD helps with maps, archives and models. RoachNet reads the machine and suggests model sizes that fit it.

## Does it need Docker, Node, Homebrew or Debian?

No. RoachNet Setup and the app run on `roachnet-runtime`, a native Swift helper built on Apple system frameworks. Homebrew is one way to install it, not a requirement. Docker-backed support services are an opt-in in Setup and off by default. The Debian and Docker lanes from the imported upstream base are gone.

## Do I need Ollama?

No. Since 1.1 RoachClaw runs on RoachInference, RoachNet's own GGUF engine with Metal kernels, on the same Ollama-compatible API at `127.0.0.1`. Models you already pulled with Ollama are read in place, so nothing is downloaded twice. If you would rather keep using an Ollama you installed yourself, set `ROACHNET_INFERENCE_ENGINE=ollama`. RoachNet 1.0.x bundled Ollama; 1.1 doesn't.

## Can RoachClaw use cloud models?

Only if you add a provider and its key yourself. Local models are the default, and a cloud route is always an explicit choice.

## What are feature packs?

1.1 installs a small core and lets you add the rest: panes (RoachClaw, Org, Dev, Vault, RoachArcade, Maps, Education, speech, the companion bridge), speech models, map collections, knowledge bundles and themes. Manage them in Settings › Packs. Disabling or removing a pack unloads it and stops its background work. Removing keeps your data unless you choose to move it to a Retired folder. Resource packs are checked by SHA-256 and size before they're swapped in.

## How do themes work?

Settings › Appearance has 31 built-in themes, 13 snippets that tweak one thing (corners, glass, glow, text size, motion), and an editor for every color, font, radius, shadow and background token. A theme is a JSON file: export it, share it, or drop one into your themes folder. Theme packs on RoachNet Apps add more. Every built-in theme is tested for readable text in each mode it ships, and the iOS companion follows the theme you pick on the Mac.

## Is my Vault encrypted?

RoachNet doesn't add its own encryption to Vault files. They are ordinary files in your RoachNet storage folder, so turn on FileVault to encrypt them at rest. RoachClaw state, provider keys, RoachTail state and the runtime's server-info file are written readable by your macOS account only. Dev secrets go in the macOS Keychain.

## Can a website talk to RoachNet's local API?

It shouldn't be able to. The loopback API only answers `localhost`, `::1` and `127.x.x.x` hosts, refuses requests whose `Origin` is another site, and only accepts JSON bodies. Since 1.1 the app also starts the runtime with a fresh per-launch token, so other programs on your Mac need that token or a RoachClaw API token too. Make RoachClaw API tokens in Settings › RoachClaw, give each only the scopes it needs (`chat`, `read`, `admin`), and revoke them there.

## How does pairing an iPhone work?

RoachTail shows a one-use, expiring join code. The phone trades it for its own peer token; RoachNet keeps only a hash. A token that goes unused for 90 days stops working, and you can remove a single device from the list. The companion refuses plain HTTP to anything but loopback, your tailnet or the simulator.

## Why does macOS say RoachNet Setup can't be verified?

Releases are ad-hoc signed and not Apple-notarized until RoachWares has a Developer ID. Check the DMG against the `.sha256` file on the release page, then open System Settings › Privacy & Security and choose **Open Anyway**.

## Can I change where things are stored?

Yes. Setup asks for an install root and keeps the app, runtime, models, workspace and storage under it. [docs/LOCAL_BOOT.md](docs/LOCAL_BOOT.md) covers the environment variables for development builds.

## What languages does the UI support?

English only for now.

## Is RoachNet free and open source?

Yes, under the Apache License 2.0. The iOS companion is Apache-2.0 too.

## Where do I report bugs or ask for features?

- Issues: [github.com/RoachWares/RoachNet/issues](https://github.com/RoachWares/RoachNet/issues)
- Discussions: [github.com/RoachWares/RoachNet/discussions](https://github.com/RoachWares/RoachNet/discussions)

Before opening one, check [README.md](README.md), [docs/LOCAL_BOOT.md](docs/LOCAL_BOOT.md) and [CONTRIBUTING.md](CONTRIBUTING.md).
