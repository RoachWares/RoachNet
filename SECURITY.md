# Security

## Reporting a problem

Please don't report security problems in a public issue. Email **contact@roachwares.org** with "Security" in the subject. Include:

- what you found and how to reproduce it;
- the RoachNet version (shown in About) and your macOS version;
- for the iOS companion, its version too.

Leave out personal data, tokens and Vault contents. If a log helps, redact it first.

Fixes ship in a normal release, and the release notes say what was fixed. RoachWares is a small company: there's no bug bounty and no fixed response time.

## Supported versions

Only the latest release gets security fixes. Upgrade to it before reporting, if you can.

| Version | Fixes |
| --- | --- |
| 1.1.x (macOS), 0.3.x (iOS) | Yes |
| Anything older | No: please upgrade |

## What's in scope

- The RoachNet app, RoachNet Setup and `roachnet-runtime`, including:
  - the loopback API and the model server;
  - RoachTail, RoachNet Cluster and the Vault;
  - packs and their installer.
- The iOS companion.
- roachnet.org, apps.roachnet.org and accounts.roachnet.org, and the RoachNet account service behind them.
- The release artifacts and the Homebrew cask.

How the app protects your data, and where it can't, is described in:

- the release notes' Security section ([1.1.0](docs/releases/1.1.0.md));
- [`docs/CLUSTER.md`](docs/CLUSTER.md);
- [`docs/VAULT_ENCRYPTION.md`](docs/VAULT_ENCRYPTION.md), for 1.1.1, not released yet.
