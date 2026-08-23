# RoachNet Native UI Brief For Figma

This brief is the screen list and interaction scope to build once Figma edit access is available.

## Visual Direction

- dark modern interface
- RoachNet carbon-black base
- neon green primary actions
- magenta accent for focus and AI state
- bronze used sparingly for warm status and completion moments
- minimal always-visible copy
- one dominant action per screen
- motion should feel deliberate, not noisy

Reference mood:

- Arc
- Raycast
- Craft
- CleanShot
- IINA

## Setup App Screens

1. Welcome
   - headline only
   - one primary CTA
   - subtle system scan animation

2. Machine Check
   - hardware summary
   - prerequisites detected
   - one progress lane

3. Install Location
   - RoachNet install root
   - native app destination
   - advanced options hidden by default

4. Runtime Preparation
   - Docker/Desktop state
   - contained install explanation
   - progress-only view while work is active

5. RoachClaw
   - bundled Ollama + OpenClaw setup
   - default local-model path
   - recommended model card by hardware class

6. Finish
   - install complete
   - one primary CTA to open RoachNet
   - intro animation preview

## Main App Screens

1. Locked First-Run Gate
   - shown only before setup is complete
   - open setup CTA
   - no workbench content exposed

2. Command Deck Home
   - calm native dashboard
   - runtime state
   - RoachClaw status
   - launcher entry

3. AI Studio
   - models
   - chat
   - skills
   - acceleration profile

4. Knowledge Workspace
   - file ingestion
   - jobs
   - status

5. RoachCast
   - quick launcher
   - command search
   - suite actions

6. Intro Tour
   - post-install reveal
   - feature sequence
   - handoff into main dashboard

## Interaction Rules

- avoid long paragraphs
- show only the current step in setup
- keep sidebars supportive, not dominant
- avoid visible dev/runtime jargon during install unless the user opens advanced details
- keep scrolling contained inside panes
- never let critical content overflow the window bounds
