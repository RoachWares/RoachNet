# RoachNet Secrets Architecture

## Goal

RoachNet needs one secrets model that works across:

- the native macOS app
- the contained local runtime
- GitHub Actions release automation
- Netlify-hosted website surfaces

The system should stop treating `.env` files as the source of truth for sensitive values while still letting the app run offline and move cleanly between machines.

## Design

### 1. Native app secrets

The native app is the local source of truth for user-owned secrets.

- Secret values are stored in macOS Keychain.
- Secret metadata stays inside the RoachNet vault under the install storage root.
- Metadata includes:
  - display label
  - stable secret key
  - environment variable name
  - scope
  - notes
  - timestamps

Current vault path shape:

- `storage/vault/projects`
- `storage/vault/secrets/manifest.json`

Current Keychain service shape:

- `com.roachnet.secret.<install-derived-suffix>`

This split keeps actual secret bytes off disk while keeping the vault portable enough to preserve structure and references.

### 2. Non-secret local config

Non-secret installation and routing settings stay in:

- `~/Library/Application Support/roachnet/roachnet-installer.json`

This file is still appropriate for:

- install path
- storage path
- runtime preferences
- preferred distributed inference backend
- release channel

It is not the place for API keys, tokens, or provider secrets.

### 3. Runtime injection

The contained runtime should consume secrets through generated environment injection, not through a hand-maintained checked-in `.env`.

Planned runtime contract:

- RoachNet reads Keychain-backed secrets from the native vault.
- RoachNet materializes a runtime env map in memory at launch.
- `scripts/run-roachnet.mjs` and the native runtime bridge pass only the needed values into spawned services.
- The shipped `admin/.env` becomes a compatibility/bootstrap file, not a secrets database.

That keeps:

- local-first startup
- offline usability
- lower AI-agent exposure
- less secret sprawl across cloned repos

Current v1.30.7 runtime behavior:

- `scripts/run-roachnet.mjs` now creates a local-only managed runtime secret file under the runtime-state root.
- The tracked compose file and generated setup compose file interpolate `APP_KEY`, `DB_PASSWORD`, and `ROACHNET_DB_ROOT_PASSWORD` from the launch environment instead of hardcoding them.
- The compiled native runtime consumes those generated values at launch time, while `admin/.env` remains a compatibility input for non-secret defaults and legacy flows.

Managed runtime secret state is local only:

- `~/Library/Application Support/roachnet/runtime-state/roachnet-managed-runtime-secrets.json` on macOS native installs

That file should not be committed, mirrored into the public website, or copied into release assets.

### 4. CI/CD secrets

GitHub Actions remains the source of truth for release/build secrets.

Use GitHub repository secrets for:

- Apple signing certificate data
- notarization credentials
- release tokens or other CI-only credentials

Those should never be copied into the local RoachNet vault automatically.

### 5. Netlify secrets

Netlify remains the source of truth for website/runtime secrets that only matter in hosted deployment.

Use Netlify environment variables for:

- website API tokens
- build-time deployment secrets
- server-side integration credentials

The public website must never assume access to local machine secrets.

## Portability model

RoachNet should preserve this distinction:

- portable:
  - project folders
  - secret metadata
  - runtime preferences
  - content downloads
  - local workspace structure
- machine-bound by default:
  - Keychain secret values

That is intentional. Raw secret values should not silently travel with copied app folders.

Future portability upgrade:

- encrypted secret export/import with a user passphrase
- optional sync bridge to Infisical or another hosted/open-source secret manager

## v1.30.7 implementation slice

This slice adds:

- native developer workspace paths inside the RoachNet vault
- native secret metadata manifest
- Keychain-backed secret storage
- native Dev pane with a secrets surface
- local-only managed runtime secret generation for contained MySQL/App key injection
- compose placeholder interpolation so tracked files stop carrying live runtime credentials

This slice does not yet:

- rewrite the entire admin runtime away from env-file compatibility
- add encrypted secret export/import
- add hosted secret sync
- inject all runtime secrets from the native vault automatically

## Files

Primary implementation files:

- `/Users/roach/DEVPROJECTS/RoachNet/native/macos/Sources/RoachNetCore/RoachNetDeveloperSupport.swift`
- `/Users/roach/DEVPROJECTS/RoachNet/native/macos/Sources/RoachNetCore/RuntimeModels.swift`
- `/Users/roach/DEVPROJECTS/RoachNet/native/macos/Sources/RoachNetCore/ManagedAppRuntime.swift`
- `/Users/roach/DEVPROJECTS/RoachNet/native/macos/Sources/RoachNetApp/DevWorkspaceView.swift`
- `/Users/roach/DEVPROJECTS/RoachNet/scripts/run-roachnet.mjs`

Operational secret owners:

- local app user: Keychain + RoachNet vault metadata
- CI/CD: GitHub repository secrets
- website hosting: Netlify environment variables
