# Imported Source and Upstream Policy

Last verified: 2026-08-23

RoachNet contains code and documentation inherited from an imported open-source
base. The current native product has moved beyond that architecture, but its
license and attribution obligations remain part of the repository history and
release boundary.

## What is proven in this checkout

- `LICENSE` is Apache License 2.0.
- Its retained copyright notice names Crosstalk Solutions LLC for 2024–2026.
- The current clone has one configured remote:
  `https://github.com/RoachWares/RoachNet.git`.
- No separate imported-source remote is configured in this checkout.
- `admin/` (removed after v1.0.5) and `desktop/`, `installer/` and the
  Compose/management files (removed in 1.1.1) came from the imported
  web/container architecture; tags `v1.0.5` and `v1.1.0` keep them for
  reference.
- The public Apple Silicon product is owned by the native Swift package
  (both apps and `roachnet-runtime`) and the packaging scripts described in
  `DEVELOPMENT.md`. Nothing that ships runs Node.

The exact imported repository URL and baseline commit are not established by
current remote configuration. Do not invent them from naming similarities or
from a third-party project that happens to share features.

## Contributor rules

1. Keep the Apache 2.0 license and applicable copyright/attribution notices.
2. Do not remove or rewrite attribution as part of cleanup, rebranding, or
   source-boundary work without a repository-history and licensing review.
3. Do not configure or fetch an assumed upstream remote until its identity and
   baseline are verified from history or authoritative project records.
4. Treat retained web/Electron/container code as reference-only unless a task
   explicitly reassigns shipping ownership.
5. Prefer extracting behavior and tests into the native lane over reviving a
   second public desktop architecture.
6. Record the source URL, tag/commit, license, imported paths, and reason when
   introducing any new third-party source.
7. Keep upstream stable-release records in `docs/release-gates/` distinct from
   source ancestry. A dependency used for parity or bundled tooling is not
   automatically RoachNet's historical parent project.

## Before changing licensing or attribution

Verify all of the following:

```text
- repository history for the original import
- retained file headers and copyright notices
- LICENSE and any NOTICE file required by distributed dependencies
- bundled source and binary dependency licenses
- release archive contents
- public README, About/Credits UI, and source offer
```

If the historical imported-source identity is recovered, update this document
with the authoritative URL and baseline commit. Until then, preserve the
current license and state the provenance gap explicitly.
