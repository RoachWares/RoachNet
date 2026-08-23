# AnythingLLM Evaluation For RoachNet

Date: 2026-03-28

## Summary

AnythingLLM is worth learning from, but it should not become the primary shell or primary architecture for RoachNet.

RoachNet should adopt the strongest AnythingLLM ideas:

- workspace-oriented RAG and document chat
- MCP tool loading
- agent skill management
- desktop assistant / overlay interaction
- provider-agnostic local + cloud model plumbing

RoachNet should not adopt AnythingLLM wholesale as the base runtime because it conflicts with the current native-first rewrite.

## Why it is attractive

Current upstream AnythingLLM materials show:

- a desktop app for macOS, Windows, and Linux
- local-first operation
- Ollama support
- LM Studio support
- MCP compatibility
- custom agent skills
- agent flows and document pipelines
- a desktop assistant overlay

This maps well to the RoachNet direction:

- offline local AI
- OpenClaw integration
- skills and agents
- native installers and native desktop UX
- coding and operator workflows

## What does not fit RoachNet directly

AnythingLLM still centers on a frontend + server + collector architecture. Their own bare-metal guidance describes three main sections and calls non-container deployment a reference path rather than a supported one.

That matters because RoachNet is moving in the opposite direction:

- native desktop shell first
- local service/runtime control under our app
- RoachClaw as the combined Ollama + OpenClaw experience
- no dependence on a browser-loaded shell as the primary interface

If we embed AnythingLLM wholesale, we risk recreating the same web-first product shape we are actively removing.

## Recommended RoachNet position

Use AnythingLLM as a feature reference and optional compatibility target, not as the main product shell.

Recommended stance:

1. Keep RoachNet as the native application shell.
2. Keep RoachClaw as the primary local AI control plane.
3. Borrow AnythingLLM-grade capabilities into RoachNet natively.
4. Optionally support importing or linking AnythingLLM workspaces later.

## Best features to replicate

### 1. Workspace RAG

RoachNet should add native workspaces with:

- document ingestion
- embeddings selection
- vector store selection
- citations and source grounding
- per-workspace model/provider defaults

### 2. MCP tool management

AnythingLLM desktop supports MCP tools, but their docs note that desktop support is tools-focused and does not install required host commands automatically.

RoachNet should do better:

- detect missing MCP host commands
- offer install flows per OS
- validate tool health before enabling
- expose tools inside RoachClaw with native permission prompts

### 3. Agent skills

AnythingLLM custom skills are effectively an execution-extension model. RoachNet should provide:

- a native skill browser
- skill install/update/remove
- trust and permission controls
- local file and process sandbox policies

This should align OpenClaw skills, MCP tools, and RoachNet-native skills under one interface.

### 4. Desktop assistant

AnythingLLM's desktop assistant is one of the strongest ideas in the project.

RoachNet should build a native overlay assistant that can:

- open globally by hotkey
- chat with the selected RoachClaw model
- attach local context from files or clipboard
- run coding/dev workflows
- invoke skills and MCP tools

### 5. Provider flexibility

AnythingLLM shows the value of a provider-agnostic layer. RoachNet should keep:

- Ollama as the default local chat engine
- OpenClaw as the local agent/skill runtime
- optional LM Studio compatibility later
- optional remote providers only as secondary plug-ins

## Best integration model for RoachNet

### Recommended

Build an "AnythingLLM-style capability layer" inside RoachNet:

- native shell
- RoachClaw onboarding
- native chat/workbench
- native workspace/RAG manager
- native skill and MCP manager
- optional overlay assistant

### Optional later

Add an "AnythingLLM compatibility bridge":

- import workspace metadata
- connect to a local AnythingLLM endpoint if already installed
- reuse document stores or prompts where practical

### Not recommended

Do not replace RoachNet's native shell with the AnythingLLM frontend/server stack.

## Immediate implementation suggestions

1. Add RoachClaw Workspaces as a native feature area.
2. Add document ingestion and vectorized local knowledge stores.
3. Add MCP server management with automatic dependency detection and installation help.
4. Add a global native assistant overlay for chat, coding, and operator workflows.
5. Add advanced model controls in the native shell:
   - context window
   - temperature
   - keep-alive / unload policy
   - quantization-aware recommendations
   - per-workspace model defaults

## Source references

- GitHub repo: https://github.com/Mintplex-Labs/anything-llm
- Docs home: https://docs.anythingllm.com/
- Desktop system requirements: https://docs.anythingllm.com/installation-desktop/system-requirements
- Ollama setup: https://docs.anythingllm.com/setup/llm-configuration/local/ollama
- MCP on desktop: https://docs.anythingllm.com/mcp-compatibility/desktop
- Custom agent skills: https://docs.anythingllm.com/agent/custom/introduction
- Desktop assistant: https://docs.anythingllm.com/desktop-assistant/introduction
- Bare metal reference: https://github.com/Mintplex-Labs/anything-llm/blob/master/BARE_METAL.md
