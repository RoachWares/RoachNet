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
ROACHNET_CANDIDATE_BUILD=1 node scripts/build-native-macos-apps.mjs
```

This is the credential-independent Gate C candidate path: it builds ad-hoc
signed local artifacts with the exact reviewed Node/Ollama runtime URLs and
SHA-256 pins. It does not notarize and is not public-release evidence. The
protected release workflow alone uses `ROACHNET_RELEASE_BUILD=1`, which remains
fail-closed on Developer ID, notarization, and DMG requirements.

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
- You can push those secrets into GitHub with one command once you have the certificate and notary credentials:

```bash
export APPLE_DEVELOPER_ID_APP_CERT_PATH="$HOME/Downloads/RoachNet-Developer-ID.p12"
export APPLE_DEVELOPER_ID_APP_CERT_PASSWORD="your-p12-export-password"
export APPLE_DEVELOPER_ID_APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_NOTARY_APPLE_ID="you@example.com"
export APPLE_NOTARY_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_NOTARY_TEAM_ID="TEAMID1234"
npm run release:apple-secrets
```

- If you already have the certificate as a base64 string, set `APPLE_DEVELOPER_ID_APP_CERT_BASE64` instead of `APPLE_DEVELOPER_ID_APP_CERT_PATH`.
- The App Store Connect password here is the Apple app-specific password used by `notarytool`.
- When those secrets are present, `scripts/build-native-macos-apps.mjs` signs with Developer ID and the workflow notarizes plus staples the macOS artifacts.

This scaffold is intentionally focused on:

- window structure
- installer flow shape
- shared RoachNet design language
- native navigation patterns

It is not the full application replacement yet.
