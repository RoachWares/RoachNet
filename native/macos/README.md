# RoachNet Native macOS Scaffold

This package is the first concrete step away from the transitional Electron shell.

Targets:

- `RoachNetSetup`
  Native SwiftUI installer/setup application for macOS Apple Silicon.
- `RoachNetApp`
  Native SwiftUI main application shell for macOS Apple Silicon.
- `RoachNetDesign`
  Shared design system primitives, colors, surfaces, and small reusable UI pieces.

Build locally:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build --package-path native/macos
```

Build native macOS app bundles:

```bash
node scripts/build-native-macos-apps.mjs
```

Bundle output:

- `native/macos/dist/RoachNet Setup.app`
- `native/macos/dist/RoachNet.app`
- `native/macos/dist/RoachNet-Setup-macOS.dmg`

Signing and Gatekeeper:

- Local builds are now ad-hoc signed so the app bundles have a valid signature structure instead of stale/invalid metadata.
- To ship a Gatekeeper-safe internet download, the GitHub `Native Packages` workflow expects these repository secrets:
  - `APPLE_DEVELOPER_ID_APP_CERT_BASE64`
  - `APPLE_DEVELOPER_ID_APP_CERT_PASSWORD`
  - `APPLE_DEVELOPER_ID_APP_IDENTITY`
  - `APPLE_NOTARY_APPLE_ID`
  - `APPLE_NOTARY_APP_PASSWORD`
  - `APPLE_NOTARY_TEAM_ID`
- When those secrets are present, `scripts/build-native-macos-apps.mjs` signs with Developer ID and the workflow notarizes plus staples the macOS artifacts.

This scaffold is intentionally focused on:

- window structure
- installer flow shape
- shared RoachNet design language
- native navigation patterns

It is not the full application replacement yet.
