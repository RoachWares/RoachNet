# RoachNet for Linux: parity status

RoachNet for Linux is not released. It is its own release line, separate from macOS releases. Nothing ships for Linux until three things are true: every area below is at parity with the Mac app, a Linux release gate passes, and the maintainer approves publication. Until then, no Linux build, download or announcement is published.

The Linux app is planned as native Swift with GTK 4 and libadwaita. It will use swift-crypto on Linux only, and no Node or Electron. A successful Linux build does not by itself mean any area is ready.

## How parity is measured

1. **Runtime unit tests:** the XCTest suites for `RoachNetRuntime` and `RoachInference`, run on Linux by the `Linux runtime` workflow.
2. **Runtime contract tests:** the Node tests the macOS gates run against `roachnet-runtime`, run against the Linux build by the same workflow. Node is only the test harness. Nothing in RoachNet ships or launches it.
3. **Hand checks:** each area is also checked by hand against the Mac app once a Linux UI exists for it.

An area is at parity only when its Linux implementation passes the same tests as the Mac's and the hand check matches.

## Current numbers

Measured on 2026-10-13, with the ROA-90 fix. The macOS run was on an Apple silicon Mac. The Linux run was on Ubuntu 24.04 x86_64 with 2 CPUs, Swift 6.4.1 and Node 26.11.1.

| Measure | macOS | Linux |
| --- | --- | --- |
| Runtime XCTests | 169 run, 0 failures | 159 run, 1 skipped ([ROA-87](https://linear.app/roachwares/issue/ROA-87)), 0 failures. The 10 fewer are Mac-only: the Cluster's 7, and the installer's 3 archive-pack tests, which install macOS-platform packs. |
| Inference XCTests | 36 run, 13 skipped (no model files), 0 failures | 36 run, 13 skipped (Metal, model files), 0 failures |
| Runtime contract tests | 133 tests, run with the model files: 131 pass, 2 skip themselves (the Metal kernel check, which needs a built `roachnet-infer`, and a RoachVoice check that only runs where Core ML tooling is missing), 0 failures | 133 tests: 112 pass, 21 skip themselves, 0 failures |

In CI, the ROA-72 port test can skip itself too, when something already holds 127.0.0.1:36434 at that moment. It passes in a local run.

The 21 self-skipping contract tests on Linux:
- **12 need model files** (`ROACHNET_TEST_MODELS`). They also skip on a Mac without those files. Nothing in them is Mac-specific, and running them on Linux with the files is L2 work.
- **2 need model files and an Apple silicon Mac:**
  - the Cluster test, which splits a model across two Macs (L3);
  - "numbers no client should send get a reply, not a crash", which should also run on Linux (L2).
- **1 checks the Metal kernels** against the Swift reference (`ROACHNET_INFERENCE_TOOL` and a C++ compiler). It is Mac-only, and the Vulkan kernels need their own version (L4).
- **6 need macOS tools:**
  - 4 RoachSpeech pack tests that need `ditto`;
  - 1 zipped-app test that needs `ditto`;
  - 1 disk-image test that needs `hdiutil`.

Running the contract tests on Linux has found two Linux-only problems, both fixed:
- Reading RoachClaw's status killed the runtime when the time zone had a legacy name, such as `US/Eastern` (PR #39).
- Requests that waited on each other's probes stalled for seconds, because blocking work ran on dispatch's few workers ([ROA-90](https://linear.app/roachwares/issue/ROA-90)). Eight status reads at once took 2 to 13 seconds on 2 CPUs. They now take about a quarter of a second.

## Areas

Status key: ✅ at parity, ⚠️ partly there, ❌ not started.

| Area | Linux status | Evidence | What's left | Phase |
| --- | --- | --- | --- | --- |
| Runtime API (Ollama-, OpenAI- and Anthropic-compatible, RoachClaw, Org, packs) | ⚠️ | Contract and runtime tests above | Model-backed contract tests on Linux | L2 |
| Local inference (RoachInference) | ⚠️ CPU reference path | Inference XCTests | Fast CPU kernels and benchmarks (L2); GPU through Vulkan (L4) | L2, L4 |
| Model management (pull and verify, create and copy, memory fitting) | ⚠️ builds; tests need model files | Skipped model-backed contract tests | Run them on Linux with the model files | L2 |
| Feature packs (catalog, install, toggles, uninstall) | ⚠️ runtime only | "native API manages feature packs" passes; the ZIP reader unpacks with `unzip` and checks each file's size | Linux-platform packs, so the installer's archive-pack tests run on Linux too; pack views in the GTK app; Linux speech packs (L6) | L5, L6 |
| Local-first storage and data ownership | ⚠️ runtime only | Storage, trace replay and Vault-path tests pass | Vault encryption with swift-crypto and Secret Service, optional and off by default | L1 |
| Privacy and security | ⚠️ runtime only | Loopback-only bind, API token and redaction tests pass | Secret Service in place of the Keychain; a Linux packaging and security review | L1, L7 |
| Authentication and integrations (RoachTail pairing, cloud providers, subscription CLIs) | ⚠️ runtime only | RoachTail join-key and peer-token tests pass; the bring-your-own agent test passes with `curl` installed | Pairing an iPhone with a Linux host, tested; secrets in Secret Service; the Linux package must require `curl`, which the `roachnet-org` helper uses | L1, L5, L7 |
| Error handling and recovery | ⚠️ | The legacy-time-zone crash is fixed; trace-recovery tests pass | Setup recovery on Linux; a crash-free soak test | L5, L7 |
| Performance, reliability and stability | ⚠️ | Model memory follows cgroup limits; concurrent requests no longer stall ([ROA-90](https://linear.app/roachwares/issue/ROA-90)) | [ROA-87](https://linear.app/roachwares/issue/ROA-87); Linux benchmarks | L0 to L4 |
| RoachNet Cluster | ❌ compiled out (`dnssd`, CryptoKit, Metal) | none | swift-crypto links, Avahi discovery, CPU and GPU stages | L3 |
| RoachSpeech (Whisper, Kokoro, Chatterbox) | ❌ Core ML on the Mac | none | Run on RoachInference instead of Core ML | L6 |
| App UI (GTK 4 + libadwaita) | ❌ | none | Shell, then each pane checked against the Mac | L5 |
| Setup, installation and updates | ❌ Setup is macOS-specific | none | A Linux Setup lane, a packaging decision, an updater | L5, L7 |
| Linux conventions (XDG folders, desktop entry, theming, Reduce Motion, accessibility) | ❌ | none | All of it | L5 |
| Release engineering (packages, checksums and signatures, release gate) | ❌ | none | A Linux release gate, separate from macOS | L7 |

**Summary:** 0 of 15 areas at parity, 9 partly there, 6 not started.

## Reproducing the numbers

Use Ubuntu 24.04 with Swift 6.4 and Node 26:

```sh
swift build --package-path native/macos --build-tests
swift test --package-path native/macos --skip-build
ROACHNET_NATIVE_API_BINARY="$PWD/native/macos/.build/debug/roachnet-runtime" \
  node --test scripts/tests/*.test.mjs
```
