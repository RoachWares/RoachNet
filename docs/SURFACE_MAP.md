# Settings, Onboarding, And Ollama Surface Map

This map captures the current surfaces before the first OpenClaw integration layer.

## Verified Route Status

Working locally:

- `GET /api/health`
- `GET /home`
- `GET /easy-setup`
- `GET /settings/system`
- `GET /api/ollama/models`
- `GET /api/system/ai/providers`

Working with a local Ollama daemon available on `127.0.0.1:11434`:

- `GET /chat`
- `GET /settings/models`
- `GET /api/ollama/installed-models`

Still coupled to service-install assumptions:

- `/easy-setup`

## Settings Surfaces

### `/settings/apps`

- Route: `admin/start/routes.ts`
- Controller: `admin/app/controllers/settings_controller.ts`
- Page: `admin/inertia/pages/settings/apps.tsx`
- Backend dependency: `SystemService.getServices({ installedOnly: false })`
- Current behavior: Works locally, but service state is still derived from the Docker-oriented services table plus Docker status sync

### `/settings/system`

- Route: `admin/start/routes.ts`
- Controller: `admin/app/controllers/settings_controller.ts`
- Page: `admin/inertia/pages/settings/system.tsx`
- Backend dependency: `SystemService.getSystemInfo()`
- Current behavior: Works locally. Docker enrichment is optional and safely skipped when Docker is absent

### `/settings/models`

- Route: `admin/start/routes.ts`
- Controller: `admin/app/controllers/settings_controller.ts`
- Page: `admin/inertia/pages/settings/models.tsx`
- Backend dependency:
  - `OllamaService.getAvailableModels(...)`
  - `OllamaService.getModels()`
  - `KVStore` settings `chat.suggestionsEnabled` and `ai.assistantCustomName`
- Current behavior:
  - remote model catalog is fine
  - installed-model lookup now resolves Ollama through runtime discovery in this order: `OLLAMA_BASE_URL`, local `127.0.0.1:11434`, then Docker-managed Ollama
  - page renders even when no local runtime is available, instead of throwing a `500`
- OpenClaw implication: this is the primary settings page to generalize into an AI runtime/settings hub

### Settings Navigation Gating

- Layout: `admin/inertia/layouts/SettingsLayout.tsx`
- Hook: `admin/inertia/hooks/useAIRuntimeStatus.tsx`
- Current behavior: the AI settings nav item appears when `/api/system/ai/providers` reports an available Ollama runtime
- OpenClaw implication: provider availability must be decoupled from Docker-installed service state or the UI will hide valid local runtimes

## Onboarding Surfaces

### `/easy-setup`

- Route: `admin/start/routes.ts`
- Controller: `admin/app/controllers/easy_setup_controller.ts`
- Page: `admin/inertia/pages/easy-setup/index.tsx`

Current AI-related behavior:

- the AI capability is hardcoded to `SERVICE_NAMES.OLLAMA`
- recommended models come from `api.getAvailableModels({ recommendedOnly: true })`
- finish step installs selected services through `/api/system/services/install`
- selected AI models are queued through `/api/ollama/models`
- review logic treats AI as a service install plus model downloads

Key integration seam:

- `buildCoreCapabilities()` in `admin/inertia/pages/easy-setup/index.tsx`
- `handleFinish()` in `admin/inertia/pages/easy-setup/index.tsx`

OpenClaw implication:

- the wizard needs to move from "install this Docker service" to "configure this runtime/provider"
- Ollama and OpenClaw should become selectable runtime backends, not just one hardcoded service

## Ollama Surfaces

### API Routes

Defined in `admin/start/routes.ts`:

- `POST /api/ollama/chat`
- `GET /api/ollama/models`
- `POST /api/ollama/models`
- `DELETE /api/ollama/models`
- `GET /api/ollama/installed-models`

### Controller

- File: `admin/app/controllers/ollama_controller.ts`
- Responsibilities:
  - available model catalog
  - chat and streaming chat
  - model download queueing
  - installed model listing
  - query rewriting + RAG context injection

### Runtime Service

- File: `admin/app/services/ollama_service.ts`
- Current behavior:
  - local runtime client initialization now checks `OLLAMA_BASE_URL`, then `http://127.0.0.1:11434`, then Docker-managed Ollama
  - available model catalog uses a remote API fallback and therefore works without a local Ollama runtime
  - installed model, chat, delete, and thinking-capability checks all require the local runtime client

### AI Runtime Status Surface

- Route: `GET /api/system/ai/providers`
- Controller: `admin/app/controllers/system_controller.ts`
- Service: `admin/app/services/ai_runtime_service.ts`
- Current behavior:
  - backend and frontend can now ask for provider availability without pretending that every AI runtime is a Docker-managed service
  - current response shape already supports adding more providers later

### Chat Entry Surface

- File: `admin/app/controllers/chats_controller.ts`
- Route: `GET /chat`
- Current behavior:
  - route is gated by AI runtime availability instead of Docker install state
  - local Ollama is enough to open chat

### App Navigation Gating

- File: `admin/inertia/layouts/AppLayout.tsx`
- Hook: `admin/inertia/hooks/useAIRuntimeStatus.tsx`
- Current behavior:
  - floating chat UI appears when the AI runtime status API reports Ollama as available

## RAG Coupling

- File: `admin/app/services/rag_service.ts`
- Current behavior:
  - Qdrant URL is resolved through `DockerService.getServiceURL(SERVICE_NAMES.QDRANT)`
  - embeddings rely on the Ollama runtime
  - chat controller query rewriting and context injection both depend on this service

OpenClaw implication:

- OpenClaw work should not start inside the RAG layer
- first introduce a runtime/provider abstraction, then rewire Ollama and OpenClaw through it, then revisit RAG

## First OpenClaw Cut

The lowest-risk next cut is:

1. Extend `/easy-setup` from service installation into provider onboarding.
2. Add OpenClaw as a second provider in the new AI runtime status layer.
3. Move model/provider configuration into a shared AI settings surface instead of provider-specific assumptions.
4. Leave RAG and Qdrant on the existing path until Ollama/OpenClaw runtime selection is stable.
