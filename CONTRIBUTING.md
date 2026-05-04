# Contributing to RoachNet

RoachNet is being built into an offline-first command center with local AI, maps, content archives, and guided runtime management. Contributions are welcome, but they need to move the project toward that goal rather than back toward a generic Docker-only mirror of the imported upstream base.

## Before You Start

1. Open or review an issue first so the work is aligned before code lands.
2. Read [README.md](README.md), [docs/LOCAL_BOOT.md](docs/LOCAL_BOOT.md), and [docs/ROADMAP.md](docs/ROADMAP.md).
3. Keep privacy, offline capability, and local-first operation in mind when proposing changes.

## Development Priorities

Changes are especially valuable when they improve one of these areas:

- Apple Silicon performance and efficiency
- Local runtime management for Ollama and OpenClaw
- Guided onboarding and settings UX
- Offline content workflows
- Stability and clear diagnostics

## Local Setup

Follow the boot guide in [docs/LOCAL_BOOT.md](docs/LOCAL_BOOT.md). The current local development flow uses:

- Node.js 22
- MySQL
- Redis
- The `admin/` app for the current backend and Inertia UI

Apple Silicon contributors should prefer arm64-native tools and local AI runtimes where possible.

## Fork, Clone, and Remotes

Clone your fork:

```bash
git clone https://github.com/YOUR_USERNAME/RoachNet.git
cd RoachNet
```

Point `origin` at your fork and keep the main RoachNet repo as the primary sync target:

```bash
git remote add upstream https://github.com/RoachWares/RoachNet.git
```

If you are working on upstream-base synchronization, there is also a separate imported-source remote documented in [docs/UPSTREAM.md](docs/UPSTREAM.md).

## Workflow

1. Sync with the main branch before new work:

```bash
git fetch upstream
git checkout main
git rebase upstream/main
```

2. Create a focused branch:

```bash
git checkout -b feature/your-change
```

3. Make the change with a bias toward:

- native local runtimes over unnecessary container indirection
- Apple Silicon efficiency
- dark RoachNet brand styling
- maintainable, explicit code over clever shortcuts

4. Add release notes for user-facing changes in [admin/docs/release-notes.md](admin/docs/release-notes.md).

5. Test what you changed locally.

6. Push the branch and open a pull request.

## Commit Messages

Use Conventional Commits:

```text
<type>(<scope>): <description>
```

Examples:

```text
feat(ai): add OpenClaw provider diagnostics
fix(system): reduce hardware probe overhead on Apple Silicon
docs: refresh local boot guide for RoachNet branding
```

## Release Notes

Human-readable release notes live in [admin/docs/release-notes.md](admin/docs/release-notes.md).

When the change affects users, add an entry under `## Unreleased` using:

```markdown
- **Area**: Description
```

## Pull Requests

A good PR should include:

- what changed
- why it changed
- how it was tested
- any runtime or environment assumptions

If the change touches performance, call out the target hardware and whether Apple Silicon behavior was checked.

## Style and Scope

Please avoid changes that:

- reintroduce upstream branding
- assume Docker is the only valid runtime path
- add unnecessary network dependencies to offline workflows
- weaken local privacy guarantees without a strong reason

## Community

RoachNet coordination currently lives in the repository:

- Issues: [github.com/RoachWares/RoachNet/issues](https://github.com/RoachWares/RoachNet/issues)
- Discussions: [github.com/RoachWares/RoachNet/discussions](https://github.com/RoachWares/RoachNet/discussions)

RoachNet is licensed under the [Apache License 2.0](LICENSE).
