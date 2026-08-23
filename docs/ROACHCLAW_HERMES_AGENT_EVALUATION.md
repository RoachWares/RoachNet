# RoachClaw Hermes Agent Evaluation

Release gate: RoachClaw cannot ship a public build that treats OpenClaw as the only long-term agent lane. Hermes Agent is tracked as a design reference only. It is not a runtime dependency, not vendored code, and not something RoachNet fetches during release validation.

## Upstream

- Project: https://github.com/NousResearch/hermes-agent
- Docs: https://hermes-agent.nousresearch.com/docs/
- Reviewed upstream release: `v2026.5.16`
- Reviewed upstream HEAD: `dffb602f37b3c1b9c9fd7f0417aab3af56cffa38`

Latest reviewed upstream delta: `fix(xai): drop stale X Premium+ hint from entitlement 403 surfacing (#27110)`. This reinforces a RoachClaw rule: provider-specific errors belong in explicit adapters, not scattered through the agent loop.

Hermes Agent is a local-first AI agent framework with persistent memory, provider routing, skill/procedure support, terminal and editor workflows, browser automation hooks, messaging gateways, scheduled automations, and a security model around command approval and tool guardrails. RoachClaw should recreate the useful shape natively inside RoachNet instead of relying on Hermes upstream.

The current upstream project version is `0.14.0`. Its core Python dependency set is exact-pinned, while provider-specific, messaging, voice, web, ACP, MCP, and sandbox backends live behind optional extras. That fits RoachNet's release goal: keep the default lane small, then hydrate heavier agent capabilities only when the user turns them on.

## What RoachClaw Should Borrow

- Profiles: isolate memory, configuration, and tool permissions per user/project/game/vault.
- Skills: treat repeatable procedures as versioned local playbooks instead of hidden prompts.
- Provider abstraction: keep Ollama, LM Studio, remote providers, and future Hermes runtimes behind one RoachClaw provider contract.
- Security gateway: every shell, file, browser, and app-control action must pass through explicit allow/deny rules and approval state.
- ACP bridge: Hermes already exposes an Agent Client Protocol surface. RoachClaw can use that shape for Dev workspace and command-bar agent sessions instead of inventing another one-off bridge.
- Tool-loop guardrails: Hermes tracks repeated failures and no-progress tool loops. RoachClaw should adopt the same class of circuit breaker before allowing autonomous Dev, Vault, or installer repairs.
- Migration workflow: preserve OpenClaw workspaces, skills, and model preferences while adding a Hermes-compatible runtime lane.

## Native Rewrite Assessment

Hermes Agent is no longer a candidate runtime dependency. RoachClaw should replace OpenClaw with a RoachNet-owned native agent spine. OpenClaw remains deferred and optional while RoachClaw defaults to the contained Ollama lane and the first-party `roachclaw-native-agent` packet builder.

The safe path:

1. Keep `scripts/lib/roachnet_roachclaw_agent.mjs` as the owned runtime spine for permissions, skills, budgets, and prompt packets.
2. Store RoachClaw work under `storage/RoachClaw` and RoachBrain memory under the existing storage root.
3. Map RoachClaw permissions to explicit allowed/blocked command policy before shell, file, browser, network, installer, or destructive work.
4. Import OpenClaw skills into RoachClaw-native skills rather than exporting Hermes-compatible procedures.
5. Route Dev sessions through a RoachNet-native ACP-style contract so RoachClaw can stream tool calls, diffs, approvals, and command output into the native UI.
6. Add parity tests for chat, tool approval, file edits, project context, local memory, skill import, and fresh-install hydration.
7. Only remove OpenClaw fallback after the RoachClaw native agent passes those tests on a fresh install and on an upgraded install.

## RoachNet Fit

RoachNet needs one agent spine that can see the app with permission: Dev, Vault, RoachArcade, media, maps, settings, and installer state. Hermes Agent's profile and skill model fits that better than a one-off CLI wrapper.

The design target is not more chat. It is local agent work tied to visible app state:

- RoachArcade: explain running games, mods, controller mapping, emulator config, and cheat files.
- Vault: search local notes/books/media and produce citations from files on disk.
- Dev: edit projects with command approval, terminal context, and rollback-visible diffs.
- Installer/runtime: inspect logs, diagnose failed dependencies, and repair local state without phoning home.

## Release Rule

Before a public release:

- `docs/release-gates/runtime-freshness.json` must point at the RoachClaw native agent module and the reviewed Hermes reference HEAD.
- `scripts/audit-runtime-freshness.mjs` must prove Hermes is design-reference-only and that RoachNet does not vendor or poll Hermes as a runtime dependency.
- Any RoachClaw native-agent integration must be additive until it has feature parity with the existing RoachClaw/OpenClaw behavior.
- OpenClaw can remain deferred, but the pinned package metadata must track the latest npm package so first-run hydration never installs stale agent code.
