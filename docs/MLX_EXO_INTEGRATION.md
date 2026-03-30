# MLX And exo Integration Notes

Date: 2026-03-28

## Why MLX matters for RoachNet

Apple's MLX project is explicitly designed for efficient and flexible machine learning on Apple silicon.

The MLX docs highlight:

- Apple silicon focus
- lazy computation
- unified memory
- multi-device support
- distributed communication

That makes MLX the right optimization target for the macOS-native edition of RoachNet when we want to move beyond generic Ollama-only local inference.

## Why exo matters for RoachNet

The exo project positions itself as a multi-device local AI cluster.

Its upstream README currently highlights:

- automatic device discovery
- topology-aware auto-parallel planning
- tensor parallelism
- MLX as an inference backend
- MLX distributed for communication
- API compatibility with OpenAI, Claude, OpenAI Responses, and Ollama

This makes exo the best current reference for a future RoachNet multi-device mode, especially for Apple Silicon fleets.

## RoachNet integration stance

### MLX

Recommended:

- treat MLX as the preferred Apple-native acceleration path
- keep Ollama as the default general local runtime today
- add MLX-backed inference as an advanced Apple mode
- use mlx-lm for local LLM execution experiments and model-profile tuning

### exo

Recommended:

- treat exo as an optional distributed backend
- keep exo disabled by default on single-machine installs
- do not make exo the default single-device runtime
- expose exo cluster configuration in the native shell
- later add provider routing so RoachNet can talk to exo through its compatible APIs

## Immediate implementation phases

1. Native shell configuration and health probes
2. Apple Silicon MLX detection and onboarding
3. exo cluster endpoint and role management
4. model-provider routing layer for Ollama vs MLX vs exo
5. deeper Apple performance tuning

## Current repo status

RoachNet now includes:

- native persisted settings for MLX/exo preference in the desktop config
- native shell UI for Apple acceleration mode and exo cluster settings
- runtime probes for MLX, mlx-lm, and exo endpoint reachability
- single-machine guidance that keeps exo off unless the user explicitly enables cluster mode

RoachNet does not yet include:

- automatic MLX installation
- mlx-lm model execution inside the app
- native exo process orchestration
- provider routing that sends chat/generation requests into exo or MLX instead of Ollama

## Source references

- MLX docs: https://ml-explore.github.io/mlx/build/html/index.html
- MLX repo: https://github.com/ml-explore/mlx
- exo repo: https://github.com/exo-explore/exo
