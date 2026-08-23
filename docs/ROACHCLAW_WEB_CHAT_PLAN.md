# RoachClaw Web Chat Plan

## Goal

Ship a RoachClaw chat surface that feels native to RoachNet, stays open-source friendly, and does not split the AI lane across three different state models.

The web lane should read the same contained RoachClaw profile that the desktop app and companion app already use:

- workspace root
- state dir
- pinned endpoints
- preferred model
- contained vs configured launch lane

## Reference Pattern

Portable-AI-USB shows the useful part of a portable AI product:

- one obvious runtime root
- one obvious chat workspace
- one obvious launcher contract
- offline-first behavior after first bootstrap

RoachNet should keep that discipline, but use RoachNet surfaces instead of a generic portable launcher.

Reference:
- [Portable-AI-USB](https://github.com/jarvesusaram99/Portable-AI-USB)

## Recommended Shape

### Phase 1

Ship `roachnet.org/roachclaw` as a public product page plus a paired web chat client.

The page should:

- explain what RoachClaw is
- show runtime status language that matches the desktop app
- offer a paired web chat for users who already have a desktop install
- avoid promising anonymous public inference

The actual chat should talk to a paired RoachNet desktop runtime, not to a shared hosted model.

### Phase 2

If the web chat grows faster than the marketing site, split it into its own deploy target:

- `claw.roachnet.org`
- or a second Netlify site, the same way `apps.roachnet.org` was separated

Keep `roachnet.org/roachclaw` as the branded entry page either way.

## Why Pairing First

The safest first version is not a public chatbot. It is a remote face on top of the user's own RoachNet runtime.

That keeps:

- chat history local-first
- RoachBrain context local-first
- model choice local-first
- RoachTail as the secure transport story

It also avoids turning RoachClaw into a hosted inference bill.

## Runtime Contract

The web chat should depend on the RoachClaw portable profile, not on guessed paths.

Required profile fields:

- `profilePath`
- `portableRoot`
- `workspacePath`
- `stateDir`
- `defaultModel`
- `preferredMode`
- `providerEndpoints`
- `runtimeHints`

That lets the desktop app, iOS companion, and web client all describe the same AI lane.

## Transport Options

### Option A: Paired desktop relay

Recommended first ship.

Flow:

1. User opens `roachnet.org/roachclaw`
2. User signs in with a short-lived paired session token or RoachTail session
3. Web UI calls the paired desktop bridge
4. Desktop bridge calls the same local RoachClaw / Ollama / RoachBrain surfaces already used by native clients

Pros:

- cheapest
- local-first
- keeps the user's model on the user's machine
- easy to explain

Cons:

- desktop must be online for full remote chat

### Option B: Browser-only fallback

Useful later, but not the first ship.

Possible forms:

- limited WASM model in-browser
- cached RoachBrain-only search lane
- prompt drafting without execution until the desktop reconnects

Pros:

- works without paired desktop uptime

Cons:

- lower model quality
- more browser complexity
- separate runtime constraints

## Proposed Web Surface

### Routes

- `roachnet.org/roachclaw`
  - product page
  - quick status explainer
  - install/download CTA
  - paired chat CTA
- `roachnet.org/roachclaw/chat`
  - paired web chat UI
  - session list
  - model badge
  - runtime badge
  - RoachBrain context indicators

### UI Tone

Match the apps store and main site:

- dark RoachNet shell
- sparse copy
- strong action buttons
- clear runtime badges
- no generic SaaS assistant look

## API Shape

The web chat should sit on top of narrow companion-safe endpoints instead of calling the full admin surface directly.

Recommended additions:

- `GET /api/companion/bootstrap`
- `GET /api/companion/runtime`
- `GET /api/companion/chat/sessions`
- `GET /api/companion/chat/sessions/:id`
- `POST /api/companion/chat/sessions`
- `POST /api/companion/chat/send`

Potential RoachClaw-specific additions:

- `GET /api/companion/roachclaw/profile`
- `GET /api/companion/roachclaw/models`
- `POST /api/companion/roachclaw/model`

These should stay read-mostly unless the paired device token is trusted for mutation.

## Auth

Use the existing companion / RoachTail pairing story, not a separate account system.

Recommended:

- short-lived join or session token
- peer-scoped device permissions
- read-only mode first
- explicit elevation before model or service mutation

## Offline Story

The web surface should degrade in steps:

1. Paired desktop online:
   - full chat
   - full session history
   - full install and model controls
2. Paired desktop offline, browser online:
   - show cached sessions metadata
   - show runtime unavailable state
   - allow queued draft prompts
3. Browser offline:
   - show cached shell
   - show last-known runtime state
   - allow draft capture only

## First Build Checklist

- expose portable RoachClaw profile through status
- make companion runtime payload include that profile
- build `roachnet.org/roachclaw` product page
- build paired chat shell against companion endpoints
- add clear runtime badges: local, paired, offline
- keep RoachBrain context and install intents visible in the web UI

## Later Work

- browser-safe markdown rendering for chat
- attachment upload lane
- remote install-from-app-store handoff from within chat
- RoachBrain search panel
- model switcher
- RoachTail peer picker
