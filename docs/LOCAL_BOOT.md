# Local Boot

This is the verified macOS local-dev path used to boot the imported upstream base inside RoachNet on 2026-03-27.

## Runtime Choice

Use Node 26 for this repo.

- `@openzim/libzim` rejects Node 25 during install
- the native release lane uses Node 26
- the legacy admin/WebUI lane still uses Node 24 because `@openzim/libzim` rejects current Node majors
- cold `ace` startup is still slow, but it does complete
- Node 25 caused enough friction during bootstrap that it should not be treated as the default local runtime

The repo now includes a root `.nvmrc` with `26`.

## Prerequisites

Install the required local services with Homebrew:

```bash
brew install node mysql redis
brew services start mysql
brew services start redis
```

Optional but useful for later AI work:

```bash
brew install ollama
ollama serve
```

## Database Setup

Create the local database and app user:

```bash
mysql -u root -e "CREATE DATABASE IF NOT EXISTS roachnet; CREATE USER IF NOT EXISTS 'roachnet_user'@'localhost' IDENTIFIED BY 'roachnet_dev_password'; GRANT ALL PRIVILEGES ON roachnet.* TO 'roachnet_user'@'localhost'; FLUSH PRIVILEGES;"
```

Quick checks:

```bash
mysqladmin ping -u root
redis-cli ping
```

## Environment File

The upstream `admin/.env.example` was missing `URL`, even though startup validation requires it.

Create `admin/.env` with values like:

```dotenv
PORT=8080
HOST=localhost
URL=http://localhost:8080
LOG_LEVEL=info
APP_KEY=replace_with_a_random_32_plus_char_value
NODE_ENV=development
SESSION_DRIVER=cookie
DB_HOST=localhost
DB_PORT=3306
DB_USER=roachnet_user
DB_DATABASE=roachnet
DB_PASSWORD=roachnet_dev_password
DB_SSL=false
REDIS_HOST=localhost
REDIS_PORT=6379
OLLAMA_BASE_URL=http://127.0.0.1:11434
OPENCLAW_BASE_URL=http://127.0.0.1:3001
ROACHNET_STORAGE_PATH=/absolute/path/to/RoachNet/admin/storage
```

Create the storage directories:

```bash
mkdir -p admin/storage/logs admin/storage/kb_uploads admin/storage/zim admin/storage/maps/pmtiles admin/storage/maps/basemaps-assets
```

## Install And Boot

Use the Homebrew Node 24 toolchain explicitly for the legacy admin/WebUI lane:

```bash
cd /path/to/RoachNet/admin
PATH="/opt/homebrew/opt/node@24/bin:$PATH" npm ci
PATH="/opt/homebrew/opt/node@24/bin:$PATH" node ace migration:run
PATH="/opt/homebrew/opt/node@24/bin:$PATH" node ace db:seed
PATH="/opt/homebrew/opt/node@24/bin:$PATH" npm run dev
```

For the normal local RoachNet entry path from the repo root:

```bash
cd /path/to/RoachNet
npm start
```

The root launcher starts the dependency-free native API bridge. It binds to loopback, waits for `/api/health`, and opens no browser when `ROACHNET_NO_BROWSER=1` is set.

### RoachTail Native Control Plane

RoachTail now runs through the dependency-free native API instead of a legacy WebUI lane. The implementation is shaped after Headscale's control-plane model: the desktop keeps the node registry, expiring pre-auth key, approved routes, and relay map locally, while paired devices receive peer-scoped tokens instead of broad companion credentials.

- State lives at `~/RoachNet/storage/vault/roachtail/state.json`.
- The state schema is `org.roachnet.roachtail.control-plane.v1`.
- Peer tokens are only returned once during pairing; the stored state keeps SHA-256 token hashes.
- User vault content does not move through the control plane.
- A custom relay host can be advertised through `ROACHTAIL_RELAY_HOST` or the runtime's companion advertised URL.

Useful local endpoints:

```text
GET  /api/companion/roachtail
POST /api/companion/roachtail/pair
POST /api/companion/roachtail/affect
```

The iOS companion and local devices should pair through `/api/companion/roachtail/pair` with the current desktop join code, then use the returned `rtpeer_...` token for future RoachTail-scoped calls. Peer-scoped requests can remove their own peer record, but cannot clear the whole RoachTail state.

## Verified Local Status

The imported base boots locally with the configuration above.

Verified responses:

- `200 /api/health`
- `200 /home`
- `200 /easy-setup`
- `200 /settings/system`
- `200 /api/ollama/models`
- `200 /api/system/ai/providers`

With a local Ollama daemon running on `127.0.0.1:11434`:

- `200 /chat`
- `200 /settings/models`
- `200 /api/ollama/installed-models`

With an OpenClaw runtime configured through `OPENCLAW_BASE_URL` or the AI Control page:

- `200 /settings/ai`
- `200 /api/system/ai/providers`
- `providers.openclaw` reports reachability when the endpoint responds on `/health`, `/api/health`, or `/`
- when you containerize the admin app, set `OPENCLAW_WORKSPACE_PATH` to a volume-mounted path so the workspace survives redeploys

Remaining limitation:

- `/easy-setup` still treats AI as a Docker-style service install flow instead of a generic runtime/provider onboarding flow

See `docs/SURFACE_MAP.md` for the current integration seams that still need work.

## Cold Start Warning

The first `node ace ...` and `npm run dev` invocations are extremely slow on a cold boot.

Observed timings during verification:

- first successful `node ace migration:run`: about 2 minutes of startup overhead before migration output, then about 7 seconds of actual migration work
- first successful `node ace db:seed`: about 3 minutes of startup overhead
- first successful `npm run dev`: about 5.5 minutes before the dev server reported ready

This appears to be heavy module evaluation and file reads during cold Adonis/TypeScript startup, not a deadlock.
