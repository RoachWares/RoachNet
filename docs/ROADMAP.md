# RoachNet Roadmap

## Product Goal

RoachNet should let a user continue normal day-to-day operations entirely offline by combining local knowledge, local AI, offline utilities, and guided system management in one interface.

The imported base stack already covers offline content, maps, and Ollama-backed chat. RoachNet adds a stronger focus on local AI operator workflows, agent management, and a setup experience that explains itself clearly.

## Workstreams

### 1. Rebrand And Stabilize The Imported Base

- replace upstream naming, logos, and product copy where appropriate
- preserve upstream attribution and license details
- verify the imported app boots cleanly in the RoachNet repo before larger feature work

### 2. Add OpenClaw As A First-Class Runtime

- introduce an OpenClaw configuration model
- add service health checks, start/stop actions, and endpoint validation
- expose OpenClaw settings next to existing Ollama controls instead of burying them in a separate admin flow
- design provider abstractions so local and remote AI backends can be swapped cleanly

### 3. Build A Unified AI Settings Surface

- expand the existing settings area into a central AI configuration hub
- support Ollama model paths, host settings, concurrency, and model management
- support OpenClaw connector settings, local model bindings, and runtime diagnostics
- add clear explanations for every setting so non-expert users can still finish setup correctly

### 4. Extend The Onboarding Wizard

- keep the existing easy-setup flow, but broaden it into a full RoachNet onboarding process
- walk users through Ollama setup, OpenClaw setup, provider checks, and local storage choices
- explain defaults, risks, and tradeoffs during setup rather than hiding them in docs
- save partial progress so onboarding can be resumed offline after interruption

### 5. Add Agent And Skill Management

- create persistent records for agents, skills, prompts, and provider assignments
- allow users to register their own agents and skills from the UI
- validate configuration step-by-step instead of forcing direct file edits
- expose import and export paths for local backups and disaster recovery

### 6. Expand Offline Operations Coverage

- identify the highest-value offline tasks beyond content browsing and chat
- add tools that help a user operate during power, network, or service disruption
- prefer local processing and self-hosted dependencies wherever practical

### 7. Ship A Native Secrets Manager

- move runtime bootstrap secrets out of repo `.env` files and into native-managed secure storage
- use Keychain on macOS as the canonical device-local secret store
- adopt Infisical as the canonical hosted secret manager for Netlify, GitHub releases, and site infrastructure
- make secret export, import, and rotation explicit user actions instead of hidden file copying

### 8. Build The RoachNet App Store Mirror

- stop relying on upstream content availability during end-user installs
- host public catalog manifests on `roachnet.org`
- mirror large downloadable content into RoachNet-controlled object storage behind first-party URLs
- keep upstream sync credentials and signing material outside the repo in the hosted secrets manager

### 9. Add A Native Development Workspace

- ship a RoachNet-owned terminal surface inspired by Ghostty, not a handoff to an external app
- add a RoachNet code editor for projects stored in the user vault instead of embedding or launching VS Code directly
- expose AI-assisted coding flows inside that editor surface using the same RoachClaw/runtime model-routing stack
- keep the development workspace optional and sandboxed from the main offline/content experience

## First Technical Targets

Start with these files and surfaces:

- `admin/start/routes.ts`
- `admin/app/controllers/settings_controller.ts`
- `admin/app/controllers/easy_setup_controller.ts`
- `admin/app/controllers/ollama_controller.ts`
- `admin/app/services/ollama_service.ts`
- `admin/inertia/pages/settings/models.tsx`
- `admin/inertia/pages/easy-setup/index.tsx`

## Near-Term Delivery Order

1. Boot the imported base locally and document the dev workflow
2. Rebrand the top-level product copy and visible UI labels
3. Add an abstraction for multiple AI providers
4. Ship the first OpenClaw settings and health-check flow
5. Extend onboarding to cover provider setup and validation
6. Build the first user-manageable agent and skill screens
7. Move runtime secrets into native-managed secure storage
8. Bring up the first RoachNet-controlled App Store mirror path
9. Ship the first native development workspace surfaces
