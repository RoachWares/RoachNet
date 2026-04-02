# RoachNet Secrets Architecture

## Goals

- Keep RoachNet portable: install once, move machines, no silent data loss.
- Stop treating plaintext `.env` files as the system of record for secrets.
- Support the macOS-native app first, with the local runtime as an implementation detail.
- Reduce AI-agent secret exposure by keeping long-lived secrets out of the repo and out of workspace-adjacent plaintext files.
- Keep offline/local-first behavior where possible, while still supporting hosted services on `roachnet.org`.

## Principles

- The native app owns user-scoped secrets.
- The local runtime receives secrets through explicit injection, not by reading repo-local developer `.env` files.
- Production secrets live in a centralized manager, not in GitHub, Netlify build logs, or committed files.
- Machine-local bootstrap secrets should be rotated and revocable.
- Non-secret configuration and secret material must be separated.

## Secret Classes

### 1. Device-local secrets

Examples:

- Local runtime app key
- Local service enrollment tokens
- Optional imported Ollama/OpenClaw credentials or paths
- RoachClaw cloud model/provider tokens if the user enables them

Storage:

- macOS Keychain only

Owner:

- `RoachNet.app`

Rules:

- Never write these to `admin/.env`
- Never place them in the RoachNet vault as plaintext
- Export/import must be explicit and user-approved

### 2. Local runtime bootstrap secrets

Examples:

- Managed MySQL password
- Managed Redis auth if enabled later
- Runtime-side service API keys for optional cloud providers

Storage:

- Generated and stored in Keychain by the native app
- Injected into the staged runtime `.env` at launch time

Owner:

- Native launcher / managed runtime bootstrap

Rules:

- The staged runtime `.env` is disposable
- The repo checkout is never the canonical location for these values
- Rotating the bootstrap set should be possible from the native settings UI

### 3. User content-provider secrets

Examples:

- Optional cloud LLM keys
- Optional upstream sync tokens
- Future Tailscale auth or device enrollment tokens

Storage:

- Keychain on device
- Optional encrypted RoachNet export bundle for migration between machines

Rules:

- Default to local-only mode with no remote secret required
- Imported remote credentials must be individually revocable

### 4. Build/deploy secrets

Examples:

- Netlify environment variables
- GitHub release/deploy credentials
- roachnet.org upstream mirror sync credentials
- App Store manifest signing keys

Storage:

- Infisical project/environment as source of truth
- Netlify shared environment variables for deploy-time injection
- GitHub Actions obtains short-lived secrets through Infisical or OIDC-backed broker flow

Rules:

- Do not duplicate the same secret across ad-hoc GitHub repository secrets unless unavoidable
- Production deploys should consume environment-specific injected values

## Concrete Design

## A. Native macOS app

Use Keychain for:

- `roachnet.runtime.app_key`
- `roachnet.runtime.db_password`
- `roachnet.runtime.redis_password` if/when enabled
- `roachnet.ai.ollama.imported_path`
- `roachnet.ai.openclaw.imported_path`
- `roachnet.ai.cloud.*`
- `roachnet.user.tailscale.*` if that feature lands

Implementation notes:

- Add a small Swift Keychain wrapper in the native layer
- The setup app generates missing local runtime secrets on first install
- “Move RoachNet to another machine” should export an encrypted bundle, not raw secret values

## B. Local runtime

Current problem:

- The runtime still reads too much from `admin/.env`

Target:

- `scripts/run-roachnet.mjs` builds a disposable staged runtime env from:
  - Keychain-derived secrets provided by the native host
  - non-secret runtime config
  - managed local support-service values

Rules:

- `admin/.env` remains development-only and non-authoritative
- The staged `.env` inside `/tmp/roachnet-runtime-cache/...` is ephemeral
- Local runtime support credentials must be generated per install, not hard-coded long term

## C. Developer workflow

Replace repo-local secret handling with:

- `.env.example` for names only, no real values
- `.env.local` only for temporary local development fallback
- Infisical CLI as the preferred development sync/inject path

Recommended developer flow:

1. `infisical login`
2. `infisical pull --env=dev` for local non-production work, or
3. `infisical run --env=dev -- node scripts/run-roachnet.mjs`

Rules:

- `.env`, `.env.local`, and generated runtime env files stay gitignored
- AI agents should be pointed at redacted config docs, not raw secret files
- Any command that needs secrets should prefer `infisical run -- ...`

## D. Netlify / roachnet.org

Use Netlify for:

- Public app-store/catalog manifests
- roachnet.org deploy-time env injection
- Shared environment variables across previews and production as appropriate

Source of truth:

- Infisical project for `roachnet.org`

Deployment model:

- Infisical stores canonical values
- Netlify receives environment-specific synced values
- Large content mirror credentials should not live in the website repo

## E. GitHub Actions / releases

Use:

- Infisical as canonical secret manager
- OIDC or short-lived injected credentials for release pipelines when possible

Release pipeline responsibilities:

- Build/sign/package DMG artifacts
- Publish GitHub release
- Push website metadata/screen manifests
- Update App Store content manifests

Rules:

- Avoid static long-lived GitHub secrets when a short-lived broker flow is possible
- Never commit release tokens to workflow files or repo-local config

## F. App Store / upstream mirror

For the future `roachnet.org/app-store`:

- Keep the catalog manifest public
- Keep mirror sync credentials private in Infisical
- Use object storage behind `roachnet.org` URLs for downloadable artifacts
- Sync upstream content in the background; users download from the RoachNet mirror first

Secret domains:

- `app-store/sync`
- `app-store/storage`
- `app-store/signing`

## Migration Plan

### Phase 1

- Keep current launcher behavior, but stop relying on repo `.env` for managed runtime secrets
- Move local runtime bootstrap secrets into Keychain + staged env injection
- Add this architecture doc to the repo

### Phase 2

- Add Infisical project layout:
  - `roachnet-dev`
  - `roachnet-staging`
  - `roachnet-prod`
  - `roachnet-site`
- Add CLI-based developer bootstrap
- Add Netlify + GitHub pipeline integration

### Phase 3

- Add native export/import of encrypted RoachNet install state
- Add secret rotation UI in the native app
- Add per-feature secret scopes for cloud AI, upstream sync, and future tailnet features

## Immediate Implementation Work

- Remove hard-coded managed runtime credentials from `scripts/run-roachnet.mjs`
- Generate and persist managed runtime bootstrap secrets in macOS Keychain
- Pass those values into the staged runtime env on launch
- Keep `admin/.env` as dev-only fallback, not runtime truth
- Add Infisical project bootstrap docs for developers and deploy pipelines
