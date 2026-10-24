<p align="center">
  <img src="https://roachnet.org/assets/readme/roachnet.png" width="100%" alt="RoachNet, offline on purpose: local AI, code, maps, media, games and your vault in one native Mac app.">
</p>

# RoachNet

Local AI, code, maps, media, games and your vault in one native Mac app. Models, archives, notes and code stay on your Mac, in one folder: `~/RoachNet`. The internet is a bonus round, not a requirement.

**RoachNet 1.1.2** · Apple Silicon, macOS 14 or later · [Download](https://github.com/RoachWares/RoachNet/releases/latest) · [Docs](https://roachnet.org/docs/) · [roachnet.org](https://roachnet.org/)

## A quick tour

<table>
  <tr>
    <td width="50%"><img src="https://roachnet.org/assets/screens/roachnet-native-home.webp" alt="RoachNet's Home pane"></td>
    <td width="50%"><img src="https://roachnet.org/assets/screens/roachnet-native-roachclaw.webp" alt="RoachClaw, the local AI workbench"></td>
  </tr>
  <tr>
    <td><b>Home</b>, the command grid: start a chat or a project, open a map or browse the Vault.</td>
    <td><b>RoachClaw</b>: chat with models that run on your Mac's GPU, with no Ollama inside.</td>
  </tr>
  <tr>
    <td><img src="https://roachnet.org/assets/screens/roachnet-native-dev.webp" alt="Dev Studio, the IDE workspace"></td>
    <td><img src="https://roachnet.org/assets/screens/roachnet-native-vault.webp" alt="The Vault, your library offline"></td>
  </tr>
  <tr>
    <td><b>Dev</b>, the native coding workspace. RoachBrain remembers the project, and RoachClaw pairs with you.</td>
    <td><b>Vault</b>, your library, offline: notes, courses, books, saved web pages and anything you install from RoachNet Apps.</td>
  </tr>
  <tr>
    <td colspan="2"><img src="https://roachnet.org/assets/screens/roachnet-native-runtime.webp" alt="Runtime, the engine room"></td>
  </tr>
  <tr>
    <td colspan="2"><b>Runtime</b>, the engine room: what's running, what's downloading, and where a problem is hiding.</td>
  </tr>
</table>

## Install

1. Download `RoachNet-Setup-macOS.dmg` and its `.sha256` file from the [latest release](https://github.com/RoachWares/RoachNet/releases/latest). Keep them in the same folder.
2. Check the download. The command prints `OK` when the file matches.

   ```sh
   shasum -a 256 -c RoachNet-Setup-macOS.dmg.sha256
   ```

3. Open the disk image and run **RoachNet Setup**.

> [!NOTE]
> RoachNet is ad-hoc signed and not Apple-notarized. The first time, macOS says it can't verify RoachNet Setup: open **System Settings › Privacy & Security** and choose **Open Anyway**. It doesn't ask again. The hash check above is what stands in for notarization.

Setup puts the app in `~/RoachNet/app` and your data in `~/RoachNet/storage`. It installs nothing else: no Node, no Docker, no Ollama.

Prefer Homebrew? The cask installs the same release:

```sh
brew tap --force RoachWares/roachnet
brew install --cask roachnet
```

## What's in this repository

The source of the files in the RoachNet 1.1.2 release:

| Path | What it is |
| --- | --- |
| `native/macos` | The app, its runtime (`roachnet-runtime`), RoachInference and RoachNet Setup: a Swift package of the seven targets that ship |
| `collections` | The catalogs the app ships with: maps, models, packs and archives |
| `package.json` | The version and build number |

The repository changes with each release. Issues and pull requests are off; to report a problem, write to the address below.

## Help

- **Documentation:** [roachnet.org/docs](https://roachnet.org/docs/)
- **Something broken, or a security problem?** Email [support@roachwares.org](mailto:support@roachwares.org). For anything about security, please don't post it in public. [How to report](https://roachnet.org/docs/support/).

## License

Apache License 2.0. See [LICENSE](LICENSE).

---

<sub>Made by RoachWares LLC. RoachNet · offline on purpose.</sub>
