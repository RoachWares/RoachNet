## RoachNet Setup

This directory contains the standalone installer application for RoachNet.

Purpose:
- ship `RoachNet Setup` as the only initial download
- detect machine hardware and prerequisites
- install and configure Docker, RoachClaw, and the RoachNet app
- hand off into the installed native `RoachNet` application
- remain disposable after setup is complete

Packaging entrypoints:
- `installer/main.cjs`
- `installer/preload.cjs`
- `installer/renderer/`
- `installer/builder.cjs`

The main desktop application remains under `desktop/`.
