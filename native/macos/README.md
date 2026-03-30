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

This scaffold is intentionally focused on:

- window structure
- installer flow shape
- shared RoachNet design language
- native navigation patterns

It is not the full application replacement yet.
