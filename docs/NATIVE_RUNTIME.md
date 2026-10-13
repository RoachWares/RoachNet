# Native runtime (`roachnet-runtime`)

RoachNet ships no Node runtime (from 1.0.6) and, from 1.1.1, has no Node fallback or JavaScript runtime at all (ROA-78). Everything the bundled Node 26 runtime used to do runs in one native Swift helper, `roachnet-runtime`:

- the loopback API;
- the iOS companion bridge;
- RoachTail and RoachClaw state;
- downloads and the update mirror;
- the installer;
- the RoachInference model server (1.1).

The helper links only Apple system frameworks: Foundation, Dispatch, Darwin and CryptoKit, plus Compression (RoachNet's own ZIP reader inflates pack archives with it), Metal (RoachInference's kernels) and dnssd (the Cluster's Bonjour). On Linux it uses FoundationNetworking and Glibc for the source test lane. `Package.swift` declares no third-party packages, and `scripts/audit-native-release-scope.mjs` enforces both rules.

## Where it lives

| Location | What it is |
| --- | --- |
| `native/macos/Sources/RoachNetRuntime/` | Library: HTTP server/client, JSON, router, stores, RoachTail, RoachClaw, downloads, setup engine |
| `native/macos/Sources/RoachNetRuntimeHost/main.swift` | The `roachnet-runtime` executable (CLI modes below) |
| `RoachNet.app/Contents/Helpers/roachnet-runtime` | Packaged helper (arm64, system libraries only, verified by the packager) |
| `RoachNet.app/Contents/Resources/RoachNetRuntimeData/` | Catalog data (`collections/`) and `package.json` version metadata |
| `RoachNet Setup.app/Contents/Helpers/roachnet-runtime` | The same helper, used as the installer backend |

The helper finds its data folder relative to its real executable path, and resolves symlinks first. It therefore runs with no environment variables set, including when launched through a symlink such as a Homebrew `bin/` link.

## CLI modes

```
roachnet-runtime                     # start the runtime
roachnet-runtime --stop              # stop the runtime that owns ROACHNET_STORAGE_PATH
roachnet-runtime --setup             # RoachNet Setup backend on 127.0.0.1 (ROACHNET_SETUP_PORT, default ephemeral)
roachnet-runtime --install [--install-path P] [--storage-path P] [--no-roachclaw] [--launch] [--profile NAME] [--no-companion]
roachnet-runtime --provision-alias [--hosts-file F] [--interactive] [--print-command]
roachnet-runtime --version | --help
```

The runtime keeps the environment contract of the retired Node launcher:

- `HOST` and `PORT`;
- `ROACHNET_STORAGE_PATH`, `ROACHNET_RUNTIME_STATE_ROOT` and `ROACHNET_SERVER_INFO_FILE`;
- the `ROACHNET_COMPANION_*` settings;
- `OLLAMA_BASE_URL`.

`HOST` must be a loopback address. The companion bridge refuses to bind to anything else. `RoachNetCore.ManagedAppRuntime` launches only the helper; if it is missing, the app says to reinstall with RoachNet Setup rather than looking for anything else to run.

## Install workflow (Setup app, `--install`, Homebrew)

The Setup app, `roachnet-runtime --install` and the Homebrew cask all run the same phases. The percentage is the progress shown when each phase starts.

| Progress | Phase | What happens |
| --- | --- | --- |
| 5 | Inspecting system | Checks for Apple Silicon hardware (Rosetta-translated launches are detected), macOS 14 or later, free space (2 GiB, or 5 GiB with RoachClaw), a writable location that isn't installer media, and memory. Picks a RAM-aware RoachClaw starter model. |
| 12 | Validating | Stops if any required preflight check failed. |
| 24 | Staging | Creates `<root>.staging-<hex>` on the same volume as the target. |
| 38 | AI tooling | RoachClaw runs on the native RoachInference engine inside `roachnet-runtime`, so no separate model runner is installed (1.1). Upgrades drop a carried-forward `runtime/vendor/ollama`. Existing Ollama model folders are still imported in place. |
| 52 | Preparing | Writes `roachnet-install.json`. |
| 64 | Installing app | Copies `RoachNet.app` (from the folder or the `.zip` in InstallerAssets), clears quarantine, and ad-hoc signs it only if `codesign --verify` fails. |
| 76 | Verifying | Boots the staged app's helper against scratch storage and requires `/api/health` to answer. |
| 88 | Finalizing | Stops any running RoachNet, backs up and swaps the root, carries `storage/` across, and rolls back on failure. |
| 94 | RoachTail alias | Points `RoachNet` at loopback in `/etc/hosts`, with a one-time administrator prompt if needed. Best effort unless `ROACHNET_REQUIRE_LOCAL_ALIAS=1`. |
| 98 | Launching | Opens the app when auto-launch is on. |

During the swap, anything at the top of the old root that setup does not manage is carried into the new root. That covers the Homebrew-installed `setup/RoachNet Setup.app` and any files the user placed there.

The setup backend exits when the Setup app quits, but it finishes a running install first. If a run is force-killed, the next run removes its stale `.staging-*` folder. If the root itself had been moved aside, the next run also restores the `.backup-*` copy before continuing.

If any phase fails, the staging folder is removed and the previous install is left untouched. Set `ROACHNET_SETUP_KEEP_STAGED_FAILURE=1` to keep the staging folder for debugging. Log lines and error messages replace home paths with `~` and install paths with "RoachNet root".

## Building and testing

```
npm run runtime:build          # swift build -c release --product roachnet-runtime (macOS or Linux)
npm run test:native-runtime    # the contract suite (Node test runner) against the built helper
npm run native:test            # Swift XCTests (macOS; RoachNetRuntimeTests also run on Linux)
```

On Linux only the runtime targets build. The app targets sit behind `#if os(macOS)` in `Package.swift`. The contract tests use `ROACHNET_NATIVE_API_BINARY=<path to roachnet-runtime>`. `scripts/tests/roachnet-native-setup.test.mjs` exercises install, upgrade, rollback, the alias and headless installs against fake InstallerAssets. On a non-Apple host it needs the test-only override `ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST=1`.

## No Node, no JavaScript

There is no compatibility build any more: `ROACHNET_BUNDLE_NODE_COMPAT`, the embedded Node runtime and the bundled `RoachNetSource` tree are gone. `scripts/build-native-macos-apps.mjs` fails if either bundle holds a `node` binary, `node_modules`, a `.js`/`.mjs`/`.cjs`/`.node` file or RoachNet source, and the release-scope and runtime-freshness audits check the built apps for the same.

Node is still the toolchain for the scripts in `scripts/` (packaging, audits, contract tests). Moving those to Swift as well is tracked separately.

## Third-party runtimes

None ship. Since 1.1 the local model runner is RoachInference, inside `roachnet-runtime`; the bundled Ollama runner is retired (`docs/release-gates/runtime-freshness.json`). An Ollama or OpenClaw the person runs themselves stays optional.
