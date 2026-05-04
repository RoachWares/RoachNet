# Frequently Asked Questions

Answers to the common questions around RoachNet, its current runtime model, and the direction of the project.

## What is RoachNet?

RoachNet is an offline-first command center for maps, archives, local AI, and day-to-day utility workflows that need to keep running when the network is gone. The current codebase started from an open-source upstream base and is being adapted into a broader local operations platform with guided onboarding, user-managed agents and skills, and OpenClaw support.

## Can I run RoachNet on macOS or Apple Silicon?

Yes. Local development works on macOS, and Apple Silicon is now a first-class optimization target for local AI runtime guidance inside the app. For AI workloads, the preferred path on Apple Silicon is native local runtimes on loopback endpoints instead of Docker-managed AI containers.

## Does RoachNet still require Debian?

The legacy installer and management compose flow are still Debian-oriented because they came from the imported upstream base. That does not mean RoachNet itself is conceptually Debian-only. The current project direction is broader: local development on macOS is supported, and the runtime layer is being moved toward provider-based local execution rather than Docker-only assumptions.

## Do I need Docker to use RoachNet?

Not for every part of the platform. The imported management stack still uses Docker for some services, but RoachNet now detects local Ollama before falling back to a managed Docker runtime, and OpenClaw is being added through the same provider abstraction. The long-term direction is to prefer direct local runtimes where that improves reliability and performance.

## What AI runtimes are supported right now?

Ollama is fully wired for runtime discovery, model controls, chat access, and benchmarking. OpenClaw has an initial integration layer for endpoint discovery and health checks, and the next phase is guided onboarding plus agent and connector controls.

## What hardware works best?

The best current experience is:

- Apple Silicon with 16 GB or more of memory for local AI and content workflows
- Fast local SSD storage for maps, archives, and model files
- Native arm64 runtimes on Apple Silicon whenever possible

RoachNet now exposes an optimization profile in the System settings page so the app can recommend model size ranges and runtime posture from the actual machine it is running on.

## Can I customize ports and storage locations?

Yes. The imported compose-based stack is still configurable through its compose and environment files, and the local development setup is documented in [docs/LOCAL_BOOT.md](docs/LOCAL_BOOT.md). As RoachNet moves further toward native local runtime management, more of these settings will be surfaced directly in the UI.

## Is RoachNet only for AI?

No. Local AI is one subsystem. The broader goal is an all-in-one offline toolkit that keeps maps, documents, learning resources, and operational utilities available without depending on a live internet connection.

## What languages does the UI support?

The current UI is English-first. Internationalization is still a future enhancement.

## Is RoachNet free and open source?

Yes. The project remains open source under the Apache License 2.0.

## Where should I report bugs or request features?

Use the RoachNet repository:

- Issues: [github.com/RoachWares/RoachNet/issues](https://github.com/RoachWares/RoachNet/issues)
- Discussions: [github.com/RoachWares/RoachNet/discussions](https://github.com/RoachWares/RoachNet/discussions)

## Where should I look before opening a bug?

Start with:

- [README.md](README.md)
- [docs/LOCAL_BOOT.md](docs/LOCAL_BOOT.md)
- [docs/SURFACE_MAP.md](docs/SURFACE_MAP.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
